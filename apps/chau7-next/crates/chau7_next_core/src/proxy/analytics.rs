//! Read-only API charts. Normalize each request before aggregation and retain
//! nullable measurement coverage rather than converting missing evidence to zero.
mod calendar;

use chrono::{DateTime, Local, TimeZone, Utc};
use rusqlite::{Connection, OpenFlags, Row, params};
use serde::{Deserialize, Serialize};
use std::{collections::HashSet, path::Path, time::Instant};

pub const MODEL_LIMIT: usize = 1000;
pub const PROVIDER_LIMIT: usize = 100;
pub const RECENT_LIMIT: usize = 30;
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum AnalyticsRange {
    Today,
    #[default]
    Week,
    TwoWeeks,
    Month,
    AllTime,
}
impl AnalyticsRange {
    pub const ALL: [Self; 5] = [
        Self::Today,
        Self::Week,
        Self::TwoWeeks,
        Self::Month,
        Self::AllTime,
    ];
    pub fn label(self) -> &'static str {
        match self {
            Self::Today => "Today",
            Self::Week => "7 Days",
            Self::TwoWeeks => "14 Days",
            Self::Month => "30 Days",
            Self::AllTime => "All Time",
        }
    }
    pub fn chart_days(self) -> u64 {
        match self {
            Self::Today => 1,
            Self::Week => 7,
            Self::TwoWeeks => 14,
            Self::Month => 30,
            Self::AllTime => 90,
        }
    }
    pub fn after<Tz: TimeZone>(self, now: DateTime<Tz>) -> Option<DateTime<Utc>> {
        match self {
            Self::Today => calendar::start_of_day(now),
            Self::AllTime => None,
            _ => calendar::subtract_days(now, self.chart_days()),
        }
    }
}
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum TrendMetric {
    #[default]
    Cost,
    Tokens,
}
impl TrendMetric {
    pub const ALL: [Self; 2] = [Self::Cost, Self::Tokens];
    pub fn label(self) -> &'static str {
        match self {
            Self::Cost => "Cost",
            Self::Tokens => "Tokens",
        }
    }
}
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Measured<T> {
    pub value: Option<T>,
    pub observed_calls: usize,
}
#[derive(Debug, Clone, Default, PartialEq, Serialize)]
pub struct Metrics {
    pub calls: usize,
    pub status_observed_calls: usize,
    pub failed_calls: usize,
    pub complete_token_calls: usize,
    pub timestamp_observed_calls: usize,
    pub input: Measured<i64>,
    pub cache_write: Measured<i64>,
    pub cache_read: Measured<i64>,
    pub output: Measured<i64>,
    pub reasoning: Measured<i64>,
    pub billable_tokens: Measured<i64>,
    pub recorded_cost_usd: Measured<f64>,
    pub average_latency_ms: Measured<f64>,
}
impl Metrics {
    pub fn error_rate(&self) -> Option<f64> {
        (self.status_observed_calls > 0)
            .then(|| self.failed_calls as f64 / self.status_observed_calls as f64)
    }
}
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Breakdown {
    pub provider: String,
    pub model: Option<String>,
    pub metrics: Metrics,
}
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct DailyPoint {
    pub date: String,
    pub metrics: Metrics,
}
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct RecentCall {
    pub id: i64,
    pub provider: String,
    pub model: String,
    pub endpoint: Option<String>,
    pub metrics: Metrics,
    pub status_code: Option<i64>,
    pub timestamp: Option<DateTime<Utc>>,
    pub error_message: Option<String>,
    pub pricing_version: Option<String>,
}
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Dashboard {
    pub schema_version: u32,
    pub range: AnalyticsRange,
    pub captured_at: DateTime<Utc>,
    pub load_elapsed_ms: f64,
    pub overall: Metrics,
    pub providers: Vec<Breakdown>,
    pub models: Vec<Breakdown>,
    pub daily: Vec<DailyPoint>,
    pub recent: Vec<RecentCall>,
    pub provider_dimensions_truncated: bool,
    pub model_dimensions_truncated: bool,
}
#[derive(Debug, Clone, PartialEq)]
pub struct PieSegment {
    pub provider: String,
    pub fraction: f64,
    pub start: f64,
    pub end: f64,
}
/// Shares describe only recorded positive cost, with no invented slice for unknown cost.
pub fn cost_segments(providers: &[Breakdown]) -> Vec<PieSegment> {
    let total: f64 = providers
        .iter()
        .filter_map(|p| p.metrics.recorded_cost_usd.value)
        .filter(|v| v.is_finite() && *v > 0.)
        .sum();
    if !total.is_finite() || total <= 0. {
        return vec![];
    }
    let mut position = 0.;
    providers
        .iter()
        .filter_map(|p| {
            let value = p
                .metrics
                .recorded_cost_usd
                .value
                .filter(|v| v.is_finite() && *v > 0.)?;
            let fraction = value / total;
            let start = position;
            position += fraction;
            Some(PieSegment {
                provider: p.provider.clone(),
                fraction,
                start,
                end: position.min(1.),
            })
        })
        .collect()
}
pub fn trend_value(point: &DailyPoint, metric: TrendMetric) -> Option<f64> {
    match metric {
        TrendMetric::Cost => point.metrics.recorded_cost_usd.value,
        TrendMetric::Tokens => point.metrics.billable_tokens.value.map(|v| v as f64),
    }
}
pub fn normalized_bar(value: Option<f64>, maximum: f64) -> Option<f32> {
    value.filter(|v| v.is_finite() && *v >= 0.).map(|v| {
        if maximum.is_finite() && maximum > 0. {
            (v / maximum).clamp(0., 1.) as f32
        } else {
            0.
        }
    })
}

fn optional_column(columns: &HashSet<String>, name: &str) -> String {
    if columns.contains(name) {
        name.into()
    } else {
        "NULL".into()
    }
}
fn nonnegative(expr: &str) -> String {
    format!("CASE WHEN {expr} >= 0 THEN {expr} END")
}
struct SqlMetrics {
    provider: String,
    model: String,
    columns: HashSet<String>,
    aggregate: String,
}
impl SqlMetrics {
    fn new(conn: &Connection) -> rusqlite::Result<Self> {
        let mut stmt = conn.prepare("PRAGMA table_info(api_calls)")?;
        let columns: HashSet<String> = stmt
            .query_map([], |r| r.get(1))?
            .collect::<rusqlite::Result<_>>()?;
        if !columns.contains("provider") || !columns.contains("timestamp") {
            return Err(rusqlite::Error::InvalidQuery);
        }
        let raw_provider = "LOWER(TRIM(provider))";
        let provider = format!(
            "CASE WHEN {raw_provider} IN ('claude','anthropic') THEN 'anthropic' WHEN {raw_provider} IN ('codex','chatgpt','openai') THEN 'openai' WHEN {raw_provider} IN ('google','gemini') THEN 'google' ELSE COALESCE(NULLIF({raw_provider},''),'unknown') END"
        );
        let model = format!(
            "COALESCE(NULLIF(TRIM({}),''),'(unknown)')",
            optional_column(&columns, "model")
        );
        let raw_input = optional_column(&columns, "input_tokens");
        let raw_output = optional_column(&columns, "output_tokens");
        let creation = nonnegative(&optional_column(&columns, "cache_creation_input_tokens"));
        let read = nonnegative(&optional_column(&columns, "cache_read_input_tokens"));
        let reasoning = nonnegative(&optional_column(&columns, "reasoning_output_tokens"));
        // Match Swift and TokenUsage::provider: OpenAI/Gemini inclusive input,
        // OpenAI inclusive reasoning output. Normalize per row before SUM.
        let input = format!(
            "CASE WHEN {raw_input} >= 0 THEN CASE WHEN {raw_provider} IN ('openai','codex','chatgpt','gemini','google') THEN MAX({raw_input}-COALESCE(({read}),0),0) ELSE {raw_input} END END"
        );
        let output = format!(
            "CASE WHEN {raw_output} >= 0 THEN CASE WHEN {raw_provider} IN ('openai','codex','chatgpt') THEN MAX({raw_output}-COALESCE(({reasoning}),0),0) ELSE {raw_output} END END"
        );
        let counters = [input, creation, read, output, reasoning];
        let any = counters
            .iter()
            .map(|e| format!("({e}) IS NOT NULL"))
            .collect::<Vec<_>>()
            .join(" OR ");
        let sum = counters
            .iter()
            .map(|e| format!("COALESCE(({e}),0)"))
            .collect::<Vec<_>>()
            .join("+");
        let billable = format!("CASE WHEN {any} THEN {sum} END");
        let cost = optional_column(&columns, "cost_usd");
        let cost =
            format!("CASE WHEN {cost} >= 0 AND {cost} <= 1.7976931348623157e308 THEN {cost} END");
        let latency = nonnegative(&optional_column(&columns, "latency_ms"));
        let status = optional_column(&columns, "status_code");
        let mut aggregate = format!(
            "COUNT(*), COUNT(CASE WHEN {status} BETWEEN 100 AND 599 THEN 1 END), COUNT(CASE WHEN {status} BETWEEN 100 AND 599 AND ({status}<200 OR {status}>=300) THEN 1 END), COUNT(CASE WHEN {raw_input} >= 0 AND {raw_output} >= 0 THEN 1 END), COUNT(julianday(timestamp))"
        );
        for expression in counters.iter().chain([&billable, &cost]) {
            aggregate.push_str(&format!(", SUM(({expression})), COUNT(({expression}))"));
        }
        aggregate.push_str(&format!(", AVG(({latency})), COUNT(({latency}))"));
        Ok(Self {
            provider,
            model,
            columns,
            aggregate,
        })
    }
    fn select(&self, key1: &str, key2: &str) -> String {
        format!("SELECT {key1}, {key2}, {} FROM api_calls", self.aggregate)
    }
}
fn counts(row: &Row<'_>, index: usize) -> rusqlite::Result<usize> {
    Ok(row.get::<_, i64>(index)?.max(0) as usize)
}
fn integer_metric(row: &Row<'_>, index: usize) -> rusqlite::Result<Measured<i64>> {
    Ok(Measured {
        value: row.get::<_, Option<i64>>(index)?.filter(|v| *v >= 0),
        observed_calls: counts(row, index + 1)?,
    })
}
fn float_metric(row: &Row<'_>, index: usize) -> rusqlite::Result<Measured<f64>> {
    Ok(Measured {
        value: row
            .get::<_, Option<f64>>(index)?
            .filter(|v| v.is_finite() && *v >= 0.),
        observed_calls: counts(row, index + 1)?,
    })
}
fn metrics(row: &Row<'_>) -> rusqlite::Result<Metrics> {
    Ok(Metrics {
        calls: counts(row, 2)?,
        status_observed_calls: counts(row, 3)?,
        failed_calls: counts(row, 4)?,
        complete_token_calls: counts(row, 5)?,
        timestamp_observed_calls: counts(row, 6)?,
        input: integer_metric(row, 7)?,
        cache_write: integer_metric(row, 9)?,
        cache_read: integer_metric(row, 11)?,
        output: integer_metric(row, 13)?,
        reasoning: integer_metric(row, 15)?,
        billable_tokens: integer_metric(row, 17)?,
        recorded_cost_usd: float_metric(row, 19)?,
        average_latency_ms: float_metric(row, 21)?,
    })
}
fn query_breakdown(
    conn: &Connection,
    sql: &SqlMetrics,
    after: Option<&str>,
    models: bool,
) -> rusqlite::Result<(Vec<Breakdown>, bool)> {
    let key2 = if models { sql.model.as_str() } else { "''" };
    let query = format!(
        "{} WHERE (?1 IS NULL OR julianday(timestamp)>=julianday(?1)) GROUP BY 1,2 ORDER BY SUM({}) DESC,COUNT(*) DESC,1,2 LIMIT ?2",
        sql.select(&sql.provider, key2),
        optional_column(&sql.columns, "cost_usd")
    );
    let limit = if models { MODEL_LIMIT } else { PROVIDER_LIMIT };
    let mut stmt = conn.prepare(&query)?;
    let mut rows = stmt
        .query_map(params![after, (limit + 1) as i64], |row| {
            Ok(Breakdown {
                provider: row.get(0)?,
                model: models.then(|| row.get(1)).transpose()?,
                metrics: metrics(row)?,
            })
        })?
        .collect::<rusqlite::Result<Vec<_>>>()?;
    let truncated = rows.len() > limit;
    rows.truncate(limit);
    Ok((rows, truncated))
}
fn load_connection(
    conn: &mut Connection,
    range: AnalyticsRange,
    now: DateTime<Utc>,
    after: Option<DateTime<Utc>>,
) -> rusqlite::Result<Dashboard> {
    // Only All Time intentionally has no lower bound. A failed calendar
    // conversion must never silently turn a bounded KPI into all-time data.
    if range != AnalyticsRange::AllTime && after.is_none() {
        return Err(rusqlite::Error::InvalidQuery);
    }
    let began = Instant::now();
    let tx = conn.transaction()?;
    let sql = SqlMetrics::new(&tx)?;
    let after = after.map(|at| at.to_rfc3339());
    let query = format!(
        "{} WHERE (?1 IS NULL OR julianday(timestamp)>=julianday(?1))",
        sql.select("''", "''")
    );
    let overall = tx.query_row(&query, [after.as_deref()], metrics)?;
    let (providers, provider_dimensions_truncated) =
        query_breakdown(&tx, &sql, after.as_deref(), false)?;
    let (models, model_dimensions_truncated) = query_breakdown(&tx, &sql, after.as_deref(), true)?;
    // Swift's dailyTrend(days:) is a rolling 1/7/14/30/90-day chart,
    // separate from the Today KPI's local-midnight boundary.
    let chart_after = calendar::subtract_days(now.with_timezone(&Local), range.chart_days())
        .map(|d| d.to_rfc3339())
        .ok_or(rusqlite::Error::InvalidQuery)?;
    let day = "date(datetime(timestamp,'localtime'))";
    let query = format!(
        "{} WHERE julianday(timestamp)>=julianday(?1) AND {day} IS NOT NULL GROUP BY 1 ORDER BY 1",
        sql.select(day, "''")
    );
    let daily = {
        let mut stmt = tx.prepare(&query)?;
        stmt.query_map([chart_after], |row| {
            Ok(DailyPoint {
                date: row.get(0)?,
                metrics: metrics(row)?,
            })
        })?
        .collect::<rusqlite::Result<_>>()?
    };
    let extra = [
        "timestamp",
        "status_code",
        "endpoint",
        "error_message",
        "pricing_version",
    ]
    .map(|c| optional_column(&sql.columns, c))
    .join(",");
    let id = if sql.columns.contains("id") {
        "id"
    } else {
        "rowid"
    };
    // Swift's recent calls are latest across all time, independent of the KPI range.
    let query = format!(
        "SELECT {},{}, {},{extra},{id} FROM api_calls GROUP BY {id} ORDER BY julianday(timestamp) DESC,{id} DESC LIMIT ?1",
        sql.provider, sql.model, sql.aggregate
    );
    let recent = {
        let mut stmt = tx.prepare(&query)?;
        stmt.query_map([RECENT_LIMIT as i64], |row| {
            Ok(RecentCall {
                id: row.get(28)?,
                provider: row.get(0)?,
                model: row.get(1)?,
                metrics: metrics(row)?,
                timestamp: row
                    .get::<_, Option<String>>(23)?
                    .as_deref()
                    .and_then(super::parse_db_time),
                status_code: row.get(24)?,
                endpoint: row.get(25)?,
                error_message: row.get(26)?,
                pricing_version: row.get(27)?,
            })
        })?
        .collect::<rusqlite::Result<_>>()?
    };
    tx.commit()?;
    Ok(Dashboard {
        schema_version: 1,
        range,
        captured_at: now,
        load_elapsed_ms: began.elapsed().as_secs_f64() * 1000.,
        overall,
        providers,
        models,
        daily,
        recent,
        provider_dimensions_truncated,
        model_dimensions_truncated,
    })
}
/// A snapshot transaction keeps all chart projections consistent under concurrent writes.
/// This only opens SQLite read-only and is intended for a background executor.
pub fn load(path: &Path, range: AnalyticsRange) -> Result<Dashboard, String> {
    if !path.is_file() {
        return Err("No proxy database exists yet. Enable API Analytics to capture calls.".into());
    }
    let mut conn = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|e| format!("API analytics unavailable: {e}"))?;
    conn.busy_timeout(std::time::Duration::from_secs(1))
        .map_err(|e| e.to_string())?;
    let now = Local::now();
    load_connection(&mut conn, range, now.with_timezone(&Utc), range.after(now))
        .map_err(|e| format!("API analytics unavailable: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;
    fn modern() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        c.execute_batch("CREATE TABLE api_calls(id INTEGER PRIMARY KEY,provider TEXT,model TEXT,endpoint TEXT,input_tokens INTEGER,output_tokens INTEGER,cache_creation_input_tokens INTEGER,cache_read_input_tokens INTEGER,reasoning_output_tokens INTEGER,cost_usd REAL,latency_ms INTEGER,status_code INTEGER,timestamp TEXT,error_message TEXT,pricing_version TEXT);").unwrap();
        c
    }
    fn now() -> DateTime<Utc> {
        DateTime::parse_from_rfc3339("2026-10-11T12:00:00Z")
            .unwrap()
            .with_timezone(&Utc)
    }
    fn dashboard(c: &mut Connection) -> Dashboard {
        load_connection(c, AnalyticsRange::AllTime, now(), None).unwrap()
    }
    #[test]
    fn bounded_range_cannot_silently_become_all_time() {
        let mut connection = modern();
        let result = load_connection(&mut connection, AnalyticsRange::Week, now(), None);
        assert!(matches!(result, Err(rusqlite::Error::InvalidQuery)));
        assert!(load_connection(&mut connection, AnalyticsRange::AllTime, now(), None).is_ok());
    }
    #[test]
    fn missing_values_are_distinct_from_observed_zero_and_partial_coverage() {
        let mut c = modern();
        c.execute_batch("INSERT INTO api_calls(id,provider,model,timestamp) VALUES(1,'openai','m','2026-10-11T10:00:00Z');").unwrap();
        let d = dashboard(&mut c);
        assert_eq!(d.overall.calls, 1);
        assert_eq!(d.overall.billable_tokens.value, None);
        assert_eq!(d.overall.recorded_cost_usd.value, None);
        assert_eq!(d.overall.error_rate(), None);
        assert_eq!(d.recent[0].metrics.billable_tokens.value, None);
        c.execute_batch("INSERT INTO api_calls(id,provider,model,input_tokens,output_tokens,cost_usd,latency_ms,status_code,timestamp) VALUES(2,'openai','m',0,0,0,0,200,'2026-10-11T11:00:00Z');").unwrap();
        let d = dashboard(&mut c);
        assert_eq!(d.overall.calls, 2);
        assert_eq!(d.overall.billable_tokens.value, Some(0));
        assert_eq!(d.overall.billable_tokens.observed_calls, 1);
        assert_eq!(d.overall.complete_token_calls, 1);
        assert_eq!(d.overall.recorded_cost_usd.value, Some(0.));
        assert_eq!(d.overall.recorded_cost_usd.observed_calls, 1);
        assert_eq!(d.overall.average_latency_ms.value, Some(0.));
        assert_eq!(d.overall.error_rate(), Some(0.));
        assert!(cost_segments(&d.providers).is_empty());
    }
    #[test]
    fn provider_aliases_and_per_row_inclusive_counters_match_canonical_usage() {
        let mut c = modern();
        c.execute_batch("INSERT INTO api_calls(id,provider,model,input_tokens,output_tokens,cache_read_input_tokens,reasoning_output_tokens,cost_usd,status_code,timestamp) VALUES(1,'Codex','m',100,50,20,10,1,200,'2026-10-11T10:00:00Z'),(2,'OPENAI','m',10,20,20,10,2,500,'2026-10-11T11:00:00Z');").unwrap();
        let d = dashboard(&mut c);
        assert_eq!(d.providers.len(), 1);
        assert_eq!(d.providers[0].provider, "openai");
        assert_eq!(d.overall.input.value, Some(80));
        assert_eq!(d.overall.output.value, Some(50));
        assert_eq!(d.overall.cache_read.value, Some(40));
        assert_eq!(d.overall.reasoning.value, Some(20));
        assert_eq!(d.overall.billable_tokens.value, Some(190));
        assert_eq!(d.overall.error_rate(), Some(0.5));
        assert_eq!(d.models[0].metrics, d.overall);
    }
    #[test]
    fn legacy_optional_columns_are_unknown_and_query_does_not_migrate() {
        let mut c = Connection::open_in_memory().unwrap();
        c.execute_batch("CREATE TABLE api_calls(id INTEGER PRIMARY KEY,provider TEXT,model TEXT,input_tokens INTEGER,output_tokens INTEGER,cost_usd REAL,timestamp TEXT);INSERT INTO api_calls VALUES(1,'anthropic','m',10,5,NULL,'2026-10-11 10:00:00');").unwrap();
        let d = dashboard(&mut c);
        assert_eq!(d.overall.billable_tokens.value, Some(15));
        assert_eq!(d.overall.cache_read.value, None);
        assert_eq!(d.overall.reasoning.value, None);
        assert_eq!(d.overall.recorded_cost_usd.value, None);
        assert!(d.recent[0].timestamp.is_some());
        let columns = SqlMetrics::new(&c).unwrap().columns;
        assert!(!columns.contains("cache_read_input_tokens"));
    }
    #[test]
    fn periods_filter_numeric_dates_and_all_time_chart_is_only_last_90_days() {
        let mut c = modern();
        c.execute_batch("INSERT INTO api_calls(id,provider,model,input_tokens,output_tokens,cost_usd,status_code,timestamp) VALUES(1,'anthropic','old',1,1,1,200,'2026-01-01T10:00:00Z'),(2,'anthropic','new',10,5,2,200,'2026-10-11T11:00:00Z');").unwrap();
        let all = dashboard(&mut c);
        assert_eq!(all.overall.calls, 2);
        assert_eq!(all.daily.iter().map(|p| p.metrics.calls).sum::<usize>(), 1);
        let week = load_connection(
            &mut c,
            AnalyticsRange::Week,
            now(),
            AnalyticsRange::Week.after(now()),
        )
        .unwrap();
        assert_eq!(week.overall.calls, 1);
        assert_eq!(week.models[0].model.as_deref(), Some("new"));
        assert_eq!(week.recent.len(), 2);
        c.execute("INSERT INTO api_calls(id,provider,input_tokens,output_tokens,timestamp) VALUES(3,'anthropic',2,3,'2026-10-10T18:00:00Z')", []).unwrap();
        let today = load_connection(
            &mut c,
            AnalyticsRange::Today,
            now(),
            AnalyticsRange::Today.after(now()),
        )
        .unwrap();
        assert_eq!(today.overall.calls, 1);
        assert_eq!(
            today.daily.iter().map(|p| p.metrics.calls).sum::<usize>(),
            2
        );
        let local = DateTime::parse_from_rfc3339("2026-10-11T12:00:00+02:00").unwrap();
        assert_eq!(
            AnalyticsRange::Today.after(local).unwrap().to_rfc3339(),
            "2026-10-10T22:00:00+00:00"
        );
        assert_eq!(
            AnalyticsRange::Week.after(local).unwrap().to_rfc3339(),
            "2026-10-04T10:00:00+00:00"
        );
    }
    #[test]
    fn unknown_and_zero_chart_values_never_create_cost_slices() {
        let metrics = |value| Metrics {
            recorded_cost_usd: Measured {
                value,
                observed_calls: usize::from(value.is_some()),
            },
            ..Default::default()
        };
        let providers = vec![
            Breakdown {
                provider: "unknown".into(),
                model: None,
                metrics: metrics(None),
            },
            Breakdown {
                provider: "zero".into(),
                model: None,
                metrics: metrics(Some(0.)),
            },
            Breakdown {
                provider: "a".into(),
                model: None,
                metrics: metrics(Some(1.)),
            },
            Breakdown {
                provider: "b".into(),
                model: None,
                metrics: metrics(Some(3.)),
            },
        ];
        let segments = cost_segments(&providers);
        assert_eq!(segments.len(), 2);
        assert_eq!(segments[0].fraction, 0.25);
        assert_eq!(segments[1].start, 0.25);
        assert_eq!(segments[1].end, 1.);
        assert_eq!(normalized_bar(None, 10.), None);
        assert_eq!(normalized_bar(Some(f64::NAN), 10.), None);
        assert_eq!(normalized_bar(Some(0.), 0.), Some(0.));
        assert_eq!(normalized_bar(Some(5.), 10.), Some(0.5));
    }
    #[test]
    fn dimension_and_recent_budgets_keep_overall_totals_complete() {
        let mut c = modern();
        {
            let tx = c.transaction().unwrap();
            {
                let mut stmt = tx.prepare("INSERT INTO api_calls(id,provider,model,input_tokens,output_tokens,cost_usd,status_code,timestamp) VALUES(?1,'anthropic',?2,1,1,1,200,'2026-10-11T10:00:00Z')").unwrap();
                for id in 1..=(MODEL_LIMIT + 2) {
                    stmt.execute(params![id as i64, format!("model-{id}")])
                        .unwrap();
                }
            }
            tx.commit().unwrap();
        }
        let d = dashboard(&mut c);
        assert_eq!(d.overall.calls, MODEL_LIMIT + 2);
        assert_eq!(
            d.overall.billable_tokens.value,
            Some((MODEL_LIMIT as i64 + 2) * 2)
        );
        assert_eq!(d.models.len(), MODEL_LIMIT);
        assert!(d.model_dimensions_truncated);
        assert!(!d.provider_dimensions_truncated);
        assert_eq!(d.recent.len(), RECENT_LIMIT);
        assert_eq!(d.recent[0].id, (MODEL_LIMIT + 2) as i64);
    }
    #[test]
    fn real_file_loader_preserves_database_bytes() {
        let path =
            std::env::temp_dir().join(format!("chau7-chart-readonly-{}.db", uuid::Uuid::new_v4()));
        {
            let c = Connection::open(&path).unwrap();
            c.execute_batch("CREATE TABLE api_calls(id INTEGER PRIMARY KEY,provider TEXT,input_tokens INTEGER,output_tokens INTEGER,cost_usd REAL,timestamp TEXT);INSERT INTO api_calls VALUES(1,'openai',0,0,NULL,'2026-10-11T10:00:00Z');").unwrap();
        }
        let before = std::fs::read(&path).unwrap();
        let d = load(&path, AnalyticsRange::AllTime).unwrap();
        assert_eq!(d.overall.calls, 1);
        assert_eq!(d.overall.billable_tokens.value, Some(0));
        assert_eq!(d.overall.recorded_cost_usd.value, None);
        assert_eq!(std::fs::read(&path).unwrap(), before);
        std::fs::remove_file(path).unwrap();
    }
    #[test]
    fn missing_database_is_unavailable_and_never_created() {
        let path =
            std::env::temp_dir().join(format!("chau7-chart-missing-{}.db", uuid::Uuid::new_v4()));
        assert!(load(&path, AnalyticsRange::Week).is_err());
        assert!(!path.exists());
    }
}
