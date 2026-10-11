//! Port of `Telemetry/TelemetryStore.swift`: the SQLite store of AI runs,
//! their turns and tool calls, plus the iOS client events.
//!
//! Same schema, column names and text encodings as Swift (ISO 8601 dates
//! with milliseconds, JSON for tags, metadata and per-turn tool calls), so a
//! Chau7 Next database could be read by the Swift app. Chau7 Next keeps its
//! own file (`DataRoot::telemetry_db`).
//!
//! Swift serializes every access on one queue; here one mutex guards the
//! connection, so the store can be shared between threads.

use std::collections::HashMap;
use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use parking_lot_free::Mutex;
use rusqlite::types::Value as SqlValue;
use rusqlite::{Connection, OptionalExtension, Row, params, params_from_iter};
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value};

use super::date_codec;
use super::remote_client_event::RemoteClientTelemetryEvent;
use super::run::{TelemetryRun, TelemetryRunFilter};
use super::token_metrics::TelemetryMetricState;
use super::turn::{TelemetryToolCall, TelemetryTurn, ToolCallStatus};
use crate::debug_console::DailyRunCost;
use crate::token_optimization::{ProviderConsumptionStats, TabTokenConsumption};

/// `std::sync::Mutex` without poisoning noise.
mod parking_lot_free {
    pub struct Mutex<T>(std::sync::Mutex<T>);

    impl<T> Mutex<T> {
        pub fn new(value: T) -> Self {
            Self(std::sync::Mutex::new(value))
        }

        pub fn lock(&self) -> std::sync::MutexGuard<'_, T> {
            self.0.lock().unwrap_or_else(|e| e.into_inner())
        }
    }
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS runs (
    run_id TEXT PRIMARY KEY,
    session_id TEXT,
    tab_id TEXT,
    provider TEXT NOT NULL,
    model TEXT,
    cwd TEXT NOT NULL,
    repo_path TEXT,
    started_at TEXT NOT NULL,
    ended_at TEXT,
    duration_ms INTEGER,
    exit_status INTEGER,
    total_input_tokens INTEGER,
    total_cached_input_tokens INTEGER,
    total_output_tokens INTEGER,
    total_reasoning_output_tokens INTEGER,
    cost_usd REAL,
    token_usage_source TEXT,
    token_usage_state TEXT,
    cost_source TEXT,
    cost_state TEXT,
    turn_count INTEGER DEFAULT 0,
    tags TEXT,
    metadata TEXT,
    raw_transcript_ref TEXT,
    parent_run_id TEXT,
    error_message TEXT,
    created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE INDEX IF NOT EXISTS idx_runs_session ON runs(session_id);
CREATE INDEX IF NOT EXISTS idx_runs_repo ON runs(repo_path);
CREATE INDEX IF NOT EXISTS idx_runs_provider ON runs(provider);
CREATE INDEX IF NOT EXISTS idx_runs_started ON runs(started_at);
CREATE INDEX IF NOT EXISTS idx_runs_tab ON runs(tab_id);

CREATE TABLE IF NOT EXISTS turns (
    turn_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    turn_index INTEGER NOT NULL,
    role TEXT NOT NULL,
    content TEXT,
    input_tokens INTEGER,
    cached_input_tokens INTEGER,
    output_tokens INTEGER,
    reasoning_output_tokens INTEGER,
    tool_calls TEXT,
    timestamp TEXT,
    duration_ms INTEGER
);

CREATE INDEX IF NOT EXISTS idx_turns_run ON turns(run_id, turn_index);

CREATE TABLE IF NOT EXISTS tool_calls (
    call_id TEXT PRIMARY KEY,
    run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
    turn_id TEXT NOT NULL REFERENCES turns(turn_id) ON DELETE CASCADE,
    tool_name TEXT NOT NULL,
    arguments TEXT,
    result TEXT,
    status TEXT,
    duration_ms INTEGER,
    call_index INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_tool_calls_run ON tool_calls(run_id);
CREATE INDEX IF NOT EXISTS idx_tool_calls_name ON tool_calls(tool_name);

CREATE TABLE IF NOT EXISTS schema_version (
    version INTEGER PRIMARY KEY,
    applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE IF NOT EXISTS remote_client_events (
    event_id TEXT PRIMARY KEY,
    source TEXT NOT NULL,
    device_id TEXT,
    device_name TEXT,
    app_version TEXT NOT NULL,
    session_id TEXT,
    event_type TEXT NOT NULL,
    status TEXT,
    tab_id INTEGER,
    tab_title TEXT,
    message TEXT,
    metadata TEXT,
    timestamp TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_remote_client_events_time
    ON remote_client_events(timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_remote_client_events_device
    ON remote_client_events(device_id);
CREATE INDEX IF NOT EXISTS idx_remote_client_events_session
    ON remote_client_events(session_id);
CREATE INDEX IF NOT EXISTS idx_remote_client_events_type
    ON remote_client_events(event_type);

INSERT OR IGNORE INTO schema_version (version) VALUES (1);
";

/// Fills the metric states of rows written before they existed.
const BACKFILL_STATES: &str = "
UPDATE runs
SET token_usage_state = COALESCE(token_usage_state,
    CASE
        WHEN total_input_tokens IS NULL
             AND total_cached_input_tokens IS NULL
             AND total_output_tokens IS NULL
             AND total_reasoning_output_tokens IS NULL
        THEN 'missing'
        ELSE 'complete'
    END
),
cost_state = COALESCE(cost_state,
    CASE WHEN cost_usd IS NULL THEN 'missing' ELSE 'complete' END
),
cost_source = COALESCE(cost_source,
    CASE WHEN cost_usd IS NULL THEN 'unavailable' ELSE 'observed' END
)";

/// TEL-007: the sanity rule, applied again to old rows at every open.
const INVALIDATE_IMPLAUSIBLE: &str = "
UPDATE runs
SET total_input_tokens = NULL,
    total_cached_input_tokens = NULL,
    total_output_tokens = NULL,
    total_reasoning_output_tokens = NULL,
    cost_usd = NULL,
    token_usage_source = NULL,
    token_usage_state = 'invalid',
    cost_source = 'unavailable',
    cost_state = 'missing',
    error_message = COALESCE(error_message, 'invalidated historical telemetry metrics that exceeded sanity thresholds')
WHERE COALESCE(total_input_tokens, 0) > 100000000
   OR COALESCE(total_cached_input_tokens, 0) > 100000000
   OR COALESCE(total_output_tokens, 0) > 100000000
   OR COALESCE(total_reasoning_output_tokens, 0) > 100000000
   OR (
        COALESCE(total_input_tokens, 0) +
        COALESCE(total_cached_input_tokens, 0) +
        COALESCE(total_output_tokens, 0) +
        COALESCE(total_reasoning_output_tokens, 0)
      ) > 150000000";

/// Aggregate run numbers of a repository (`runStatsForRepo`).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct RepoRunStats {
    pub total_runs: i64,
    pub total_tokens: i64,
    pub total_cost: f64,
    pub total_turns: i64,
    pub last_run_at: Option<DateTime<Utc>>,
}

/// The telemetry database.
pub struct TelemetryStore {
    conn: Mutex<Option<Connection>>,
    path: Option<PathBuf>,
}

/// A Swift raw value (`rawValue`) of a string enum.
fn raw<T: Serialize>(value: &T) -> Option<String> {
    match serde_json::to_value(value) {
        Ok(Value::String(s)) => Some(s),
        _ => None,
    }
}

fn from_raw<T: DeserializeOwned>(text: Option<String>) -> Option<T> {
    serde_json::from_value(Value::String(text?)).ok()
}

fn iso(date: &DateTime<Utc>) -> String {
    date_codec::format_iso8601_fractional(date)
}

fn parse_date(text: Option<String>) -> Option<DateTime<Utc>> {
    date_codec::parse_iso8601(text.as_deref())
}

fn encode_json<T: Serialize>(value: &T) -> Option<String> {
    serde_json::to_string(value).ok()
}

fn decode_json<T: DeserializeOwned>(text: Option<String>) -> Option<T> {
    serde_json::from_str(&text?).ok()
}

/// A column by name, `None` when absent or NULL.
fn col<T: rusqlite::types::FromSql>(row: &Row, name: &str) -> Option<T> {
    row.get::<_, Option<T>>(name).ok().flatten()
}

fn parse_run(row: &Row) -> Option<TelemetryRun> {
    let id: String = col(row, "run_id")?;
    let provider: String = col(row, "provider")?;
    let cwd: String = col(row, "cwd")?;
    let started_at = parse_date(col(row, "started_at"))?;
    let mut run = TelemetryRun::new(provider, cwd);
    run.id = id;
    run.session_id = col(row, "session_id");
    run.tab_id = col(row, "tab_id");
    run.model = col(row, "model");
    run.repo_path = col(row, "repo_path");
    run.started_at = started_at;
    run.ended_at = parse_date(col(row, "ended_at"));
    run.duration_ms = col(row, "duration_ms");
    run.exit_status = col(row, "exit_status");
    run.total_input_tokens = col(row, "total_input_tokens");
    run.total_cached_input_tokens = col(row, "total_cached_input_tokens");
    run.total_output_tokens = col(row, "total_output_tokens");
    run.total_reasoning_output_tokens = col(row, "total_reasoning_output_tokens");
    run.cost_usd = col(row, "cost_usd");
    run.token_usage_source = from_raw(col(row, "token_usage_source"));
    run.token_usage_state =
        from_raw(col(row, "token_usage_state")).unwrap_or(TelemetryMetricState::Missing);
    run.cost_source = from_raw(col(row, "cost_source"));
    run.cost_state = from_raw(col(row, "cost_state")).unwrap_or(TelemetryMetricState::Missing);
    run.turn_count = col(row, "turn_count").unwrap_or(0);
    run.tags = decode_json(col(row, "tags")).unwrap_or_default();
    run.metadata = decode_json(col(row, "metadata")).unwrap_or_default();
    run.raw_transcript_ref = col(row, "raw_transcript_ref");
    run.parent_run_id = col(row, "parent_run_id");
    run.error_message = col(row, "error_message");
    Some(run)
}

fn parse_turn(row: &Row) -> Option<TelemetryTurn> {
    let id: String = col(row, "turn_id")?;
    let run_id: String = col(row, "run_id")?;
    let role = from_raw(col(row, "role"))?;
    let mut turn = TelemetryTurn::new(run_id, col(row, "turn_index").unwrap_or(0), role);
    turn.id = id;
    turn.content = col(row, "content");
    turn.input_tokens = col(row, "input_tokens");
    turn.cached_input_tokens = col(row, "cached_input_tokens");
    turn.output_tokens = col(row, "output_tokens");
    turn.reasoning_output_tokens = col(row, "reasoning_output_tokens");
    turn.tool_calls = decode_json(col(row, "tool_calls")).unwrap_or_default();
    turn.timestamp = parse_date(col(row, "timestamp"));
    turn.duration_ms = col(row, "duration_ms");
    Some(turn)
}

fn parse_tool_call(row: &Row) -> TelemetryToolCall {
    let mut call = TelemetryToolCall::new(
        col::<String>(row, "run_id").unwrap_or_default(),
        col::<String>(row, "turn_id").unwrap_or_default(),
        col::<String>(row, "tool_name").unwrap_or_default(),
    );
    if let Some(id) = col(row, "call_id") {
        call.id = id;
    }
    call.arguments = col(row, "arguments");
    call.result = col(row, "result");
    call.status = from_raw(col(row, "status")).unwrap_or(ToolCallStatus::Success);
    call.duration_ms = col(row, "duration_ms");
    call.call_index = col(row, "call_index").unwrap_or(0);
    call
}

fn parse_remote_event(row: &Row) -> Option<RemoteClientTelemetryEvent> {
    let id: String = col(row, "event_id")?;
    let source: String = col(row, "source")?;
    let app_version: String = col(row, "app_version")?;
    let event_type = from_raw(col(row, "event_type"))?;
    let timestamp = parse_date(col(row, "timestamp"))?;
    let mut event = RemoteClientTelemetryEvent::new(app_version, event_type);
    event.id = id;
    event.source = source;
    event.device_id = col(row, "device_id");
    event.device_name = col(row, "device_name");
    event.session_id = col(row, "session_id");
    event.status = col(row, "status");
    event.tab_id = col::<i64>(row, "tab_id").map(|v| v as u32);
    event.tab_title = col(row, "tab_title");
    event.message = col(row, "message");
    event.metadata =
        decode_json::<HashMap<String, String>>(col(row, "metadata")).unwrap_or_default();
    event.timestamp = timestamp;
    Some(event)
}

const PRICED: &str = "SUM(CASE WHEN COALESCE(cost_state, 'missing') IN ('complete', 'estimated') AND cost_usd IS NOT NULL THEN 1 ELSE 0 END)";
const MISSING_COST: &str = "SUM(CASE WHEN COALESCE(cost_state, 'missing') = 'missing' OR cost_usd IS NULL THEN 1 ELSE 0 END)";

impl TelemetryStore {
    /// Open (or create) the store at `path`. A database that fails
    /// `PRAGMA quick_check` is deleted and created again (TEL-008).
    pub fn open(path: &Path) -> Self {
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let mut conn = match Connection::open(path) {
            Ok(conn) => Some(conn),
            Err(err) => {
                log::error!(
                    "TelemetryStore: failed to open database at {}: {err}",
                    path.display()
                );
                None
            }
        };
        if let Some(c) = &conn {
            configure(c);
            if !integrity_ok(c) {
                log::error!("TelemetryStore: database integrity check failed, recreating it");
                drop(conn.take());
                let _ = std::fs::remove_file(path);
                let _ = std::fs::remove_file(path.with_extension("db-wal"));
                let _ = std::fs::remove_file(path.with_extension("db-shm"));
                conn = Connection::open(path).ok();
                if let Some(c) = &conn {
                    configure(c);
                    log::info!("TelemetryStore: recreated database after corruption");
                }
            }
        }
        if let Some(c) = &conn {
            setup(c);
        }
        Self {
            conn: Mutex::new(conn),
            path: Some(path.to_path_buf()),
        }
    }

    /// A throwaway store (tests).
    pub fn in_memory() -> Self {
        let conn = Connection::open_in_memory().ok();
        if let Some(c) = &conn {
            configure(c);
            setup(c);
        }
        Self {
            conn: Mutex::new(conn),
            path: None,
        }
    }

    /// Where the database lives (`None` in memory).
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    fn with<T>(&self, fallback: T, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> T {
        let guard = self.conn.lock();
        let Some(conn) = guard.as_ref() else {
            return fallback;
        };
        match f(conn) {
            Ok(value) => value,
            Err(err) => {
                log::warn!("TelemetryStore: {err}");
                fallback
            }
        }
    }

    // MARK: write

    /// Insert a new run (`INSERT OR IGNORE`: safe to call twice).
    pub fn insert_run(&self, run: &TelemetryRun) {
        self.with((), |c| {
            c.execute(
                "INSERT OR IGNORE INTO runs
                (run_id, session_id, tab_id, provider, model, cwd, repo_path,
                 started_at, ended_at, duration_ms, exit_status,
                 total_input_tokens, total_cached_input_tokens, total_output_tokens, total_reasoning_output_tokens,
                 cost_usd, token_usage_source, token_usage_state, cost_source, cost_state,
                 turn_count, tags, metadata, raw_transcript_ref, parent_run_id, error_message)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
                params![
                    run.id,
                    run.session_id,
                    run.tab_id,
                    run.provider,
                    run.model,
                    run.cwd,
                    run.repo_path,
                    iso(&run.started_at),
                    run.ended_at.as_ref().map(iso),
                    run.duration_ms,
                    run.exit_status,
                    run.total_input_tokens,
                    run.total_cached_input_tokens,
                    run.total_output_tokens,
                    run.total_reasoning_output_tokens,
                    run.cost_usd,
                    run.token_usage_source.as_ref().and_then(raw),
                    raw(&run.token_usage_state),
                    run.cost_source.as_ref().and_then(raw),
                    raw(&run.cost_state),
                    run.turn_count,
                    encode_json(&run.tags),
                    encode_json(&run.metadata),
                    run.raw_transcript_ref,
                    run.parent_run_id,
                    run.error_message,
                ],
            )
            .map(|_| ())
        });
    }

    /// Finish a run: update its row and add its turns and tool calls in one
    /// transaction (UPDATE, never delete and insert, so children survive).
    pub fn finalize_run(
        &self,
        run: &TelemetryRun,
        turns: &[TelemetryTurn],
        tool_calls: &[TelemetryToolCall],
    ) {
        self.with((), |c| {
            let tx = c.unchecked_transaction()?;
            tx.execute(
                "UPDATE runs SET
                    session_id = ?, model = ?, ended_at = ?, duration_ms = ?, exit_status = ?,
                    total_input_tokens = ?, total_cached_input_tokens = ?, total_output_tokens = ?,
                    total_reasoning_output_tokens = ?, cost_usd = ?, token_usage_source = ?,
                    token_usage_state = ?, cost_source = ?, cost_state = ?,
                    turn_count = ?, raw_transcript_ref = ?, error_message = ?
                WHERE run_id = ?",
                params![
                    run.session_id,
                    run.model,
                    run.ended_at.as_ref().map(iso),
                    run.duration_ms,
                    run.exit_status,
                    run.total_input_tokens,
                    run.total_cached_input_tokens,
                    run.total_output_tokens,
                    run.total_reasoning_output_tokens,
                    run.cost_usd,
                    run.token_usage_source.as_ref().and_then(raw),
                    raw(&run.token_usage_state),
                    run.cost_source.as_ref().and_then(raw),
                    raw(&run.cost_state),
                    run.turn_count,
                    run.raw_transcript_ref,
                    run.error_message,
                    run.id,
                ],
            )?;
            for turn in turns {
                insert_turn(&tx, turn);
            }
            for call in tool_calls {
                insert_tool_call(&tx, call);
            }
            tx.commit()
        });
    }

    /// Replace everything about a finished run (transcript repair).
    pub fn rewrite_completed_run(
        &self,
        run: &TelemetryRun,
        turns: &[TelemetryTurn],
        tool_calls: &[TelemetryToolCall],
    ) {
        self.with((), |c| {
            let tx = c.unchecked_transaction()?;
            tx.execute("DELETE FROM tool_calls WHERE run_id = ?", [&run.id])?;
            tx.execute("DELETE FROM turns WHERE run_id = ?", [&run.id])?;
            tx.execute(
                "UPDATE runs SET
                    session_id = ?, tab_id = ?, provider = ?, model = ?, cwd = ?, repo_path = ?,
                    started_at = ?, ended_at = ?, duration_ms = ?, exit_status = ?,
                    total_input_tokens = ?, total_cached_input_tokens = ?, total_output_tokens = ?,
                    total_reasoning_output_tokens = ?, cost_usd = ?, token_usage_source = ?,
                    token_usage_state = ?, cost_source = ?, cost_state = ?, turn_count = ?,
                    tags = ?, metadata = ?, raw_transcript_ref = ?, parent_run_id = ?, error_message = ?
                WHERE run_id = ?",
                params![
                    run.session_id,
                    run.tab_id,
                    run.provider,
                    run.model,
                    run.cwd,
                    run.repo_path,
                    iso(&run.started_at),
                    run.ended_at.as_ref().map(iso),
                    run.duration_ms,
                    run.exit_status,
                    run.total_input_tokens,
                    run.total_cached_input_tokens,
                    run.total_output_tokens,
                    run.total_reasoning_output_tokens,
                    run.cost_usd,
                    run.token_usage_source.as_ref().and_then(raw),
                    raw(&run.token_usage_state),
                    run.cost_source.as_ref().and_then(raw),
                    raw(&run.cost_state),
                    run.turn_count,
                    encode_json(&run.tags),
                    encode_json(&run.metadata),
                    run.raw_transcript_ref,
                    run.parent_run_id,
                    run.error_message,
                    run.id,
                ],
            )?;
            for turn in turns {
                insert_turn(&tx, turn);
            }
            for call in tool_calls {
                insert_tool_call(&tx, call);
            }
            tx.commit()
        });
    }

    /// Clear a run's tokens and cost and mark them invalid.
    pub fn invalidate_run_metrics(&self, run_id: &str, reason: Option<&str>) {
        self.with((), |c| {
            c.execute(
                "UPDATE runs
                SET total_input_tokens = NULL,
                    total_cached_input_tokens = NULL,
                    total_output_tokens = NULL,
                    total_reasoning_output_tokens = NULL,
                    cost_usd = NULL,
                    token_usage_source = NULL,
                    token_usage_state = 'invalid',
                    cost_source = 'unavailable',
                    cost_state = 'missing',
                    error_message = COALESCE(?, error_message)
                WHERE run_id = ?",
                params![reason, run_id],
            )
            .map(|_| ())
        });
    }

    pub fn insert_turns(&self, turns: &[TelemetryTurn]) {
        self.with((), |c| {
            for turn in turns {
                insert_turn(c, turn);
            }
            Ok(())
        });
    }

    pub fn insert_tool_calls(&self, calls: &[TelemetryToolCall]) {
        self.with((), |c| {
            for call in calls {
                insert_tool_call(c, call);
            }
            Ok(())
        });
    }

    pub fn update_run_session_id(&self, run_id: &str, session_id: &str) {
        self.with((), |c| {
            c.execute(
                "UPDATE runs SET session_id = ? WHERE run_id = ?",
                params![session_id, run_id],
            )
            .map(|_| ())
        });
    }

    /// TEL-009: replace a run's tags (JSON array).
    pub fn update_run_tags(&self, run_id: &str, tags: &[String]) {
        self.with((), |c| {
            c.execute(
                "UPDATE runs SET tags = ? WHERE run_id = ?",
                params![encode_json(&tags), run_id],
            )
            .map(|_| ())
        });
    }

    /// TEL-015: one event from the paired iPhone.
    pub fn insert_remote_client_event(&self, event: &RemoteClientTelemetryEvent) {
        self.with((), |c| {
            c.execute(
                "INSERT OR IGNORE INTO remote_client_events
                (event_id, source, device_id, device_name, app_version, session_id,
                 event_type, status, tab_id, tab_title, message, metadata, timestamp)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)",
                params![
                    event.id,
                    event.source,
                    event.device_id,
                    event.device_name,
                    event.app_version,
                    event.session_id,
                    raw(&event.event_type),
                    event.status,
                    event.tab_id.map(i64::from),
                    event.tab_title,
                    event.message,
                    encode_json(&event.metadata),
                    iso(&event.timestamp),
                ],
            )
            .map(|_| ())
        });
    }

    pub fn list_remote_client_events(&self, limit: usize) -> Vec<RemoteClientTelemetryEvent> {
        self.with(Vec::new(), |c| {
            let mut stmt =
                c.prepare("SELECT * FROM remote_client_events ORDER BY timestamp DESC LIMIT ?")?;
            let rows = stmt.query_map([limit as i64], |row| Ok(parse_remote_event(row)))?;
            Ok(rows.filter_map(|r| r.ok().flatten()).collect())
        })
    }

    // MARK: read

    pub fn get_run(&self, run_id: &str) -> Option<TelemetryRun> {
        self.with(None, |c| {
            c.query_row("SELECT * FROM runs WHERE run_id = ?", [run_id], |row| {
                Ok(parse_run(row))
            })
            .optional()
            .map(Option::flatten)
        })
    }

    /// Runs matching `filter`, newest first. Like Swift, `tags` is not a
    /// database filter.
    pub fn list_runs(&self, filter: &TelemetryRunFilter) -> Vec<TelemetryRun> {
        let mut clauses = Vec::new();
        let mut values: Vec<String> = Vec::new();
        if let Some(v) = &filter.session_id {
            clauses.push("session_id = ?");
            values.push(v.clone());
        }
        if let Some(v) = &filter.repo_path {
            clauses.push("repo_path = ?");
            values.push(v.clone());
        }
        if let Some(v) = &filter.provider {
            clauses.push("provider = ?");
            values.push(v.clone());
        }
        if let Some(v) = &filter.after {
            clauses.push("started_at >= ?");
            values.push(iso(v));
        }
        if let Some(v) = &filter.before {
            clauses.push("started_at <= ?");
            values.push(iso(v));
        }
        let mut sql = "SELECT * FROM runs".to_string();
        if !clauses.is_empty() {
            sql.push_str(" WHERE ");
            sql.push_str(&clauses.join(" AND "));
        }
        sql.push_str(" ORDER BY started_at DESC");
        if let Some(limit) = filter.limit {
            sql.push_str(&format!(" LIMIT {limit}"));
            if let Some(offset) = filter.offset {
                sql.push_str(&format!(" OFFSET {offset}"));
            }
        }
        self.with(Vec::new(), |c| {
            let mut stmt = c.prepare(&sql)?;
            let rows = stmt.query_map(params_from_iter(values.iter()), |row| Ok(parse_run(row)))?;
            Ok(rows.filter_map(|r| r.ok().flatten()).collect())
        })
    }

    pub fn get_turns(&self, run_id: &str) -> Vec<TelemetryTurn> {
        self.with(Vec::new(), |c| {
            let mut stmt = c.prepare("SELECT * FROM turns WHERE run_id = ? ORDER BY turn_index")?;
            let rows = stmt.query_map([run_id], |row| Ok(parse_turn(row)))?;
            Ok(rows.filter_map(|r| r.ok().flatten()).collect())
        })
    }

    pub fn get_tool_calls(&self, run_id: &str) -> Vec<TelemetryToolCall> {
        self.with(Vec::new(), |c| {
            let mut stmt =
                c.prepare("SELECT * FROM tool_calls WHERE run_id = ? ORDER BY call_index")?;
            let rows = stmt.query_map([run_id], |row| Ok(parse_tool_call(row)))?;
            Ok(rows.filter_map(Result::ok).collect())
        })
    }

    /// Tool calls of a run by name, most used first (`toolCallSummary`).
    pub fn tool_call_summary(&self, run_id: &str) -> Vec<(String, i64)> {
        self.with(Vec::new(), |c| {
            let mut stmt = c.prepare(
                "SELECT tool_name, COUNT(*) as cnt FROM tool_calls
                 WHERE run_id = ? GROUP BY tool_name ORDER BY cnt DESC",
            )?;
            let rows = stmt.query_map([run_id], |r| Ok((r.get(0)?, r.get(1)?)))?;
            Ok(rows.filter_map(Result::ok).collect())
        })
    }

    /// `runStatsForRepo`.
    pub fn run_stats_for_repo(&self, repo_path: &str) -> RepoRunStats {
        self.with(RepoRunStats::default(), |c| {
            c.query_row(
                "SELECT COUNT(*),
                        COALESCE(SUM(total_input_tokens + total_output_tokens), 0),
                        COALESCE(SUM(cost_usd), 0),
                        COALESCE(SUM(turn_count), 0),
                        MAX(started_at)
                 FROM runs WHERE repo_path = ?",
                [repo_path],
                |r| {
                    Ok(RepoRunStats {
                        total_runs: r.get(0)?,
                        total_tokens: r.get(1)?,
                        total_cost: r.get(2)?,
                        total_turns: r.get(3)?,
                        last_run_at: parse_date(r.get(4)?),
                    })
                },
            )
        })
    }

    /// Distinct providers used in a repository, sorted.
    pub fn providers_for_repo(&self, repo_path: &str) -> Vec<String> {
        self.with(Vec::new(), |c| {
            let mut stmt = c.prepare(
                "SELECT DISTINCT provider FROM runs WHERE repo_path = ? ORDER BY provider",
            )?;
            let rows = stmt.query_map([repo_path], |r| r.get(0))?;
            Ok(rows.filter_map(Result::ok).collect())
        })
    }

    /// Most used tools across a repository's runs.
    pub fn tool_call_distribution_for_repo(
        &self,
        repo_path: &str,
        limit: usize,
    ) -> Vec<(String, i64)> {
        self.with(Vec::new(), |c| {
            let mut stmt = c.prepare(
                "SELECT tc.tool_name, COUNT(*) as cnt FROM tool_calls tc
                 JOIN runs r ON tc.run_id = r.run_id
                 WHERE r.repo_path = ?
                 GROUP BY tc.tool_name ORDER BY cnt DESC LIMIT ?",
            )?;
            let rows = stmt.query_map(params![repo_path, limit as i64], |r| {
                Ok((r.get(0)?, r.get(1)?))
            })?;
            Ok(rows.filter_map(Result::ok).collect())
        })
    }

    pub fn latest_run_for_repo(
        &self,
        repo_path: &str,
        provider: Option<&str>,
    ) -> Option<TelemetryRun> {
        let mut sql = "SELECT * FROM runs WHERE repo_path = ?".to_string();
        let mut values = vec![repo_path.to_string()];
        if let Some(p) = provider {
            sql.push_str(" AND provider = ?");
            values.push(p.to_string());
        }
        sql.push_str(" ORDER BY started_at DESC LIMIT 1");
        self.with(None, |c| {
            c.query_row(&sql, params_from_iter(values.iter()), |row| {
                Ok(parse_run(row))
            })
            .optional()
            .map(Option::flatten)
        })
    }

    /// AI sessions with their latest provider and repository, run count and
    /// last activity, most recent first (`listSessions`).
    pub fn list_sessions(&self, repo_path: Option<&str>) -> Vec<Map<String, Value>> {
        let mut sql = "WITH filtered_runs AS (
                SELECT * FROM runs WHERE session_id IS NOT NULL"
            .to_string();
        let mut values = Vec::new();
        if let Some(rp) = repo_path {
            sql.push_str(" AND repo_path = ?");
            values.push(rp.to_string());
        }
        sql.push_str(
            "),
            session_rollup AS (
                SELECT session_id, COUNT(*) AS run_count, MAX(started_at) AS last_active
                FROM filtered_runs GROUP BY session_id
            )
            SELECT session_rollup.session_id,
                   (SELECT provider FROM filtered_runs latest
                    WHERE latest.session_id = session_rollup.session_id
                      AND latest.provider IS NOT NULL
                    ORDER BY latest.started_at DESC, latest.created_at DESC LIMIT 1) AS provider,
                   (SELECT repo_path FROM filtered_runs latest
                    WHERE latest.session_id = session_rollup.session_id
                      AND latest.repo_path IS NOT NULL
                    ORDER BY latest.started_at DESC, latest.created_at DESC LIMIT 1) AS repo_path,
                   session_rollup.run_count,
                   session_rollup.last_active
            FROM session_rollup
            ORDER BY session_rollup.last_active DESC",
        );
        self.with(Vec::new(), |c| {
            let mut stmt = c.prepare(&sql)?;
            let rows = stmt.query_map(params_from_iter(values.iter()), |r| {
                let text = |i: usize| -> String {
                    r.get::<_, Option<String>>(i)
                        .ok()
                        .flatten()
                        .unwrap_or_default()
                };
                let mut map = Map::new();
                map.insert("session_id".into(), Value::String(text(0)));
                map.insert("provider".into(), Value::String(text(1)));
                map.insert("repo_path".into(), Value::String(text(2)));
                map.insert("run_count".into(), Value::from(r.get::<_, i64>(3)?));
                map.insert("last_active".into(), Value::String(text(4)));
                Ok(map)
            })?;
            Ok(rows.filter_map(Result::ok).collect())
        })
    }

    pub fn run_count(&self) -> i64 {
        self.with(0, |c| {
            c.query_row("SELECT COUNT(*) FROM runs", [], |r| r.get(0))
        })
    }

    // MARK: aggregates (TEL-013)

    /// Token use per tab, most tokens first (`tokenUsagePerTab`).
    pub fn token_usage_per_tab(&self, after: Option<DateTime<Utc>>) -> Vec<TabTokenConsumption> {
        let mut sql = "WITH filtered_runs AS (
                SELECT * FROM runs
                WHERE tab_id IS NOT NULL
                  AND COALESCE(token_usage_state, 'missing') != 'invalid'"
            .to_string();
        if after.is_some() {
            sql.push_str(" AND started_at >= ?");
        }
        sql.push_str(&format!(
            "),
            tab_rollup AS (
                SELECT tab_id,
                       COUNT(*) AS run_count,
                       {PRICED} AS priced_run_count,
                       {MISSING_COST} AS missing_cost_run_count,
                       COALESCE(SUM(total_input_tokens),0) AS total_input_tokens,
                       COALESCE(SUM(total_cached_input_tokens),0) AS total_cached_input_tokens,
                       COALESCE(SUM(total_output_tokens),0) AS total_output_tokens,
                       COALESCE(SUM(total_reasoning_output_tokens),0) AS total_reasoning_output_tokens,
                       COALESCE(SUM(cost_usd),0) AS total_cost_usd
                FROM filtered_runs GROUP BY tab_id
            ),
            latest_run_key AS (
                SELECT tab_id, MAX(started_at || '|' || created_at || '|' || run_id) AS latest_key
                FROM filtered_runs GROUP BY tab_id
            ),
            latest_per_tab AS (
                SELECT filtered_runs.tab_id,
                       filtered_runs.provider AS last_provider,
                       COALESCE(filtered_runs.repo_path, filtered_runs.cwd) AS last_location_path
                FROM filtered_runs
                INNER JOIN latest_run_key
                    ON latest_run_key.tab_id = filtered_runs.tab_id
                    AND (filtered_runs.started_at || '|' || filtered_runs.created_at || '|' || filtered_runs.run_id) = latest_run_key.latest_key
            )
            SELECT tab_rollup.tab_id, tab_rollup.run_count, tab_rollup.priced_run_count,
                   tab_rollup.missing_cost_run_count, tab_rollup.total_input_tokens,
                   tab_rollup.total_cached_input_tokens, tab_rollup.total_output_tokens,
                   tab_rollup.total_reasoning_output_tokens, tab_rollup.total_cost_usd,
                   latest_per_tab.last_provider, latest_per_tab.last_location_path
            FROM tab_rollup
            LEFT JOIN latest_per_tab ON latest_per_tab.tab_id = tab_rollup.tab_id
            ORDER BY tab_rollup.total_input_tokens + tab_rollup.total_cached_input_tokens +
                tab_rollup.total_output_tokens + tab_rollup.total_reasoning_output_tokens DESC"
        ));
        let values: Vec<String> = after.iter().map(iso).collect();
        self.with(Vec::new(), |c| {
            let mut stmt = c.prepare(&sql)?;
            let rows = stmt.query_map(params_from_iter(values.iter()), |r| {
                let mut t = TabTokenConsumption::new(
                    &r.get::<_, String>(0)?,
                    r.get(1)?,
                    r.get(4)?,
                    r.get(6)?,
                    r.get(8)?,
                );
                t.priced_run_count = r.get(2)?;
                t.missing_cost_run_count = r.get(3)?;
                t.total_cached_input_tokens = r.get(5)?;
                t.total_reasoning_output_tokens = r.get(7)?;
                t.last_provider = r.get(9)?;
                t.last_location_path = r.get(10)?;
                Ok(t)
            })?;
            Ok(rows.filter_map(Result::ok).collect())
        })
    }

    /// Token use per provider, most expensive first (`consumptionPerProvider`).
    pub fn consumption_per_provider(
        &self,
        after: Option<DateTime<Utc>>,
    ) -> Vec<ProviderConsumptionStats> {
        let mut sql = format!(
            "SELECT provider, COUNT(*), {PRICED}, {MISSING_COST},
                   COALESCE(SUM(total_input_tokens),0),
                   COALESCE(SUM(total_cached_input_tokens),0),
                   COALESCE(SUM(total_output_tokens),0),
                   COALESCE(SUM(total_reasoning_output_tokens),0),
                   COALESCE(SUM(cost_usd),0)
            FROM runs WHERE provider IS NOT NULL
              AND COALESCE(token_usage_state, 'missing') != 'invalid'"
        );
        if after.is_some() {
            sql.push_str(" AND started_at >= ?");
        }
        sql.push_str(" GROUP BY provider ORDER BY COALESCE(SUM(cost_usd),0) DESC");
        let values: Vec<String> = after.iter().map(iso).collect();
        self.with(Vec::new(), |c| {
            let mut stmt = c.prepare(&sql)?;
            let rows = stmt.query_map(params_from_iter(values.iter()), |r| {
                let mut p = ProviderConsumptionStats::new(
                    &r.get::<_, String>(0)?,
                    r.get(1)?,
                    r.get(4)?,
                    r.get(6)?,
                    r.get(8)?,
                );
                p.priced_run_count = r.get(2)?;
                p.missing_cost_run_count = r.get(3)?;
                p.total_cached_input_tokens = r.get(5)?;
                p.total_reasoning_output_tokens = r.get(7)?;
                Ok(p)
            })?;
            Ok(rows.filter_map(Result::ok).collect())
        })
    }

    /// Cost and tokens per day over the last `days` (1 to 90).
    pub fn daily_cost_trend(&self, days: i64) -> Vec<DailyRunCost> {
        let days = days.clamp(1, 90);
        let sql = format!(
            "SELECT date(started_at) as day, COUNT(*), {PRICED},
                   COALESCE(SUM(cost_usd), 0),
                   COALESCE(SUM(total_input_tokens), 0) +
                   COALESCE(SUM(total_cached_input_tokens), 0) +
                   COALESCE(SUM(total_output_tokens), 0) +
                   COALESCE(SUM(total_reasoning_output_tokens), 0)
            FROM runs
            WHERE started_at >= date('now', '-{days} days')
              AND COALESCE(token_usage_state, 'missing') != 'invalid'
            GROUP BY day ORDER BY day"
        );
        self.with(Vec::new(), |c| {
            let mut stmt = c.prepare(&sql)?;
            let rows = stmt.query_map([], |r| {
                Ok(DailyRunCost {
                    date: r.get(0)?,
                    total_run_count: r.get(1)?,
                    priced_run_count: r.get(2)?,
                    cost: r.get(3)?,
                    tokens: r.get(4)?,
                })
            })?;
            Ok(rows.filter_map(Result::ok).collect())
        })
    }

    /// Raw rows of a query (tests and diagnostics).
    #[doc(hidden)]
    pub fn query_values(&self, sql: &str) -> Vec<Vec<SqlValue>> {
        self.with(Vec::new(), |c| {
            let mut stmt = c.prepare(sql)?;
            let n = stmt.column_count();
            let rows = stmt.query_map([], |r| (0..n).map(|i| r.get::<_, SqlValue>(i)).collect())?;
            Ok(rows.filter_map(Result::ok).collect())
        })
    }

    #[doc(hidden)]
    pub fn execute_raw(&self, sql: &str) {
        self.with((), |c| c.execute_batch(sql));
    }

    /// Apply the open-time migrations again (tests of TEL-007).
    #[doc(hidden)]
    pub fn reapply_migrations(&self) {
        self.with((), |c| {
            migrate(c);
            Ok(())
        });
    }
}

fn configure(conn: &Connection) {
    let _: Option<String> = conn
        .query_row("PRAGMA journal_mode=WAL", [], |r| r.get(0))
        .optional()
        .ok()
        .flatten();
    let _ = conn.execute_batch("PRAGMA foreign_keys=ON");
}

fn integrity_ok(conn: &Connection) -> bool {
    match conn.query_row("PRAGMA quick_check", [], |r| r.get::<_, String>(0)) {
        Ok(result) => result == "ok",
        Err(err) => {
            log::error!("TelemetryStore: quick_check failed: {err}");
            false
        }
    }
}

fn setup(conn: &Connection) {
    if let Err(err) = conn.execute_batch(SCHEMA) {
        log::error!("TelemetryStore: schema creation failed: {err}");
    }
    migrate(conn);
}

fn migrate(conn: &Connection) {
    for (table, name, definition) in [
        ("runs", "total_cached_input_tokens", "INTEGER"),
        ("runs", "total_reasoning_output_tokens", "INTEGER"),
        ("runs", "token_usage_source", "TEXT"),
        ("runs", "token_usage_state", "TEXT"),
        ("runs", "cost_source", "TEXT"),
        ("runs", "cost_state", "TEXT"),
        ("turns", "cached_input_tokens", "INTEGER"),
        ("turns", "reasoning_output_tokens", "INTEGER"),
    ] {
        ensure_column(conn, table, name, definition);
    }
    let _ = conn.execute_batch(BACKFILL_STATES);
    let _ = conn.execute_batch(INVALIDATE_IMPLAUSIBLE);
}

fn ensure_column(conn: &Connection, table: &str, name: &str, definition: &str) {
    let exists = conn
        .prepare(&format!("PRAGMA table_info({table})"))
        .and_then(|mut stmt| {
            let names = stmt.query_map([], |r| r.get::<_, String>(1))?;
            Ok(names.filter_map(Result::ok).any(|n| n == name))
        })
        .unwrap_or(true);
    if !exists
        && conn
            .execute_batch(&format!(
                "ALTER TABLE {table} ADD COLUMN {name} {definition}"
            ))
            .is_err()
    {
        log::warn!("TelemetryStore: failed to add column {table}.{name}");
    }
}

fn insert_turn(conn: &Connection, turn: &TelemetryTurn) {
    if let Err(err) = conn.execute(
        "INSERT OR IGNORE INTO turns
        (turn_id, run_id, turn_index, role, content, input_tokens, cached_input_tokens, output_tokens,
         reasoning_output_tokens, tool_calls, timestamp, duration_ms)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)",
        params![
            turn.id,
            turn.run_id,
            turn.turn_index,
            raw(&turn.role),
            turn.content,
            turn.input_tokens,
            turn.cached_input_tokens,
            turn.output_tokens,
            turn.reasoning_output_tokens,
            encode_json(&turn.tool_calls),
            turn.timestamp.as_ref().map(iso),
            turn.duration_ms,
        ],
    ) {
        log::warn!("TelemetryStore: insert turn failed for {}: {err}", turn.id);
    }
}

fn insert_tool_call(conn: &Connection, call: &TelemetryToolCall) {
    if let Err(err) = conn.execute(
        "INSERT OR IGNORE INTO tool_calls
        (call_id, run_id, turn_id, tool_name, arguments, result, status, duration_ms, call_index)
        VALUES (?,?,?,?,?,?,?,?,?)",
        params![
            call.id,
            call.run_id,
            call.turn_id,
            call.tool_name,
            call.arguments,
            call.result,
            raw(&call.status),
            call.duration_ms,
            call.call_index,
        ],
    ) {
        log::warn!(
            "TelemetryStore: insert tool_call failed for {}: {err}",
            call.id
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::telemetry::token_metrics::{CostSource, TokenUsageSource};
    use crate::telemetry::turn::TurnRole;
    use chrono::Duration;

    fn run(provider: &str, repo: Option<&str>, tab: Option<&str>) -> TelemetryRun {
        let mut run = TelemetryRun::new(provider, repo.unwrap_or("/tmp"));
        run.repo_path = repo.map(str::to_string);
        run.tab_id = tab.map(str::to_string);
        run
    }

    #[test]
    fn insert_finalize_and_read_back() {
        let store = TelemetryStore::in_memory();
        let mut r = run("claude", Some("/repo"), Some("TAB"));
        r.tags = vec!["control".into()];
        r.metadata.insert("k".into(), "v".into());
        store.insert_run(&r);
        store.insert_run(&r); // OR IGNORE

        let mut turn = TelemetryTurn::new(&r.id, 0, TurnRole::Assistant);
        turn.content = Some("hello".into());
        let mut call = TelemetryToolCall::new(&r.id, &turn.id, "Read");
        call.call_index = 0;
        turn.tool_calls.push(call.clone());
        let mut call2 = TelemetryToolCall::new(&r.id, &turn.id, "Read");
        call2.call_index = 1;
        let mut call3 = TelemetryToolCall::new(&r.id, &turn.id, "Bash");
        call3.call_index = 2;

        r.ended_at = Some(r.started_at + Duration::seconds(3));
        r.duration_ms = Some(3000);
        r.exit_status = Some(0);
        r.model = Some("claude-x".into());
        r.total_input_tokens = Some(100);
        r.total_output_tokens = Some(50);
        r.cost_usd = Some(0.5);
        r.cost_state = TelemetryMetricState::Complete;
        r.cost_source = Some(CostSource::Observed);
        r.token_usage_state = TelemetryMetricState::Complete;
        r.token_usage_source = Some(TokenUsageSource::TranscriptDelta);
        r.turn_count = 1;
        store.finalize_run(&r, &[turn.clone()], &[call, call2, call3]);

        let back = store.get_run(&r.id).unwrap();
        assert_eq!(back.model.as_deref(), Some("claude-x"));
        assert_eq!(back.tags, vec!["control".to_string()]);
        assert_eq!(back.metadata.get("k").map(String::as_str), Some("v"));
        assert_eq!(
            back.token_usage_source,
            Some(TokenUsageSource::TranscriptDelta)
        );
        assert_eq!(back.duration_ms, Some(3000));
        assert_eq!(
            back.started_at.timestamp_millis(),
            r.started_at.timestamp_millis()
        );
        let turns = store.get_turns(&r.id);
        assert_eq!(turns.len(), 1);
        assert_eq!(turns[0].tool_calls.len(), 1);
        assert_eq!(store.get_tool_calls(&r.id).len(), 3);
        assert_eq!(
            store.tool_call_summary(&r.id),
            vec![("Read".to_string(), 2), ("Bash".to_string(), 1)]
        );

        let stats = store.run_stats_for_repo("/repo");
        assert_eq!(stats.total_runs, 1);
        assert_eq!(stats.total_tokens, 150);
        assert_eq!(stats.total_turns, 1);
        assert!(stats.last_run_at.is_some());
        assert_eq!(
            store.providers_for_repo("/repo"),
            vec!["claude".to_string()]
        );
        assert_eq!(
            store.tool_call_distribution_for_repo("/repo", 1),
            vec![("Read".to_string(), 2)]
        );
        assert_eq!(
            store
                .latest_run_for_repo("/repo", Some("claude"))
                .unwrap()
                .id,
            r.id
        );
        assert!(store.latest_run_for_repo("/repo", Some("codex")).is_none());
        assert_eq!(store.run_count(), 1);

        store.update_run_tags(&r.id, &["a".into(), "b".into()]);
        assert_eq!(store.get_run(&r.id).unwrap().tags, vec!["a", "b"]);
        store.update_run_session_id(&r.id, "S1");
        let sessions = store.list_sessions(None);
        assert_eq!(sessions.len(), 1);
        assert_eq!(sessions[0]["session_id"], "S1");
        assert_eq!(sessions[0]["provider"], "claude");
        assert_eq!(sessions[0]["run_count"], 1);
        assert!(store.list_sessions(Some("/other")).is_empty());
    }

    #[test]
    fn list_runs_filters_and_pages() {
        let store = TelemetryStore::in_memory();
        let now = Utc::now();
        for i in 0..5 {
            let mut r = run(
                if i % 2 == 0 { "claude" } else { "codex" },
                Some("/r"),
                None,
            );
            r.started_at = now - Duration::minutes(i);
            store.insert_run(&r);
        }
        let all = store.list_runs(&TelemetryRunFilter::default());
        assert_eq!(all.len(), 5);
        assert!(all[0].started_at >= all[1].started_at);
        let claude = store.list_runs(&TelemetryRunFilter {
            provider: Some("claude".into()),
            ..Default::default()
        });
        assert_eq!(claude.len(), 3);
        let page = store.list_runs(&TelemetryRunFilter {
            limit: Some(2),
            offset: Some(1),
            ..Default::default()
        });
        assert_eq!(page.len(), 2);
        assert_eq!(page[0].id, all[1].id);
        let recent = store.list_runs(&TelemetryRunFilter {
            after: Some(now - Duration::seconds(90)),
            ..Default::default()
        });
        assert_eq!(recent.len(), 2);
    }

    #[test]
    fn aggregates_skip_invalid_runs_and_count_priced() {
        let store = TelemetryStore::in_memory();
        let mut a = run("claude", Some("/r"), Some("T1"));
        a.total_input_tokens = Some(10);
        a.total_output_tokens = Some(5);
        a.cost_usd = Some(1.0);
        a.cost_state = TelemetryMetricState::Complete;
        a.token_usage_state = TelemetryMetricState::Complete;
        store.insert_run(&a);
        let mut b = run("claude", Some("/r"), Some("T1"));
        b.total_input_tokens = Some(20);
        b.token_usage_state = TelemetryMetricState::Complete;
        store.insert_run(&b);
        let mut c = run("codex", Some("/r"), Some("T2"));
        c.token_usage_state = TelemetryMetricState::Invalid;
        store.insert_run(&c);

        let tabs = store.token_usage_per_tab(None);
        assert_eq!(tabs.len(), 1);
        assert_eq!(tabs[0].tab_id, "T1");
        assert_eq!(tabs[0].run_count, 2);
        assert_eq!(tabs[0].priced_run_count, 1);
        assert_eq!(tabs[0].missing_cost_run_count, 1);
        assert_eq!(tabs[0].total_input_tokens, 30);
        assert_eq!(tabs[0].last_provider.as_deref(), Some("claude"));
        assert_eq!(tabs[0].last_location_path.as_deref(), Some("/r"));

        let providers = store.consumption_per_provider(None);
        assert_eq!(providers.len(), 1);
        assert_eq!(providers[0].provider, "claude");
        assert!((providers[0].total_cost_usd - 1.0).abs() < 1e-9);

        let daily = store.daily_cost_trend(7);
        assert_eq!(daily.len(), 1);
        assert_eq!(daily[0].total_run_count, 2);
        assert_eq!(daily[0].priced_run_count, 1);
        assert_eq!(daily[0].tokens, 35);

        let future = store.token_usage_per_tab(Some(Utc::now() + Duration::hours(1)));
        assert!(future.is_empty());
    }

    #[test]
    fn migrations_invalidate_implausible_rows() {
        let store = TelemetryStore::in_memory();
        let mut r = run("codex", None, None);
        r.total_input_tokens = Some(120_000_000);
        r.cost_usd = Some(3.0);
        store.insert_run(&r);
        store.reapply_migrations();
        let back = store.get_run(&r.id).unwrap();
        assert_eq!(back.token_usage_state, TelemetryMetricState::Invalid);
        assert_eq!(back.total_input_tokens, None);
        assert_eq!(back.cost_usd, None);
        assert_eq!(back.cost_source, Some(CostSource::Unavailable));
        assert!(back.error_message.unwrap().contains("sanity thresholds"));

        // Old rows without states get them filled.
        store.execute_raw(
            "INSERT INTO runs (run_id, provider, cwd, started_at, cost_usd) VALUES ('old', 'claude', '/', '2026-01-01T00:00:00.000Z', 1.5)",
        );
        store.reapply_migrations();
        let old = store.get_run("old").unwrap();
        assert_eq!(old.token_usage_state, TelemetryMetricState::Missing);
        assert_eq!(old.cost_state, TelemetryMetricState::Complete);
        assert_eq!(old.cost_source, Some(CostSource::Observed));
    }

    #[test]
    fn rewrite_and_invalidate() {
        let store = TelemetryStore::in_memory();
        let mut r = run("claude", None, None);
        store.insert_run(&r);
        let t1 = TelemetryTurn::new(&r.id, 0, TurnRole::Human);
        store.finalize_run(&r, &[t1], &[]);
        r.model = Some("m2".into());
        let t2 = TelemetryTurn::new(&r.id, 0, TurnRole::Assistant);
        let t3 = TelemetryTurn::new(&r.id, 1, TurnRole::Assistant);
        store.rewrite_completed_run(&r, &[t2, t3], &[]);
        assert_eq!(store.get_turns(&r.id).len(), 2);
        assert_eq!(store.get_run(&r.id).unwrap().model.as_deref(), Some("m2"));
        store.invalidate_run_metrics(&r.id, Some("why"));
        let back = store.get_run(&r.id).unwrap();
        assert_eq!(back.token_usage_state, TelemetryMetricState::Invalid);
        assert_eq!(back.error_message.as_deref(), Some("why"));
    }

    #[test]
    fn remote_client_events_round_trip() {
        use crate::telemetry::remote_client_event::RemoteClientTelemetryEventType as T;
        let store = TelemetryStore::in_memory();
        let mut e = RemoteClientTelemetryEvent::new("1.0", T::TabSwitched);
        e.tab_id = Some(3);
        e.metadata.insert("a".into(), "b".into());
        store.insert_remote_client_event(&e);
        let back = store.list_remote_client_events(10);
        assert_eq!(back.len(), 1);
        assert_eq!(back[0].event_type, T::TabSwitched);
        assert_eq!(back[0].tab_id, Some(3));
        assert_eq!(back[0].metadata.get("a").map(String::as_str), Some("b"));
    }

    #[test]
    fn corrupt_file_is_recreated() {
        let dir = std::env::temp_dir().join(format!("chau7-next-tel-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("runs.db");
        std::fs::write(
            &path,
            b"this is not a database at all, not even close......",
        )
        .unwrap();
        let store = TelemetryStore::open(&path);
        store.insert_run(&run("claude", None, None));
        assert_eq!(store.run_count(), 1);
        drop(store);
        let again = TelemetryStore::open(&path);
        assert_eq!(again.run_count(), 1);
        let _ = std::fs::remove_dir_all(dir);
    }
}
