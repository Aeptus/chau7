//! The API analytics proxy, without UI (`Proxy/*.swift`).
//!
//! The proxy itself is the Go program `chau7-proxy`
//! (`apps/chau7-macos/chau7-proxy`), started by the app. This module has
//! what the app needs around it: the ports and environments (for the
//! proxy and for shells), the newline-delimited JSON messages it sends on
//! its IPC socket, the task lifecycle models, a small HTTP client for its
//! local endpoints, and the read-only queries of its `analytics.db`.
//!
//! Chau7 Next runs its own proxy next to the Swift app's, so its default
//! ports differ ([`DEFAULT_PORT`]) and every file lives in its own data root.

pub mod analytics;

use std::io::{Read, Write};
use std::net::{Ipv4Addr, SocketAddr, TcpStream};
use std::path::Path;
use std::time::Duration;

use base64::Engine as _;
use chrono::{DateTime, Utc};
use rusqlite::{Connection, OpenFlags, OptionalExtension, params};
use serde::Deserialize;
use serde_json::Value;

use crate::data_root::DataRoot;
use crate::debug_console::{ProxyCall, ProxyDailyPoint, ProxyProviderStat, ProxyStats};

/// File name of the Go proxy binary.
pub const PROXY_BINARY: &str = "chau7-proxy";

/// Default HTTP port. The Swift app uses 18080 (and 18081 for TLS); Chau7
/// Next uses its own pair so both proxies can run at the same time.
pub const DEFAULT_PORT: u16 = 18090;

/// Ports below this are refused (`max(1024, min(port, 65535))`). The TLS
/// port is `port + 1`, so the highest HTTP port is 65534.
pub fn clamp_port(port: i64) -> u16 {
    port.clamp(1024, 65534) as u16
}

/// The TLS listener is always on the next port.
pub fn tls_port(port: u16) -> u16 {
    port.saturating_add(1)
}

/// Recent API calls kept in memory (`maxRecentEvents`, `trimToLast(100)`).
pub const MAX_RECENT_CALLS: usize = 100;

/// Prompt previews kept by the proxy when "Log Prompt Previews" is on.
pub const PROMPT_PREVIEW_CHARS: usize = 500;

/// Seconds before the proxy is started again after a crash.
pub const RESTART_DELAY: Duration = Duration::from_secs(2);

/// The proxy process's environment (PRX-003).
pub fn proxy_env(root: &DataRoot, port: u16, log_prompts: bool) -> Vec<(String, String)> {
    let path = |p: std::path::PathBuf| p.to_string_lossy().into_owned();
    vec![
        ("CHAU7_PROXY_PORT".into(), port.to_string()),
        ("CHAU7_DB_PATH".into(), path(root.proxy_db())),
        ("CHAU7_IPC_SOCKET".into(), path(root.proxy_socket())),
        ("CHAU7_LOG_LEVEL".into(), "info".into()),
        (
            "CHAU7_LOG_PROMPTS".into(),
            if log_prompts { "1" } else { "0" }.into(),
        ),
        ("CHAU7_TLS_PORT".into(), tls_port(port).to_string()),
        ("CHAU7_TLS_CERT".into(), path(root.proxy_tls_cert())),
        ("CHAU7_TLS_KEY".into(), path(root.proxy_tls_key())),
        // Without it the proxy reads the Swift app's global rules.
        (
            "CHAU7_INJECTION_RULES".into(),
            path(root.proxy_injection_rules_file()),
        ),
        // Only Next enables owned local-rule overrides; Swift keeps its default lookup.
        (
            "CHAU7_INJECTION_REPO_OVERRIDES".into(),
            path(root.repo_overlays_dir()),
        ),
        // The proxy exits when this process goes away.
        ("CHAU7_PARENT_PID".into(), std::process::id().to_string()),
    ]
}

/// Variables a shell gets while API analytics is on (PRX-006, PRX-007,
/// TRM-026): AI CLIs send their calls to the local proxy, tagged with the
/// shell, tab and project.
pub fn shell_env(
    port: u16,
    include_openai: bool,
    term_session_id: &str,
    tab_id: &str,
    cwd: &str,
) -> Vec<(String, String)> {
    let base = format!("http://127.0.0.1:{port}");
    let mut env = vec![("ANTHROPIC_BASE_URL".to_string(), base.clone())];
    if include_openai {
        env.push((
            "OPENAI_BASE_URL".into(),
            format!(
                "https://127.0.0.1:{}{}/v1",
                tls_port(port),
                proxy_project_path(cwd)
            ),
        ));
    }
    env.push(("CHAU7_NEXT_PROXY_CORRELATION_ENABLED".into(), "1".into()));
    env.push(("GOOGLE_GEMINI_BASE_URL".into(), base));
    env.push(("CHAU7_NEXT_SESSION_ID".into(), term_session_id.to_string()));
    env.push(("CHAU7_NEXT_TAB_ID".into(), tab_id.to_string()));
    env.push(("CHAU7_NEXT_PROJECT".into(), cwd.to_string()));
    env
}

/// URL-safe project identity without shell or TOML interpolation.
pub fn proxy_project_path(cwd: &str) -> String {
    format!(
        "/_chau7/project/{}",
        base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(cwd)
    )
}

/// Owned launcher context. Go provisions the loopback CA under DataRoot;
/// no global trust store or provider authentication is changed.
pub fn codex_shell_env(root: &DataRoot, port: u16) -> Vec<(String, String)> {
    vec![
        (
            "CHAU7_NEXT_OPENAI_PROXY_BASE_URL".into(),
            format!("https://127.0.0.1:{}", tls_port(port)),
        ),
        (
            "CHAU7_NEXT_CODEX_PROXY_WRAPPER_DIR".into(),
            crate::shell_integration::codex_wrapper_dir(&root.shell_integration_dir())
                .to_string_lossy()
                .into_owned(),
        ),
        (
            "CHAU7_NEXT_CODEX_CA_CERTIFICATE".into(),
            root.proxy_tls_cert().to_string_lossy().into_owned(),
        ),
    ]
}

// ----- formatting (PRX-011) ---------------------------------------------------

/// `$0.0012` below one cent, else `$0.12`.
pub fn format_cost(cost: f64) -> String {
    if cost < 0.01 {
        format!("${cost:.4}")
    } else {
        format!("${cost:.2}")
    }
}

/// `850ms` or `1.2s`.
pub fn format_latency(ms: i64) -> String {
    if ms < 1000 {
        format!("{ms}ms")
    } else {
        format!("{:.1}s", ms as f64 / 1000.0)
    }
}

/// `12,345` (`NumberFormatter.decimal`, en_US grouping).
pub fn format_grouped(value: i64) -> String {
    let digits = value.unsigned_abs().to_string();
    let mut out = String::new();
    for (i, c) in digits.chars().enumerate() {
        if i > 0 && (digits.len() - i).is_multiple_of(3) {
            out.push(',');
        }
        out.push(c);
    }
    if value < 0 { format!("-{out}") } else { out }
}

/// `5s`, `3m 12s`, `1h 4m` (`formattedDuration`).
pub fn format_task_duration(seconds: i64) -> String {
    let seconds = seconds.max(0);
    if seconds < 60 {
        format!("{seconds}s")
    } else if seconds < 3600 {
        format!("{}m {}s", seconds / 60, seconds % 60)
    } else {
        format!("{}h {}m", seconds / 3600, seconds % 3600 / 60)
    }
}

/// `+120`, `-40` or `0` (`formattedTokensSaved`).
pub fn format_tokens_saved(saved: i64) -> String {
    if saved > 0 {
        format!("+{saved}")
    } else {
        saved.to_string()
    }
}

/// The API a call went to (`APICallEvent.Provider`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Provider {
    Anthropic,
    OpenAi,
    Gemini,
    Unknown,
}

impl Provider {
    pub fn from_raw(raw: &str) -> Self {
        match raw {
            "anthropic" => Self::Anthropic,
            "openai" => Self::OpenAi,
            "gemini" => Self::Gemini,
            _ => Self::Unknown,
        }
    }

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Anthropic => "anthropic",
            Self::OpenAi => "openai",
            Self::Gemini => "gemini",
            Self::Unknown => "unknown",
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Anthropic => "Anthropic",
            Self::OpenAi => "OpenAI",
            Self::Gemini => "Google",
            Self::Unknown => "Unknown",
        }
    }

    /// SF Symbol of the Swift UI.
    pub fn icon_system_name(self) -> &'static str {
        match self {
            Self::Anthropic => "brain.head.profile",
            Self::OpenAi => "sparkles",
            Self::Gemini => "diamond",
            Self::Unknown => "questionmark.circle",
        }
    }

    pub fn color_name(self) -> &'static str {
        match self {
            Self::Anthropic => "purple",
            Self::OpenAi => "green",
            Self::Gemini => "blue",
            Self::Unknown => "gray",
        }
    }

    pub fn api_base_url(self) -> &'static str {
        match self {
            Self::Anthropic => "https://api.anthropic.com",
            Self::OpenAi => "https://api.openai.com",
            Self::Gemini => "https://generativelanguage.googleapis.com",
            Self::Unknown => "",
        }
    }
}

/// One API call seen by the proxy (`APICallEvent`).
#[derive(Debug, Clone, PartialEq)]
pub struct ApiCallEvent {
    pub id: String,
    pub session_id: String,
    pub provider: Provider,
    pub model: String,
    pub endpoint: String,
    pub input_tokens: i64,
    pub output_tokens: i64,
    pub latency_ms: i64,
    pub status_code: i64,
    pub cost_usd: f64,
    pub timestamp: DateTime<Utc>,
    pub error_message: Option<String>,
}

impl ApiCallEvent {
    pub fn total_tokens(&self) -> i64 {
        self.input_tokens + self.output_tokens
    }

    pub fn is_success(&self) -> bool {
        (200..300).contains(&self.status_code)
    }

    pub fn has_error(&self) -> bool {
        self.error_message.as_deref().is_some_and(|m| !m.is_empty())
    }

    pub fn formatted_cost(&self) -> String {
        format_cost(self.cost_usd)
    }

    pub fn formatted_latency(&self) -> String {
        format_latency(self.latency_ms)
    }

    pub fn formatted_tokens(&self) -> String {
        format_grouped(self.total_tokens())
    }

    /// The timeline line (`handleAPICallEvent`):
    /// `Anthropic claude-x: in:10 out:5 $0.0012`.
    pub fn timeline_message(&self) -> String {
        format!(
            "{} {}: in:{} out:{} {}",
            self.provider.display_name(),
            self.model,
            self.input_tokens,
            self.output_tokens,
            self.formatted_cost()
        )
    }

    /// Event type on the timeline: `error` when the proxy reported one.
    pub fn timeline_type(&self) -> &'static str {
        if self.has_error() {
            "error"
        } else {
            "api_call"
        }
    }

    /// As the Debug Console lists it.
    pub fn debug_call(&self) -> ProxyCall {
        ProxyCall {
            provider: self.provider.raw_value().to_string(),
            model: self.model.clone(),
            total_tokens: self.total_tokens(),
            formatted_cost: crate::l10n::numbers::cost_precise(self.cost_usd),
            formatted_latency: self.formatted_latency(),
        }
    }
}

/// Today's numbers (`APICallStats`, from `GET /stats`).
#[derive(Debug, Clone, Default, PartialEq)]
pub struct ApiCallStats {
    pub call_count: i64,
    pub total_input_tokens: i64,
    pub total_output_tokens: i64,
    pub total_cost: f64,
    pub average_latency_ms: f64,
}

impl ApiCallStats {
    pub fn total_tokens(&self) -> i64 {
        self.total_input_tokens + self.total_output_tokens
    }

    /// Totals of a list of calls (`APICallStats.from`).
    pub fn from_events(events: &[ApiCallEvent]) -> Self {
        if events.is_empty() {
            return Self::default();
        }
        Self {
            call_count: events.len() as i64,
            total_input_tokens: events.iter().map(|e| e.input_tokens).sum(),
            total_output_tokens: events.iter().map(|e| e.output_tokens).sum(),
            total_cost: events.iter().map(|e| e.cost_usd).sum(),
            average_latency_ms: events.iter().map(|e| e.latency_ms).sum::<i64>() as f64
                / events.len() as f64,
        }
    }
}

// ----- tasks ------------------------------------------------------------------

/// What made the proxy suggest a task (`TaskTrigger`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskTrigger {
    Manual,
    NewSession,
    IdleGap,
    RepoSwitch,
}

impl TaskTrigger {
    pub fn from_raw(raw: &str) -> Self {
        match raw {
            "new_session" => Self::NewSession,
            "idle_gap" => Self::IdleGap,
            "repo_switch" => Self::RepoSwitch,
            _ => Self::Manual,
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Manual => "Manual",
            Self::NewSession => "New Session",
            Self::IdleGap => "Idle Gap",
            Self::RepoSwitch => "Repo Switch",
        }
    }
}

/// How a task was started (`TaskStartMethod`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TaskStartMethod {
    Manual,
    AutoConfirmed,
    UserConfirmed,
}

impl TaskStartMethod {
    pub fn from_raw(raw: &str) -> Self {
        match raw {
            "auto_confirmed" => Self::AutoConfirmed,
            "user_confirmed" => Self::UserConfirmed,
            _ => Self::Manual,
        }
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Manual => "Manual",
            Self::AutoConfirmed => "Auto-confirmed",
            Self::UserConfirmed => "User-confirmed",
        }
    }
}

/// A suggested task waiting for Confirm or Dismiss (`TaskCandidate`).
#[derive(Debug, Clone, PartialEq)]
pub struct TaskCandidate {
    pub id: String,
    pub tab_id: String,
    pub session_id: String,
    pub project_path: String,
    pub suggested_name: String,
    pub trigger: TaskTrigger,
    pub confidence: f64,
    pub grace_period_end: DateTime<Utc>,
    pub created_at: DateTime<Utc>,
}

impl TaskCandidate {
    pub fn grace_remaining_ms(&self, now: DateTime<Utc>) -> i64 {
        (self.grace_period_end - now).num_milliseconds().max(0)
    }

    pub fn is_expired(&self, now: DateTime<Utc>) -> bool {
        now > self.grace_period_end
    }
}

/// A task being tracked in a tab (`TrackedTask`).
#[derive(Debug, Clone, PartialEq)]
pub struct TrackedTask {
    pub id: String,
    pub candidate_id: Option<String>,
    pub tab_id: String,
    pub session_id: String,
    pub project_path: String,
    pub name: String,
    pub start_method: TaskStartMethod,
    pub trigger: TaskTrigger,
    pub started_at: DateTime<Utc>,
    pub completed_at: Option<DateTime<Utc>>,
    pub total_api_calls: i64,
    pub total_tokens: i64,
    pub total_cost_usd: f64,
    pub baseline_total_tokens: i64,
    pub tokens_saved: i64,
}

impl TrackedTask {
    pub fn duration_seconds(&self, now: DateTime<Utc>) -> i64 {
        (self.completed_at.unwrap_or(now) - self.started_at).num_seconds()
    }

    pub fn formatted_cost(&self) -> String {
        format_cost(self.total_cost_usd)
    }

    pub fn formatted_duration(&self, now: DateTime<Utc>) -> String {
        format_task_duration(self.duration_seconds(now))
    }

    pub fn formatted_tokens_saved(&self) -> String {
        format_tokens_saved(self.tokens_saved)
    }

    pub fn has_savings(&self) -> bool {
        self.tokens_saved > 0
    }

    /// An `api_call` for this tab: the bar's numbers grow live.
    pub fn add_call(&mut self, call: &ApiCallEvent) {
        self.total_api_calls += 1;
        self.total_tokens += call.total_tokens();
        self.total_cost_usd += call.cost_usd;
    }
}

/// The proxy's verdict on a finished task (`TaskAssessment`).
#[derive(Debug, Clone, PartialEq)]
pub struct TaskAssessment {
    pub task_id: String,
    pub tab_id: String,
    pub approved: bool,
    pub note: Option<String>,
    pub total_api_calls: i64,
    pub total_tokens: i64,
    pub total_cost_usd: f64,
    pub tokens_saved: Option<i64>,
    pub duration_seconds: i64,
}

// ----- IPC messages (PRX-009) ----------------------------------------------------

/// One line from the proxy's IPC socket.
#[derive(Debug, Clone, PartialEq)]
pub enum ProxyMessage {
    /// An API call, with the tab it came from when known.
    ApiCall {
        event: ApiCallEvent,
        tab_id: Option<String>,
        project_path: Option<String>,
        token_rate: Option<crate::telemetry::token_rate::TokenRateReading>,
        evidence: Box<crate::telemetry::evidence::UsageEvidence>,
    },
    GenerationProgress {
        tab_id: String,
        reading: crate::telemetry::token_rate::TokenRateReading,
    },
    TaskCandidate(TaskCandidate),
    TaskStarted(TrackedTask),
    TaskCandidateDismissed {
        candidate_id: String,
        tab_id: String,
    },
    TaskAssessment(TaskAssessment),
    Unknown(String),
}

#[derive(Deserialize)]
struct ApiCallData {
    #[serde(default)]
    request_id: Option<String>,
    #[serde(default)]
    cache_creation_input_tokens: Option<i64>,
    #[serde(default)]
    cache_read_input_tokens: Option<i64>,
    #[serde(default)]
    reasoning_output_tokens: Option<i64>,
    #[serde(default)]
    pricing_version: Option<String>,
    session_id: String,
    provider: String,
    model: String,
    endpoint: String,
    input_tokens: Option<i64>,
    output_tokens: Option<i64>,
    #[serde(default)]
    ttft_ms: i64,
    #[serde(default)]
    is_streaming: bool,
    #[serde(default)]
    output_tokens_estimated: bool,
    latency_ms: i64,
    status_code: i64,
    cost_usd: Option<f64>,
    timestamp: String,
    #[serde(default)]
    error_message: Option<String>,
    #[serde(default)]
    tab_id: Option<String>,
    #[serde(default)]
    project_path: Option<String>,
}

#[derive(Deserialize)]
struct CandidateData {
    candidate_id: String,
    tab_id: String,
    session_id: String,
    project_path: String,
    suggested_name: String,
    trigger: String,
    confidence: f64,
    grace_period_seconds: i64,
}

#[derive(Deserialize)]
struct StartedData {
    task_id: String,
    #[serde(default)]
    candidate_id: Option<String>,
    tab_id: String,
    session_id: String,
    project_path: String,
    task_name: String,
    start_method: String,
    trigger: String,
}

#[derive(Deserialize)]
struct DismissedData {
    candidate_id: String,
    tab_id: String,
}

#[derive(Deserialize)]
struct AssessmentData {
    task_id: String,
    tab_id: String,
    approved: bool,
    #[serde(default)]
    note: Option<String>,
    total_api_calls: i64,
    total_tokens: i64,
    total_cost_usd: f64,
    #[serde(default)]
    tokens_saved: Option<i64>,
    duration_seconds: i64,
}

fn parse_time(text: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(text)
        .ok()
        .map(|d| d.with_timezone(&Utc))
}

/// Decode one IPC line. `Err` for lines that are not JSON or miss fields
/// of their type (Swift logs and drops them).
pub fn parse_message(line: &str, now: DateTime<Utc>) -> Result<ProxyMessage, String> {
    let value: Value = serde_json::from_str(line).map_err(|e| e.to_string())?;
    let kind = value
        .get("type")
        .and_then(Value::as_str)
        .ok_or("missing type")?
        .to_string();
    let data = value.get("data").cloned().unwrap_or(Value::Null);
    fn decode<T: for<'de> Deserialize<'de>>(data: Value) -> Result<T, String> {
        serde_json::from_value(data).map_err(|e| e.to_string())
    }
    Ok(match kind.as_str() {
        "api_call" => {
            let d: ApiCallData = decode(data)?;
            let mut rate_store = crate::telemetry::token_rate::TokenRateStore::default();
            let source = if d.output_tokens_estimated {
                crate::telemetry::token_rate::TokenRateSource::ProxyEstimatedUsage
            } else if d.is_streaming {
                crate::telemetry::token_rate::TokenRateSource::ProxyUsage
            } else {
                crate::telemetry::token_rate::TokenRateSource::ProxyRequestUsage
            };
            if (200..300).contains(&d.status_code) {
                rate_store.record(
                    d.tab_id.as_deref().unwrap_or(""),
                    &d.provider,
                    d.output_tokens.unwrap_or(0),
                    if d.is_streaming {
                        (d.latency_ms - d.ttft_ms.max(0)).max(1)
                    } else {
                        d.latency_ms.max(1)
                    },
                    source,
                    now,
                );
            }
            let token_rate = rate_store
                .reading(d.tab_id.as_deref().unwrap_or(""))
                .cloned();
            let mut evidence = crate::telemetry::evidence::UsageEvidence::empty(
                &d.provider,
                crate::telemetry::evidence::SourceKind::Proxy,
                parse_time(&d.timestamp).unwrap_or(now),
            );
            evidence.session_id = Some(d.session_id.clone());
            evidence.model = Some(d.model.clone());
            evidence.endpoint = Some(d.endpoint.clone());
            evidence.project_path = d.project_path.clone();
            evidence.input_tokens = d.input_tokens;
            evidence.output_tokens = d.output_tokens;
            evidence.cache_creation_input_tokens = d.cache_creation_input_tokens;
            evidence.cache_read_input_tokens = d.cache_read_input_tokens;
            evidence.reasoning_output_tokens = d.reasoning_output_tokens;
            evidence.cost_usd = d.cost_usd;
            evidence.pricing_version = d.pricing_version.clone();
            if let Some(tab) = &d.tab_id {
                evidence.metadata.insert("tab_id".into(), tab.clone());
            }
            evidence.finish_proxy_identity(d.request_id.as_deref());
            if d.output_tokens_estimated {
                evidence.token_usage_state =
                    crate::telemetry::token_metrics::TelemetryMetricState::Estimated;
            }
            let error = d.error_message.filter(|m| !m.is_empty());
            ProxyMessage::ApiCall {
                event: ApiCallEvent {
                    id: uuid::Uuid::new_v4().to_string().to_uppercase(),
                    session_id: d.session_id,
                    provider: Provider::from_raw(&d.provider),
                    model: d.model,
                    endpoint: d.endpoint,
                    input_tokens: d.input_tokens.unwrap_or(0),
                    output_tokens: d.output_tokens.unwrap_or(0),
                    latency_ms: d.latency_ms,
                    status_code: d.status_code,
                    cost_usd: d.cost_usd.unwrap_or(0.0),
                    timestamp: parse_time(&d.timestamp).unwrap_or(now),
                    error_message: error,
                },
                tab_id: d.tab_id.filter(|t| !t.is_empty()),
                project_path: d.project_path.filter(|p| !p.is_empty()),
                token_rate,
                evidence: Box::new(evidence),
            }
        }
        "generation_progress" => {
            let tab = text(&data, "tab_id").unwrap_or_default();
            let provider = text(&data, "provider").unwrap_or_default();
            let mut store = crate::telemetry::token_rate::TokenRateStore::default();
            store.record_rate(
                &tab,
                &provider,
                float(&data, "tokens_per_second"),
                int(&data, "output_tokens_estimate"),
                int(&data, "duration_ms"),
                crate::telemetry::token_rate::TokenRateSource::ProxyStreamEstimate,
                text(&data, "timestamp")
                    .and_then(|s| parse_time(&s))
                    .unwrap_or(now),
            );
            match store.reading(&tab).cloned() {
                Some(reading) => ProxyMessage::GenerationProgress {
                    tab_id: tab,
                    reading,
                },
                None => ProxyMessage::Unknown(kind),
            }
        }
        "task_candidate" => {
            let d: CandidateData = decode(data)?;
            ProxyMessage::TaskCandidate(TaskCandidate {
                id: d.candidate_id,
                tab_id: d.tab_id,
                session_id: d.session_id,
                project_path: d.project_path,
                suggested_name: d.suggested_name,
                trigger: TaskTrigger::from_raw(&d.trigger),
                confidence: d.confidence,
                grace_period_end: now + chrono::Duration::seconds(d.grace_period_seconds),
                created_at: now,
            })
        }
        "task_started" => {
            let d: StartedData = decode(data)?;
            ProxyMessage::TaskStarted(TrackedTask {
                id: d.task_id,
                candidate_id: d.candidate_id.filter(|c| !c.is_empty()),
                tab_id: d.tab_id,
                session_id: d.session_id,
                project_path: d.project_path,
                name: d.task_name,
                start_method: TaskStartMethod::from_raw(&d.start_method),
                trigger: TaskTrigger::from_raw(&d.trigger),
                started_at: now,
                completed_at: None,
                total_api_calls: 0,
                total_tokens: 0,
                total_cost_usd: 0.0,
                baseline_total_tokens: 0,
                tokens_saved: 0,
            })
        }
        "task_candidate_dismissed" => {
            let d: DismissedData = decode(data)?;
            ProxyMessage::TaskCandidateDismissed {
                candidate_id: d.candidate_id,
                tab_id: d.tab_id,
            }
        }
        "task_assessment" => {
            let d: AssessmentData = decode(data)?;
            ProxyMessage::TaskAssessment(TaskAssessment {
                task_id: d.task_id,
                tab_id: d.tab_id,
                approved: d.approved,
                note: d.note.filter(|n| !n.is_empty()),
                total_api_calls: d.total_api_calls,
                total_tokens: d.total_tokens,
                total_cost_usd: d.total_cost_usd,
                tokens_saved: d.tokens_saved,
                duration_seconds: d.duration_seconds,
            })
        }
        other => ProxyMessage::Unknown(other.to_string()),
    })
}

/// Splits a byte stream into newline-terminated lines.
#[derive(Debug, Default)]
pub struct LineBuffer {
    buffer: Vec<u8>,
}

impl LineBuffer {
    /// Add bytes; returns the complete, non-empty lines.
    pub fn push(&mut self, bytes: &[u8]) -> Vec<String> {
        self.buffer.extend_from_slice(bytes);
        let mut lines = Vec::new();
        while let Some(pos) = self.buffer.iter().position(|b| *b == b'\n') {
            let line: Vec<u8> = self.buffer.drain(..=pos).collect();
            let text = String::from_utf8_lossy(&line[..line.len() - 1])
                .trim_end_matches('\r')
                .to_string();
            if !text.is_empty() {
                lines.push(text);
            }
        }
        lines
    }
}

// ----- HTTP to the proxy's local endpoints (PRX-012 to PRX-014, PRX-019) ----------

/// A tiny HTTP/1.1 client for `127.0.0.1:<port>`: one request per
/// connection, `Connection: close`, plain or chunked bodies.
pub fn http_request(
    port: u16,
    method: &str,
    path: &str,
    body: Option<&Value>,
    timeout: Duration,
) -> Result<(u16, String), String> {
    let addr = SocketAddr::from((Ipv4Addr::LOCALHOST, port));
    let mut stream = TcpStream::connect_timeout(&addr, timeout).map_err(|e| e.to_string())?;
    let _ = stream.set_read_timeout(Some(timeout));
    let _ = stream.set_write_timeout(Some(timeout));
    let body = body.map(|b| b.to_string()).unwrap_or_default();
    let mut request = format!(
        "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\nAccept: application/json\r\n"
    );
    if method != "GET" {
        request.push_str(&format!(
            "Content-Type: application/json\r\nContent-Length: {}\r\n",
            body.len()
        ));
    }
    request.push_str("\r\n");
    request.push_str(&body);
    stream
        .write_all(request.as_bytes())
        .map_err(|e| e.to_string())?;
    let mut raw = Vec::new();
    stream.read_to_end(&mut raw).map_err(|e| e.to_string())?;
    parse_http_response(&raw)
}

/// Status code and body of a raw HTTP/1.1 response.
pub fn parse_http_response(raw: &[u8]) -> Result<(u16, String), String> {
    let split = raw
        .windows(4)
        .position(|w| w == b"\r\n\r\n")
        .ok_or("incomplete response")?;
    let head = String::from_utf8_lossy(&raw[..split]);
    let body = &raw[split + 4..];
    let mut lines = head.lines();
    let status: u16 = lines
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|s| s.parse().ok())
        .ok_or("bad status line")?;
    let mut chunked = false;
    let mut length = None;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            let value = value.trim();
            match name.trim().to_ascii_lowercase().as_str() {
                "transfer-encoding" => chunked = value.eq_ignore_ascii_case("chunked"),
                "content-length" => length = value.parse::<usize>().ok(),
                _ => {}
            }
        }
    }
    let body = if chunked {
        decode_chunked(body)?
    } else if let Some(n) = length {
        body[..n.min(body.len())].to_vec()
    } else {
        body.to_vec()
    };
    Ok((status, String::from_utf8_lossy(&body).into_owned()))
}

fn decode_chunked(mut data: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    loop {
        let end = data
            .windows(2)
            .position(|w| w == b"\r\n")
            .ok_or("bad chunk")?;
        let size_text = String::from_utf8_lossy(&data[..end]);
        let size = usize::from_str_radix(size_text.split(';').next().unwrap_or("").trim(), 16)
            .map_err(|_| "bad chunk size")?;
        data = &data[end + 2..];
        if size == 0 {
            return Ok(out);
        }
        if data.len() < size {
            return Err("truncated chunk".into());
        }
        out.extend_from_slice(&data[..size]);
        data = data.get(size + 2..).unwrap_or(&[]);
    }
}

fn int(v: &Value, key: &str) -> i64 {
    v.get(key).and_then(Value::as_i64).unwrap_or(0)
}

fn float(v: &Value, key: &str) -> f64 {
    v.get(key).and_then(Value::as_f64).unwrap_or(0.0)
}

fn text(v: &Value, key: &str) -> Option<String> {
    v.get(key).and_then(Value::as_str).map(str::to_string)
}

/// `GET /health` answered `{"status": "ok"}`.
pub fn health_ok(body: &str) -> bool {
    serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| text(&v, "status"))
        .as_deref()
        == Some("ok")
}

/// `GET /stats`: today's totals.
pub fn decode_stats(body: &str) -> Option<ApiCallStats> {
    let v: Value = serde_json::from_str(body).ok()?;
    v.is_object().then(|| ApiCallStats {
        call_count: int(&v, "calls_today"),
        total_input_tokens: int(&v, "input_tokens_today"),
        total_output_tokens: int(&v, "output_tokens_today"),
        total_cost: float(&v, "cost_today"),
        average_latency_ms: float(&v, "avg_latency_ms"),
    })
}

/// `GET /task/current?tab_id=`: the tab's active task.
pub fn decode_current_task(body: &str, tab_id: &str, now: DateTime<Utc>) -> Option<TrackedTask> {
    let v: Value = serde_json::from_str(body).ok()?;
    if !v.get("has_task").and_then(Value::as_bool).unwrap_or(false) {
        return None;
    }
    Some(TrackedTask {
        id: text(&v, "task_id")?,
        candidate_id: None,
        tab_id: tab_id.to_string(),
        session_id: String::new(),
        project_path: text(&v, "project_path").unwrap_or_default(),
        name: text(&v, "task_name")?,
        start_method: TaskStartMethod::from_raw(
            &text(&v, "start_method").unwrap_or_else(|| "manual".into()),
        ),
        trigger: TaskTrigger::from_raw(&text(&v, "trigger").unwrap_or_default()),
        started_at: now - chrono::Duration::seconds(int(&v, "duration_sec")),
        completed_at: None,
        total_api_calls: int(&v, "total_calls"),
        total_tokens: int(&v, "total_tokens"),
        total_cost_usd: float(&v, "total_cost_usd"),
        baseline_total_tokens: int(&v, "baseline_total_tokens"),
        tokens_saved: int(&v, "tokens_saved"),
    })
}

/// `GET /task/candidate?tab_id=`: the tab's pending candidate.
pub fn decode_candidate(body: &str, tab_id: &str, now: DateTime<Utc>) -> Option<TaskCandidate> {
    let v: Value = serde_json::from_str(body).ok()?;
    if !v
        .get("has_candidate")
        .and_then(Value::as_bool)
        .unwrap_or(false)
    {
        return None;
    }
    let grace = v.get("grace_remaining_ms").and_then(Value::as_i64)?;
    Some(TaskCandidate {
        id: text(&v, "candidate_id")?,
        tab_id: tab_id.to_string(),
        session_id: String::new(),
        project_path: String::new(),
        suggested_name: text(&v, "suggested_name")?,
        trigger: TaskTrigger::from_raw(&text(&v, "trigger")?),
        confidence: v.get("confidence").and_then(Value::as_f64).unwrap_or(0.5),
        grace_period_end: now + chrono::Duration::milliseconds(grace),
        created_at: now,
    })
}

/// `POST /task/start` answered `{"task_id", "task_name"}`.
pub fn decode_started_task(
    body: &str,
    tab_id: &str,
    candidate_id: Option<&str>,
    now: DateTime<Utc>,
) -> Option<TrackedTask> {
    let v: Value = serde_json::from_str(body).ok()?;
    Some(TrackedTask {
        id: text(&v, "task_id")?,
        candidate_id: candidate_id.map(str::to_string),
        tab_id: tab_id.to_string(),
        session_id: String::new(),
        project_path: String::new(),
        name: text(&v, "task_name")?,
        start_method: if candidate_id.is_some() {
            TaskStartMethod::UserConfirmed
        } else {
            TaskStartMethod::Manual
        },
        trigger: TaskTrigger::Manual,
        started_at: now,
        completed_at: None,
        total_api_calls: 0,
        total_tokens: 0,
        total_cost_usd: 0.0,
        baseline_total_tokens: 0,
        tokens_saved: 0,
    })
}

/// A boolean field of a JSON answer (`dismissed`, `success`).
pub fn decode_flag(body: &str, key: &str) -> bool {
    serde_json::from_str::<Value>(body)
        .ok()
        .and_then(|v| v.get(key).and_then(Value::as_bool))
        .unwrap_or(false)
}

/// Percent-encode a query value.
pub fn query_escape(value: &str) -> String {
    let mut out = String::new();
    for b in value.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

// ----- analytics.db, read only (PRX-020, DBG-018) -----------------------------------

/// Read-only queries of the proxy's database (`ProxyAnalyticsStore`).
/// Every call opens the file read-only and closes it; a missing file gives
/// empty results.
pub struct ProxyAnalyticsStore<'a> {
    path: &'a Path,
    failures: std::sync::atomic::AtomicU64,
}

impl<'a> ProxyAnalyticsStore<'a> {
    pub fn new(path: &'a Path) -> Self {
        Self {
            path,
            failures: Default::default(),
        }
    }

    /// Missing database is normal; unreadable files and SQL errors are not an
    /// empty observation. Readers can preserve their last successful snapshot.
    pub fn failure_count(&self) -> u64 {
        self.failures.load(std::sync::atomic::Ordering::Relaxed)
    }
    fn failed(&self) {
        let _ = self.failures.fetch_update(
            std::sync::atomic::Ordering::Relaxed,
            std::sync::atomic::Ordering::Relaxed,
            |v| Some(v.saturating_add(1)),
        );
    }
    fn with<T>(&self, fallback: T, f: impl FnOnce(&Connection) -> rusqlite::Result<T>) -> T {
        match std::fs::metadata(self.path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => return fallback,
            Ok(m) if m.is_file() => {}
            _ => {
                self.failed();
                return fallback;
            }
        }
        let Ok(conn) = Connection::open_with_flags(self.path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        else {
            self.failed();
            log::warn!("ProxyAnalyticsStore: database is unavailable");
            return fallback;
        };
        match f(&conn) {
            Ok(value) => value,
            Err(_) => {
                self.failed();
                log::warn!("ProxyAnalyticsStore: query failed");
                fallback
            }
        }
    }

    /// Bounded cursor walk over retained requests, including optional columns
    /// added by newer Go proxies. Historical missing values remain unknown.
    pub fn evidence_batch(
        &self,
        after_id: i64,
        limit: usize,
    ) -> Vec<(i64, crate::telemetry::evidence::UsageEvidence)> {
        use crate::telemetry::evidence::{SourceKind, UsageEvidence};
        self.with(vec![], |conn| {
            let mut stmt =
                conn.prepare("SELECT * FROM api_calls WHERE id>?1 ORDER BY id LIMIT ?2")?;
            let rows = stmt.query_map(params![after_id, limit.clamp(1, 500) as i64], |row| {
                fn field<T: rusqlite::types::FromSql>(
                    row: &rusqlite::Row<'_>,
                    name: &str,
                ) -> Option<T> {
                    row.get::<_, Option<T>>(name).ok().flatten()
                }
                let id: i64 = row.get("id")?;
                let provider: String = row.get("provider")?;
                let timestamp: String = row.get("timestamp")?;
                let at = parse_time(&timestamp).ok_or(rusqlite::Error::InvalidQuery)?;
                let mut e = UsageEvidence::empty(&provider, SourceKind::Proxy, at);
                e.session_id = field(row, "session_id");
                e.model = field(row, "model");
                e.endpoint = field(row, "endpoint");
                e.project_path = field(row, "project_path");
                e.input_tokens = field(row, "input_tokens");
                e.output_tokens = field(row, "output_tokens");
                e.cache_creation_input_tokens = field(row, "cache_creation_input_tokens");
                e.cache_read_input_tokens = field(row, "cache_read_input_tokens");
                e.reasoning_output_tokens = field(row, "reasoning_output_tokens");
                e.cost_usd = field(row, "cost_usd");
                e.pricing_version = field(row, "pricing_version");
                if let Some(tab) = field::<String>(row, "tab_id").filter(|s| !s.is_empty()) {
                    e.metadata.insert("tab_id".into(), tab);
                }
                let request: Option<String> = field(row, "request_id");
                e.finish_proxy_identity(request.as_deref());
                // Persist a cursor for failed rows too, but preserve failure evidence as unknown.
                if !field::<i64>(row, "status_code").is_some_and(|s| (200..300).contains(&s)) {
                    e.metadata.insert(
                        "request_status".into(),
                        field::<i64>(row, "status_code").unwrap_or(0).to_string(),
                    );
                }
                Ok((id, e))
            })?;
            rows.collect()
        })
    }

    pub fn activity_samples(
        &self,
        after: Option<DateTime<Utc>>,
    ) -> Vec<crate::telemetry::latency::ActivitySample> {
        self.with(vec![],|conn| {
            let mut stmt=conn.prepare("SELECT provider,endpoint,timestamp FROM api_calls WHERE status_code>=200 AND status_code<300 AND (?1 IS NULL OR timestamp >= ?1) ORDER BY timestamp,id")?;
            let rows=stmt.query_map([after.map(|at|at.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string())],|row|{
                let provider:String=row.get(0)?;let endpoint:String=row.get(1)?;let at:String=row.get(2)?;
                if !crate::telemetry::latency::relevant_endpoint(&provider,&endpoint){return Ok(None);}
                Ok(crate::telemetry::date_codec::parse_iso8601(Some(&at)).map(|timestamp|crate::telemetry::latency::ActivitySample{provider:provider.to_lowercase(),timestamp}))
            })?;
            rows.filter_map(|r|r.transpose()).collect()
        })
    }

    /// Successful generation requests only. Prefer observed TTFT; old schemas
    /// without TTFT keep their request latency instead of inventing a value.
    pub fn latency_samples(
        &self,
        after: Option<DateTime<Utc>>,
    ) -> Vec<crate::telemetry::latency::LatencySample> {
        use crate::telemetry::latency::{
            LatencySample, MetricKind, preferred_api_latency, relevant_endpoint,
        };
        self.with(vec![], |conn| {
            let mut columns=conn.prepare("PRAGMA table_info(api_calls)")?;
            let has_ttft=columns.query_map([],|row|row.get::<_,String>(1))?.filter_map(Result::ok).any(|name|name=="ttft_ms");
            let sql=format!("SELECT id,provider,model,session_id,endpoint,latency_ms,{},timestamp FROM api_calls WHERE status_code >= 200 AND status_code < 300 AND (?1 IS NULL OR timestamp >= ?1) ORDER BY timestamp,id",if has_ttft {"ttft_ms"}else{"NULL"});
            let mut stmt=conn.prepare(&sql)?;
            let rows=stmt.query_map([after.map(|at|at.format("%Y-%m-%dT%H:%M:%S%.3fZ").to_string())], |row| {
                let provider:String=row.get(1)?;let endpoint:String=row.get(4)?;
                let latency=preferred_api_latency(row.get(5)?,row.get(6)?);
                let timestamp:String=row.get(7)?;
                if !relevant_endpoint(&provider,&endpoint) {return Ok(None);}
                let Some(latency_ms)=latency else {return Ok(None);};
                let Some(timestamp)=crate::telemetry::date_codec::parse_iso8601(Some(&timestamp)) else {return Ok(None);};
                Ok(Some(LatencySample{id:format!("proxy|{}",row.get::<_,i64>(0)?),provider:provider.to_lowercase(),metric_kind:MetricKind::ApiRequest,latency_ms,timestamp,model:row.get(2)?,session_id:row.get(3)?,run_id:None,round_index:None,project_path:None,source_kind:"proxy_request".into()}))
            })?;
            rows.filter_map(|r|r.transpose()).collect::<rusqlite::Result<Vec<_>>>()
        })
    }

    /// Calls, tokens, cost and average latency, since `after` when given.
    pub fn overall_stats(&self, after: Option<DateTime<Utc>>) -> ProxyStats {
        let after = after.map(|d| crate::telemetry::date_codec::format_iso8601_fractional(&d));
        let mut sql =
            "SELECT COUNT(*), COALESCE(SUM(input_tokens), 0), COALESCE(SUM(output_tokens), 0),
                    COALESCE(SUM(cost_usd), 0), COALESCE(AVG(latency_ms), 0) FROM api_calls"
                .to_string();
        if after.is_some() {
            sql.push_str(" WHERE timestamp >= ?");
        }
        self.with(ProxyStats::default(), |c| {
            c.query_row(&sql, rusqlite::params_from_iter(after.iter()), |r| {
                Ok(ProxyStats {
                    call_count: r.get(0)?,
                    total_tokens: r.get::<_, i64>(1)? + r.get::<_, i64>(2)?,
                    total_cost: r.get(3)?,
                    average_latency_ms: r.get(4)?,
                })
            })
        })
    }

    /// Per provider, most calls first.
    pub fn provider_stats(&self) -> Vec<ProxyProviderStat> {
        self.with(Vec::new(), |c| {
            let mut stmt = c.prepare(
                "SELECT provider, COUNT(*), COALESCE(SUM(input_tokens), 0) + COALESCE(SUM(output_tokens), 0),
                        COALESCE(SUM(cost_usd), 0)
                 FROM api_calls GROUP BY provider ORDER BY COUNT(*) DESC, provider ASC",
            )?;
            let rows = stmt.query_map([], |r| {
                Ok(ProxyProviderStat {
                    provider: r.get(0)?,
                    call_count: r.get(1)?,
                    total_tokens: r.get(2)?,
                    total_cost: r.get(3)?,
                })
            })?;
            Ok(rows.filter_map(Result::ok).collect())
        })
    }

    /// Per day over the last `days` (1 to 90).
    pub fn daily_trend(&self, days: i64) -> Vec<ProxyDailyPoint> {
        let days = days.clamp(1, 90);
        let sql = format!(
            "SELECT date(timestamp) AS day, COUNT(*),
                    COALESCE(SUM(input_tokens), 0) + COALESCE(SUM(output_tokens), 0),
                    COALESCE(SUM(cost_usd), 0)
             FROM api_calls WHERE timestamp >= date('now', '-{days} days')
             GROUP BY day ORDER BY day"
        );
        self.with(Vec::new(), |c| {
            let mut stmt = c.prepare(&sql)?;
            let rows = stmt.query_map([], |r| {
                Ok(ProxyDailyPoint {
                    date: r.get(0)?,
                    call_count: r.get(1)?,
                    total_tokens: r.get(2)?,
                    total_cost: r.get(3)?,
                })
            })?;
            Ok(rows.filter_map(Result::ok).collect())
        })
    }

    /// The most recent calls, newest first.
    pub fn recent_calls(&self, limit: usize) -> Vec<ApiCallEvent> {
        self.with(Vec::new(), |c| {
            let mut stmt = c.prepare(
                "SELECT session_id, provider, model, endpoint, input_tokens, output_tokens,
                        latency_ms, status_code, cost_usd, timestamp, error_message
                 FROM api_calls ORDER BY timestamp DESC LIMIT ?",
            )?;
            let rows = stmt.query_map(params![limit as i64], |r| {
                let timestamp: Option<String> = r.get(9)?;
                Ok(ApiCallEvent {
                    id: uuid::Uuid::new_v4().to_string().to_uppercase(),
                    session_id: r.get::<_, Option<String>>(0)?.unwrap_or_default(),
                    provider: Provider::from_raw(
                        &r.get::<_, Option<String>>(1)?.unwrap_or_default(),
                    ),
                    model: r.get::<_, Option<String>>(2)?.unwrap_or_default(),
                    endpoint: r.get::<_, Option<String>>(3)?.unwrap_or_default(),
                    input_tokens: r.get::<_, Option<i64>>(4)?.unwrap_or(0),
                    output_tokens: r.get::<_, Option<i64>>(5)?.unwrap_or(0),
                    latency_ms: r.get::<_, Option<i64>>(6)?.unwrap_or(0),
                    status_code: r.get::<_, Option<i64>>(7)?.unwrap_or(0),
                    cost_usd: r.get::<_, Option<f64>>(8)?.unwrap_or(0.0),
                    timestamp: timestamp
                        .as_deref()
                        .and_then(parse_db_time)
                        .unwrap_or(DateTime::<Utc>::MIN_UTC),
                    error_message: r.get(10)?,
                })
            })?;
            Ok(rows.filter_map(Result::ok).collect())
        })
    }

    /// Whether the file exists (used for "no data yet").
    pub fn exists(&self) -> bool {
        self.with(false, |c| {
            c.query_row(
                "SELECT name FROM sqlite_master WHERE type='table' AND name='api_calls'",
                [],
                |_| Ok(()),
            )
            .optional()
            .map(|r| r.is_some())
        })
    }
}

/// The proxy writes RFC 3339 or SQLite `datetime('now')` text.
fn parse_db_time(text: &str) -> Option<DateTime<Utc>> {
    parse_time(text).or_else(|| {
        chrono::NaiveDateTime::parse_from_str(text, "%Y-%m-%d %H:%M:%S")
            .ok()
            .map(|n| n.and_utc())
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn now() -> DateTime<Utc> {
        parse_time("2026-10-10T12:00:00Z").unwrap()
    }

    #[test]
    fn ports_and_envs_are_our_own() {
        assert_ne!(DEFAULT_PORT, 18080);
        assert_ne!(tls_port(DEFAULT_PORT), 18081);
        assert_eq!(clamp_port(80), 1024);
        assert_eq!(clamp_port(70000), 65534);
        assert_eq!(clamp_port(18090), 18090);
        let root = DataRoot::with_home(PathBuf::from("/home/u"), true);
        let env = proxy_env(&root, 18090, true);
        let get = |k: &str| env.iter().find(|(key, _)| key == k).unwrap().1.clone();
        assert_eq!(get("CHAU7_PROXY_PORT"), "18090");
        assert_eq!(get("CHAU7_TLS_PORT"), "18091");
        assert_eq!(get("CHAU7_LOG_PROMPTS"), "1");
        assert_eq!(get("CHAU7_LOG_LEVEL"), "info");
        for key in [
            "CHAU7_DB_PATH",
            "CHAU7_IPC_SOCKET",
            "CHAU7_TLS_CERT",
            "CHAU7_TLS_KEY",
            "CHAU7_INJECTION_RULES",
            "CHAU7_INJECTION_REPO_OVERRIDES",
        ] {
            let path = PathBuf::from(get(key));
            let home = PathBuf::from("/home/u");
            assert!(
                path.starts_with(home.join(".chau7-next"))
                    || path.starts_with(home.join(".chau7-next-state")),
                "{key}"
            );
        }
        assert_eq!(get("CHAU7_PARENT_PID"), std::process::id().to_string());
        let shell = shell_env(18090, true, "TERM", "TAB", "/p");
        let get = |k: &str| shell.iter().find(|(key, _)| key == k).map(|v| v.1.clone());
        assert_eq!(
            get("ANTHROPIC_BASE_URL").as_deref(),
            Some("http://127.0.0.1:18090")
        );
        assert_eq!(
            get("OPENAI_BASE_URL").as_deref(),
            Some("https://127.0.0.1:18091/_chau7/project/L3A/v1")
        );
        assert_eq!(
            get("GOOGLE_GEMINI_BASE_URL").as_deref(),
            Some("http://127.0.0.1:18090")
        );
        assert_eq!(get("CHAU7_NEXT_SESSION_ID").as_deref(), Some("TERM"));
        assert_eq!(get("CHAU7_NEXT_TAB_ID").as_deref(), Some("TAB"));
        assert_eq!(get("CHAU7_NEXT_PROJECT").as_deref(), Some("/p"));
        let no_openai = shell_env(18090, false, "T", "B", "/p");
        assert!(!no_openai.iter().any(|(k, _)| k == "OPENAI_BASE_URL"));
    }

    #[test]
    fn codex_launch_paths_are_owned_and_project_tokens_round_trip() {
        let root = DataRoot::with_home(std::path::PathBuf::from("/fixture-home"), true);
        let vars = codex_shell_env(&root, 18090);
        for (key, path) in vars
            .iter()
            .filter(|(key, _)| key != "CHAU7_NEXT_OPENAI_PROXY_BASE_URL")
        {
            assert!(std::path::Path::new(path).starts_with(root.home()), "{key}");
            assert!(path.contains("chau7-next"), "{key}");
        }
        let project = "/repo with quote\\\" and 🦀";
        let path = proxy_project_path(project);
        let token = path.strip_prefix("/_chau7/project/").unwrap();
        assert_eq!(
            base64::engine::general_purpose::URL_SAFE_NO_PAD
                .decode(token)
                .unwrap(),
            project.as_bytes()
        );
        assert!(
            !vars
                .iter()
                .any(|(key, _)| key == "HTTPS_PROXY" || key == "CODEX_CA_CERTIFICATE")
        );
    }
    #[test]
    fn formatting_matches_swift() {
        assert_eq!(format_cost(0.0012), "$0.0012");
        assert_eq!(format_cost(0.123), "$0.12");
        assert_eq!(format_latency(850), "850ms");
        assert_eq!(format_latency(1234), "1.2s");
        assert_eq!(format_grouped(1234567), "1,234,567");
        assert_eq!(format_grouped(12), "12");
        assert_eq!(format_task_duration(42), "42s");
        assert_eq!(format_task_duration(192), "3m 12s");
        assert_eq!(format_task_duration(3840), "1h 4m");
        assert_eq!(format_tokens_saved(120), "+120");
        assert_eq!(format_tokens_saved(-40), "-40");
        assert_eq!(format_tokens_saved(0), "0");
        assert_eq!(Provider::from_raw("gemini").display_name(), "Google");
        assert_eq!(Provider::from_raw("x"), Provider::Unknown);
        assert_eq!(Provider::Anthropic.color_name(), "purple");
        assert_eq!(Provider::OpenAi.icon_system_name(), "sparkles");
    }

    #[test]
    fn parses_ipc_messages() {
        let line = r#"{"schema_version":"1.0.0","type":"api_call","tool":"proxy","origin":"proxy","ts":"2026-10-10T11:00:00Z","data":{"session_id":"S","provider":"anthropic","model":"claude-x","endpoint":"/v1/messages","input_tokens":10,"output_tokens":5,"latency_ms":850,"ttft_ms":0,"status_code":200,"cost_usd":0.0012,"timestamp":"2026-10-10T11:00:00Z","tab_id":"TAB"}}"#;
        let ProxyMessage::ApiCall { event, tab_id, .. } = parse_message(line, now()).unwrap()
        else {
            panic!()
        };
        assert_eq!(tab_id.as_deref(), Some("TAB"));
        assert_eq!(event.provider, Provider::Anthropic);
        assert_eq!(event.total_tokens(), 15);
        assert!(event.is_success() && !event.has_error());
        assert_eq!(
            event.timeline_message(),
            "Anthropic claude-x: in:10 out:5 $0.0012"
        );
        assert_eq!(event.timeline_type(), "api_call");
        assert_eq!(event.timestamp, parse_time("2026-10-10T11:00:00Z").unwrap());

        let line = r#"{"type":"task_candidate","data":{"candidate_id":"C","tab_id":"TAB","session_id":"S","project_path":"/p","suggested_name":"Fix bug","trigger":"idle_gap","confidence":0.8,"grace_period_seconds":5}}"#;
        let ProxyMessage::TaskCandidate(c) = parse_message(line, now()).unwrap() else {
            panic!()
        };
        assert_eq!(c.trigger, TaskTrigger::IdleGap);
        assert_eq!(c.grace_remaining_ms(now()), 5000);
        assert!(!c.is_expired(now()));

        let line = r#"{"type":"task_started","data":{"task_id":"T","candidate_id":"C","tab_id":"TAB","session_id":"S","project_path":"/p","task_name":"Fix bug","start_method":"auto_confirmed","trigger":"idle_gap"}}"#;
        let ProxyMessage::TaskStarted(mut t) = parse_message(line, now()).unwrap() else {
            panic!()
        };
        assert_eq!(t.start_method, TaskStartMethod::AutoConfirmed);
        t.add_call(&event);
        assert_eq!(t.total_api_calls, 1);
        assert_eq!(t.total_tokens, 15);

        let line = r#"{"type":"task_candidate_dismissed","data":{"candidate_id":"C","tab_id":"TAB","dismiss_method":"user","reason":"x"}}"#;
        assert_eq!(
            parse_message(line, now()).unwrap(),
            ProxyMessage::TaskCandidateDismissed {
                candidate_id: "C".into(),
                tab_id: "TAB".into()
            }
        );
        let line = r#"{"type":"task_assessment","data":{"task_id":"T","tab_id":"TAB","session_id":"S","approved":true,"total_api_calls":3,"total_tokens":9,"total_cost_usd":0.5,"tokens_saved":null,"duration_seconds":60}}"#;
        let ProxyMessage::TaskAssessment(a) = parse_message(line, now()).unwrap() else {
            panic!()
        };
        assert!(a.approved && a.tokens_saved.is_none());
        assert!(matches!(
            parse_message(r#"{"type":"other"}"#, now()),
            Ok(ProxyMessage::Unknown(_))
        ));
        assert!(parse_message("nope", now()).is_err());
        assert!(parse_message(r#"{"type":"api_call","data":{}}"#, now()).is_err());
    }

    #[test]
    fn generation_progress_and_optional_usage_preserve_confidence() {
        let now = now();
        let line = r#"{"type":"generation_progress","data":{"tab_id":"tab","provider":"claude","output_tokens_estimate":50,"tokens_per_second":25.0,"duration_ms":2000,"timestamp":"2026-04-01T10:00:00Z"}}"#;
        let ProxyMessage::GenerationProgress { tab_id, reading } =
            parse_message(line, now).unwrap()
        else {
            panic!("progress")
        };
        assert_eq!(tab_id, "tab");
        assert_eq!(reading.formatted(), "~25 t/s");
        let line = r#"{"type":"api_call","data":{"session_id":"s","tab_id":"tab","provider":"claude","model":"m","endpoint":"/v1/messages","input_tokens":null,"output_tokens":50,"cost_usd":null,"latency_ms":3000,"ttft_ms":1000,"is_streaming":true,"status_code":200,"timestamp":"2026-04-01T10:00:00Z"}}"#;
        let ProxyMessage::ApiCall {
            token_rate: Some(reading),
            event,
            ..
        } = parse_message(line, now).unwrap()
        else {
            panic!("call")
        };
        assert_eq!(event.input_tokens, 0);
        assert_eq!(reading.formatted(), "25 t/s");
        assert_eq!(reading.duration_ms, 2000);
        let line = line.replace("\"is_streaming\":true", "\"is_streaming\":false");
        let ProxyMessage::ApiCall {
            token_rate: Some(reading),
            ..
        } = parse_message(&line, now).unwrap()
        else {
            panic!("request")
        };
        assert!(reading.source.estimated());
        assert_eq!(reading.duration_ms, 3000);
        let line = line.replace("\"output_tokens\":50", "\"output_tokens\":null");
        let ProxyMessage::ApiCall { token_rate, .. } = parse_message(&line, now).unwrap() else {
            panic!("missing")
        };
        assert!(token_rate.is_none());
    }

    #[test]
    fn line_buffer_splits_on_newlines() {
        let mut b = LineBuffer::default();
        assert!(b.push(b"{\"a\":").is_empty());
        assert_eq!(
            b.push(b"1}\n\n{\"b\":2}\r\n{"),
            vec!["{\"a\":1}", "{\"b\":2}"]
        );
        assert_eq!(b.push(b"}\n"), vec!["{}"]);
    }

    #[test]
    fn http_responses_and_endpoint_bodies() {
        let raw = b"HTTP/1.1 200 OK\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}";
        let (code, body) = parse_http_response(raw).unwrap();
        assert_eq!(code, 200);
        assert!(health_ok(&body));
        let chunked = b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\n{\"dis\r\nd\r\nmissed\":true}\r\n0\r\n\r\n";
        let (_, body) = parse_http_response(chunked).unwrap();
        assert!(decode_flag(&body, "dismissed"));
        assert!(!decode_flag(&body, "success"));

        let stats = decode_stats(r#"{"calls_today":3,"input_tokens_today":10,"output_tokens_today":5,"cost_today":0.25,"avg_latency_ms":400.5}"#).unwrap();
        assert_eq!(stats.call_count, 3);
        assert_eq!(stats.total_tokens(), 15);

        let task = decode_current_task(
            r#"{"has_task":true,"task_id":"T","task_name":"N","state":"active","total_calls":2,"total_tokens":40,"total_cost_usd":0.1,"duration_sec":30,"tokens_saved":-5}"#,
            "TAB",
            now(),
        )
        .unwrap();
        assert_eq!(task.duration_seconds(now()), 30);
        assert_eq!(task.formatted_tokens_saved(), "-5");
        assert!(decode_current_task(r#"{"has_task":false}"#, "TAB", now()).is_none());

        let cand = decode_candidate(
            r#"{"has_candidate":true,"candidate_id":"C","suggested_name":"N","trigger":"new_session","grace_remaining_ms":2500}"#,
            "TAB",
            now(),
        )
        .unwrap();
        assert_eq!(cand.grace_remaining_ms(now()), 2500);
        assert_eq!(cand.confidence, 0.5);

        let started = decode_started_task(
            r#"{"task_id":"T","task_name":"N"}"#,
            "TAB",
            Some("C"),
            now(),
        )
        .unwrap();
        assert_eq!(started.start_method, TaskStartMethod::UserConfirmed);
        assert_eq!(query_escape("a b/c"), "a%20b%2Fc");
    }

    #[test]
    fn http_request_round_trip() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = std::thread::spawn(move || {
            let (mut s, _) = listener.accept().unwrap();
            let mut buf = [0u8; 4096];
            let n = s.read(&mut buf).unwrap();
            let req = String::from_utf8_lossy(&buf[..n]).to_string();
            s.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 16\r\n\r\n{\"success\":true}")
                .unwrap();
            req
        });
        let (code, body) = http_request(
            port,
            "POST",
            "/task/assess",
            Some(&serde_json::json!({"task_id": "T", "approved": true})),
            Duration::from_secs(2),
        )
        .unwrap();
        let req = server.join().unwrap();
        assert!(req.starts_with("POST /task/assess HTTP/1.1"));
        assert!(req.contains("\"approved\":true"));
        assert_eq!(code, 200);
        assert!(decode_flag(&body, "success"));
    }

    #[test]
    fn analytics_store_reads_the_proxy_database() {
        let dir = std::env::temp_dir().join(format!("chau7-next-proxy-db-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("analytics.db");
        let store = ProxyAnalyticsStore::new(&path);
        assert_eq!(store.overall_stats(None), ProxyStats::default());
        assert!(!store.exists());
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE api_calls (id INTEGER PRIMARY KEY, session_id TEXT, provider TEXT NOT NULL, model TEXT,
              endpoint TEXT NOT NULL, input_tokens INTEGER DEFAULT 0, output_tokens INTEGER DEFAULT 0,
              latency_ms INTEGER, ttft_ms INTEGER DEFAULT 0, status_code INTEGER, cost_usd REAL DEFAULT 0,
              timestamp TEXT DEFAULT (datetime('now')), error_message TEXT, task_id TEXT, tab_id TEXT, project_path TEXT);
             INSERT INTO api_calls (session_id, provider, model, endpoint, input_tokens, output_tokens, latency_ms, status_code, cost_usd)
               VALUES ('s', 'anthropic', 'm', '/v1/messages', 10, 5, 100, 200, 0.5);
             INSERT INTO api_calls (session_id, provider, model, endpoint, input_tokens, output_tokens, latency_ms, status_code, cost_usd)
               VALUES ('s', 'openai', 'g', '/v1/responses', 1, 1, 300, 500, 0.1);",
        )
        .unwrap();
        drop(conn);
        assert!(store.exists());
        let stats = store.overall_stats(None);
        assert_eq!(stats.call_count, 2);
        assert_eq!(stats.total_tokens, 17);
        assert!((stats.average_latency_ms - 200.0).abs() < 1e-9);
        let providers = store.provider_stats();
        assert_eq!(providers.len(), 2);
        assert_eq!(providers[0].provider, "anthropic");
        assert_eq!(store.daily_trend(7).len(), 1);
        let recent = store.recent_calls(15);
        assert_eq!(recent.len(), 2);
        assert!(recent[0].timestamp > DateTime::<Utc>::MIN_UTC);
        assert!(!recent[0].debug_call().formatted_latency.is_empty());
        let _ = std::fs::remove_dir_all(dir);
    }
    #[test]
    fn request_latency_filters_errors_and_prefers_ttft_on_new_and_legacy_schemas() {
        for ttft in [true, false] {
            let dir = std::env::temp_dir().join(format!(
                "chau7-next-latency-db-{}-{ttft}",
                std::process::id()
            ));
            let _ = std::fs::remove_dir_all(&dir);
            std::fs::create_dir_all(&dir).unwrap();
            let path = dir.join("db");
            let conn = Connection::open(&path).unwrap();
            conn.execute_batch(&format!("CREATE TABLE api_calls (id INTEGER PRIMARY KEY,provider TEXT,model TEXT,session_id TEXT,endpoint TEXT,latency_ms INTEGER,{}status_code INTEGER,timestamp TEXT);INSERT INTO api_calls(id,provider,endpoint,latency_ms,status_code,timestamp) VALUES (1,'openai','/v1/responses',500,200,'2026-10-11T10:00:00Z'),(2,'openai','/v1/models',50,200,'2026-10-11T10:00:00Z'),(3,'anthropic','/v1/messages',40,500,'2026-10-11T10:00:00Z');",if ttft {"ttft_ms INTEGER,"}else{""})).unwrap();
            if ttft {
                conn.execute("UPDATE api_calls SET ttft_ms=100 WHERE id=1", [])
                    .unwrap();
            }
            drop(conn);
            let samples = ProxyAnalyticsStore::new(&path).latency_samples(None);
            assert_eq!(samples.len(), 1);
            assert_eq!(samples[0].latency_ms, if ttft { 100 } else { 500 });
            let _ = std::fs::remove_dir_all(dir);
        }
    }
}

#[cfg(test)]
mod analytics_failure_tests {
    use super::*;
    #[test]
    fn missing_is_normal_but_owned_invalid_database_and_sql_errors_are_unknown() {
        let directory =
            std::env::temp_dir().join(format!("next-proxy-failure-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory).unwrap();
        let path = directory.join("owned.db");
        let store = ProxyAnalyticsStore::new(&path);
        let _ = store.overall_stats(None);
        assert_eq!(store.failure_count(), 0);
        std::fs::write(&path, b"invalid owned fixture, no user records").unwrap();
        let _ = store.overall_stats(None);
        assert_eq!(store.failure_count(), 1);
        std::fs::remove_file(&path).unwrap();
        let connection = Connection::open(&path).unwrap();
        connection
            .execute_batch("CREATE TABLE owned(value INTEGER)")
            .unwrap();
        drop(connection);
        let _ = store.overall_stats(None);
        assert_eq!(store.failure_count(), 2);
        store
            .failures
            .store(u64::MAX, std::sync::atomic::Ordering::Relaxed);
        store.failed();
        assert_eq!(store.failure_count(), u64::MAX);
        std::fs::remove_dir_all(directory).unwrap();
    }
}
