//! Persistent command history in SQLite (`History/PersistentHistoryStore.swift`).
//!
//! Chau7 Next keeps its own database (`DataRoot::history_db`), never the Swift
//! app's `history.db`. The schema is the Swift one, so a file can be exchanged
//! with the Swift app by hand:
//!
//! ```sql
//! CREATE TABLE history (
//!     id INTEGER PRIMARY KEY AUTOINCREMENT,
//!     command TEXT NOT NULL, directory TEXT, exit_code INTEGER,
//!     shell TEXT, tab_id TEXT, session_id TEXT,
//!     timestamp REAL NOT NULL, duration REAL
//! );
//! ```
//!
//! Differences from Swift: the text search and the repository prefix match
//! escape `%` and `_` (Swift passes them to `LIKE` as wildcards), and ties in
//! the timestamp are broken by the row id so the order is stable.

use std::path::{Path, PathBuf};

use chrono::{DateTime, Utc};
use rusqlite::types::Value;
use rusqlite::{Connection, OptionalExtension, params};
use serde::{Deserialize, Serialize};

use crate::history_record::{FrequentCommand, HistoryRecord};

/// Default and bounds of the "maximum records" setting.
pub const DEFAULT_MAX_RECORDS: usize = 50_000;
pub const MIN_MAX_RECORDS: usize = 10_000;
pub const MAX_MAX_RECORDS: usize = 100_000;

/// Aggregate command statistics of one repository (`commandStatsForRepo`).
#[derive(Debug, Clone, Copy, Default, PartialEq)]
pub struct CommandStats {
    pub total: i64,
    pub successful: i64,
    pub failed: i64,
    pub avg_duration: f64,
}

/// A history record as Swift exports it (`.iso8601` dates, `tabID` keys).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExportRecord {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    id: Option<i64>,
    command: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    directory: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    exit_code: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    shell: Option<String>,
    #[serde(default, rename = "tabID", skip_serializing_if = "Option::is_none")]
    tab_id: Option<String>,
    #[serde(default, rename = "sessionID", skip_serializing_if = "Option::is_none")]
    session_id: Option<String>,
    #[serde(with = "crate::iso8601::iso8601_seconds")]
    timestamp: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    duration: Option<f64>,
}

impl From<HistoryRecord> for ExportRecord {
    fn from(r: HistoryRecord) -> Self {
        Self {
            id: r.id,
            command: r.command,
            directory: r.directory,
            exit_code: r.exit_code,
            shell: r.shell,
            tab_id: r.tab_id,
            session_id: r.session_id,
            timestamp: r.timestamp,
            duration: r.duration,
        }
    }
}

impl From<ExportRecord> for HistoryRecord {
    fn from(r: ExportRecord) -> Self {
        Self {
            id: None,
            command: r.command,
            directory: r.directory,
            exit_code: r.exit_code,
            shell: r.shell,
            tab_id: r.tab_id,
            session_id: r.session_id,
            timestamp: r.timestamp,
            duration: r.duration,
        }
    }
}

/// The SQLite history database. Not `Sync`: share it behind a mutex.
pub struct HistoryStore {
    conn: Connection,
    path: Option<PathBuf>,
    /// Groups the commands of one app launch (`sessionID`).
    pub session_id: String,
    /// Records kept; older ones are trimmed after each insert.
    pub max_records: usize,
}

const COLUMNS: &str =
    "id, command, directory, exit_code, shell, tab_id, session_id, timestamp, duration";

fn to_unix(date: DateTime<Utc>) -> f64 {
    date.timestamp() as f64 + f64::from(date.timestamp_subsec_nanos()) / 1e9
}

fn from_unix(seconds: f64) -> DateTime<Utc> {
    let whole = seconds.floor();
    let nanos = (((seconds - whole) * 1e9).round() as u32).min(999_999_999);
    DateTime::from_timestamp(whole as i64, nanos).unwrap_or_default()
}

/// Escape `%`, `_` and `\` for `LIKE ... ESCAPE '\'`.
fn like_escape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for c in text.chars() {
        if matches!(c, '%' | '_' | '\\') {
            out.push('\\');
        }
        out.push(c);
    }
    out
}

fn read_record(row: &rusqlite::Row) -> rusqlite::Result<HistoryRecord> {
    Ok(HistoryRecord {
        id: Some(row.get(0)?),
        command: row.get(1)?,
        directory: row.get(2)?,
        exit_code: row.get(3)?,
        shell: row.get(4)?,
        tab_id: row.get(5)?,
        session_id: row.get(6)?,
        timestamp: from_unix(row.get(7)?),
        duration: row.get(8)?,
    })
}

impl HistoryStore {
    /// Open (or create) the database at `path`; `":memory:"` gives a
    /// throwaway one. A file that cannot be opened is renamed to
    /// `*.corrupt.<unix time>` and a fresh one is created.
    pub fn open(path: &Path) -> rusqlite::Result<Self> {
        if path.as_os_str() == ":memory:" {
            return Self::from_connection(Connection::open_in_memory()?, None);
        }
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let opened = Connection::open(path).and_then(|conn| {
            // A quick read proves the file is a database.
            conn.query_row("SELECT count(*) FROM sqlite_master", [], |r| {
                r.get::<_, i64>(0)
            })?;
            Ok(conn)
        });
        let conn = match opened {
            Ok(conn) => conn,
            Err(err) => {
                log::error!("history store: cannot open {}: {err}", path.display());
                let stamp = Utc::now().timestamp();
                let corrupt = PathBuf::from(format!("{}.corrupt.{stamp}", path.display()));
                let _ = std::fs::rename(path, &corrupt);
                log::warn!(
                    "history store: renamed corrupt database to {}, retrying",
                    corrupt.display()
                );
                Connection::open(path)?
            }
        };
        Self::from_connection(conn, Some(path.to_path_buf()))
    }

    fn from_connection(conn: Connection, path: Option<PathBuf>) -> rusqlite::Result<Self> {
        // `journal_mode` returns a row, so it cannot go through `execute`.
        let _: Option<String> = conn
            .query_row("PRAGMA journal_mode=WAL", [], |r| r.get(0))
            .optional()?;
        conn.execute_batch("PRAGMA synchronous=NORMAL")?;
        conn.execute_batch(
            "CREATE TABLE IF NOT EXISTS history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                command TEXT NOT NULL,
                directory TEXT,
                exit_code INTEGER,
                shell TEXT,
                tab_id TEXT,
                session_id TEXT,
                timestamp REAL NOT NULL,
                duration REAL
            );
            CREATE INDEX IF NOT EXISTS idx_history_timestamp ON history(timestamp DESC);
            CREATE INDEX IF NOT EXISTS idx_history_command ON history(command);
            CREATE INDEX IF NOT EXISTS idx_history_directory ON history(directory);",
        )?;
        Ok(Self {
            conn,
            path,
            session_id: uuid::Uuid::new_v4().to_string().to_uppercase(),
            max_records: DEFAULT_MAX_RECORDS,
        })
    }

    // MARK: insert

    /// Add one record (a missing session id becomes this launch's), then trim
    /// the oldest records beyond `max_records`.
    pub fn insert(&self, record: &HistoryRecord) -> rusqlite::Result<()> {
        self.conn.execute(
            "INSERT INTO history (command, directory, exit_code, shell, tab_id, session_id, timestamp, duration)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)",
            params![
                record.command,
                record.directory,
                record.exit_code,
                record.shell,
                record.tab_id,
                record.session_id.as_deref().unwrap_or(&self.session_id),
                to_unix(record.timestamp),
                record.duration,
            ],
        )?;
        self.trim_if_needed()
    }

    fn trim_if_needed(&self) -> rusqlite::Result<()> {
        let count = self.total_count();
        let max = self.max_records as i64;
        if count > max {
            let excess = count - max;
            self.conn.execute(
                "DELETE FROM history WHERE id IN (SELECT id FROM history ORDER BY timestamp ASC, id ASC LIMIT ?1)",
                params![excess],
            )?;
            log::info!("history store: trimmed {excess} oldest records");
        }
        Ok(())
    }

    // MARK: query

    fn query(&self, sql: &str, args: &[Value]) -> Vec<HistoryRecord> {
        let run = || -> rusqlite::Result<Vec<HistoryRecord>> {
            let mut stmt = self.conn.prepare(sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(args.iter()), read_record)?;
            rows.collect()
        };
        run().unwrap_or_else(|err| {
            log::warn!("history store query failed: {err}");
            Vec::new()
        })
    }

    /// Commands containing `query`, newest first.
    pub fn search(&self, query: &str, limit: usize) -> Vec<HistoryRecord> {
        self.query(
            &format!(
                "SELECT {COLUMNS} FROM history WHERE command LIKE ?1 ESCAPE '\\' ORDER BY timestamp DESC, id DESC LIMIT ?2"
            ),
            &[
                Value::Text(format!("%{}%", like_escape(query))),
                Value::Integer(limit as i64),
            ],
        )
    }

    /// The newest records.
    pub fn recent(&self, limit: usize) -> Vec<HistoryRecord> {
        self.query(
            &format!("SELECT {COLUMNS} FROM history ORDER BY timestamp DESC, id DESC LIMIT ?1"),
            &[Value::Integer(limit as i64)],
        )
    }

    /// The newest record of each distinct command containing `query` (all
    /// when empty): the command picker's list.
    pub fn recent_unique(&self, query: &str, limit: usize) -> Vec<HistoryRecord> {
        self.query(
            &format!(
                "SELECT {COLUMNS} FROM history
                 WHERE id IN (SELECT MAX(id) FROM history WHERE command LIKE ?1 ESCAPE '\\' GROUP BY command)
                 ORDER BY timestamp DESC, id DESC LIMIT ?2"
            ),
            &[
                Value::Text(format!("%{}%", like_escape(query))),
                Value::Integer(limit as i64),
            ],
        )
    }

    /// The newest records that ran in exactly `directory`.
    pub fn recent_for_directory(&self, directory: &str, limit: usize) -> Vec<HistoryRecord> {
        self.query(
            &format!(
                "SELECT {COLUMNS} FROM history WHERE directory = ?1 ORDER BY timestamp DESC, id DESC LIMIT ?2"
            ),
            &[
                Value::Text(directory.to_string()),
                Value::Integer(limit as i64),
            ],
        )
    }

    fn frequent(&self, sql: &str, args: &[Value]) -> Vec<FrequentCommand> {
        let run = || -> rusqlite::Result<Vec<FrequentCommand>> {
            let mut stmt = self.conn.prepare(sql)?;
            let rows = stmt.query_map(rusqlite::params_from_iter(args.iter()), |row| {
                Ok(FrequentCommand::new(
                    row.get::<_, String>(0)?,
                    row.get::<_, i64>(1)?,
                    from_unix(row.get(2)?),
                ))
            })?;
            rows.collect()
        };
        run().unwrap_or_else(|err| {
            log::warn!("history store query failed: {err}");
            Vec::new()
        })
    }

    /// The most used commands, by count.
    pub fn frequent_commands(&self, limit: usize) -> Vec<FrequentCommand> {
        self.frequent(
            "SELECT command, COUNT(*) AS cnt, MAX(timestamp) AS last_ts
             FROM history GROUP BY command ORDER BY cnt DESC, last_ts DESC LIMIT ?1",
            &[Value::Integer(limit as i64)],
        )
    }

    /// Frequent commands inside a repository (root and subfolders): the
    /// `limit` most used, then sorted by frecency.
    pub fn frequent_commands_for_repo(
        &self,
        repo_root: &str,
        limit: usize,
    ) -> Vec<FrequentCommand> {
        let mut list = self.frequent(
            "SELECT command, COUNT(*) AS cnt, MAX(timestamp) AS last_ts
             FROM history WHERE directory LIKE ?1 ESCAPE '\\' OR directory = ?2
             GROUP BY command ORDER BY cnt DESC, last_ts DESC LIMIT ?3",
            &[
                Value::Text(format!("{}/%", like_escape(repo_root))),
                Value::Text(repo_root.to_string()),
                Value::Integer(limit as i64),
            ],
        );
        let now = Utc::now();
        list.sort_by(|a, b| {
            b.frecency_score_at(now)
                .partial_cmp(&a.frecency_score_at(now))
                .unwrap_or(std::cmp::Ordering::Equal)
        });
        list
    }

    /// Total, succeeded, failed and average duration of the commands run in
    /// a repository.
    pub fn command_stats_for_repo(&self, repo_root: &str) -> CommandStats {
        self.conn
            .query_row(
                "SELECT COUNT(*),
                        COALESCE(SUM(CASE WHEN exit_code = 0 THEN 1 ELSE 0 END), 0),
                        COALESCE(SUM(CASE WHEN exit_code != 0 AND exit_code IS NOT NULL THEN 1 ELSE 0 END), 0),
                        COALESCE(AVG(CASE WHEN duration > 0 THEN duration ELSE NULL END), 0)
                 FROM history WHERE directory LIKE ?1 ESCAPE '\\' OR directory = ?2",
                params![format!("{}/%", like_escape(repo_root)), repo_root],
                |row| {
                    Ok(CommandStats {
                        total: row.get(0)?,
                        successful: row.get(1)?,
                        failed: row.get(2)?,
                        avg_duration: row.get(3)?,
                    })
                },
            )
            .unwrap_or_default()
    }

    /// When the newest command of a repository ran.
    pub fn last_command_timestamp_for_repo(&self, repo_root: &str) -> Option<DateTime<Utc>> {
        let seconds: Option<f64> = self
            .conn
            .query_row(
                "SELECT MAX(timestamp) FROM history WHERE directory LIKE ?1 ESCAPE '\\' OR directory = ?2",
                params![format!("{}/%", like_escape(repo_root)), repo_root],
                |row| row.get(0),
            )
            .ok()
            .flatten();
        seconds.filter(|s| *s > 0.0).map(from_unix)
    }

    pub fn total_count(&self) -> i64 {
        self.conn
            .query_row("SELECT COUNT(*) FROM history", [], |row| row.get(0))
            .unwrap_or(0)
    }

    /// Exact read-only statistics for off-UI snapshots. Unlike legacy display
    /// helpers, real read errors are preserved instead of becoming false zero.
    pub fn statistics(&self) -> Result<(i64, u64), String> {
        let records = self
            .conn
            .query_row("SELECT COUNT(*) FROM history", [], |row| {
                row.get::<_, i64>(0)
            })
            .map_err(|error| error.to_string())?;
        let bytes = if let Some(path) = &self.path {
            let database = std::fs::metadata(path)
                .map_err(|error| error.to_string())?
                .len();
            let wal = PathBuf::from(format!("{}-wal", path.display()));
            let wal = match std::fs::metadata(wal) {
                Ok(metadata) => metadata.len(),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => 0,
                Err(error) => return Err(error.to_string()),
            };
            database.saturating_add(wal)
        } else {
            0
        };
        Ok((records, bytes))
    }

    /// Size of the database file (plus its write-ahead log) in bytes.
    pub fn database_size_bytes(&self) -> u64 {
        let Some(path) = &self.path else { return 0 };
        let size = |p: &Path| std::fs::metadata(p).map(|m| m.len()).unwrap_or(0);
        let wal = PathBuf::from(format!("{}-wal", path.display()));
        size(path) + size(&wal)
    }

    // MARK: export and import

    /// All records (up to `max_records`) as pretty JSON with sorted keys and
    /// ISO 8601 dates, like Swift's `exportJSON`.
    pub fn export_json(&self) -> Option<String> {
        let records: Vec<ExportRecord> = self
            .recent(self.max_records)
            .into_iter()
            .map(ExportRecord::from)
            .collect();
        // `serde_json::Value` keeps object keys sorted.
        let value = serde_json::to_value(records).ok()?;
        serde_json::to_string_pretty(&value).ok()
    }

    /// Add the records of an exported file; returns how many were added (0
    /// for text that is not an export).
    pub fn import_json(&self, text: &str) -> usize {
        let records: Vec<ExportRecord> = match serde_json::from_str(text) {
            Ok(r) => r,
            Err(err) => {
                log::error!("history store: cannot decode import JSON: {err}");
                return 0;
            }
        };
        let mut count = 0;
        for record in records {
            let record: HistoryRecord = record.into();
            if self.insert(&record).is_ok() {
                count += 1;
            }
        }
        log::info!("history store: imported {count} records");
        count
    }

    // MARK: maintenance

    /// Delete every record and shrink the file.
    pub fn clear_all(&self) {
        if let Err(err) = self.conn.execute_batch("DELETE FROM history; VACUUM") {
            log::error!("history store: clear failed: {err}");
        }
        log::info!("history store: cleared all history");
    }

    /// Delete the records older than `days` days.
    pub fn clear_older_than(&self, days: u32) {
        let cutoff = to_unix(Utc::now()) - f64::from(days) * 86_400.0;
        if let Err(err) = self
            .conn
            .execute("DELETE FROM history WHERE timestamp < ?1", params![cutoff])
        {
            log::error!("history store: clear older failed: {err}");
        }
        log::info!("history store: cleared history older than {days} days");
    }

    /// Keep the newest `max` records from now on and trim at once.
    pub fn set_max_records(&mut self, max: usize) {
        self.max_records = max;
        let _ = self.trim_if_needed();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::iso8601::adding_seconds;

    fn store() -> HistoryStore {
        let mut s = HistoryStore::open(Path::new(":memory:")).unwrap();
        s.max_records = 100;
        s
    }

    fn at(command: &str, offset: f64) -> HistoryRecord {
        HistoryRecord {
            timestamp: adding_seconds(Utc::now(), offset),
            ..HistoryRecord::new(command)
        }
    }

    #[test]
    fn statistics_preserve_exact_counts_and_actual_read_errors() {
        let directory =
            std::env::temp_dir().join(format!("chau7-history-statistics-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("owned.sqlite");
        let store = HistoryStore::open(&path).unwrap();
        store.insert(&HistoryRecord::new("owned")).unwrap();
        let observed = store.statistics().unwrap();
        assert_eq!(observed.0, 1);
        assert_eq!(observed.1, store.database_size_bytes());
        assert!(observed.1 > 0);
        drop(store);
        let memory = HistoryStore::open(Path::new(":memory:")).unwrap();
        assert_eq!(memory.statistics().unwrap(), (0, 0));
        memory.insert(&HistoryRecord::new("memory")).unwrap();
        assert_eq!(memory.statistics().unwrap(), (1, 0));
        // A readable SQLite handle must not invent a zero-sized on-disk DB
        // after its path disappears. Reopen the now-empty primary path.
        let mut store = HistoryStore::open(&path).unwrap();
        store.path = Some(directory.join("missing-primary.sqlite"));
        assert!(store.statistics().is_err());
        drop(store);
        drop(memory);
        std::fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn insert_and_retrieve() {
        let s = store();
        let record = HistoryRecord {
            id: None,
            command: "ls -la".into(),
            directory: Some("/tmp".into()),
            exit_code: Some(0),
            shell: Some("zsh".into()),
            tab_id: Some("tab-1".into()),
            session_id: Some("session-1".into()),
            timestamp: Utc::now(),
            duration: Some(0.5),
        };
        s.insert(&record).unwrap();
        let results = s.recent(10);
        assert_eq!(results.len(), 1);
        let r = &results[0];
        assert_eq!(r.command, "ls -la");
        assert_eq!(r.directory.as_deref(), Some("/tmp"));
        assert_eq!(r.exit_code, Some(0));
        assert_eq!(r.shell.as_deref(), Some("zsh"));
        assert_eq!(r.tab_id.as_deref(), Some("tab-1"));
        assert_eq!(r.session_id.as_deref(), Some("session-1"));
        assert!(r.id.is_some());
        assert_eq!(r.duration, Some(0.5));
    }

    #[test]
    fn insert_with_nil_optionals() {
        let s = store();
        s.insert(&HistoryRecord::new("echo hello")).unwrap();
        let r = &s.recent(10)[0];
        assert_eq!(r.command, "echo hello");
        assert_eq!(r.directory, None);
        assert_eq!(r.exit_code, None);
        assert_eq!(r.shell, None);
        assert_eq!(r.tab_id, None);
        // The store's launch id fills a missing session id.
        assert_eq!(r.session_id.as_deref(), Some(s.session_id.as_str()));
        assert_eq!(r.duration, None);
    }

    #[test]
    fn search_with_query_and_limit() {
        let s = store();
        for c in ["git status", "git commit -m 'fix'", "ls -la", "npm install"] {
            s.insert(&at(c, 0.0)).unwrap();
        }
        assert_eq!(s.search("git", 50).len(), 2);
        let ls = s.search("ls", 50);
        assert_eq!(ls.len(), 1);
        assert_eq!(ls[0].command, "ls -la");
        assert!(s.search("python", 50).is_empty());
        for i in 0..20 {
            s.insert(&at(&format!("command-{i}"), f64::from(i)))
                .unwrap();
        }
        assert_eq!(s.search("command", 5).len(), 5);
    }

    #[test]
    fn search_treats_wildcards_literally() {
        let s = store();
        s.insert(&at("echo 100%", 0.0)).unwrap();
        s.insert(&at("echo 1000", 1.0)).unwrap();
        assert_eq!(s.search("100%", 10).len(), 1);
        assert_eq!(s.search("_", 10).len(), 0);
    }

    #[test]
    fn recent_orders_by_timestamp() {
        let s = store();
        s.insert(&at("oldest", -100.0)).unwrap();
        s.insert(&at("newest", 0.0)).unwrap();
        s.insert(&at("middle", -50.0)).unwrap();
        let names: Vec<_> = s.recent(10).into_iter().map(|r| r.command).collect();
        assert_eq!(names, ["newest", "middle", "oldest"]);
        for i in 0..10 {
            s.insert(&at(&format!("cmd-{i}"), 10.0 + f64::from(i)))
                .unwrap();
        }
        let top: Vec<_> = s.recent(3).into_iter().map(|r| r.command).collect();
        assert_eq!(top, ["cmd-9", "cmd-8", "cmd-7"]);
    }

    #[test]
    fn recent_for_directory() {
        let s = store();
        for (c, d) in [
            ("ls", "/home"),
            ("pwd", "/tmp"),
            ("cat file", "/home"),
            ("echo hi", "/var"),
        ] {
            s.insert(&HistoryRecord {
                directory: Some(d.into()),
                ..HistoryRecord::new(c)
            })
            .unwrap();
        }
        let home = s.recent_for_directory("/home", 50);
        assert_eq!(home.len(), 2);
        assert!(home.iter().all(|r| r.directory.as_deref() == Some("/home")));
        assert_eq!(s.recent_for_directory("/tmp", 50)[0].command, "pwd");
        assert!(s.recent_for_directory("/nonexistent", 50).is_empty());
    }

    #[test]
    fn frequent_commands() {
        let s = store();
        for i in 0..3 {
            s.insert(&at("git status", f64::from(i))).unwrap();
        }
        for i in 0..5 {
            s.insert(&at("ls", 10.0 + f64::from(i))).unwrap();
        }
        s.insert(&at("pwd", 0.0)).unwrap();
        let f = s.frequent_commands(10);
        assert_eq!((f[0].command.as_str(), f[0].count), ("ls", 5));
        assert_eq!((f[1].command.as_str(), f[1].count), ("git status", 3));
        assert_eq!((f[2].command.as_str(), f[2].count), ("pwd", 1));
        for i in 0..10 {
            s.insert(&at(&format!("unique-cmd-{i}"), 0.0)).unwrap();
        }
        assert_eq!(s.frequent_commands(3).len(), 3);
    }

    #[test]
    fn repo_frequency_and_stats() {
        let s = store();
        let add = |c: &str, dir: &str, code: Option<i64>, dur: Option<f64>| {
            s.insert(&HistoryRecord {
                directory: Some(dir.into()),
                exit_code: code,
                duration: dur,
                ..HistoryRecord::new(c)
            })
            .unwrap();
        };
        add("cargo build", "/r/app", Some(0), Some(2.0));
        add("cargo build", "/r/app/src", Some(1), Some(4.0));
        add("cargo test", "/r/app", Some(0), None);
        add("cargo build", "/r/app2", Some(0), Some(9.0));
        add("ls", "/other", Some(0), Some(1.0));
        let f = s.frequent_commands_for_repo("/r/app", 10);
        assert_eq!(f.len(), 2);
        assert!(!f[0].command.is_empty());
        let stats = s.command_stats_for_repo("/r/app");
        assert_eq!(stats.total, 3);
        assert_eq!(stats.successful, 2);
        assert_eq!(stats.failed, 1);
        assert!((stats.avg_duration - 3.0).abs() < 1e-9);
        assert!(s.last_command_timestamp_for_repo("/r/app").is_some());
        assert!(s.last_command_timestamp_for_repo("/nope").is_none());
        assert_eq!(s.command_stats_for_repo("/nope"), CommandStats::default());
    }

    #[test]
    fn recent_unique_collapses_duplicates() {
        let s = store();
        s.insert(&at("ls", -30.0)).unwrap();
        s.insert(&at("pwd", -20.0)).unwrap();
        s.insert(&at("ls", -10.0)).unwrap();
        let list = s.recent_unique("", 10);
        let names: Vec<_> = list.iter().map(|r| r.command.as_str()).collect();
        assert_eq!(names, ["ls", "pwd"]);
        assert_eq!(s.recent_unique("pw", 10).len(), 1);
    }

    #[test]
    fn total_count_clear_and_older_than() {
        let s = store();
        assert_eq!(s.total_count(), 0);
        for i in 0..3 {
            s.insert(&at(&format!("old-{i}"), -60.0 * 86_400.0 + f64::from(i)))
                .unwrap();
        }
        for i in 0..2 {
            s.insert(&at(&format!("new-{i}"), -86_400.0 + f64::from(i)))
                .unwrap();
        }
        assert_eq!(s.total_count(), 5);
        s.clear_older_than(30);
        assert_eq!(s.total_count(), 2);
        assert!(s.recent(10).iter().all(|r| r.command.starts_with("new-")));
        s.clear_all();
        assert_eq!(s.total_count(), 0);
        assert!(s.recent(10).is_empty());
    }

    #[test]
    fn trims_at_capacity() {
        let mut s = store();
        s.max_records = 5;
        for i in 0..10 {
            s.insert(&at(&format!("cmd-{i}"), f64::from(i))).unwrap();
        }
        assert!(s.total_count() <= 5);
        assert!(s.recent(10).iter().any(|r| r.command == "cmd-9"));
        s.set_max_records(2);
        assert_eq!(s.total_count(), 2);
    }

    #[test]
    fn export_import_round_trip() {
        let s = store();
        s.insert(&HistoryRecord {
            directory: Some("/test".into()),
            exit_code: Some(0),
            shell: Some("zsh".into()),
            tab_id: Some("t".into()),
            ..HistoryRecord::new("exported-cmd")
        })
        .unwrap();
        let json = s.export_json().unwrap();
        // Swift's key names and whole-second ISO 8601 dates.
        assert!(json.contains("\"exitCode\": 0"));
        assert!(json.contains("\"tabID\": \"t\""));
        assert!(
            regex::Regex::new(r#""timestamp": "\d{4}-\d\d-\d\dT\d\d:\d\d:\d\dZ""#)
                .unwrap()
                .is_match(&json)
        );
        let other = store();
        assert_eq!(other.import_json(&json), 1);
        let r = &other.recent(10)[0];
        assert_eq!(r.command, "exported-cmd");
        assert_eq!(r.directory.as_deref(), Some("/test"));
        assert_eq!(other.import_json("not json"), 0);
    }

    #[test]
    fn file_database_reopens_and_reports_size() {
        let dir = std::env::temp_dir().join(format!("chau7-next-histdb-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("history.db");
        {
            let s = HistoryStore::open(&path).unwrap();
            s.insert(&HistoryRecord::new("persisted")).unwrap();
            assert!(s.database_size_bytes() > 0);
        }
        let s = HistoryStore::open(&path).unwrap();
        assert_eq!(s.recent(1)[0].command, "persisted");
        drop(s);
        // A garbage file is moved aside.
        std::fs::write(&path, b"this is not a database at all, really not").unwrap();
        let _ = std::fs::remove_file(dir.join("history.db-wal"));
        let s = HistoryStore::open(&path).unwrap();
        assert_eq!(s.total_count(), 0);
        let moved = std::fs::read_dir(&dir)
            .unwrap()
            .filter_map(Result::ok)
            .any(|e| e.file_name().to_string_lossy().contains(".corrupt."));
        assert!(moved);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
