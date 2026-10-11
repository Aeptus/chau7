//! State snapshots, bug reports and the "Report an Issue" draft
//! (`Logging/DebugContext.swift` `StateSnapshot` and `BugReporter`,
//! `Logging/BugReportDraft.swift`).
//!
//! Pure logic: the snapshot types with Swift's JSON shape, the Markdown of
//! the local report, the Markdown of the opt-in draft (privacy first: every
//! sensitive section is off by default), path redaction, the prefilled GitHub
//! issue URL, and the validation of the submit request and its response.
//! Capturing the state and the HTTP call are in `chau7_next/src/debug/`.

use std::collections::BTreeMap;

use chrono::{DateTime, NaiveDateTime, SecondsFormat, Utc};
use serde::{Deserialize, Serialize};

use crate::iso8601::format_iso8601;

/// Repository the prefilled issue is opened in.
pub const GITHUB_ISSUE_OWNER: &str = "anthropics";
pub const GITHUB_ISSUE_REPO: &str = "chau7";

/// Shown in the report when the user typed nothing.
pub const NO_DESCRIPTION: &str = "(No description provided)";

/// A date as Swift's `.iso8601` strategy writes it: whole seconds, `Z`.
mod seconds_date {
    use super::*;
    use serde::{Deserializer, Serializer};

    pub fn serialize<S: Serializer>(date: &DateTime<Utc>, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_str(&date.to_rfc3339_opts(SecondsFormat::Secs, true))
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<DateTime<Utc>, D::Error> {
        let text = String::deserialize(d)?;
        DateTime::parse_from_rfc3339(&text)
            .map(|d| d.with_timezone(&Utc))
            .map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TabState {
    pub id: String,
    pub title: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub custom_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub active_app_name: Option<String>,
    pub status: String,
    pub current_directory: String,
    pub is_git_repo: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub git_branch: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ClaudeSessionState {
    pub id: String,
    pub project_name: String,
    pub state: String,
    #[serde(with = "seconds_date")]
    pub last_activity: DateTime<Utc>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_tool_name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct EventState {
    #[serde(with = "seconds_date")]
    pub timestamp: DateTime<Utc>,
    #[serde(rename = "type")]
    pub kind: String,
    pub hook: String,
    pub tool_name: String,
    pub message: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ContextState {
    pub id: String,
    pub operation: String,
    #[serde(with = "seconds_date")]
    pub start_time: DateTime<Utc>,
    pub duration_ms: u64,
}

/// A snapshot of the whole app state (`StateSnapshot`).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StateSnapshot {
    #[serde(with = "seconds_date")]
    pub timestamp: DateTime<Utc>,
    pub app_version: String,
    pub os_version: String,
    pub tab_count: usize,
    pub active_tab_index: usize,
    pub tab_states: Vec<TabState>,
    pub claude_sessions: Vec<ClaudeSessionState>,
    pub recent_events: Vec<EventState>,
    pub feature_flags: BTreeMap<String, bool>,
    pub recent_logs: Vec<String>,
    pub active_contexts: Vec<ContextState>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub recent_incidents: Vec<crate::incidents::Breadcrumb>,
}

impl StateSnapshot {
    /// The JSON file content: pretty printed with sorted keys, like the
    /// Swift encoder (`.prettyPrinted`, `.sortedKeys`).
    pub fn to_json(&self) -> String {
        let compact = serde_json::to_string(self).unwrap_or_default();
        crate::json_pretty::pretty_print(&compact).unwrap_or(compact)
    }

    /// `chau7-snapshot-<yyyy-MM-dd_HH-mm-ss>.json` (local time).
    pub fn file_name(local: NaiveDateTime) -> String {
        format!("chau7-snapshot-{}.json", file_stamp(local))
    }

    /// Title of the issue (`Bug report from Chau7 <version>`).
    pub fn issue_title(&self, product: &str) -> String {
        format!("Bug report from {product} {}", self.app_version)
    }
}

/// `yyyy-MM-dd_HH-mm-ss`.
pub fn file_stamp(local: NaiveDateTime) -> String {
    local.format("%Y-%m-%d_%H-%M-%S").to_string()
}

/// `chau7-bug-report-<ts>.md`.
pub fn report_file_name(local: NaiveDateTime) -> String {
    format!("chau7-bug-report-{}.md", file_stamp(local))
}

// ----- local bug report (BugReporter.makeReportPayload) --------------------

/// The Markdown of a local bug report: everything, no opt-in
/// (`BugReporter.makeReportPayload`).
pub fn local_report(
    snapshot: &StateSnapshot,
    description: &str,
    generated: DateTime<Utc>,
) -> String {
    let description = if description.is_empty() {
        NO_DESCRIPTION
    } else {
        description
    };
    let mut report = format!(
        "# Chau7 Bug Report\nGenerated: {}\n\n## User Description\n{description}\n\n## Environment\n- App Version: {}\n- OS Version: {}\n- Tabs: {} (active: {})\n\n## Tab States",
        format_iso8601(generated),
        snapshot.app_version,
        snapshot.os_version,
        snapshot.tab_count,
        snapshot.active_tab_index
    );
    for (i, tab) in snapshot.tab_states.iter().enumerate() {
        let title = tab.custom_title.as_deref().unwrap_or(&tab.title);
        let git = if tab.is_git_repo {
            tab.git_branch.as_deref().unwrap_or("yes")
        } else {
            "no"
        };
        report.push_str(&format!(
            "\n\n### Tab {}: {title}\n- Active App: {}\n- Status: {}\n- Directory: {}\n- Git: {git}",
            i + 1,
            tab.active_app_name.as_deref().unwrap_or("none"),
            tab.status,
            tab.current_directory,
        ));
    }
    report.push_str("\n\n\n## Claude Code Sessions");
    for session in &snapshot.claude_sessions {
        report.push_str(&format!(
            "\n\n- {}: {}\n  Last activity: {}\n  Last tool: {}",
            session.project_name,
            session.state,
            format_iso8601(session.last_activity),
            session.last_tool_name.as_deref().unwrap_or("none")
        ));
    }
    report.push_str("\n\n\n## Recent Events (last 20)");
    for event in &snapshot.recent_events {
        let tool = if event.tool_name.is_empty() {
            &event.hook
        } else {
            &event.tool_name
        };
        report.push_str(&format!("\n- [{}] {tool}: {}", event.kind, event.message));
    }
    report.push_str("\n\n\n## Active Debug Contexts");
    for ctx in &snapshot.active_contexts {
        report.push_str(&format!(
            "\n- [{}] {} (running {}ms)",
            ctx.id, ctx.operation, ctx.duration_ms
        ));
    }
    if !snapshot.recent_incidents.is_empty() {
        report.push_str("\n\n## Recent local incidents\n```json\n");
        report.push_str(
            &serde_json::to_string_pretty(&snapshot.recent_incidents).unwrap_or_default(),
        );
        report.push_str("\n```");
    }
    report.push_str("\n\n\n## Feature Flags");
    for (flag, enabled) in &snapshot.feature_flags {
        report.push_str(&format!(
            "\n- {flag}: {}",
            if *enabled { "enabled" } else { "disabled" }
        ));
    }
    report.push_str(&format!(
        "\n\n\n## Recent Logs (last 50 lines)\n```\n{}\n```",
        snapshot.recent_logs.join("\n")
    ));
    report
}

// ----- prefilled GitHub issue ------------------------------------------------

/// Percent-encode everything but the unreserved characters.
pub fn percent_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    for byte in text.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

/// Longest prefilled URL GitHub reliably accepts.
pub const MAX_ISSUE_URL_LEN: usize = 7500;

/// `https://github.com/anthropics/chau7/issues/new?title=..&body=..`. A body
/// that would make the link too long for GitHub is cut, with a note.
pub fn prefilled_issue_url(title: &str, body: &str) -> String {
    let base = format!(
        "https://github.com/{GITHUB_ISSUE_OWNER}/{GITHUB_ISSUE_REPO}/issues/new?title={}&body=",
        percent_encode(title)
    );
    let encoded = percent_encode(body);
    if base.len() + encoded.len() <= MAX_ISSUE_URL_LEN {
        return format!("{base}{encoded}");
    }
    let note = "\n\n(Report truncated to fit the link. Use Save Report for the full text.)";
    let budget = MAX_ISSUE_URL_LEN.saturating_sub(base.len() + percent_encode(note).len());
    let mut cut = String::new();
    let mut used = 0;
    for c in body.chars() {
        let cost = percent_encode(&c.to_string()).len();
        if used + cost > budget {
            break;
        }
        used += cost;
        cut.push(c);
    }
    format!("{base}{}{}", percent_encode(&cut), percent_encode(note))
}

// ----- path redaction ----------------------------------------------------------

/// Replace the home directory with `~` (`redactPath`).
pub fn redact_path(path: &str, home: &str) -> String {
    if path.is_empty() {
        return path.to_string();
    }
    if !home.is_empty() && path.starts_with(home) {
        return format!("~{}", &path[home.len()..]);
    }
    path.to_string()
}

/// A tab title the shell set to a full path is redacted too (`redactTitle`).
pub fn redact_title(title: &str, home: &str) -> String {
    if title.starts_with('/') || (!home.is_empty() && title.starts_with(home)) {
        redact_path(title, home)
    } else {
        title.to_string()
    }
}

// ----- the Report an Issue draft --------------------------------------------------

/// What the dialog collects; the Markdown is rebuilt from it on every change
/// (`BugReportDraft`). All the sensitive sections start off.
#[derive(Debug, Clone, PartialEq)]
pub struct Draft {
    pub description: String,
    pub contact_name: String,
    pub contact_handle: String,
    pub include_feature_flags: bool,
    pub include_logs: bool,
    pub include_events: bool,
    pub include_tab_metadata: bool,
    pub metadata_tab: Option<String>,
    pub include_terminal_history: bool,
    pub history_tab: Option<String>,
    pub include_ai_session: bool,
    /// The tab that was current when the dialog opened.
    pub current_tab: Option<String>,
    /// Cached output of the history tab (read when the toggle goes on).
    pub terminal_history: Option<String>,
}

impl Draft {
    pub fn new(current_tab: Option<String>) -> Self {
        Self {
            description: String::new(),
            contact_name: String::new(),
            contact_handle: String::new(),
            include_feature_flags: true,
            include_logs: false,
            include_events: false,
            include_tab_metadata: false,
            metadata_tab: current_tab.clone(),
            include_terminal_history: false,
            history_tab: current_tab.clone(),
            include_ai_session: false,
            current_tab,
            terminal_history: None,
        }
    }

    /// The tab whose AI sessions are listed: the metadata tab when metadata
    /// is on, else the current tab.
    pub fn ai_session_tab(&self) -> Option<&str> {
        if self.include_tab_metadata {
            self.metadata_tab.as_deref()
        } else {
            self.current_tab.as_deref()
        }
    }

    /// `markdownReport`.
    pub fn markdown(&self, snapshot: &StateSnapshot, home: &str) -> String {
        let mut sections: Vec<String> = Vec::new();
        sections.push(format!(
            "# Chau7 Bug Report\nGenerated: {}",
            format_iso8601(snapshot.timestamp)
        ));

        if !self.contact_name.is_empty() || !self.contact_handle.is_empty() {
            let mut contact = String::from("## Contact");
            if !self.contact_name.is_empty() {
                contact.push_str(&format!("\n- Name: {}", self.contact_name));
            }
            if !self.contact_handle.is_empty() {
                contact.push_str(&format!("\n- GitHub/Email: {}", self.contact_handle));
            }
            sections.push(contact);
        }

        let desc = self.description.trim();
        sections.push(format!(
            "## Description\n{}",
            if desc.is_empty() {
                NO_DESCRIPTION
            } else {
                desc
            }
        ));

        sections.push(format!(
            "## Environment\n- App Version: {}\n- macOS: {}\n- Tabs: {}",
            snapshot.app_version, snapshot.os_version, snapshot.tab_count
        ));

        if self.include_feature_flags {
            let mut flags = String::from("## Feature Flags");
            for (flag, enabled) in &snapshot.feature_flags {
                flags.push_str(&format!(
                    "\n- {flag}: {}",
                    if *enabled { "on" } else { "off" }
                ));
            }
            sections.push(flags);
        }

        if self.include_tab_metadata
            && let Some(tab) = self.tab_state(snapshot, self.metadata_tab.as_deref())
        {
            let title = redact_title(tab.custom_title.as_deref().unwrap_or(&tab.title), home);
            let mut text = format!("## Tab: {title}");
            text.push_str(&format!("\n- Status: {}", tab.status));
            text.push_str(&format!(
                "\n- Active App: {}",
                tab.active_app_name.as_deref().unwrap_or("none")
            ));
            text.push_str(&format!(
                "\n- Directory: {}",
                redact_path(&tab.current_directory, home)
            ));
            if tab.is_git_repo {
                text.push_str(&format!(
                    "\n- Git Branch: {}",
                    tab.git_branch.as_deref().unwrap_or("unknown")
                ));
            }
            sections.push(text);
        }

        if self.include_terminal_history {
            match self.terminal_history.as_deref().filter(|h| !h.is_empty()) {
                Some(output) => sections.push(format!("## Terminal History\n```\n{output}\n```")),
                None => sections.push("## Terminal History\n(No output captured)".to_string()),
            }
        }

        if self.include_ai_session
            && let Some(tab_id) = self.ai_session_tab()
        {
            let dir = self
                .tab_state(snapshot, Some(tab_id))
                .map(|t| t.current_directory.as_str())
                .unwrap_or("");
            // Only the sessions of the selected tab, never all of them.
            let matching: Vec<&ClaudeSessionState> = snapshot
                .claude_sessions
                .iter()
                .filter(|s| {
                    !dir.is_empty()
                        && (s.project_name == dir
                            || dir.starts_with(&s.project_name)
                            || s.project_name.starts_with(dir))
                })
                .collect();
            if matching.is_empty() {
                sections
                    .push("## AI Sessions\n(No AI session found for the selected tab)".to_string());
            } else {
                let mut text = String::from("## AI Sessions");
                for s in matching {
                    text.push_str(&format!("\n- State: {}", s.state));
                    text.push_str(&format!(
                        " | Project: {}",
                        redact_path(&s.project_name, home)
                    ));
                    text.push_str(&format!(
                        " | Last tool: {}",
                        s.last_tool_name.as_deref().unwrap_or("none")
                    ));
                    text.push_str(&format!(
                        " | Last activity: {}",
                        format_iso8601(s.last_activity)
                    ));
                }
                sections.push(text);
            }
        }

        if self.include_events && !snapshot.recent_events.is_empty() {
            let mut text = format!("## Recent Events (last {})", snapshot.recent_events.len());
            for event in &snapshot.recent_events {
                let tool = if event.tool_name.is_empty() {
                    &event.hook
                } else {
                    &event.tool_name
                };
                text.push_str(&format!("\n- [{}] {tool}: {}", event.kind, event.message));
            }
            sections.push(text);
        }

        if self.include_logs && !snapshot.recent_logs.is_empty() {
            let lines: Vec<&String> = snapshot
                .recent_logs
                .iter()
                .filter(|l| !l.trim().is_empty())
                .collect();
            if !lines.is_empty() {
                let body = lines
                    .iter()
                    .map(|l| l.as_str())
                    .collect::<Vec<_>>()
                    .join("\n");
                sections.push(format!(
                    "## Recent Logs (last {} lines)\n```\n{body}\n```",
                    lines.len()
                ));
            }
        }

        sections.join("\n\n")
    }

    fn tab_state<'a>(&self, snapshot: &'a StateSnapshot, id: Option<&str>) -> Option<&'a TabState> {
        let id = id?;
        snapshot.tab_states.iter().find(|t| t.id == id)
    }
}

// ----- submitting -----------------------------------------------------------------

/// Why a submit failed (`BugReportError`); `Display` is the dialog text.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BugReportError {
    InvalidEndpoint,
    InsecureEndpoint,
    RateLimited,
    Network(String),
    Server(u16, String),
}

impl std::fmt::Display for BugReportError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidEndpoint => write!(f, "Issue reporting endpoint is not configured."),
            Self::InsecureEndpoint => write!(f, "Issue reporting endpoint must use HTTPS."),
            Self::RateLimited => write!(
                f,
                "Too many reports submitted recently. Please try again later."
            ),
            Self::Network(message) => write!(f, "Network error: {message}"),
            Self::Server(code, body) => write!(f, "Server error ({code}): {body}"),
        }
    }
}

/// Check the configured endpoint: set, a URL, and `https`.
pub fn validate_endpoint(endpoint: &str) -> Result<&str, BugReportError> {
    let endpoint = endpoint.trim();
    let valid = !endpoint.is_empty()
        && !endpoint
            .chars()
            .any(|c| c.is_whitespace() || c.is_control())
        && endpoint
            .split_once("://")
            .is_some_and(|(scheme, rest)| !scheme.is_empty() && !rest.is_empty());
    if !valid {
        return Err(BugReportError::InvalidEndpoint);
    }
    if !endpoint.starts_with("https://") {
        return Err(BugReportError::InsecureEndpoint);
    }
    Ok(endpoint)
}

/// The JSON body of the POST: `{"title":..,"body":..}`.
pub fn submit_body(title: &str, report: &str) -> String {
    serde_json::json!({ "title": title, "body": report }).to_string()
}

/// Timeout of the POST, in seconds.
pub const SUBMIT_TIMEOUT_SECS: u64 = 15;

/// Read the answer: 200 or 201 is success (with `issue_number` when the
/// server sends one, else 0); 429 is rate limiting.
pub fn parse_submit_response(status: u16, body: &str) -> Result<u64, BugReportError> {
    if status != 200 && status != 201 {
        if status == 429 {
            return Err(BugReportError::RateLimited);
        }
        return Err(BugReportError::Server(status, body.to_string()));
    }
    let number = serde_json::from_str::<serde_json::Value>(body)
        .ok()
        .and_then(|v| v.get("issue_number").and_then(|n| n.as_u64()))
        .unwrap_or(0);
    Ok(number)
}

/// "Issue #N submitted" (the dialog closes 1.5 s later).
pub fn success_text(issue_number: u64) -> String {
    format!("Issue #{issue_number} submitted")
}

/// Arguments of the `curl` command that posts the report (the body comes on
/// stdin). Only HTTPS is allowed, also after redirects. The answer is the
/// body, a newline and the HTTP status.
pub fn curl_args(url: &str) -> Vec<String> {
    [
        "-sS",
        "-X",
        "POST",
        "-H",
        "Content-Type: application/json",
        "--proto",
        "=https",
        "--proto-redir",
        "=https",
        "--max-time",
    ]
    .iter()
    .map(|a| a.to_string())
    .chain([
        SUBMIT_TIMEOUT_SECS.to_string(),
        "-w".into(),
        "\n%{http_code}".into(),
        "--data-binary".into(),
        "@-".into(),
        url.to_string(),
    ])
    .collect()
}

/// Read what `curl` printed with [`curl_args`].
pub fn parse_curl_output(stdout: &str) -> Result<u64, BugReportError> {
    let Some((body, status)) = stdout.rsplit_once('\n') else {
        return Err(BugReportError::Network("Invalid response".into()));
    };
    match status.trim().parse::<u16>() {
        Ok(status) if status > 0 => parse_submit_response(status, body),
        _ => Err(BugReportError::Network("Invalid response".into())),
    }
}

#[cfg(test)]
mod curl_tests {
    use super::*;

    #[test]
    fn curl_arguments_force_https_and_stdin() {
        let args = curl_args("https://example.com/report");
        assert!(args.windows(2).any(|w| w == ["--proto", "=https"]));
        assert!(args.windows(2).any(|w| w == ["--max-time", "15"]));
        assert!(args.windows(2).any(|w| w == ["--data-binary", "@-"]));
        assert_eq!(
            args.last().map(String::as_str),
            Some("https://example.com/report")
        );
    }

    #[test]
    fn curl_output_is_body_then_status() {
        assert_eq!(parse_curl_output("{\"issue_number\":42}\n201"), Ok(42));
        assert_eq!(parse_curl_output("{}\n200"), Ok(0));
        assert_eq!(
            parse_curl_output("slow down\n429"),
            Err(BugReportError::RateLimited)
        );
        assert_eq!(
            parse_curl_output("oops\n500"),
            Err(BugReportError::Server(500, "oops".into()))
        );
        assert!(matches!(
            parse_curl_output("no status"),
            Err(BugReportError::Network(_))
        ));
        assert!(matches!(
            parse_curl_output("body\nabc"),
            Err(BugReportError::Network(_))
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use chrono::TimeZone;

    fn snapshot() -> StateSnapshot {
        let at = Utc.with_ymd_and_hms(2026, 1, 15, 10, 30, 45).unwrap();
        StateSnapshot {
            timestamp: at,
            app_version: "0.9.3".into(),
            os_version: "15.4".into(),
            tab_count: 2,
            active_tab_index: 1,
            tab_states: vec![
                TabState {
                    id: "t1".into(),
                    title: "zsh".into(),
                    custom_title: None,
                    active_app_name: Some("Claude".into()),
                    status: "running".into(),
                    current_directory: "/Users/me/code/app".into(),
                    is_git_repo: true,
                    git_branch: Some("main".into()),
                },
                TabState {
                    id: "t2".into(),
                    title: "/Users/me/secret".into(),
                    custom_title: Some("build".into()),
                    active_app_name: None,
                    status: "idle".into(),
                    current_directory: "/tmp".into(),
                    is_git_repo: false,
                    git_branch: None,
                },
            ],
            claude_sessions: vec![ClaudeSessionState {
                id: "s".into(),
                project_name: "/Users/me/code/app".into(),
                state: "working".into(),
                last_activity: at,
                last_tool_name: Some("Edit".into()),
            }],
            recent_events: vec![EventState {
                timestamp: at,
                kind: "tool".into(),
                hook: "PreToolUse".into(),
                tool_name: String::new(),
                message: "msg".into(),
            }],
            feature_flags: [
                ("snippets".to_string(), true),
                ("bookmarks".to_string(), false),
            ]
            .into_iter()
            .collect(),
            recent_logs: vec!["a".into(), "  ".into(), "b".into()],
            recent_incidents: vec![],
            active_contexts: vec![ContextState {
                id: "ABC234".into(),
                operation: "op".into(),
                start_time: at,
                duration_ms: 12,
            }],
        }
    }

    #[test]
    fn default_report_has_no_session_data() {
        let draft = Draft::new(Some("t1".into()));
        let md = draft.markdown(&snapshot(), "/Users/me");
        assert!(md.starts_with("# Chau7 Bug Report\nGenerated: 2026-01-15T10:30:45.000Z"));
        assert!(md.contains("## Description\n(No description provided)"));
        assert!(md.contains("## Environment\n- App Version: 0.9.3\n- macOS: 15.4\n- Tabs: 2"));
        assert!(md.contains("## Feature Flags\n- bookmarks: off\n- snippets: on"));
        for hidden in [
            "Tab:",
            "Terminal History",
            "AI Sessions",
            "Recent Events",
            "Recent Logs",
            "Contact",
        ] {
            assert!(!md.contains(hidden), "{hidden} must be opt-in");
        }
    }

    #[test]
    fn contact_and_description() {
        let mut draft = Draft::new(None);
        draft.description = "  it broke \n".into();
        draft.contact_name = "Ada".into();
        let md = draft.markdown(&snapshot(), "");
        assert!(md.contains("## Contact\n- Name: Ada\n\n## Description\nit broke"));
        assert!(!md.contains("GitHub/Email"));
        draft.contact_handle = "ada@x.org".into();
        assert!(
            draft
                .markdown(&snapshot(), "")
                .contains("- GitHub/Email: ada@x.org")
        );
    }

    #[test]
    fn tab_metadata_is_redacted() {
        let mut draft = Draft::new(Some("t1".into()));
        draft.include_tab_metadata = true;
        let md = draft.markdown(&snapshot(), "/Users/me");
        assert!(md.contains("## Tab: zsh\n- Status: running\n- Active App: Claude\n- Directory: ~/code/app\n- Git Branch: main"));
        draft.metadata_tab = Some("t2".into());
        let md = draft.markdown(&snapshot(), "/Users/me");
        assert!(md.contains("## Tab: build"));
        assert!(!md.contains("Git Branch"));
        // A title that is a path is redacted when there is no custom title.
        let mut snap = snapshot();
        snap.tab_states[1].custom_title = None;
        assert!(
            draft
                .markdown(&snap, "/Users/me")
                .contains("## Tab: ~/secret")
        );
    }

    #[test]
    fn history_logs_events_sections() {
        let mut draft = Draft::new(Some("t1".into()));
        draft.include_terminal_history = true;
        assert!(
            draft
                .markdown(&snapshot(), "")
                .contains("(No output captured)")
        );
        draft.terminal_history = Some("$ ls".into());
        assert!(
            draft
                .markdown(&snapshot(), "")
                .contains("## Terminal History\n```\n$ ls\n```")
        );

        draft.include_logs = true;
        assert!(
            draft
                .markdown(&snapshot(), "")
                .contains("## Recent Logs (last 2 lines)\n```\na\nb\n```")
        );
        draft.include_events = true;
        assert!(
            draft
                .markdown(&snapshot(), "")
                .contains("## Recent Events (last 1)\n- [tool] PreToolUse: msg")
        );
    }

    #[test]
    fn incident_evidence_is_local_and_old_snapshots_still_decode() {
        let mut state = snapshot();
        state
            .recent_incidents
            .push(crate::incidents::Breadcrumb::new(
                state.timestamp,
                crate::incidents::Kind::MainThreadHang,
                crate::incidents::Severity::Warning,
                "local incident test",
                BTreeMap::new(),
            ));
        assert!(local_report(&state, "", state.timestamp).contains("local incident test"));
        assert!(
            !Draft::new(None)
                .markdown(&state, "")
                .contains("local incident test")
        );
        let mut old = serde_json::to_value(&state).unwrap();
        old.as_object_mut().unwrap().remove("recentIncidents");
        assert!(
            serde_json::from_value::<StateSnapshot>(old)
                .unwrap()
                .recent_incidents
                .is_empty()
        );
    }

    #[test]
    fn ai_sessions_only_for_the_selected_tab() {
        let mut draft = Draft::new(Some("t1".into()));
        draft.include_ai_session = true;
        let md = draft.markdown(&snapshot(), "/Users/me");
        assert!(md.contains("- State: working | Project: ~/code/app | Last tool: Edit | Last activity: 2026-01-15T10:30:45.000Z"));
        // The other tab's directory matches no session.
        draft.current_tab = Some("t2".into());
        assert!(
            draft
                .markdown(&snapshot(), "")
                .contains("(No AI session found for the selected tab)")
        );
        // With metadata on, the metadata tab decides.
        draft.include_tab_metadata = true;
        draft.metadata_tab = Some("t1".into());
        assert!(draft.markdown(&snapshot(), "").contains("- State: working"));
    }

    #[test]
    fn local_report_lists_everything() {
        let at = Utc.with_ymd_and_hms(2026, 1, 15, 11, 0, 0).unwrap();
        let md = local_report(&snapshot(), "", at);
        assert!(md.contains("## User Description\n(No description provided)"));
        assert!(md.contains("- Tabs: 2 (active: 1)"));
        assert!(md.contains(
            "### Tab 2: build\n- Active App: none\n- Status: idle\n- Directory: /tmp\n- Git: no"
        ));
        assert!(md.contains("### Tab 1: zsh"));
        assert!(md.contains("- Git: main"));
        assert!(md.contains("- /Users/me/code/app: working\n  Last activity: 2026-01-15T10:30:45.000Z\n  Last tool: Edit"));
        assert!(md.contains("- [tool] PreToolUse: msg"));
        assert!(md.contains("- [ABC234] op (running 12ms)"));
        assert!(md.contains("- bookmarks: disabled\n- snippets: enabled"));
        assert!(md.ends_with("```\na\n  \nb\n```"));
    }

    #[test]
    fn snapshot_json_shape() {
        let json = snapshot().to_json();
        assert!(json.contains("\"appVersion\" : \"0.9.3\""));
        assert!(json.contains("\"timestamp\" : \"2026-01-15T10:30:45Z\""));
        assert!(json.contains("\"isGitRepo\" : true"));
        // nil optionals are left out, as the Swift encoder does.
        assert!(!json.contains("gitBranch\" : null"));
        // Sorted keys.
        assert!(json.find("activeContexts").unwrap() < json.find("tabStates").unwrap());
        let back: StateSnapshot = serde_json::from_str(&json).unwrap();
        assert_eq!(back, snapshot());
    }

    #[test]
    fn file_names() {
        let local = chrono::NaiveDate::from_ymd_opt(2026, 1, 5)
            .unwrap()
            .and_hms_opt(9, 8, 7)
            .unwrap();
        assert_eq!(
            StateSnapshot::file_name(local),
            "chau7-snapshot-2026-01-05_09-08-07.json"
        );
        assert_eq!(
            report_file_name(local),
            "chau7-bug-report-2026-01-05_09-08-07.md"
        );
        assert_eq!(
            snapshot().issue_title("Chau7"),
            "Bug report from Chau7 0.9.3"
        );
    }

    #[test]
    fn issue_url_encodes_and_truncates() {
        let url = prefilled_issue_url("Bug report from Chau7 1.0", "a b&c\n# x");
        assert_eq!(
            url,
            "https://github.com/anthropics/chau7/issues/new?title=Bug%20report%20from%20Chau7%201.0&body=a%20b%26c%0A%23%20x"
        );
        let long = "x".repeat(20_000);
        let url = prefilled_issue_url("t", &long);
        assert!(url.len() <= MAX_ISSUE_URL_LEN);
        assert!(url.contains("truncated"));
    }

    #[test]
    fn redaction() {
        assert_eq!(redact_path("/Users/me/x", "/Users/me"), "~/x");
        assert_eq!(redact_path("/opt/x", "/Users/me"), "/opt/x");
        assert_eq!(redact_path("", "/Users/me"), "");
        assert_eq!(redact_title("vim", "/Users/me"), "vim");
        assert_eq!(redact_title("/Users/me/a", "/Users/me"), "~/a");
        assert_eq!(redact_title("/var/x", "/Users/me"), "/var/x");
    }

    #[test]
    fn endpoint_validation() {
        assert_eq!(validate_endpoint(""), Err(BugReportError::InvalidEndpoint));
        assert_eq!(
            validate_endpoint("not a url"),
            Err(BugReportError::InvalidEndpoint)
        );
        assert_eq!(
            validate_endpoint("example.com/x"),
            Err(BugReportError::InvalidEndpoint)
        );
        assert_eq!(
            validate_endpoint("http://example.com/x"),
            Err(BugReportError::InsecureEndpoint)
        );
        assert_eq!(
            validate_endpoint(" https://example.com/x "),
            Ok("https://example.com/x")
        );
    }

    #[test]
    fn responses() {
        assert_eq!(parse_submit_response(201, "{\"issue_number\": 42}"), Ok(42));
        assert_eq!(parse_submit_response(200, "ok"), Ok(0));
        assert_eq!(
            parse_submit_response(429, ""),
            Err(BugReportError::RateLimited)
        );
        let err = parse_submit_response(500, "boom").unwrap_err();
        assert_eq!(err.to_string(), "Server error (500): boom");
        assert_eq!(success_text(7), "Issue #7 submitted");
        let body: serde_json::Value = serde_json::from_str(&submit_body("T", "B\"x")).unwrap();
        assert_eq!(body["title"], "T");
        assert_eq!(body["body"], "B\"x");
    }
}
