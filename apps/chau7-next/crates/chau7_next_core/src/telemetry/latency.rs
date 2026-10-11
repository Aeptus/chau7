//! Provider request and first-response latency with separate provenance.
use super::{
    run::TelemetryRun,
    turn::{TelemetryTurn, TurnRole},
};
use chrono::{DateTime, Datelike, Local, TimeZone, Timelike, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap};
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MetricKind {
    ApiRequest,
    FirstResponse,
}
impl MetricKind {
    pub fn label(self) -> &'static str {
        match self {
            Self::ApiRequest => "API Response",
            Self::FirstResponse => "Round Trip",
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum TimeRange {
    Today,
    Week,
    TwoWeeks,
    Month,
    Quarter,
    AllTime,
}
impl TimeRange {
    pub const ALL: [Self; 6] = [
        Self::Today,
        Self::Week,
        Self::TwoWeeks,
        Self::Month,
        Self::Quarter,
        Self::AllTime,
    ];
    pub fn label(self) -> &'static str {
        match self {
            Self::Today => "Today",
            Self::Week => "7 Days",
            Self::TwoWeeks => "14 Days",
            Self::Month => "30 Days",
            Self::Quarter => "90 Days",
            Self::AllTime => "All Time",
        }
    }
    pub fn start(self, now: DateTime<Utc>) -> Option<DateTime<Utc>> {
        match self {
            Self::AllTime => None,
            Self::Today => Local
                .from_local_datetime(
                    &now.with_timezone(&Local)
                        .date_naive()
                        .and_hms_opt(0, 0, 0)?,
                )
                .earliest()
                .map(|d| d.with_timezone(&Utc)),
            range => Some(
                now - chrono::Duration::days(match range {
                    Self::Week => 7,
                    Self::TwoWeeks => 14,
                    Self::Month => 30,
                    Self::Quarter => 90,
                    _ => 0,
                }),
            ),
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum BucketKind {
    Day,
    Weekday,
    Period,
    Hour,
}
impl BucketKind {
    pub const ALL: [Self; 4] = [Self::Day, Self::Weekday, Self::Period, Self::Hour];
    pub fn label(self) -> &'static str {
        match self {
            Self::Day => "Per Day",
            Self::Weekday => "Weekday",
            Self::Period => "Period",
            Self::Hour => "Hour",
        }
    }
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LatencySample {
    pub id: String,
    pub provider: String,
    pub metric_kind: MetricKind,
    pub latency_ms: i64,
    pub timestamp: DateTime<Utc>,
    pub model: Option<String>,
    pub session_id: Option<String>,
    pub run_id: Option<String>,
    pub round_index: Option<i64>,
    pub project_path: Option<String>,
    pub source_kind: String,
}
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Aggregate {
    pub count: usize,
    pub average_latency_ms: f64,
    pub p50_latency_ms: i64,
    pub p95_latency_ms: i64,
    pub min_latency_ms: i64,
    pub max_latency_ms: i64,
}
#[derive(Debug, Clone, Serialize)]
pub struct ActivitySample {
    pub provider: String,
    pub timestamp: DateTime<Utc>,
}
#[derive(Debug, Clone, Serialize)]
pub struct Bucket {
    pub id: String,
    pub label: String,
    pub aggregate: Option<Aggregate>,
    pub interactions: usize,
}
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LatencyDashboard {
    pub provider: String,
    pub metric_kind: MetricKind,
    pub aggregate: Option<Aggregate>,
    pub interaction_count: usize,
    pub buckets: Vec<Bucket>,
}
pub fn aggregate(samples: &[LatencySample]) -> Option<Aggregate> {
    if samples.is_empty() {
        return None;
    }
    let mut values: Vec<_> = samples.iter().map(|s| s.latency_ms.max(0)).collect();
    values.sort_unstable();
    let count = values.len();
    Some(Aggregate {
        count,
        average_latency_ms: values.iter().map(|n| *n as f64).sum::<f64>() / count as f64,
        p50_latency_ms: values[((count - 1) as f64 * 0.5).round_ties_even() as usize],
        p95_latency_ms: values[((count - 1) as f64 * 0.95).round_ties_even() as usize],
        min_latency_ms: values[0],
        max_latency_ms: values[count - 1],
    })
}
fn source_rank(source: &str) -> u8 {
    match source {
        "completed_run_turns" => 0,
        "terminal_first_output" => 1,
        _ => 2,
    }
}
pub fn canonical(samples: &[LatencySample]) -> Vec<LatencySample> {
    let mut preferred: HashMap<(String, String, i64), (usize, LatencySample)> = HashMap::new();
    let mut passthrough = vec![];
    for (index, sample) in samples.iter().enumerate() {
        if sample.metric_kind == MetricKind::FirstResponse
            && let (Some(run), Some(round)) = (&sample.run_id, sample.round_index)
            && !run.is_empty()
        {
            let key = (sample.provider.to_lowercase(), run.clone(), round);
            match preferred.get_mut(&key) {
                Some((_, old))
                    if source_rank(&sample.source_kind) < source_rank(&old.source_kind) =>
                {
                    *old = sample.clone()
                }
                None => {
                    preferred.insert(key, (index, sample.clone()));
                }
                _ => {}
            }
        } else {
            passthrough.push((index, sample.clone()));
        }
    }
    let completed: std::collections::HashSet<_> = passthrough
        .iter()
        .filter(|(_, s)| {
            s.metric_kind == MetricKind::FirstResponse && s.source_kind == "completed_run_turns"
        })
        .filter_map(|(_, s)| s.run_id.clone())
        .collect();
    passthrough.retain(|(_, s)| {
        !(s.metric_kind == MetricKind::FirstResponse
            && s.source_kind == "terminal_first_output"
            && s.run_id.as_ref().is_some_and(|run| completed.contains(run)))
    });
    passthrough.extend(preferred.into_values());
    passthrough.sort_by_key(|(index, s)| (s.timestamp, *index));
    passthrough.into_iter().map(|(_, s)| s).collect()
}
pub fn completed_samples(run: &TelemetryRun, turns: &[TelemetryTurn]) -> Vec<LatencySample> {
    if run
        .raw_transcript_ref
        .as_deref()
        .is_none_or(|r| r.trim().is_empty() || matches!(r.trim(), "pty_log" | "terminal_buffer"))
    {
        return vec![];
    }
    let mut turns: Vec<_> = turns
        .iter()
        .filter(|t| {
            t.timestamp
                .is_some_and(|at| at >= run.started_at && run.ended_at.is_none_or(|end| at <= end))
        })
        .collect();
    turns.sort_by_key(|t| (t.turn_index, t.timestamp));
    let mut pending = None;
    let mut round = 0;
    let mut samples = vec![];
    for turn in turns {
        let at = turn.timestamp.unwrap();
        match turn.role {
            TurnRole::Human => {
                pending = Some((round, at));
                round += 1;
            }
            TurnRole::Assistant => {
                let (index, start) = pending.take().unwrap_or_else(|| {
                    let index = round;
                    round += 1;
                    (index, run.started_at)
                });
                let latency = at.signed_duration_since(start).num_milliseconds();
                if latency < 0 {
                    continue;
                }
                samples.push(LatencySample {
                    id: format!(
                        "latency|{}|first_response|r{}|completed_run_turns",
                        run.id, index
                    ),
                    provider: run.provider.to_lowercase(),
                    metric_kind: MetricKind::FirstResponse,
                    latency_ms: latency,
                    timestamp: at,
                    model: run.model.clone(),
                    session_id: run.session_id.clone(),
                    run_id: Some(run.id.clone()),
                    round_index: Some(index),
                    project_path: run.repo_path.clone().or_else(|| Some(run.cwd.clone())),
                    source_kind: "completed_run_turns".into(),
                });
            }
            _ => {}
        }
    }
    samples
}
pub fn preferred_api_latency(round_trip: Option<i64>, ttft: Option<i64>) -> Option<i64> {
    ttft.filter(|n| *n > 0)
        .or_else(|| round_trip.filter(|n| *n > 0))
}
pub fn relevant_endpoint(provider: &str, endpoint: &str) -> bool {
    let endpoint = endpoint.trim().to_lowercase();
    if endpoint.is_empty() {
        return false;
    }
    match provider.trim().to_lowercase().as_str() {
        "openai" => matches!(
            endpoint.as_str(),
            "/v1/responses" | "/v1/chat/completions" | "/v1/completions"
        ),
        "anthropic" => matches!(endpoint.as_str(), "/v1/messages" | "/v1/complete"),
        "gemini" => endpoint.contains("generatecontent"),
        _ => true,
    }
}
pub fn meaningful_output(bytes: &[u8]) -> bool {
    let Ok(text) = std::str::from_utf8(bytes) else {
        return false;
    };
    let sanitized = crate::escape_sanitizer::sanitize(text);
    let text = sanitized.trim();
    if text.is_empty()
        || text
            .chars()
            .all(|c| "⠁⠂⠄⡀⢀⠠⠐⠈⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏⢹⢺⢼⣸⣇⡧⡗⡏⋮…·•".contains(c))
    {
        return false;
    }
    text.chars().any(|c| !c.is_control() && !c.is_whitespace())
}
fn bucket_key(at: DateTime<Utc>, kind: BucketKind) -> (String, String) {
    let at = at.with_timezone(&Local);
    match kind {
        BucketKind::Day => (
            at.format("%Y-%m-%d").to_string(),
            at.format("%m/%d").to_string(),
        ),
        BucketKind::Weekday => (
            format!("{}", at.weekday().num_days_from_monday()),
            at.format("%a").to_string(),
        ),
        BucketKind::Hour => (format!("{:02}", at.hour()), format!("{:02}:00", at.hour())),
        BucketKind::Period => {
            let (index, name) = match at.hour() {
                0..=5 => (0, "Night"),
                6..=11 => (1, "Morning"),
                12..=17 => (2, "Afternoon"),
                _ => (3, "Evening"),
            };
            (index.to_string(), name.into())
        }
    }
}
pub fn dashboard(
    samples: &[LatencySample],
    activity: &[ActivitySample],
    provider: &str,
    metric: MetricKind,
    kind: BucketKind,
    range: TimeRange,
    now: DateTime<Utc>,
) -> LatencyDashboard {
    let start = range.start(now);
    let samples: Vec<_> = canonical(samples)
        .into_iter()
        .filter(|s| {
            s.provider.eq_ignore_ascii_case(provider) && start.is_none_or(|at| s.timestamp >= at)
        })
        .collect();
    let activity: Vec<_> = activity
        .iter()
        .filter(|s| {
            s.provider.eq_ignore_ascii_case(provider) && start.is_none_or(|at| s.timestamp >= at)
        })
        .collect();
    let measured: Vec<_> = samples
        .iter()
        .filter(|s| s.metric_kind == metric)
        .cloned()
        .collect();
    let mut grouped: BTreeMap<String, (String, Vec<LatencySample>, usize)> = BTreeMap::new();
    for sample in &measured {
        let (key, label) = bucket_key(sample.timestamp, kind);
        grouped
            .entry(key)
            .or_insert((label, vec![], 0))
            .1
            .push(sample.clone());
    }
    for sample in &activity {
        let (key, label) = bucket_key(sample.timestamp, kind);
        grouped.entry(key).or_insert((label, vec![], 0)).2 += 1;
    }
    let buckets = grouped
        .into_iter()
        .map(|(id, (label, samples, interactions))| Bucket {
            id,
            label,
            aggregate: aggregate(&samples),
            interactions,
        })
        .collect();
    LatencyDashboard {
        provider: provider.into(),
        metric_kind: metric,
        aggregate: aggregate(&measured),
        interaction_count: activity.len(),
        buckets,
    }
}
/// One pending first-response measurement per actual terminal session identifier.
#[derive(Default)]
pub struct PromptTiming {
    pending: HashMap<String, (TelemetryRun, DateTime<Utc>, i64)>,
    rounds: HashMap<String, (String, i64)>,
}
impl PromptTiming {
    pub fn prompt(&mut self, tab: &str, run: TelemetryRun, now: DateTime<Utc>) {
        if self.pending.len() >= 512 && !self.pending.contains_key(tab) {
            self.pending
                .retain(|_, (_, at, _)| now.signed_duration_since(*at).num_seconds() < 120);
        }
        if self.pending.len() >= 512 {
            return;
        }
        if self.rounds.len() >= 512 {
            self.rounds.retain(|tab, _| self.pending.contains_key(tab));
        }
        let round = self.rounds.entry(tab.into()).or_insert((run.id.clone(), 0));
        if round.0 != run.id {
            *round = (run.id.clone(), 0);
        }
        let index = round.1;
        round.1 += 1;
        self.pending.insert(tab.into(), (run, now, index));
    }
    pub fn clear(&mut self, tab: &str) {
        self.pending.remove(tab);
        self.rounds.remove(tab);
    }
    pub fn output(&mut self, tab: &str, bytes: &[u8], now: DateTime<Utc>) -> Option<LatencySample> {
        if !meaningful_output(bytes) {
            return None;
        }
        let (run, at, index) = self.pending.remove(tab)?;
        let elapsed = now.signed_duration_since(at).num_milliseconds();
        if !(0..=120_000).contains(&elapsed) {
            return None;
        }
        Some(LatencySample {
            id: format!(
                "latency|{}|first_response|r{}|terminal_first_output",
                run.id, index
            ),
            provider: run.provider.to_lowercase(),
            metric_kind: MetricKind::FirstResponse,
            latency_ms: elapsed,
            timestamp: now,
            model: run.model,
            session_id: run.session_id,
            run_id: Some(run.id),
            round_index: Some(index),
            project_path: run.repo_path.or(Some(run.cwd)),
            source_kind: "terminal_first_output".into(),
        })
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    fn sample(ms: i64) -> LatencySample {
        LatencySample {
            id: ms.to_string(),
            provider: "claude".into(),
            metric_kind: MetricKind::FirstResponse,
            latency_ms: ms,
            timestamp: Utc::now(),
            model: None,
            session_id: None,
            run_id: Some("r".into()),
            round_index: None,
            project_path: None,
            source_kind: "terminal_first_output".into(),
        }
    }
    #[test]
    fn percentiles_and_unknowns() {
        assert!(aggregate(&[]).is_none());
        let a = aggregate(&[sample(10), sample(20), sample(30), sample(40)]).unwrap();
        assert_eq!(a.count, 4);
        assert_eq!(a.p50_latency_ms, 30);
        assert_eq!(a.p95_latency_ms, 40);
        assert_eq!(preferred_api_latency(Some(300), Some(100)), Some(100));
        assert_eq!(preferred_api_latency(Some(300), Some(0)), Some(300));
        assert_eq!(preferred_api_latency(None, None), None);
        assert!(!relevant_endpoint("openai", "/v1/models"));
        assert!(relevant_endpoint("anthropic", "/v1/messages"));
    }
    #[test]
    fn controls_and_spinner_are_not_responses() {
        for value in [b"\x1b[2J".as_slice(), "⠋…".as_bytes(), b"\r\n "] {
            assert!(!meaningful_output(value));
        }
        assert!(meaningful_output(b"Hello"));
        assert!(meaningful_output("✓".as_bytes()));
    }
    #[test]
    fn authoritative_rounds_replace_estimates() {
        let mut a = sample(100);
        a.round_index = Some(0);
        let mut b = a.clone();
        b.latency_ms = 200;
        b.source_kind = "completed_run_turns".into();
        assert_eq!(canonical(&[a, b])[0].latency_ms, 200);
    }
    #[test]
    fn prompt_measurement_is_bounded_and_consumed_once() {
        let now = Utc::now();
        let mut timing = PromptTiming::default();
        let mut run = TelemetryRun::new("claude", "/repo");
        run.started_at = now;
        run.id = "r".into();
        timing.prompt("t", run.clone(), now);
        assert!(timing.output("t", b"\x1b[2J", now).is_none());
        let a = timing
            .output("t", b"Answer", now + chrono::Duration::milliseconds(200))
            .unwrap();
        assert_eq!(a.latency_ms, 200);
        assert_eq!(a.round_index, Some(0));
        assert!(timing.output("t", b"Answer", now).is_none());
        timing.prompt("t", run, now);
        assert!(
            timing
                .output("t", b"Answer", now + chrono::Duration::seconds(121))
                .is_none()
        );
    }
    #[test]
    fn activity_survives_absent_request_latency() {
        let s = sample(100);
        let d = dashboard(
            &[s.clone()],
            &[ActivitySample {
                provider: s.provider.clone(),
                timestamp: s.timestamp,
            }],
            "claude",
            MetricKind::ApiRequest,
            BucketKind::Day,
            TimeRange::AllTime,
            Utc::now(),
        );
        assert!(d.aggregate.is_none());
        assert_eq!(d.interaction_count, 1);
        assert_eq!(d.buckets.len(), 1);
        assert!(d.buckets[0].aggregate.is_none());
    }
}
