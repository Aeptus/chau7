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
    total_cache_creation_input_tokens INTEGER,
    total_cache_read_input_tokens INTEGER,
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
    cache_creation_input_tokens INTEGER,
    cache_read_input_tokens INTEGER,
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

CREATE TABLE IF NOT EXISTS provider_latency_samples (
    ingest_seq INTEGER PRIMARY KEY AUTOINCREMENT,
    sample_id TEXT NOT NULL UNIQUE,
    provider TEXT NOT NULL,
    metric_kind TEXT NOT NULL,
    latency_ms INTEGER NOT NULL,
    model TEXT,
    session_id TEXT,
    run_id TEXT,
    round_index INTEGER,
    project_path TEXT,
    source_kind TEXT NOT NULL,
    observed_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_provider_latency_samples_time ON provider_latency_samples(observed_at);
CREATE INDEX IF NOT EXISTS idx_provider_latency_samples_provider ON provider_latency_samples(provider,metric_kind,observed_at);
CREATE TABLE IF NOT EXISTS proxy_run_baselines (run_id TEXT PRIMARY KEY REFERENCES runs(run_id) ON DELETE CASCADE,snapshot TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS usage_evidence (
 ingest_seq INTEGER PRIMARY KEY AUTOINCREMENT,evidence_id TEXT NOT NULL UNIQUE,unique_event_key TEXT NOT NULL UNIQUE,reconciliation_key TEXT NOT NULL,source_kind TEXT NOT NULL,provider TEXT NOT NULL,model TEXT,session_id TEXT,run_id TEXT,endpoint TEXT,project_path TEXT,input_tokens INTEGER,cache_creation_input_tokens INTEGER,cache_read_input_tokens INTEGER,output_tokens INTEGER,reasoning_output_tokens INTEGER,cost_usd REAL,token_usage_source TEXT,token_usage_state TEXT NOT NULL,cost_source TEXT,cost_state TEXT NOT NULL,pricing_version TEXT,source_ref TEXT,metadata TEXT,observed_at TEXT NOT NULL,payload TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_usage_evidence_provider ON usage_evidence(provider,observed_at);
CREATE INDEX IF NOT EXISTS idx_usage_evidence_reconciliation ON usage_evidence(reconciliation_key,source_kind);
CREATE INDEX IF NOT EXISTS idx_usage_evidence_run ON usage_evidence(run_id);
CREATE INDEX IF NOT EXISTS idx_usage_evidence_observed ON usage_evidence(observed_at);
CREATE TABLE IF NOT EXISTS maintenance_state (name TEXT PRIMARY KEY, cursor TEXT NOT NULL);
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
    total_cached_input_tokens = NULL, total_cache_creation_input_tokens = NULL, total_cache_read_input_tokens = NULL,
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
    pub raw_run_cost: f64,
    pub retained_proxy_cost: f64,
    pub attributed_proxy_cost: f64,
    pub priced_run_count: i64,
    pub estimated_run_count: i64,
    pub missing_cost_run_count: i64,
    pub partial_run_count: i64,
    pub priced_proxy_request_count: i64,
    pub missing_cost_proxy_request_count: i64,
    pub total_turns: i64,
    pub last_run_at: Option<DateTime<Utc>>,
}

/// Memory-only initialization state. Reading this never takes the SQLite lock.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum StoreReadiness {
    Loading,
    Ready,
    Failed,
    Closed,
}
impl StoreReadiness {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Loading => "loading",
            Self::Ready => "ready",
            Self::Failed => "failed",
            Self::Closed => "closed",
        }
    }
}

/// The telemetry database. Synchronous SQL access is for background callers.
pub struct TelemetryStore {
    conn: Mutex<Option<Connection>>,
    path: Option<PathBuf>,
    failures: std::sync::atomic::AtomicU64,
    readiness: std::sync::atomic::AtomicU8,
    initialization: std::sync::Mutex<()>,
    initialized: std::sync::Condvar,
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

fn insert_latency(
    conn: &Connection,
    sample: &super::latency::LatencySample,
) -> rusqlite::Result<()> {
    if sample.latency_ms < 0 || sample.provider.is_empty() {
        return Ok(());
    }
    conn.execute("INSERT INTO provider_latency_samples (sample_id,provider,metric_kind,latency_ms,model,session_id,run_id,round_index,project_path,source_kind,observed_at) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11) ON CONFLICT(sample_id) DO UPDATE SET provider=excluded.provider,metric_kind=excluded.metric_kind,latency_ms=excluded.latency_ms,model=excluded.model,session_id=excluded.session_id,run_id=excluded.run_id,round_index=excluded.round_index,project_path=excluded.project_path,source_kind=excluded.source_kind,observed_at=excluded.observed_at", params![sample.id,sample.provider,match sample.metric_kind {super::latency::MetricKind::ApiRequest=>"api_request",super::latency::MetricKind::FirstResponse=>"first_response"},sample.latency_ms,sample.model,sample.session_id,sample.run_id,sample.round_index,sample.project_path,sample.source_kind,iso(&sample.timestamp)])?;
    Ok(())
}
fn replace_completed_latency(
    conn: &Connection,
    run: &TelemetryRun,
    turns: &[TelemetryTurn],
) -> rusqlite::Result<()> {
    conn.execute("DELETE FROM provider_latency_samples WHERE run_id=?1 AND source_kind='completed_run_turns'",[&run.id])?;
    for sample in super::latency::completed_samples(run, turns) {
        insert_latency(conn, &sample)?;
    }
    Ok(())
}

fn insert_evidence(conn: &Connection, e: &super::evidence::UsageEvidence) -> rusqlite::Result<()> {
    conn.execute("INSERT INTO usage_evidence(evidence_id,unique_event_key,reconciliation_key,source_kind,provider,model,session_id,run_id,endpoint,project_path,input_tokens,cache_creation_input_tokens,cache_read_input_tokens,output_tokens,reasoning_output_tokens,cost_usd,token_usage_source,token_usage_state,cost_source,cost_state,pricing_version,source_ref,metadata,observed_at,payload) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24,?25) ON CONFLICT(unique_event_key) DO UPDATE SET reconciliation_key=excluded.reconciliation_key,source_kind=excluded.source_kind,provider=excluded.provider,model=excluded.model,session_id=excluded.session_id,run_id=excluded.run_id,endpoint=excluded.endpoint,project_path=excluded.project_path,input_tokens=excluded.input_tokens,cache_creation_input_tokens=excluded.cache_creation_input_tokens,cache_read_input_tokens=excluded.cache_read_input_tokens,output_tokens=excluded.output_tokens,reasoning_output_tokens=excluded.reasoning_output_tokens,cost_usd=excluded.cost_usd,token_usage_source=excluded.token_usage_source,token_usage_state=excluded.token_usage_state,cost_source=excluded.cost_source,cost_state=excluded.cost_state,pricing_version=excluded.pricing_version,source_ref=excluded.source_ref,metadata=excluded.metadata,observed_at=excluded.observed_at,payload=excluded.payload",params![e.id,e.unique_event_key,e.reconciliation_key,raw(&e.source_kind),e.provider,e.model,e.session_id,e.run_id,e.endpoint,e.project_path,e.input_tokens,e.cache_creation_input_tokens,e.cache_read_input_tokens,e.output_tokens,e.reasoning_output_tokens,e.cost_usd,e.token_usage_source.as_ref().and_then(raw),raw(&e.token_usage_state),e.cost_source.as_ref().and_then(raw),raw(&e.cost_state),e.pricing_version,e.source_ref,encode_json(&e.metadata),iso(&e.observed_at),encode_json(e)])?;
    Ok(())
}
fn update_run_usage(conn: &Connection, run: &TelemetryRun) -> rusqlite::Result<()> {
    conn.execute("UPDATE runs SET total_input_tokens=?1,total_cached_input_tokens=?2,total_cache_creation_input_tokens=?3,total_cache_read_input_tokens=?4,total_output_tokens=?5,total_reasoning_output_tokens=?6,cost_usd=?7,token_usage_source=?8,token_usage_state=?9,cost_source=?10,cost_state=?11,metadata=?12 WHERE run_id=?13",params![run.total_input_tokens,run.total_cached_input_tokens,run.total_cache_creation_input_tokens,run.total_cache_read_input_tokens,run.total_output_tokens,run.total_reasoning_output_tokens,run.cost_usd,run.token_usage_source.as_ref().and_then(raw),raw(&run.token_usage_state),run.cost_source.as_ref().and_then(raw),raw(&run.cost_state),encode_json(&run.metadata),run.id])?;
    insert_evidence(conn, &super::evidence::UsageEvidence::run_summary(run))
}
fn restore_baseline(mut run: TelemetryRun, baseline: TelemetryRun) -> TelemetryRun {
    run.total_input_tokens = baseline.total_input_tokens;
    run.total_cached_input_tokens = baseline.total_cached_input_tokens;
    run.total_cache_creation_input_tokens = baseline.total_cache_creation_input_tokens;
    run.total_cache_read_input_tokens = baseline.total_cache_read_input_tokens;
    run.total_output_tokens = baseline.total_output_tokens;
    run.total_reasoning_output_tokens = baseline.total_reasoning_output_tokens;
    run.cost_usd = baseline.cost_usd;
    run.token_usage_source = baseline.token_usage_source;
    run.token_usage_state = baseline.token_usage_state;
    run.cost_source = baseline.cost_source;
    run.cost_state = baseline.cost_state;
    run.metadata.retain(|key, _| !key.starts_with("proxy_"));
    run
}
fn reconcile_proxy_window(conn: &Connection, at: DateTime<Utc>) -> rusqlite::Result<bool> {
    use super::evidence::{apply_attribution, attributed};
    fn runs(
        conn: &Connection,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> rusqlite::Result<Vec<TelemetryRun>> {
        let mut stmt=conn.prepare("SELECT * FROM runs WHERE julianday(started_at)<=julianday(?1) AND (ended_at IS NULL OR julianday(ended_at)>=julianday(?2)) LIMIT 501")?;
        let rows = stmt.query_map(
            params![
                iso(&(end + chrono::Duration::seconds(1))),
                iso(&(start - chrono::Duration::seconds(1)))
            ],
            |row| Ok(parse_run(row)),
        )?;
        rows.filter_map(|r| r.transpose()).collect()
    }
    let candidates = runs(conn, at, at)?;
    if candidates.is_empty() {
        return Ok(true);
    }
    if candidates.len() > 500 {
        return Ok(false);
    }
    let start = candidates.iter().map(|r| r.started_at).min().unwrap();
    let end = candidates
        .iter()
        .map(|r| r.ended_at.unwrap_or_else(Utc::now))
        .max()
        .unwrap();
    let candidates = runs(conn, start, end)?;
    if candidates.len() > 500 {
        return Ok(false);
    }
    let mut stmt=conn.prepare("SELECT payload FROM usage_evidence WHERE source_kind='proxy' AND unique_event_key NOT LIKE 'run|%' AND julianday(observed_at)>=julianday(?1) AND julianday(observed_at)<=julianday(?2) ORDER BY observed_at,ingest_seq LIMIT 5001")?;
    let observations: Vec<_> = stmt
        .query_map(
            params![
                iso(&(start - chrono::Duration::seconds(1))),
                iso(&(end + chrono::Duration::seconds(1)))
            ],
            |row| {
                let json: String = row.get(0)?;
                Ok(serde_json::from_str::<super::evidence::UsageEvidence>(&json).ok())
            },
        )?
        .filter_map(|r| r.transpose())
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if observations.len() > 5000 {
        return Ok(false);
    }
    let attributed = attributed(&observations, &candidates);
    for run in candidates {
        if let Some(a) = attributed.get(&run.id) {
            if run.token_usage_source != Some(super::token_metrics::TokenUsageSource::Proxy) {
                conn.execute("INSERT INTO proxy_run_baselines(run_id,snapshot) VALUES (?1,?2) ON CONFLICT(run_id) DO UPDATE SET snapshot=excluded.snapshot",params![run.id,encode_json(&run)])?;
            }
            update_run_usage(conn, &apply_attribution(&run, a))?;
        } else if run.token_usage_source == Some(super::token_metrics::TokenUsageSource::Proxy) {
            let json: Option<String> = conn
                .query_row(
                    "SELECT snapshot FROM proxy_run_baselines WHERE run_id=?1",
                    [&run.id],
                    |r| r.get(0),
                )
                .optional()?;
            let baseline = json
                .and_then(|j| serde_json::from_str(&j).ok())
                .unwrap_or_else(|| TelemetryRun::new(&run.provider, &run.cwd));
            update_run_usage(conn, &restore_baseline(run, baseline))?;
        }
    }
    Ok(true)
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
    run.total_cache_creation_input_tokens = col(row, "total_cache_creation_input_tokens");
    run.total_cache_read_input_tokens = col(row, "total_cache_read_input_tokens");
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
    turn.cache_creation_input_tokens = col(row, "cache_creation_input_tokens");
    turn.cache_read_input_tokens = col(row, "cache_read_input_tokens");
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

struct InitializationGuard<'a>(&'a TelemetryStore);
impl Drop for InitializationGuard<'_> {
    fn drop(&mut self) {
        // A failed or unwinding initializer must wake readers rather than leave
        // them waiting forever. No SQLite handle is created or closed on UI.
        self.0.fail_initialization();
    }
}

impl TelemetryStore {
    /// A memory-only placeholder; no directories, files or SQL are touched.
    pub(super) fn pending(path: &Path) -> Self {
        Self {
            conn: Mutex::new(None),
            path: Some(path.to_owned()),
            failures: Default::default(),
            readiness: std::sync::atomic::AtomicU8::new(0),
            initialization: std::sync::Mutex::new(()),
            initialized: std::sync::Condvar::new(),
        }
    }
    pub fn readiness(&self) -> StoreReadiness {
        match self.readiness.load(std::sync::atomic::Ordering::Acquire) {
            0 => StoreReadiness::Loading,
            1 => StoreReadiness::Ready,
            2 => StoreReadiness::Failed,
            _ => StoreReadiness::Closed,
        }
    }
    fn publish_readiness(&self, state: StoreReadiness) {
        let _held = self
            .initialization
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        self.readiness.store(
            match state {
                StoreReadiness::Loading => 0,
                StoreReadiness::Ready => 1,
                StoreReadiness::Failed => 2,
                StoreReadiness::Closed => 3,
            },
            std::sync::atomic::Ordering::Release,
        );
        self.initialized.notify_all();
    }
    pub(super) fn fail_initialization(&self) {
        if self.readiness() == StoreReadiness::Loading {
            self.record_failure();
            self.publish_readiness(StoreReadiness::Failed);
        }
    }
    /// Background-only readiness barrier. UI uses the atomic snapshot instead.
    pub fn wait_until_initialized(&self) -> rusqlite::Result<()> {
        let mut held = self
            .initialization
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        while self.readiness() == StoreReadiness::Loading {
            held = self
                .initialized
                .wait(held)
                .unwrap_or_else(|e| e.into_inner());
        }
        if self.readiness() == StoreReadiness::Ready {
            Ok(())
        } else {
            Err(rusqlite::Error::InvalidQuery)
        }
    }
    /// First ordered writer job: open/check/migrate before admitted run writes.
    pub(super) fn initialize_background(&self) -> rusqlite::Result<()> {
        let _guard = InitializationGuard(self);
        let path = self.path.as_deref().ok_or(rusqlite::Error::InvalidQuery)?;
        let connection = open_checked(path)?;
        let mut held = self.conn.lock();
        if self.readiness() != StoreReadiness::Loading {
            return Err(rusqlite::Error::InvalidQuery);
        }
        *held = Some(connection);
        self.publish_readiness(StoreReadiness::Ready);
        Ok(())
    }
    /// Open (or create) the store at `path`. Only confirmed corruption
    /// permits deleting and recreating the database (TEL-008); ambiguous
    /// integrity, I/O and schema failures preserve it and report Failed.
    pub fn open(path: &Path) -> Self {
        let store = Self::pending(path);
        if let Err(error) = store.initialize_background() {
            log::warn!("Telemetry store initialization failed: {error}");
        }
        store
    }

    /// A throwaway store (tests).
    pub fn in_memory() -> Self {
        let conn = Connection::open_in_memory()
            .and_then(|connection| {
                configure_checked(&connection)?;
                setup_checked(&connection)?;
                Ok(connection)
            })
            .ok();
        let ready = conn.is_some();
        Self {
            conn: Mutex::new(conn),
            path: None,
            failures: Default::default(),
            readiness: std::sync::atomic::AtomicU8::new(if ready { 1 } else { 2 }),
            initialization: std::sync::Mutex::new(()),
            initialized: std::sync::Condvar::new(),
        }
    }

    /// Where the database lives (`None` in memory).
    pub fn path(&self) -> Option<&Path> {
        self.path.as_deref()
    }

    fn with<T>(&self, fallback: T, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> T {
        if self.wait_until_initialized().is_err() {
            self.record_failure();
            return fallback;
        }
        let guard = self.conn.lock();
        let Some(conn) = guard.as_ref() else {
            self.record_failure();
            return fallback;
        };
        match f(conn) {
            Ok(value) => value,
            Err(err) => {
                self.record_failure();
                log::warn!("TelemetryStore: {err}");
                fallback
            }
        }
    }

    /// Monotonic diagnostic count: background snapshot readers refuse to
    /// publish fallback zeros as fresh SQL data when any read failed.
    /// Close the actual connection after all accepted producers/readers have
    /// drained. This method can wait for background SQL and must never run on UI.
    pub fn close(&self) -> rusqlite::Result<()> {
        self.close_using(|connection| connection.close().map_err(Box::new))
    }
    fn close_using(
        &self,
        close: impl FnOnce(Connection) -> Result<(), Box<(Connection, rusqlite::Error)>>,
    ) -> rusqlite::Result<()> {
        let mut held = self.conn.lock();
        let Some(connection) = held.take() else {
            self.publish_readiness(StoreReadiness::Closed);
            return Ok(());
        };
        match close(connection) {
            Ok(()) => {
                self.publish_readiness(StoreReadiness::Closed);
                Ok(())
            }
            Err(returned) => {
                let (connection, error) = *returned;
                *held = Some(connection);
                self.record_failure();
                Err(error)
            }
        }
    }
    pub fn failure_count(&self) -> u64 {
        self.failures.load(std::sync::atomic::Ordering::Relaxed)
    }
    fn record_failure(&self) {
        let _ = self.failures.try_update(
            std::sync::atomic::Ordering::Relaxed,
            std::sync::atomic::Ordering::Relaxed,
            |value| Some(value.saturating_add(1)),
        );
    }
    #[cfg(test)]
    pub(super) fn hold_connection_test(
        &self,
        started: std::sync::mpsc::Sender<()>,
        release: std::sync::mpsc::Receiver<()>,
    ) {
        let _guard = self.conn.lock();
        started.send(()).unwrap();
        release.recv().unwrap();
    }
    fn with_result<T>(
        &self,
        f: impl FnOnce(&Connection) -> rusqlite::Result<T>,
    ) -> rusqlite::Result<T> {
        if let Err(error) = self.wait_until_initialized() {
            self.record_failure();
            return Err(error);
        }
        let guard = self.conn.lock();
        let result = guard
            .as_ref()
            .ok_or(rusqlite::Error::InvalidQuery)
            .and_then(f);
        if result.is_err() {
            self.record_failure();
        }
        result
    }
    #[cfg(test)]
    pub(super) fn try_execute_test(&self, sql: &str) -> rusqlite::Result<()> {
        self.with_result(|conn| conn.execute_batch(sql))
    }

    /// Read-only preview for an explicit retention choice. Zero keeps forever.
    pub fn retention_preview(
        &self,
        days: i64,
        protected: &[String],
        now: DateTime<Utc>,
    ) -> rusqlite::Result<super::retention::RetentionPreview> {
        let guard = self.conn.lock();
        let conn = guard.as_ref().ok_or(rusqlite::Error::InvalidQuery)?;
        super::retention::preview(conn, days, protected, now)
    }
    pub fn prune_retained(
        &self,
        days: i64,
        protected: &[String],
        limit: usize,
        now: DateTime<Utc>,
    ) -> rusqlite::Result<super::retention::PruneReport> {
        let guard = self.conn.lock();
        let conn = guard.as_ref().ok_or(rusqlite::Error::InvalidQuery)?;
        super::retention::maintain(conn, days, protected, limit, now)
    }
    /// Additional manual compaction never deletes rows. Retention maintenance
    /// also reclaims disk automatically after actual policy-driven deletions.
    pub fn compact_confirmed(&self) -> rusqlite::Result<()> {
        let guard = self.conn.lock();
        let conn = guard.as_ref().ok_or(rusqlite::Error::InvalidQuery)?;
        conn.execute_batch("VACUUM")
    }

    // MARK: write

    /// Insert a new run (`INSERT OR IGNORE`: safe to call twice).
    pub fn insert_run(&self, run: &TelemetryRun) {
        if let Err(error) = self.try_insert_run(run) {
            log::warn!("Telemetry persistence failed: {error}");
        }
    }
    pub fn try_insert_run(&self, run: &TelemetryRun) -> rusqlite::Result<()> {
        self.with_result( |c| {
            let tx=c.unchecked_transaction()?;
            tx.execute(
                "INSERT OR IGNORE INTO runs
                (run_id, session_id, tab_id, provider, model, cwd, repo_path,
                 started_at, ended_at, duration_ms, exit_status,
                 total_input_tokens, total_cached_input_tokens, total_cache_creation_input_tokens, total_cache_read_input_tokens, total_output_tokens, total_reasoning_output_tokens,
                 cost_usd, token_usage_source, token_usage_state, cost_source, cost_state,
                 turn_count, tags, metadata, raw_transcript_ref, parent_run_id, error_message)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
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
                    run.total_cache_creation_input_tokens,
                    run.total_cache_read_input_tokens,
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
            )?;
            insert_evidence(&tx,&super::evidence::UsageEvidence::run_summary(run))?;
            reconcile_proxy_window(&tx,run.started_at)?;
            tx.commit()
        })
    }

    /// Finish a run: update its row and add its turns and tool calls in one
    /// transaction (UPDATE, never delete and insert, so children survive).
    pub fn evidence_cursor(&self) -> i64 {
        self.with(0, |conn| {
            let cursor: Option<String> = conn
                .query_row(
                    "SELECT cursor FROM maintenance_state WHERE name='proxy_evidence_v1'",
                    [],
                    |r| r.get(0),
                )
                .optional()?;
            Ok(cursor.and_then(|s| s.parse().ok()).unwrap_or(0))
        })
    }
    /// Cursor and observations commit atomically; a crash safely repeats IDs.
    pub fn ingest_evidence_batch(&self, rows: &[(i64, super::evidence::UsageEvidence)]) {
        if rows.is_empty() {
            return;
        }
        self.with((),|conn|{let tx=conn.unchecked_transaction()?;for (_,e) in rows {insert_evidence(&tx,e)?;}let oldest=rows.iter().map(|(_,e)|e.observed_at).min().unwrap();let newest=rows.iter().map(|(_,e)|e.observed_at).max().unwrap();reconcile_proxy_window(&tx,oldest)?;if newest!=oldest{reconcile_proxy_window(&tx,newest)?;}tx.execute("INSERT INTO maintenance_state(name,cursor) VALUES ('proxy_evidence_v1',?1) ON CONFLICT(name) DO UPDATE SET cursor=excluded.cursor",[rows.iter().map(|(id,_)|*id).max().unwrap().to_string()])?;tx.commit()});
    }
    /// Request-scoped retained observations are independent from run projections.
    pub fn record_usage_evidence(&self, e: &super::evidence::UsageEvidence) {
        self.with((), |conn| {
            let tx = conn.unchecked_transaction()?;
            insert_evidence(&tx, e)?;
            if !reconcile_proxy_window(&tx, e.observed_at)? {
                log::warn!(
                    "Proxy usage reconciliation deferred: retained window exceeds query budget"
                );
            }
            tx.commit()
        });
    }
    pub fn usage_evidence(
        &self,
        after: Option<DateTime<Utc>>,
        limit: usize,
    ) -> Vec<super::evidence::UsageEvidence> {
        self.with(vec![],|conn|{let mut stmt=conn.prepare("SELECT payload FROM usage_evidence WHERE (?1 IS NULL OR observed_at>=?1) ORDER BY observed_at,ingest_seq LIMIT ?2")?;let rows=stmt.query_map(params![after.as_ref().map(iso),limit.clamp(1,100_000) as i64],|row|{let json:String=row.get(0)?;Ok(serde_json::from_str(&json).ok())})?;rows.filter_map(|r|r.transpose()).collect()})
    }

    /// Latency writes are idempotent and preserve the original ingest order.
    pub fn insert_latency_sample(&self, sample: &super::latency::LatencySample) {
        if let Err(error) = self.try_insert_latency_sample(sample) {
            log::warn!("Telemetry persistence failed: {error}");
        }
    }
    pub fn try_insert_latency_sample(
        &self,
        sample: &super::latency::LatencySample,
    ) -> rusqlite::Result<()> {
        self.with_result(|conn| insert_latency(conn, sample))
    }
    /// Resume historical latency reconstruction in bounded batches. The
    /// checkpoint and resulting samples commit together; interrupted work
    /// repeats safely, and skipped fallback transcripts advance the cursor.
    pub fn backfill_latency_batch(&self, limit: usize) -> usize {
        self.with(0, |conn| {
            let cursor:Option<String>=conn.query_row("SELECT cursor FROM maintenance_state WHERE name='completed_latency_v1'",[],|r|r.get(0)).optional()?;
            let mut stmt=conn.prepare("SELECT * FROM runs WHERE ended_at IS NOT NULL AND (?1 IS NULL OR started_at || '|' || run_id > ?1) ORDER BY started_at,run_id LIMIT ?2")?;
            let runs:Vec<_>=stmt.query_map(params![cursor,limit.clamp(1,500) as i64], |row|Ok(parse_run(row)))?.filter_map(|r|r.transpose()).collect::<rusqlite::Result<Vec<_>>>()?;
            if runs.is_empty(){return Ok(0);}
            let tx=conn.unchecked_transaction()?;
            for run in &runs {
                let mut turns=tx.prepare("SELECT * FROM turns WHERE run_id=? ORDER BY turn_index")?;
                let turns:Vec<_>=turns.query_map([&run.id], |row|Ok(parse_turn(row)))?.filter_map(|r|r.transpose()).collect::<rusqlite::Result<Vec<_>>>()?;
                replace_completed_latency(&tx,run,&turns)?;
            }
            let last=runs.last().unwrap();
            tx.execute("INSERT INTO maintenance_state(name,cursor) VALUES ('completed_latency_v1',?1) ON CONFLICT(name) DO UPDATE SET cursor=excluded.cursor",[format!("{}|{}",iso(&last.started_at),last.id)])?;
            tx.commit()?;Ok(runs.len())
        })
    }
    pub fn activity_samples(
        &self,
        after: Option<DateTime<Utc>>,
    ) -> Vec<super::latency::ActivitySample> {
        self.with(vec![],|conn| {
            // Match Swift's all-time completed-run cap; bounded ranges keep all observations.
            let mut stmt=conn.prepare("SELECT provider,started_at FROM runs WHERE ended_at IS NOT NULL AND (?1 IS NULL OR started_at >= ?1) ORDER BY started_at DESC LIMIT ?2")?;
            let rows=stmt.query_map(params![after.as_ref().map(iso),if after.is_none(){2000_i64}else{-1_i64}],|row|{let provider:String=row.get(0)?;let at:String=row.get(1)?;Ok(parse_date(Some(at)).map(|timestamp|super::latency::ActivitySample{provider,timestamp}))})?;
            rows.filter_map(|r|r.transpose()).collect()
        })
    }
    /// Versioned resumable historical cost estimation. Observed provider
    /// costs and invalid token totals are never overwritten by estimates.
    pub fn backfill_cost_batch(&self, limit: usize) -> usize {
        self.with(0,|conn| {
            let key=format!("pricing_{}",super::pricing::VERSION);
            let cursor:Option<String>=conn.query_row("SELECT cursor FROM maintenance_state WHERE name=?1",[&key],|r|r.get(0)).optional()?;
            let mut stmt=conn.prepare("SELECT * FROM runs WHERE ended_at IS NOT NULL AND (?1 IS NULL OR started_at || '|' || run_id > ?1) ORDER BY started_at,run_id LIMIT ?2")?;
            let runs:Vec<_>=stmt.query_map(params![cursor,limit.clamp(1,500) as i64],|r|Ok(parse_run(r)))?.filter_map(|r|r.transpose()).collect::<rusqlite::Result<Vec<_>>>()?;
            if runs.is_empty(){return Ok(0);}
            let tx=conn.unchecked_transaction()?;
            for run in &runs {
                if run.token_usage_state==TelemetryMetricState::Invalid || run.cost_usd.is_some()&&run.cost_source!=Some(super::token_metrics::CostSource::Estimated) {continue;}
                let usage=run.token_usage();if !usage.has_any_tokens(){continue;}
                let Some(price)=super::pricing::pricing(run.model.as_deref(),Some(&run.provider)) else {continue;};
                let mut metadata=run.metadata.clone();metadata.insert("pricing_catalog_version".into(),super::pricing::VERSION.into());
                tx.execute("UPDATE runs SET cost_usd=?1,cost_source='estimated',cost_state='estimated',metadata=?2 WHERE run_id=?3 AND (cost_usd IS NULL OR cost_source='estimated')",params![price.estimate(&usage),encode_json(&metadata),run.id])?;
                let mut priced=run.clone();priced.cost_usd=Some(price.estimate(&usage));priced.cost_source=Some(super::token_metrics::CostSource::Estimated);priced.cost_state=TelemetryMetricState::Estimated;priced.metadata=metadata;insert_evidence(&tx,&super::evidence::UsageEvidence::run_summary(&priced))?;
            }
            let last=runs.last().unwrap();tx.execute("INSERT INTO maintenance_state(name,cursor) VALUES (?1,?2) ON CONFLICT(name) DO UPDATE SET cursor=excluded.cursor",params![key,format!("{}|{}",iso(&last.started_at),last.id)])?;
            tx.commit()?;Ok(runs.len())
        })
    }
    /// Ordered history, including live terminal measurements and authoritative transcript replacements.
    pub fn latency_samples(
        &self,
        after: Option<DateTime<Utc>>,
    ) -> Vec<super::latency::LatencySample> {
        self.with(vec![], |conn| {
            let mut statement = conn.prepare("SELECT * FROM provider_latency_samples WHERE (?1 IS NULL OR observed_at >= ?1) ORDER BY observed_at, ingest_seq")?;
            let rows = statement.query_map([after.as_ref().map(iso)], |row| {
                let metric: String = row.get("metric_kind")?;
                let timestamp: String = row.get("observed_at")?;
                let metric_kind = match metric.as_str() { "api_request" => super::latency::MetricKind::ApiRequest, "first_response" => super::latency::MetricKind::FirstResponse, _ => return Err(rusqlite::Error::InvalidQuery) };
                Ok(super::latency::LatencySample {
                    id: row.get("sample_id")?, provider: row.get("provider")?, metric_kind,
                    latency_ms: row.get("latency_ms")?, timestamp: parse_date(Some(timestamp)).ok_or(rusqlite::Error::InvalidQuery)?,
                    model: row.get("model")?, session_id: row.get("session_id")?, run_id: row.get("run_id")?,
                    round_index: row.get("round_index")?, project_path: row.get("project_path")?, source_kind: row.get("source_kind")?,
                })
            })?;
            rows.collect()
        })
    }

    pub fn finalize_run(
        &self,
        run: &TelemetryRun,
        turns: &[TelemetryTurn],
        tool_calls: &[TelemetryToolCall],
    ) {
        if let Err(error) = self.try_finalize_run(run, turns, tool_calls) {
            log::warn!("Telemetry persistence failed: {error}");
        }
    }
    pub fn try_finalize_run(
        &self,
        run: &TelemetryRun,
        turns: &[TelemetryTurn],
        tool_calls: &[TelemetryToolCall],
    ) -> rusqlite::Result<()> {
        self.with_result( |c| {
            let tx = c.unchecked_transaction()?;
            tx.execute(
                "UPDATE runs SET
                    session_id = ?, model = ?, ended_at = ?, duration_ms = ?, exit_status = ?,
                    total_input_tokens = ?, total_cached_input_tokens = ?, total_cache_creation_input_tokens = ?, total_cache_read_input_tokens = ?, total_output_tokens = ?,
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
                    run.total_cache_creation_input_tokens,
                    run.total_cache_read_input_tokens,
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
                try_insert_turn(&tx, turn)?;
            }
            for call in tool_calls {
                try_insert_tool_call(&tx, call)?;
            }
            replace_completed_latency(&tx, run, turns)?;
            insert_evidence(&tx,&super::evidence::UsageEvidence::run_summary(run))?;
            reconcile_proxy_window(&tx,run.started_at)?;
            tx.commit()
        })
    }

    /// Replace everything about a finished run (transcript repair).
    pub fn rewrite_completed_run(
        &self,
        run: &TelemetryRun,
        turns: &[TelemetryTurn],
        tool_calls: &[TelemetryToolCall],
    ) {
        if let Err(error) = self.try_rewrite_completed_run(run, turns, tool_calls) {
            log::warn!("Telemetry persistence failed: {error}");
        }
    }
    pub fn try_rewrite_completed_run(
        &self,
        run: &TelemetryRun,
        turns: &[TelemetryTurn],
        tool_calls: &[TelemetryToolCall],
    ) -> rusqlite::Result<()> {
        self.with_result(|c| {
            let tx = c.unchecked_transaction()?;
            tx.execute("DELETE FROM tool_calls WHERE run_id = ?", [&run.id])?;
            tx.execute("DELETE FROM turns WHERE run_id = ?", [&run.id])?;
            tx.execute(
                "UPDATE runs SET
                    session_id = ?, tab_id = ?, provider = ?, model = ?, cwd = ?, repo_path = ?,
                    started_at = ?, ended_at = ?, duration_ms = ?, exit_status = ?,
                    total_input_tokens = ?, total_cached_input_tokens = ?, total_cache_creation_input_tokens = ?, total_cache_read_input_tokens = ?, total_output_tokens = ?,
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
                    run.total_cache_creation_input_tokens,
                    run.total_cache_read_input_tokens,
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
                try_insert_turn(&tx, turn)?;
            }
            for call in tool_calls {
                try_insert_tool_call(&tx, call)?;
            }
            replace_completed_latency(&tx, run, turns)?;
            insert_evidence(&tx,&super::evidence::UsageEvidence::run_summary(run))?;
            reconcile_proxy_window(&tx,run.started_at)?;
            tx.commit()
        })
    }

    /// Clear a run's tokens and cost and mark them invalid.
    pub fn invalidate_run_metrics(&self, run_id: &str, reason: Option<&str>) {
        if let Err(error) = self.try_invalidate_run_metrics(run_id, reason) {
            log::warn!("Telemetry persistence failed: {error}");
        }
    }
    pub fn try_invalidate_run_metrics(
        &self,
        run_id: &str,
        reason: Option<&str>,
    ) -> rusqlite::Result<()> {
        self.with_result(|c| {
            let tx=c.unchecked_transaction()?;
            tx.execute(
                "UPDATE runs
                SET total_input_tokens = NULL,
                    total_cached_input_tokens = NULL, total_cache_creation_input_tokens = NULL, total_cache_read_input_tokens = NULL,
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
            )?;
            let run:Option<TelemetryRun>=tx.query_row("SELECT * FROM runs WHERE run_id=?1",[run_id],|row|Ok(parse_run(row))).optional()?.flatten();
            if let Some(run)=run {insert_evidence(&tx,&super::evidence::UsageEvidence::run_summary(&run))?;tx.execute("DELETE FROM proxy_run_baselines WHERE run_id=?1",[run_id])?;}
            tx.commit()
        })
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
        if let Err(error) = self.try_update_run_session_id(run_id, session_id) {
            log::warn!("Telemetry persistence failed: {error}");
        }
    }
    pub fn try_update_run_session_id(
        &self,
        run_id: &str,
        session_id: &str,
    ) -> rusqlite::Result<()> {
        self.with_result(|conn| {
            let tx = conn.unchecked_transaction()?;
            tx.execute(
                "UPDATE runs SET session_id=?1 WHERE run_id=?2",
                params![session_id, run_id],
            )?;
            let run: Option<TelemetryRun> = tx
                .query_row("SELECT * FROM runs WHERE run_id=?1", [run_id], |row| {
                    Ok(parse_run(row))
                })
                .optional()?
                .flatten();
            if let Some(run) = run {
                insert_evidence(&tx, &super::evidence::UsageEvidence::run_summary(&run))?;
                reconcile_proxy_window(&tx, run.started_at)?;
            }
            tx.commit()
        })
    }

    /// TEL-009: replace a run's tags (JSON array).
    pub fn update_run_tags(&self, run_id: &str, tags: &[String]) {
        if let Err(error) = self.try_update_run_tags(run_id, tags) {
            log::warn!("Telemetry persistence failed: {error}");
        }
    }
    pub fn try_update_run_tags(&self, run_id: &str, tags: &[String]) -> rusqlite::Result<()> {
        self.with_result(|c| {
            c.execute(
                "UPDATE runs SET tags = ? WHERE run_id = ?",
                params![encode_json(&tags), run_id],
            )
            .map(|_| ())
        })
    }

    /// TEL-015: one event from the paired iPhone.
    pub fn insert_remote_client_event(&self, event: &RemoteClientTelemetryEvent) {
        if let Err(error) = self.try_insert_remote_client_event(event) {
            log::warn!("Telemetry persistence failed: {error}");
        }
    }
    pub fn try_insert_remote_client_event(
        &self,
        event: &RemoteClientTelemetryEvent,
    ) -> rusqlite::Result<()> {
        self.with_result(|c| {
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
        })
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
        if let Some(v) = &filter.parent_run_id {
            clauses.push("parent_run_id = ?");
            values.push(v.clone());
        }
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
            let (proxy_cost,priced_proxy,missing_proxy):(f64,i64,i64)=c.query_row("SELECT COALESCE(SUM(cost_usd),0),COALESCE(SUM(cost_usd IS NOT NULL),0),COALESCE(SUM(cost_usd IS NULL),0) FROM usage_evidence WHERE project_path=?1 AND source_kind='proxy' AND unique_event_key NOT LIKE 'run|%'",[repo_path],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?)))?;
            c.query_row(
                "SELECT COUNT(*),
                  COALESCE(SUM(COALESCE(total_input_tokens,0)+COALESCE(total_cached_input_tokens,0)+COALESCE(total_output_tokens,0)+COALESCE(total_reasoning_output_tokens,0)),0),
                  COALESCE(SUM(cost_usd),0),COALESCE(SUM(turn_count),0),MAX(started_at),
                  COALESCE(SUM(CASE WHEN token_usage_source='proxy' THEN cost_usd ELSE 0 END),0),
                  COALESCE(SUM(cost_usd IS NOT NULL),0),COALESCE(SUM(cost_source='estimated'),0),COALESCE(SUM(cost_usd IS NULL),0),
                  COALESCE(SUM(token_usage_state='partial' OR cost_state='partial'),0)
                 FROM runs WHERE repo_path=?1",[repo_path],|r| {
                    let raw_run_cost:f64=r.get(2)?;let attributed_proxy_cost:f64=r.get(5)?;
                    Ok(RepoRunStats {total_runs:r.get(0)?,total_tokens:r.get(1)?,total_cost:super::query_projection::combined_repository_cost(raw_run_cost,proxy_cost,attributed_proxy_cost),raw_run_cost,retained_proxy_cost:proxy_cost,attributed_proxy_cost,priced_run_count:r.get(6)?,estimated_run_count:r.get(7)?,missing_cost_run_count:r.get(8)?,partial_run_count:r.get(9)?,priced_proxy_request_count:priced_proxy,missing_cost_proxy_request_count:missing_proxy,total_turns:r.get(3)?,last_run_at:parse_date(r.get(4)?)})
                })
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
                   COALESCE(SUM(cost_usd),0),
                   COALESCE(SUM(total_cache_creation_input_tokens),0),
                   COALESCE(SUM(total_cache_read_input_tokens),0),
                   COALESCE(SUM(CASE WHEN total_input_tokens IS NOT NULL
                     OR total_cached_input_tokens IS NOT NULL OR total_output_tokens IS NOT NULL
                     OR total_reasoning_output_tokens IS NOT NULL
                     OR total_cache_creation_input_tokens IS NOT NULL OR total_cache_read_input_tokens IS NOT NULL
                     THEN 1 ELSE 0 END),0)
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
                p.total_cache_creation_input_tokens = r.get(9)?;
                p.total_cache_read_input_tokens = r.get(10)?;
                p.token_observed_run_count = Some(r.get(11)?);
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
        self.with((), migrate_checked);
    }
}

fn open_checked(path: &Path) -> rusqlite::Result<Connection> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|_| rusqlite::Error::InvalidPath(path.to_owned()))?;
    }
    let mut connection = Connection::open(path)?;
    let integrity = check_integrity(&connection)?;
    if integrity == IntegrityCheck::ConfirmedCorruption {
        drop(connection);
        std::fs::remove_file(path).map_err(|_| rusqlite::Error::InvalidPath(path.to_owned()))?;
        let _ = std::fs::remove_file(path.with_extension("db-wal"));
        let _ = std::fs::remove_file(path.with_extension("db-shm"));
        connection = Connection::open(path)?;
    }
    configure_checked(&connection)?;
    setup_checked(&connection)?;
    Ok(connection)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum IntegrityCheck {
    Healthy,
    ConfirmedCorruption,
}
fn check_integrity(conn: &Connection) -> rusqlite::Result<IntegrityCheck> {
    // A busy/unreadable database is unavailable, not evidence of corruption.
    match conn.query_row("PRAGMA quick_check", [], |r| r.get::<_, String>(0)) {
        Ok(result) => Ok(if result == "ok" {
            IntegrityCheck::Healthy
        } else {
            IntegrityCheck::ConfirmedCorruption
        }),
        Err(rusqlite::Error::SqliteFailure(error, _))
            if matches!(
                error.code,
                rusqlite::ErrorCode::DatabaseCorrupt | rusqlite::ErrorCode::NotADatabase
            ) =>
        {
            Ok(IntegrityCheck::ConfirmedCorruption)
        }
        Err(error) => Err(error),
    }
}
fn configure_checked(conn: &Connection) -> rusqlite::Result<()> {
    conn.pragma_update(None, "journal_mode", "WAL")?;
    conn.execute_batch("PRAGMA foreign_keys=ON")
}
fn setup_checked(conn: &Connection) -> rusqlite::Result<()> {
    conn.execute_batch(SCHEMA)?;
    migrate_checked(conn)
}

fn migrate_checked(conn: &Connection) -> rusqlite::Result<()> {
    for (table, name, definition) in [
        ("runs", "total_cached_input_tokens", "INTEGER"),
        ("runs", "total_cache_creation_input_tokens", "INTEGER"),
        ("runs", "total_cache_read_input_tokens", "INTEGER"),
        ("runs", "total_reasoning_output_tokens", "INTEGER"),
        ("runs", "token_usage_source", "TEXT"),
        ("runs", "token_usage_state", "TEXT"),
        ("runs", "cost_source", "TEXT"),
        ("runs", "cost_state", "TEXT"),
        ("turns", "cached_input_tokens", "INTEGER"),
        ("turns", "cache_creation_input_tokens", "INTEGER"),
        ("turns", "cache_read_input_tokens", "INTEGER"),
        ("turns", "reasoning_output_tokens", "INTEGER"),
    ] {
        ensure_column(conn, table, name, definition)?;
    }
    conn.execute_batch(BACKFILL_STATES)?;
    conn.execute_batch(INVALIDATE_IMPLAUSIBLE)?;
    Ok(())
}

fn ensure_column(
    conn: &Connection,
    table: &str,
    name: &str,
    definition: &str,
) -> rusqlite::Result<()> {
    let mut statement = conn.prepare(&format!("PRAGMA table_info({table})"))?;
    let names = statement
        .query_map([], |r| r.get::<_, String>(1))?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    if !names.iter().any(|n| n == name) {
        conn.execute_batch(&format!(
            "ALTER TABLE {table} ADD COLUMN {name} {definition}"
        ))?;
    }
    Ok(())
}

fn insert_turn(conn: &Connection, turn: &TelemetryTurn) {
    if let Err(error) = try_insert_turn(conn, turn) {
        log::warn!("TelemetryStore: child insert failed: {error}");
    }
}
fn try_insert_turn(conn: &Connection, turn: &TelemetryTurn) -> rusqlite::Result<()> {
    conn.execute(
        "INSERT OR IGNORE INTO turns
        (turn_id, run_id, turn_index, role, content, input_tokens, cached_input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens,
         reasoning_output_tokens, tool_calls, timestamp, duration_ms)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)",
        params![
            turn.id,
            turn.run_id,
            turn.turn_index,
            raw(&turn.role),
            turn.content,
            turn.input_tokens,
            turn.cached_input_tokens,
            turn.cache_creation_input_tokens,
            turn.cache_read_input_tokens,
            turn.output_tokens,
            turn.reasoning_output_tokens,
            encode_json(&turn.tool_calls),
            turn.timestamp.as_ref().map(iso),
            turn.duration_ms,
        ],
    ).map(|_| ())
}

fn insert_tool_call(conn: &Connection, call: &TelemetryToolCall) {
    if let Err(error) = try_insert_tool_call(conn, call) {
        log::warn!("TelemetryStore: child insert failed: {error}");
    }
}
fn try_insert_tool_call(conn: &Connection, call: &TelemetryToolCall) -> rusqlite::Result<()> {
    conn.execute(
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
    )
    .map(|_| ())
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
    fn disabled_retention_and_manual_compaction_preserve_owned_history() {
        let store = TelemetryStore::in_memory();
        let mut old = run("claude", Some("/owned"), Some("owned-tab"));
        old.started_at = "2020-01-01T00:00:00Z".parse().unwrap();
        old.ended_at = Some(old.started_at + Duration::seconds(1));
        let mut turn = TelemetryTurn::new(&old.id, 0, TurnRole::Assistant);
        turn.content = Some("owned retained transcript".into());
        store.insert_run(&old);
        store.finalize_run(&old, &[turn], &[]);
        let report = store.prune_retained(0, &[], 100, Utc::now()).unwrap();
        assert_eq!(report.rows(), 0);
        assert!(!report.compacted);
        store.compact_confirmed().unwrap();
        assert_eq!(store.get_run(&old.id).unwrap().started_at, old.started_at);
        assert_eq!(store.with(0, |conn| conn.query_row("SELECT count(*) FROM turns WHERE run_id=?1 AND content='owned retained transcript'", [&old.id], |row| row.get::<_,usize>(0))), 1);
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
    fn provider_consumption_distinguishes_missing_counters_from_measured_zero() {
        let store = TelemetryStore::in_memory();
        let missing = run("claude", None, None);
        store.insert_run(&missing);
        let p = store.consumption_per_provider(None);
        assert_eq!(p[0].token_observed_run_count, Some(0));
        let mut zero = run("claude", None, None);
        zero.total_input_tokens = Some(0);
        zero.total_output_tokens = Some(0);
        zero.token_usage_state = TelemetryMetricState::Complete;
        store.insert_run(&zero);
        let p = store.consumption_per_provider(None);
        assert_eq!(p[0].run_count, 2);
        assert_eq!(p[0].token_observed_run_count, Some(1));
        assert_eq!(p[0].total_billable_tokens(), 0);
    }
    #[test]
    fn provider_consumption_preserves_cache_categories_without_double_counting() {
        let store = TelemetryStore::in_memory();
        let now = Utc::now();
        let mut detailed = run("claude", None, None);
        detailed.started_at = now;
        detailed.token_usage_state = TelemetryMetricState::Complete;
        detailed.total_input_tokens = Some(100);
        detailed.total_cached_input_tokens = Some(75);
        detailed.total_cache_creation_input_tokens = Some(20);
        detailed.total_cache_read_input_tokens = Some(30);
        detailed.total_output_tokens = Some(10);
        detailed.total_reasoning_output_tokens = Some(2);
        store.insert_run(&detailed);
        let mut legacy = run("claude", None, None);
        legacy.started_at = now;
        legacy.token_usage_state = TelemetryMetricState::Complete;
        legacy.total_cached_input_tokens = Some(9);
        store.insert_run(&legacy);
        let mut outside = detailed.clone();
        outside.id = uuid::Uuid::new_v4().to_string();
        outside.started_at = now - Duration::hours(1);
        store.insert_run(&outside);
        let mut invalid = detailed.clone();
        invalid.id = uuid::Uuid::new_v4().to_string();
        invalid.token_usage_state = TelemetryMetricState::Invalid;
        store.insert_run(&invalid);
        let providers = store.consumption_per_provider(Some(now - Duration::minutes(10)));
        assert_eq!(providers.len(), 1);
        let p = &providers[0];
        assert_eq!(p.run_count, 2);
        assert_eq!(p.token_observed_run_count, Some(2));
        assert_eq!(p.total_cached_input_tokens, 84);
        assert_eq!(p.total_cache_creation_input_tokens, 20);
        assert_eq!(p.total_cache_read_input_tokens, 30);
        assert_eq!(p.uncategorized_cached_input_tokens(), 34);
        assert_eq!(p.total_billable_tokens(), 196);
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
    #[test]
    fn latency_history_repair_preserves_live_evidence_and_resumes_backfill() {
        let store = TelemetryStore::in_memory();
        let now = Utc::now();
        let mut run = TelemetryRun::new("claude", "/repo");
        run.started_at = now;
        run.ended_at = Some(now + chrono::Duration::seconds(5));
        run.raw_transcript_ref = Some("/transcript.jsonl".into());
        store.insert_run(&run);
        let mut turn = TelemetryTurn::new(&run.id, 0, super::super::turn::TurnRole::Assistant);
        turn.timestamp = Some(now + chrono::Duration::seconds(1));
        store.insert_turns(&[turn.clone()]);
        assert_eq!(store.backfill_latency_batch(1), 1);
        assert_eq!(store.backfill_latency_batch(1), 0);
        let mut live = super::super::latency::completed_samples(&run, &[turn.clone()])[0].clone();
        live.id = "live".into();
        live.source_kind = "terminal_first_output".into();
        live.latency_ms = 10;
        store.insert_latency_sample(&live);
        store.insert_latency_sample(&live);
        assert_eq!(store.latency_samples(None).len(), 2);
        turn.timestamp = Some(now + chrono::Duration::seconds(2));
        store.rewrite_completed_run(&run, &[turn], &[]);
        let all = store.latency_samples(None);
        assert_eq!(all.len(), 2);
        assert_eq!(super::super::latency::canonical(&all)[0].latency_ms, 2000);
        assert!(
            store
                .latency_samples(Some(now + chrono::Duration::minutes(1)))
                .is_empty()
        );
    }
    #[test]
    fn canonical_cache_categories_survive_upgrade_finalize_and_repair() {
        for legacy in [true, false] {
            let store = TelemetryStore::in_memory();
            if legacy {
                store.execute_raw("ALTER TABLE runs DROP COLUMN total_cache_creation_input_tokens; ALTER TABLE runs DROP COLUMN total_cache_read_input_tokens; ALTER TABLE turns DROP COLUMN cache_creation_input_tokens; ALTER TABLE turns DROP COLUMN cache_read_input_tokens;");
                store.reapply_migrations();
            }
            let mut r = run("claude", None, None);
            r.model = Some("claude-sonnet-4".into());
            r.total_input_tokens = Some(100);
            r.total_cached_input_tokens = Some(30);
            r.total_cache_creation_input_tokens = Some(20);
            r.total_cache_read_input_tokens = Some(10);
            r.total_output_tokens = Some(50);
            store.insert_run(&r);
            assert_eq!(store.get_run(&r.id).unwrap().token_usage(), r.token_usage());
            let mut turn = TelemetryTurn::new(&r.id, 0, TurnRole::Assistant);
            turn.input_tokens = r.total_input_tokens;
            turn.cached_input_tokens = r.total_cached_input_tokens;
            turn.cache_creation_input_tokens = r.total_cache_creation_input_tokens;
            turn.cache_read_input_tokens = r.total_cache_read_input_tokens;
            turn.output_tokens = r.total_output_tokens;
            r.ended_at = Some(Utc::now());
            store.finalize_run(&r, &[turn.clone()], &[]);
            let persisted = store.get_turns(&r.id);
            assert_eq!(persisted[0].token_usage(), r.token_usage());
            let price = super::super::pricing::pricing(r.model.as_deref(), Some("claude")).unwrap();
            assert_eq!(
                price.estimate(&store.get_run(&r.id).unwrap().token_usage()),
                price.estimate(&r.token_usage())
            );
            r.total_cache_creation_input_tokens = Some(25);
            r.total_cached_input_tokens = Some(35);
            turn.cache_creation_input_tokens = Some(25);
            turn.cached_input_tokens = Some(35);
            store.rewrite_completed_run(&r, &[turn], &[]);
            assert_eq!(store.get_run(&r.id).unwrap().token_usage(), r.token_usage());
            assert_eq!(store.get_turns(&r.id)[0].token_usage(), r.token_usage());
            store.invalidate_run_metrics(&r.id, None);
            let invalid = store.get_run(&r.id).unwrap();
            assert!(invalid.total_cache_creation_input_tokens.is_none());
            assert!(invalid.total_cache_read_input_tokens.is_none());
        }
    }
    #[test]
    fn versioned_cost_backfill_is_resumable_and_preserves_observed_prices() {
        let store = TelemetryStore::in_memory();
        let mut a = run("claude", None, None);
        a.ended_at = Some(Utc::now());
        a.model = Some("claude-sonnet-4".into());
        a.total_input_tokens = Some(1000);
        a.token_usage_state = TelemetryMetricState::Complete;
        let mut b = a.clone();
        b.id = "observed".into();
        b.started_at += chrono::Duration::seconds(1);
        b.cost_usd = Some(42.);
        b.cost_source = Some(CostSource::Observed);
        b.cost_state = TelemetryMetricState::Complete;
        store.insert_run(&a);
        store.insert_run(&b);
        assert_eq!(store.backfill_cost_batch(1), 1);
        let estimated = store.get_run(&a.id).unwrap();
        assert!(estimated.cost_usd.unwrap() > 0.);
        assert_eq!(estimated.cost_state, TelemetryMetricState::Estimated);
        assert_eq!(
            estimated.metadata["pricing_catalog_version"],
            super::super::pricing::VERSION
        );
        assert_eq!(store.backfill_cost_batch(1), 1);
        assert_eq!(store.backfill_cost_batch(1), 0);
        assert_eq!(store.get_run(&b.id).unwrap().cost_usd, Some(42.));
    }
    #[test]
    fn scoped_evidence_revokes_ambiguous_projection_and_restores_baseline() {
        use super::super::evidence::{SourceKind, UsageEvidence};
        let store = TelemetryStore::in_memory();
        let now = Utc::now();
        let mut r = run("claude", None, None);
        r.started_at = now - chrono::Duration::seconds(1);
        r.session_id = Some("s".into());
        r.total_input_tokens = Some(900);
        r.cost_usd = Some(5.);
        r.cost_source = Some(CostSource::Estimated);
        r.cost_state = TelemetryMetricState::Estimated;
        store.insert_run(&r);
        let mut e = UsageEvidence::empty("anthropic", SourceKind::Proxy, now);
        e.session_id = Some("s".into());
        e.input_tokens = Some(10);
        e.output_tokens = Some(20);
        e.cost_usd = Some(1.);
        e.finish_proxy_identity(Some("request"));
        store.record_usage_evidence(&e);
        store.record_usage_evidence(&e);
        let measured = store.get_run(&r.id).unwrap();
        assert_eq!(measured.total_input_tokens, Some(10));
        assert_eq!(measured.token_usage_state, TelemetryMetricState::Partial);
        assert_eq!(store.usage_evidence(None, 100).len(), 2);
        let mut overlapping = r.clone();
        overlapping.id = "overlap".into();
        store.insert_run(&overlapping);
        let restored = store.get_run(&r.id).unwrap();
        assert_eq!(restored.total_input_tokens, Some(900));
        assert_eq!(restored.cost_usd, Some(5.));
        assert!(!restored.metadata.contains_key("proxy_coverage"));
        let mut scoped = e.clone();
        scoped.run_id = Some(r.id.clone());
        scoped.unique_event_key = "request2".into();
        scoped.id = "request2".into();
        store.record_usage_evidence(&scoped);
        assert_eq!(store.get_run(&r.id).unwrap().total_input_tokens, Some(10));
        store.ingest_evidence_batch(&[(4, scoped)]);
        assert_eq!(store.evidence_cursor(), 4);
    }
    #[test]
    fn repository_cost_removes_only_retained_overlap_and_keeps_missing_quality() {
        use super::super::evidence::{SourceKind, UsageEvidence};
        let store = TelemetryStore::in_memory();
        let now = Utc::now();
        let mut r = run("claude", Some("/repo"), None);
        r.started_at = now - chrono::Duration::seconds(1);
        r.cost_usd = Some(5.);
        r.cost_source = Some(CostSource::Estimated);
        store.insert_run(&r);
        let mut e = UsageEvidence::empty("anthropic", SourceKind::Proxy, now);
        e.project_path = Some("/repo".into());
        e.input_tokens = Some(10);
        e.output_tokens = Some(20);
        e.cost_usd = Some(2.);
        e.run_id = Some("wrong".into());
        e.finish_proxy_identity(Some("unassigned"));
        store.record_usage_evidence(&e);
        assert_eq!(store.run_stats_for_repo("/repo").total_cost, 7.);
        e.run_id = Some(r.id.clone());
        e.cost_usd = Some(1.);
        e.cache_creation_input_tokens = Some(2);
        e.cache_read_input_tokens = Some(3);
        e.reasoning_output_tokens = Some(4);
        e.finish_proxy_identity(Some("assigned"));
        store.record_usage_evidence(&e);
        let mut missing = run("codex", Some("/repo"), None);
        missing.started_at += chrono::Duration::seconds(2);
        missing.total_input_tokens = Some(50);
        missing.total_output_tokens = None;
        missing.cost_usd = None;
        store.insert_run(&missing);
        let totals = store.run_stats_for_repo("/repo");
        assert_eq!(totals.total_cost, 3.);
        assert_eq!(totals.raw_run_cost, 1.);
        assert_eq!(totals.retained_proxy_cost, 3.);
        assert_eq!(totals.attributed_proxy_cost, 1.);
        assert_eq!(totals.total_tokens, 89);
        assert_eq!(totals.partial_run_count, 1);
        assert_eq!(totals.missing_cost_run_count, 1);
        assert_eq!(totals.priced_proxy_request_count, 2);
    }
}

#[cfg(test)]
mod ordered_failure_tests {
    use super::*;
    use std::sync::Arc;
    #[test]
    fn explicit_background_close_is_idempotent_and_releases_an_owned_file() {
        let directory =
            std::env::temp_dir().join(format!("next-telemetry-close-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let store = Arc::new(TelemetryStore::open(&directory.join("owned.db")));
        let run = TelemetryRun::new("owned-fake", "/synthetic");
        store.try_insert_run(&run).unwrap();
        let closed = store.clone();
        let caller = std::thread::current().id();
        let worker = std::thread::spawn(move || {
            closed.close().unwrap();
            closed.close().unwrap();
            std::thread::current().id()
        })
        .join()
        .unwrap();
        assert_ne!(caller, worker);
        assert!(store.try_insert_run(&run).is_err());
        assert_eq!(store.failure_count(), 1);
        // Even a retained wrapper has no SQLite handle now, including on Windows.
        std::fs::remove_dir_all(directory).unwrap();
        drop(store);
    }
    #[test]
    fn a_failed_close_restores_the_returned_connection_and_reports_the_real_sql_error() {
        let store = TelemetryStore::in_memory();
        let run = TelemetryRun::new("owned-fake", "/synthetic");
        store.try_insert_run(&run).unwrap();
        // Deterministically exercise Connection::close's returned-connection
        // branch with an actual SQLite error rather than leaking statements.
        let result = store.close_using(|connection| {
            let error = connection
                .execute("INSERT INTO missing_owned_table VALUES(1)", [])
                .unwrap_err();
            Err(Box::new((connection, error)))
        });
        assert!(result.is_err());
        assert_eq!(store.failure_count(), 1);
        assert_eq!(store.get_run(&run.id).unwrap().id, run.id);
        store.close().unwrap();
        store.close().unwrap();
    }
    #[test]
    fn checked_finalization_rolls_back_everything_when_a_child_insert_fails() {
        let store = TelemetryStore::in_memory();
        let mut run = TelemetryRun::new("owned-fake", "/owned");
        store.try_insert_run(&run).unwrap();
        run.ended_at = Some(Utc::now());
        let mut turn = TelemetryTurn::new(&run.id, 0, super::super::turn::TurnRole::Assistant);
        turn.run_id = "missing-parent".into();
        assert!(store.try_finalize_run(&run, &[turn], &[]).is_err());
        assert!(store.get_run(&run.id).unwrap().ended_at.is_none());
        assert_eq!(store.failure_count(), 1);
    }
}

#[cfg(test)]
mod checked_initialization_tests {
    use super::*;
    use std::sync::Arc;
    #[test]
    fn malformed_schema_fails_checked_initialization_without_recreating_owned_records() {
        let directory =
            std::env::temp_dir().join(format!("next-schema-failure-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("owned.db");
        let original = Connection::open(&path).unwrap();
        original.execute_batch("CREATE TABLE owned_preserved(value TEXT); INSERT INTO owned_preserved VALUES('owned-value'); CREATE VIEW runs AS SELECT 1 AS sentinel").unwrap();
        original.close().unwrap();
        let store = Arc::new(TelemetryStore::pending(&path));
        let initializing = store.clone();
        assert!(
            std::thread::spawn(move || initializing.initialize_background())
                .join()
                .unwrap()
                .is_err()
        );
        assert_eq!(store.readiness(), StoreReadiness::Failed);
        assert_eq!(store.failure_count(), 1);
        let preserved = Connection::open(&path).unwrap();
        assert_eq!(
            preserved
                .query_row("SELECT value FROM owned_preserved", [], |r| r
                    .get::<_, String>(0))
                .unwrap(),
            "owned-value"
        );
        preserved.close().unwrap();
        store.close().unwrap();
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn actual_busy_integrity_check_preserves_database_bytes_and_never_labels_it_corrupt() {
        let directory =
            std::env::temp_dir().join(format!("next-integrity-busy-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("owned.db");
        let owner = Connection::open(&path).unwrap();
        owner.execute_batch("CREATE TABLE owned_preserved(value TEXT); INSERT INTO owned_preserved VALUES('owned-value'); BEGIN EXCLUSIVE").unwrap();
        let before = std::fs::read(&path).unwrap();
        let store = Arc::new(TelemetryStore::pending(&path));
        let initializing = store.clone();
        let error = std::thread::spawn(move || initializing.initialize_background())
            .join()
            .unwrap()
            .unwrap_err();
        assert!(
            matches!(error, rusqlite::Error::SqliteFailure(ref e, _) if matches!(e.code, rusqlite::ErrorCode::DatabaseBusy | rusqlite::ErrorCode::DatabaseLocked))
        );
        assert_eq!(store.readiness(), StoreReadiness::Failed);
        assert_eq!(std::fs::read(&path).unwrap(), before);
        assert!(!path.with_extension("db-wal").exists());
        assert!(!path.with_extension("db-shm").exists());
        owner.execute_batch("ROLLBACK").unwrap();
        assert_eq!(
            owner
                .query_row("SELECT COUNT(*) FROM owned_preserved", [], |r| r
                    .get::<_, i64>(0))
                .unwrap(),
            1
        );
        owner.close().unwrap();
        store.close().unwrap();
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[test]
    fn confirmed_corruption_recreates_only_the_owned_database_and_publishes_ready() {
        let directory =
            std::env::temp_dir().join(format!("next-confirmed-corrupt-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("owned.db");
        std::fs::write(
            &path,
            b"owned synthetic invalid sqlite contents, sufficiently long",
        )
        .unwrap();
        let connection = Connection::open(&path).unwrap();
        assert_eq!(
            check_integrity(&connection).unwrap(),
            IntegrityCheck::ConfirmedCorruption
        );
        connection.close().unwrap();
        let store = TelemetryStore::open(&path);
        assert_eq!(store.readiness(), StoreReadiness::Ready);
        store
            .try_insert_run(&TelemetryRun::new("owned-fake", "/synthetic"))
            .unwrap();
        assert_eq!(store.run_count(), 1);
        store.close().unwrap();
        std::fs::remove_dir_all(directory).unwrap();
    }
}
