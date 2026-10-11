//! Opt-in retention. Zero days means keep forever, including existing profiles.
//! Preview is read-only; pruning is bounded and never removes unfinished runs.
use chrono::{DateTime, Utc};
use rusqlite::{Connection, params_from_iter, types::Value};
use serde::Serialize;

pub const MAX_DAYS: i64 = 3650;
pub fn normalize_days(days: i64) -> i64 {
    days.clamp(0, MAX_DAYS)
}
#[derive(Debug, Clone, Default, Serialize)]
pub struct RetentionPreview {
    pub cutoff: Option<String>,
    pub runs: usize,
    pub turns: usize,
    pub tool_calls: usize,
    pub run_evidence: usize,
    pub usage_evidence: usize,
    pub latency_samples: usize,
    pub remote_events: usize,
}
impl RetentionPreview {
    pub fn rows(&self) -> usize {
        self.runs
            + self.turns
            + self.tool_calls
            + self.run_evidence
            + self.usage_evidence
            + self.latency_samples
            + self.remote_events
    }
}
#[derive(Debug, Clone, Default, Serialize)]
pub struct PruneReport {
    pub runs: usize,
    pub evidence: usize,
    pub latency_samples: usize,
    pub remote_events: usize,
}
impl PruneReport {
    pub fn rows(&self) -> usize {
        self.runs + self.evidence + self.latency_samples + self.remote_events
    }
}
fn cutoff(days: i64, now: DateTime<Utc>) -> Option<String> {
    let days = normalize_days(days);
    (days > 0).then(|| (now.date_naive() - chrono::Duration::days(days)).to_string())
}
fn eligibility(
    column: &str,
    cutoff: &str,
    protected: &[String],
    protect_run: bool,
) -> (String, Vec<Value>) {
    let mut sql = format!("date({column}) < ?");
    let mut args = vec![Value::Text(cutoff.into())];
    if protect_run && !protected.is_empty() {
        let placeholders = vec!["?"; protected.len()].join(",");
        sql.push_str(&format!(
            " AND (run_id IS NULL OR run_id NOT IN ({placeholders}))"
        ));
        args.extend(protected.iter().cloned().map(Value::Text));
    }
    (sql, args)
}
fn run_eligibility(cutoff: &str, protected: &[String]) -> (String, Vec<Value>) {
    let (sql, args) = eligibility("started_at", cutoff, protected, true);
    (format!("ended_at IS NOT NULL AND {sql}"), args)
}
fn count(conn: &Connection, sql: &str, args: &[Value]) -> rusqlite::Result<usize> {
    conn.query_row(sql, params_from_iter(args), |row| row.get(0))
}
pub fn preview(
    conn: &Connection,
    days: i64,
    protected: &[String],
    now: DateTime<Utc>,
) -> rusqlite::Result<RetentionPreview> {
    let Some(cutoff) = cutoff(days, now) else {
        return Ok(RetentionPreview::default());
    };
    let (runs, args) = run_eligibility(&cutoff, protected);
    let selected = format!("SELECT run_id FROM runs WHERE {runs}");
    let run_evidence = count(
        conn,
        &format!(
            "SELECT count(*) FROM usage_evidence WHERE unique_event_key LIKE 'run|%' AND run_id IN ({selected})"
        ),
        &args,
    )?;
    let mut result = RetentionPreview {
        cutoff: Some(cutoff.clone()),
        runs: count(
            conn,
            &format!("SELECT count(*) FROM runs WHERE {runs}"),
            &args,
        )?,
        turns: count(
            conn,
            &format!("SELECT count(*) FROM turns WHERE run_id IN ({selected})"),
            &args,
        )?,
        tool_calls: count(
            conn,
            &format!("SELECT count(*) FROM tool_calls WHERE run_id IN ({selected})"),
            &args,
        )?,
        run_evidence,
        ..Default::default()
    };
    for (table, column, protect_run, slot) in [
        (
            "usage_evidence",
            "observed_at",
            true,
            &mut result.usage_evidence,
        ),
        (
            "provider_latency_samples",
            "observed_at",
            true,
            &mut result.latency_samples,
        ),
        (
            "remote_client_events",
            "timestamp",
            false,
            &mut result.remote_events,
        ),
    ] {
        let (eligible, mut args) = eligibility(column, &cutoff, protected, protect_run);
        let extra = if table == "usage_evidence" {
            args.extend(run_eligibility(&cutoff, protected).1);
            format!(" AND NOT (unique_event_key LIKE 'run|%' AND run_id IN ({selected}))")
        } else {
            String::new()
        };
        *slot = count(
            conn,
            &format!("SELECT count(*) FROM {table} WHERE {eligible}{extra}"),
            &args,
        )?;
    }
    Ok(result)
}
/// Caller must supply a policy explicitly chosen by the user. No built-in expiry.
pub fn prune(
    conn: &Connection,
    days: i64,
    protected: &[String],
    limit: usize,
    now: DateTime<Utc>,
) -> rusqlite::Result<PruneReport> {
    let Some(cutoff) = cutoff(days, now) else {
        return Ok(PruneReport::default());
    };
    let limit = limit.clamp(1, 100);
    let (eligible, mut args) = run_eligibility(&cutoff, protected);
    args.push(Value::Integer(limit as i64));
    let tx = conn.unchecked_transaction()?;
    let ids: Vec<String> = tx
        .prepare(&format!(
            "SELECT run_id FROM runs WHERE {eligible} ORDER BY started_at,run_id LIMIT ?"
        ))?
        .query_map(params_from_iter(args), |row| row.get(0))?
        .collect::<rusqlite::Result<_>>()?;
    let mut result = PruneReport::default();
    for id in ids {
        result.evidence += tx.execute(
            "DELETE FROM usage_evidence WHERE run_id=?1 AND unique_event_key LIKE 'run|%'",
            [&id],
        )?;
        result.runs += tx.execute("DELETE FROM runs WHERE run_id=?1", [&id])?;
    }
    for (table, column, protect_run, slot) in [
        ("usage_evidence", "observed_at", true, &mut result.evidence),
        (
            "provider_latency_samples",
            "observed_at",
            true,
            &mut result.latency_samples,
        ),
        (
            "remote_client_events",
            "timestamp",
            false,
            &mut result.remote_events,
        ),
    ] {
        let (eligible, mut args) = eligibility(column, &cutoff, protected, protect_run);
        args.push(Value::Integer((limit * 5) as i64));
        *slot += tx.execute(&format!("DELETE FROM {table} WHERE rowid IN (SELECT rowid FROM {table} WHERE {eligible} ORDER BY {column},rowid LIMIT ?)"), params_from_iter(args))?;
    }
    tx.commit()?;
    Ok(result)
}
#[cfg(test)]
mod tests {
    use super::*;
    fn fixture() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch("PRAGMA foreign_keys=ON;
        CREATE TABLE runs(run_id TEXT PRIMARY KEY,started_at TEXT,ended_at TEXT);
        CREATE TABLE turns(turn_id TEXT PRIMARY KEY,run_id TEXT REFERENCES runs(run_id) ON DELETE CASCADE);
        CREATE TABLE tool_calls(call_id TEXT,run_id TEXT REFERENCES runs(run_id) ON DELETE CASCADE);
        CREATE TABLE proxy_run_baselines(run_id TEXT REFERENCES runs(run_id) ON DELETE CASCADE);
        CREATE TABLE usage_evidence(unique_event_key TEXT,run_id TEXT,observed_at TEXT);
        CREATE TABLE provider_latency_samples(run_id TEXT,observed_at TEXT);
        CREATE TABLE remote_client_events(timestamp TEXT);").unwrap();
        c
    }
    fn now() -> DateTime<Utc> {
        "2026-10-11T13:00:00Z".parse().unwrap()
    }
    #[test]
    fn default_and_disabled_preview_never_remove_data() {
        let c = fixture();
        c.execute(
            "INSERT INTO runs VALUES ('old','2020-01-01','2020-01-01')",
            [],
        )
        .unwrap();
        assert_eq!(preview(&c, 0, &[], now()).unwrap().rows(), 0);
        assert_eq!(prune(&c, 0, &[], 100, now()).unwrap().rows(), 0);
        assert_eq!(count(&c, "SELECT count(*) FROM runs", &[]).unwrap(), 1);
        assert_eq!(normalize_days(-1), 0);
        assert_eq!(normalize_days(10_000), 3650);
    }
    #[test]
    fn preview_is_read_only_and_pruning_is_bounded_cascaded_and_protected() {
        let c = fixture();
        c.execute_batch("INSERT INTO runs VALUES ('old','2026-08-01','2026-08-02'),('old2','2026-08-01','2026-08-02'),('active','2026-08-01',NULL),('protected','2026-08-01','2026-08-02'),('boundary','2026-09-11T00:00:00Z','2026-09-11');
        INSERT INTO turns VALUES ('turn','old');INSERT INTO tool_calls VALUES ('tool','old');INSERT INTO proxy_run_baselines VALUES ('old');
        INSERT INTO usage_evidence VALUES ('run|old','old','2026-10-10'),('request|old','old','2026-08-01'),('request|active','active','2026-08-01');
        INSERT INTO provider_latency_samples VALUES ('protected','2026-08-01');").unwrap();
        let protected = vec!["protected".into(), "active".into()];
        let p = preview(&c, 30, &protected, now()).unwrap();
        assert_eq!(p.runs, 2);
        assert_eq!(p.turns, 1);
        assert_eq!(p.tool_calls, 1);
        assert_eq!(p.run_evidence, 1);
        assert_eq!(p.usage_evidence, 1);
        assert_eq!(count(&c, "SELECT count(*) FROM runs", &[]).unwrap(), 5);
        assert_eq!(prune(&c, 30, &protected, 1, now()).unwrap().runs, 1);
        for table in ["turns", "tool_calls", "proxy_run_baselines"] {
            assert_eq!(
                count(&c, &format!("SELECT count(*) FROM {table}"), &[]).unwrap(),
                0
            );
        }
        assert_eq!(
            count(&c, "SELECT count(*) FROM usage_evidence", &[]).unwrap(),
            1
        );
        assert_eq!(
            count(&c, "SELECT count(*) FROM provider_latency_samples", &[]).unwrap(),
            1
        );
        assert_eq!(prune(&c, 30, &protected, 1, now()).unwrap().runs, 1);
        assert_eq!(preview(&c, 30, &protected, now()).unwrap().rows(), 0);
        assert_eq!(count(&c, "SELECT count(*) FROM runs", &[]).unwrap(), 3);
    }
    #[test]
    fn unscoped_rows_prune_without_old_runs() {
        let c = fixture();
        c.execute_batch("INSERT INTO usage_evidence VALUES ('request',NULL,'2026-08-01');INSERT INTO provider_latency_samples VALUES (NULL,'2026-08-01');INSERT INTO remote_client_events VALUES ('2026-08-01');").unwrap();
        let p = preview(&c, 30, &[], now()).unwrap();
        assert_eq!(p.rows(), 3);
        assert_eq!(prune(&c, 30, &[], 1, now()).unwrap().rows(), 3);
        assert_eq!(preview(&c, 30, &[], now()).unwrap().rows(), 0);
    }
}
