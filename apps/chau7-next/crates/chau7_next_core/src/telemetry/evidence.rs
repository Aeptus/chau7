//! Current Swift UsageEvidence and constrained proxy-to-run attribution.
use super::{
    run::TelemetryRun,
    token_metrics::{CostSource, TelemetryMetricState as State, TokenUsage, TokenUsageSource},
};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashMap, HashSet};
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SourceKind {
    Proxy,
    Transcript,
    NativeStore,
    Baseline,
}
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageEvidence {
    pub id: String,
    pub unique_event_key: String,
    pub reconciliation_key: String,
    pub source_kind: SourceKind,
    pub provider: String,
    pub model: Option<String>,
    pub session_id: Option<String>,
    pub run_id: Option<String>,
    pub endpoint: Option<String>,
    pub project_path: Option<String>,
    pub input_tokens: Option<i64>,
    pub cache_creation_input_tokens: Option<i64>,
    pub cache_read_input_tokens: Option<i64>,
    pub output_tokens: Option<i64>,
    pub reasoning_output_tokens: Option<i64>,
    pub cost_usd: Option<f64>,
    pub token_usage_source: Option<TokenUsageSource>,
    pub token_usage_state: State,
    pub cost_source: Option<CostSource>,
    pub cost_state: State,
    pub pricing_version: Option<String>,
    pub source_ref: Option<String>,
    pub observed_at: DateTime<Utc>,
    pub metadata: HashMap<String, String>,
}
fn nonempty(s: Option<&str>) -> Option<String> {
    s.map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
}
pub fn reconciliation_key(
    provider: &str,
    session: Option<&str>,
    run: Option<&str>,
    project: Option<&str>,
    at: DateTime<Utc>,
) -> String {
    if let Some(id) = nonempty(session) {
        return format!("session|{provider}|{id}");
    }
    if let Some(id) = nonempty(run) {
        return format!("run|{provider}|{id}");
    }
    if let Some(path) = nonempty(project) {
        return format!("project|{provider}|{path}|{}", at.format("%Y-%m-%d"));
    }
    format!("day|{provider}|{}", at.format("%Y-%m-%d"))
}
impl UsageEvidence {
    pub fn empty(provider: &str, source: SourceKind, at: DateTime<Utc>) -> Self {
        Self {
            id: String::new(),
            unique_event_key: String::new(),
            reconciliation_key: String::new(),
            source_kind: source,
            provider: provider.trim().to_lowercase(),
            model: None,
            session_id: None,
            run_id: None,
            endpoint: None,
            project_path: None,
            input_tokens: None,
            cache_creation_input_tokens: None,
            cache_read_input_tokens: None,
            output_tokens: None,
            reasoning_output_tokens: None,
            cost_usd: None,
            token_usage_source: None,
            token_usage_state: State::Missing,
            cost_source: None,
            cost_state: State::Missing,
            pricing_version: None,
            source_ref: None,
            observed_at: at,
            metadata: HashMap::new(),
        }
    }
    pub fn finish_proxy_identity(&mut self, request_id: Option<&str>) {
        self.provider = self.provider.trim().to_lowercase();
        self.session_id = nonempty(self.session_id.as_deref());
        self.model = nonempty(self.model.as_deref());
        self.endpoint = nonempty(self.endpoint.as_deref());
        self.project_path = nonempty(self.project_path.as_deref());
        self.unique_event_key = nonempty(request_id)
            .map(|id| format!("proxy-request|{}|{}", self.provider, id))
            .unwrap_or_else(|| {
                format!(
                    "proxy|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}|{}",
                    self.provider,
                    self.session_id.as_deref().unwrap_or("-"),
                    self.model.as_deref().unwrap_or("-"),
                    self.endpoint.as_deref().unwrap_or("-"),
                    self.observed_at.format("%Y-%m-%dT%H:%M:%SZ"),
                    key(self.input_tokens),
                    key(self.output_tokens),
                    key(self.cache_creation_input_tokens),
                    key(self.cache_read_input_tokens),
                    key(self.reasoning_output_tokens),
                    self.cost_usd
                        .map(|n| format!("{n:.8}"))
                        .unwrap_or_else(|| "nil".into())
                )
            });
        self.id = self.unique_event_key.clone();
        self.reconciliation_key = reconciliation_key(
            &self.provider,
            self.session_id.as_deref(),
            self.run_id.as_deref(),
            self.project_path.as_deref(),
            self.observed_at,
        );
        self.token_usage_source = Some(TokenUsageSource::Proxy);
        self.token_usage_state = if self.has_tokens() {
            State::Complete
        } else {
            State::Missing
        };
        self.cost_source = Some(if self.cost_usd.is_some() {
            CostSource::Observed
        } else {
            CostSource::Unavailable
        });
        self.cost_state = if self.cost_usd.is_some() {
            State::Complete
        } else {
            State::Missing
        };
        self.source_ref = self.endpoint.clone();
    }
    pub fn run_summary(run: &TelemetryRun) -> Self {
        let source = match run.token_usage_source {
            Some(TokenUsageSource::Proxy) => SourceKind::Proxy,
            Some(TokenUsageSource::TranscriptDelta | TokenUsageSource::TranscriptSnapshot) => {
                SourceKind::Transcript
            }
            _ => SourceKind::NativeStore,
        };
        let at = run.ended_at.unwrap_or(run.started_at);
        let mut e = Self::empty(&run.provider, source, at);
        e.id = format!("run|{}", run.id);
        e.unique_event_key = e.id.clone();
        e.session_id = nonempty(run.session_id.as_deref());
        e.run_id = Some(run.id.clone());
        e.project_path = nonempty(run.repo_path.as_deref().or(Some(&run.cwd)));
        e.reconciliation_key = reconciliation_key(
            &e.provider,
            e.session_id.as_deref(),
            e.run_id.as_deref(),
            e.project_path.as_deref(),
            at,
        );
        e.model = run.model.clone();
        e.input_tokens = run.total_input_tokens;
        e.cache_creation_input_tokens = run.total_cache_creation_input_tokens;
        e.cache_read_input_tokens = run.total_cache_read_input_tokens;
        if let Some(combined) = run.total_cached_input_tokens {
            match (e.cache_creation_input_tokens, e.cache_read_input_tokens) {
                (Some(creation), None) => {
                    e.cache_read_input_tokens = (combined > creation).then_some(combined - creation)
                }
                (None, Some(read)) => {
                    e.cache_creation_input_tokens = (combined > read).then_some(combined - read)
                }
                (None, None) => e.cache_read_input_tokens = (combined > 0).then_some(combined),
                _ => {}
            }
        }
        e.output_tokens = run.total_output_tokens;
        e.reasoning_output_tokens = run.total_reasoning_output_tokens;
        e.cost_usd = run.cost_usd;
        e.token_usage_source = run.token_usage_source;
        e.token_usage_state = run.token_usage_state;
        e.cost_source = run.cost_source;
        e.cost_state = run.cost_state;
        e.pricing_version = (run.cost_source == Some(CostSource::Estimated))
            .then(|| super::pricing::VERSION.into());
        e.source_ref = run.raw_transcript_ref.clone();
        e.metadata = run.metadata.clone();
        e
    }
    pub fn has_tokens(&self) -> bool {
        [
            self.input_tokens,
            self.cache_creation_input_tokens,
            self.cache_read_input_tokens,
            self.output_tokens,
            self.reasoning_output_tokens,
        ]
        .iter()
        .any(Option::is_some)
    }
    pub fn token_usage(&self) -> TokenUsage {
        if self.source_kind == SourceKind::Proxy && !self.unique_event_key.starts_with("run|") {
            TokenUsage::provider(
                &self.provider,
                self.input_tokens,
                self.output_tokens,
                self.cache_creation_input_tokens,
                self.cache_read_input_tokens,
                self.reasoning_output_tokens,
            )
        } else {
            TokenUsage::canonical(
                self.input_tokens.unwrap_or(0),
                0,
                self.cache_creation_input_tokens.unwrap_or(0),
                self.cache_read_input_tokens.unwrap_or(0),
                self.output_tokens.unwrap_or(0),
                self.reasoning_output_tokens.unwrap_or(0),
            )
        }
    }
}
fn key(value: Option<i64>) -> String {
    value.map(|n| n.to_string()).unwrap_or_else(|| "nil".into())
}
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Aggregate {
    pub evidence: UsageEvidence,
    pub evidence_ids: Vec<String>,
    pub run_ids: Vec<String>,
    pub pricing_versions: Vec<String>,
    pub source_refs: Vec<String>,
    pub request_count: usize,
    pub priced_request_count: usize,
}
impl Aggregate {
    pub fn usage(&self) -> TokenUsage {
        self.evidence.token_usage()
    }
}
fn sum(values: impl Iterator<Item = Option<i64>>) -> Option<i64> {
    let (found, total) = values.flatten().fold((false, 0_i64), |(_, total), value| {
        (true, total.saturating_add(value))
    });
    found.then_some(total)
}
fn reduce(states: impl Iterator<Item = State>) -> State {
    let all: HashSet<_> = states.collect();
    if all.contains(&State::Invalid) {
        State::Invalid
    } else if all.contains(&State::Partial) {
        State::Partial
    } else if all.contains(&State::Estimated) {
        State::Estimated
    } else if all.contains(&State::Complete) {
        State::Complete
    } else {
        State::Missing
    }
}
fn token_weight(s: TokenUsageSource) -> i32 {
    match s {
        TokenUsageSource::Proxy => 50,
        TokenUsageSource::TranscriptSnapshot => 40,
        TokenUsageSource::TranscriptDelta => 35,
        TokenUsageSource::ProviderEstimate => 20,
        TokenUsageSource::Unknown => 10,
    }
}
fn cost_weight(s: CostSource) -> i32 {
    match s {
        CostSource::Observed => 50,
        CostSource::Estimated => 30,
        CostSource::Unavailable => 10,
    }
}
fn aggregate(entries: &[&UsageEvidence]) -> Aggregate {
    let mut e = entries[0].clone();
    e.unique_event_key = "run|aggregate".into();
    let usages: Vec<_> = entries.iter().map(|e| e.token_usage()).collect();
    e.input_tokens = sum(entries
        .iter()
        .zip(&usages)
        .map(|(e, u)| e.input_tokens.map(|_| u.input_tokens)));
    e.cache_creation_input_tokens = sum(entries.iter().map(|e| e.cache_creation_input_tokens));
    e.cache_read_input_tokens = sum(entries.iter().map(|e| e.cache_read_input_tokens));
    e.output_tokens = sum(entries
        .iter()
        .zip(&usages)
        .map(|(e, u)| e.output_tokens.map(|_| u.output_tokens)));
    e.reasoning_output_tokens = sum(entries.iter().map(|e| e.reasoning_output_tokens));
    e.cost_usd = entries
        .iter()
        .any(|e| e.cost_usd.is_some())
        .then(|| entries.iter().filter_map(|e| e.cost_usd).sum());
    e.token_usage_source = entries
        .iter()
        .filter_map(|e| e.token_usage_source)
        .max_by_key(|s| token_weight(*s));
    e.cost_source = entries
        .iter()
        .filter_map(|e| e.cost_source)
        .max_by_key(|s| cost_weight(*s));
    e.token_usage_state = reduce(entries.iter().map(|e| e.token_usage_state));
    e.cost_state = reduce(entries.iter().map(|e| e.cost_state));
    e.observed_at = entries.iter().map(|e| e.observed_at).max().unwrap();
    fn unique(v: impl Iterator<Item = String>) -> Vec<String> {
        let mut v: Vec<_> = v.collect();
        v.sort();
        v.dedup();
        v
    }
    Aggregate {
        evidence: e,
        evidence_ids: unique(entries.iter().map(|e| e.id.clone())),
        run_ids: unique(entries.iter().filter_map(|e| e.run_id.clone())),
        pricing_versions: unique(entries.iter().filter_map(|e| e.pricing_version.clone())),
        source_refs: unique(entries.iter().filter_map(|e| e.source_ref.clone())),
        request_count: entries.len(),
        priced_request_count: entries.iter().filter(|e| e.cost_usd.is_some()).count(),
    }
}
fn score(a: &Aggregate) -> i32 {
    let e = &a.evidence;
    let mut s = match e.source_kind {
        SourceKind::Proxy => 400,
        SourceKind::NativeStore => 320,
        SourceKind::Transcript => 280,
        SourceKind::Baseline => 180,
    };
    s += match e.cost_source {
        Some(CostSource::Observed) => 100,
        Some(CostSource::Estimated) => 50,
        _ => 0,
    };
    for state in [e.cost_state, e.token_usage_state] {
        s += match state {
            State::Complete => 60,
            State::Estimated => 30,
            State::Invalid => -500,
            _ => 0,
        };
    }
    s += if e.cost_usd.is_some() { 20 } else { 0 };
    s += if e.has_tokens() { 20 } else { 0 };
    s += if a.pricing_versions.is_empty() { 0 } else { 5 };
    s
}
#[derive(Debug, Clone, Serialize)]
pub struct ReconciledGroup {
    pub reconciliation_key: String,
    pub provider: String,
    pub selected: Aggregate,
    pub alternatives: Vec<Aggregate>,
    pub confidence: String,
    pub cost_delta_usd: Option<f64>,
    pub token_delta: Option<i64>,
}
#[derive(Debug, Clone, Default, Serialize)]
pub struct Report {
    pub groups: Vec<ReconciledGroup>,
    pub total_cost_usd: f64,
    pub total_token_usage: TokenUsage,
}
pub fn reconcile(evidence: &[UsageEvidence]) -> Report {
    let mut seen = HashSet::new();
    let mut grouped: BTreeMap<(String, String), BTreeMap<SourceKind, Vec<&UsageEvidence>>> =
        BTreeMap::new();
    for e in evidence {
        if !seen.insert(&e.unique_event_key)
            || e.source_kind == SourceKind::Proxy && e.metadata.contains_key("proxy_coverage")
        {
            continue;
        }
        grouped
            .entry((e.provider.clone(), e.reconciliation_key.clone()))
            .or_default()
            .entry(e.source_kind)
            .or_default()
            .push(e);
    }
    let mut report = Report::default();
    for ((provider, key), sources) in grouped {
        let mut alternatives: Vec<_> = sources.values().map(|s| aggregate(s)).collect();
        alternatives.sort_by_key(|a| std::cmp::Reverse(score(a)));
        let selected = alternatives.remove(0);
        let e = &selected.evidence;
        let confidence = if e.token_usage_state == State::Partial || e.cost_state == State::Partial
        {
            "incomplete"
        } else if e.source_kind == SourceKind::Proxy
            && e.cost_source == Some(CostSource::Observed)
            && e.cost_state == State::Complete
            && e.token_usage_state == State::Complete
        {
            "observed"
        } else if e.cost_source == Some(CostSource::Estimated)
            || e.cost_state == State::Estimated
            || e.token_usage_state == State::Estimated
        {
            "estimated"
        } else if !alternatives.is_empty() {
            "mixed"
        } else {
            "incomplete"
        };
        let cost_delta_usd = alternatives
            .first()
            .and_then(|a| Some(e.cost_usd? - a.evidence.cost_usd?));
        let token_delta = alternatives
            .first()
            .map(|a| selected.usage().total_billable_tokens() - a.usage().total_billable_tokens());
        report.total_cost_usd += e.cost_usd.unwrap_or(0.);
        report.total_token_usage.add(&selected.usage());
        report.groups.push(ReconciledGroup {
            reconciliation_key: key,
            provider,
            selected,
            alternatives,
            confidence: confidence.into(),
            cost_delta_usd,
            token_delta,
        });
    }
    report
}
pub fn provider_matches(observation: &str, run: &str) -> bool {
    let o = observation.to_lowercase();
    let r = run.to_lowercase();
    o == r
        || o == "openai" && r.contains("codex")
        || o.contains("anthropic") && r.contains("claude")
}
/// Every supplied identity constrains the same candidates. Ambiguity never
/// falls back to a weaker project or session identity.
pub fn attributed(evidence: &[UsageEvidence], runs: &[TelemetryRun]) -> HashMap<String, Aggregate> {
    let mut seen = HashSet::new();
    let mut by_run: HashMap<String, Vec<&UsageEvidence>> = HashMap::new();
    for e in evidence {
        if e.source_kind != SourceKind::Proxy
            || e.unique_event_key.starts_with("run|")
            || !seen.insert(&e.unique_event_key)
        {
            continue;
        }
        let mut identified = false;
        let matches: Vec<_> = runs
            .iter()
            .filter(|r| {
                provider_matches(&e.provider, &r.provider)
                    && e.observed_at >= r.started_at
                    && r.ended_at.is_none_or(|end| e.observed_at < end)
            })
            .filter(|r| {
                if let Some(id) = &e.run_id {
                    identified = true;
                    if &r.id != id {
                        return false;
                    }
                }
                if let Some(tab) = e.metadata.get("tab_id").filter(|s| !s.is_empty()) {
                    identified = true;
                    if r.tab_id.as_ref() != Some(tab) {
                        return false;
                    }
                }
                if let Some(id) = &e.session_id {
                    identified = true;
                    if r.session_id.as_ref() != Some(id) {
                        return false;
                    }
                }
                if let Some(path) = &e.project_path {
                    identified = true;
                    if r.repo_path.as_ref().unwrap_or(&r.cwd) != path {
                        return false;
                    }
                }
                true
            })
            .collect();
        if identified && matches.len() == 1 {
            by_run.entry(matches[0].id.clone()).or_default().push(e);
        }
    }
    by_run
        .into_iter()
        .map(|(id, entries)| (id, aggregate(&entries)))
        .collect()
}
pub fn apply_attribution(run: &TelemetryRun, a: &Aggregate) -> TelemetryRun {
    let mut r = run.clone();
    let e = &a.evidence;
    r.total_input_tokens = e.input_tokens;
    r.total_cache_creation_input_tokens = e.cache_creation_input_tokens;
    r.total_cache_read_input_tokens = e.cache_read_input_tokens;
    r.total_cached_input_tokens = (e.cache_creation_input_tokens.is_some()
        || e.cache_read_input_tokens.is_some())
    .then_some(e.cache_creation_input_tokens.unwrap_or(0) + e.cache_read_input_tokens.unwrap_or(0));
    r.total_output_tokens = e.output_tokens;
    r.total_reasoning_output_tokens = e.reasoning_output_tokens;
    r.cost_usd = e.cost_usd;
    r.token_usage_source = Some(TokenUsageSource::Proxy);
    r.token_usage_state = if e.has_tokens() {
        State::Partial
    } else {
        State::Missing
    };
    r.cost_source = e.cost_source;
    r.cost_state = if e.cost_usd.is_some() {
        State::Partial
    } else {
        State::Missing
    };
    r.metadata
        .insert("proxy_request_count".into(), a.request_count.to_string());
    r.metadata.insert(
        "proxy_priced_request_count".into(),
        a.priced_request_count.to_string(),
    );
    r.metadata.insert(
        "proxy_coverage".into(),
        "partial_retained_observations".into(),
    );
    r
}
#[cfg(test)]
mod tests {
    use super::*;
    fn proxy(id: &str) -> UsageEvidence {
        let mut e = UsageEvidence::empty("openai", SourceKind::Proxy, Utc::now());
        e.session_id = Some("s".into());
        e.input_tokens = Some(100);
        e.cache_read_input_tokens = Some(20);
        e.output_tokens = Some(50);
        e.reasoning_output_tokens = Some(10);
        e.cost_usd = Some(1.);
        e.finish_proxy_identity(Some(id));
        e
    }
    #[test]
    fn request_identity_and_source_selection_never_sum_duplicate_projections() {
        let p = proxy("r1");
        let p2 = proxy("r2");
        assert_ne!(p.unique_event_key, p2.unique_event_key);
        let mut transcript = p.clone();
        transcript.source_kind = SourceKind::Transcript;
        transcript.unique_event_key = "run|r".into();
        transcript.id = transcript.unique_event_key.clone();
        transcript.input_tokens = Some(800);
        transcript.cost_usd = Some(20.);
        transcript.cost_source = Some(CostSource::Estimated);
        transcript.cost_state = State::Estimated;
        let mut projection = transcript.clone();
        projection.unique_event_key = "run|projection".into();
        projection.source_kind = SourceKind::Proxy;
        projection.metadata.insert(
            "proxy_coverage".into(),
            "partial_retained_observations".into(),
        );
        let report = reconcile(&[p.clone(), p, p2, transcript, projection]);
        assert_eq!(report.groups.len(), 1);
        assert_eq!(report.total_cost_usd, 2.);
        assert_eq!(report.total_token_usage.input_tokens, 160);
        assert_eq!(report.total_token_usage.output_tokens, 80);
        assert_eq!(report.groups[0].confidence, "observed");
        assert_eq!(report.groups[0].alternatives.len(), 1);
    }
    #[test]
    fn contradictory_and_ambiguous_identities_fail_closed() {
        let e = proxy("r");
        let mut run = TelemetryRun::new("codex", "/repo");
        run.started_at = e.observed_at - chrono::Duration::seconds(1);
        run.session_id = Some("s".into());
        run.tab_id = Some("t".into());
        let a = attributed(std::slice::from_ref(&e), std::slice::from_ref(&run));
        assert_eq!(a.len(), 1);
        let updated = apply_attribution(&run, &a[&run.id]);
        assert_eq!(updated.total_input_tokens, Some(80));
        assert_eq!(updated.cost_state, State::Partial);
        let mut contradiction = e.clone();
        contradiction
            .metadata
            .insert("tab_id".into(), "wrong".into());
        assert!(attributed(&[contradiction], std::slice::from_ref(&run)).is_empty());
        let mut other = run.clone();
        other.id = "other".into();
        assert!(attributed(std::slice::from_ref(&e), &[run.clone(), other]).is_empty());
        run.ended_at = Some(e.observed_at);
        assert!(attributed(&[e], &[run]).is_empty());
    }
    #[test]
    fn run_canonical_counters_are_not_subtracted_twice() {
        let mut run = TelemetryRun::new("codex", "/repo");
        run.total_input_tokens = Some(80);
        run.total_cache_read_input_tokens = Some(20);
        run.total_output_tokens = Some(40);
        run.total_reasoning_output_tokens = Some(10);
        run.token_usage_source = Some(TokenUsageSource::Proxy);
        let e = UsageEvidence::run_summary(&run);
        assert_eq!(e.token_usage().input_tokens, 80);
        assert_eq!(e.token_usage().output_tokens, 40);
    }
}
