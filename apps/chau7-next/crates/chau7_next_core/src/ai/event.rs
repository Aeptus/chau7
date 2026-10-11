//! Port of `apps/chau7-macos/Sources/Chau7Core/AIEvent.swift`.
//!
//! Tool-agnostic event model ([`AiEvent`], [`AiEventSource`],
//! [`AiEventReliability`]) and [`parse_line`] for event log lines. The Swift
//! app and AI CLI hooks write these JSON lines, so the accepted keys match
//! Swift exactly: `source`, `type`, `tool`, `message`, `ts`, `directory` or
//! `cwd`, `tabID` / `tabId` / `tab_id`, `sessionID` / `sessionId` /
//! `session_id`. All other keys are ignored.
//!
//! The em dash in the repo prefix of the notification title is written as a
//! `\u{2014}` escape to keep source files free of the literal character.

use super::resume::is_valid_session_id;
use super::tool_registry::AI_TOOLS;
use crate::tab_target::TabTarget;
use chrono::{SecondsFormat, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};
use uuid::Uuid;

/// Identifies which tool or subsystem produced an event. Extensible: any
/// raw value is valid (`AIEventSource`, a `RawRepresentable` string struct,
/// encoded as the bare string).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(transparent)]
pub struct AiEventSource(pub String);

impl AiEventSource {
    pub const EVENTS_LOG: &'static str = "events_log";
    pub const TERMINAL_SESSION: &'static str = "terminal_session";
    pub const HISTORY_MONITOR: &'static str = "history_monitor";
    pub const APP: &'static str = "app";
    pub const API_PROXY: &'static str = "api_proxy";
    pub const UNKNOWN: &'static str = "unknown";
    pub const RUNTIME: &'static str = "runtime";
    pub const SHELL: &'static str = "shell";
    pub const CLAUDE_CODE: &'static str = "claude_code";
    pub const CODEX: &'static str = "codex";
    pub const CURSOR: &'static str = "cursor";
    pub const WINDSURF: &'static str = "windsurf";
    pub const COPILOT: &'static str = "copilot";
    pub const AIDER: &'static str = "aider";
    pub const CLINE: &'static str = "cline";
    pub const CONTINUE_AI: &'static str = "continue_ai";

    pub fn new(raw_value: impl Into<String>) -> Self {
        Self(raw_value.into())
    }

    pub fn raw_value(&self) -> &str {
        &self.0
    }

    pub fn events_log() -> Self {
        Self::new(Self::EVENTS_LOG)
    }
    pub fn terminal_session() -> Self {
        Self::new(Self::TERMINAL_SESSION)
    }
    pub fn history_monitor() -> Self {
        Self::new(Self::HISTORY_MONITOR)
    }
    pub fn app() -> Self {
        Self::new(Self::APP)
    }
    pub fn api_proxy() -> Self {
        Self::new(Self::API_PROXY)
    }
    pub fn unknown() -> Self {
        Self::new(Self::UNKNOWN)
    }
    pub fn runtime() -> Self {
        Self::new(Self::RUNTIME)
    }
    pub fn shell() -> Self {
        Self::new(Self::SHELL)
    }
    pub fn claude_code() -> Self {
        Self::new(Self::CLAUDE_CODE)
    }
    pub fn codex() -> Self {
        Self::new(Self::CODEX)
    }
    pub fn cursor() -> Self {
        Self::new(Self::CURSOR)
    }
    pub fn windsurf() -> Self {
        Self::new(Self::WINDSURF)
    }
    pub fn copilot() -> Self {
        Self::new(Self::COPILOT)
    }
    pub fn aider() -> Self {
        Self::new(Self::AIDER)
    }
    pub fn cline() -> Self {
        Self::new(Self::CLINE)
    }
    pub fn continue_ai() -> Self {
        Self::new(Self::CONTINUE_AI)
    }

    /// Maps a provider, display name or command name to its event source via
    /// the tool registry (`AIEventSource.forProvider`).
    pub fn for_provider(provider: Option<&str>) -> Option<Self> {
        let trimmed = provider?.trim().to_lowercase();
        if trimmed.is_empty() {
            return None;
        }
        let tool = AI_TOOLS.iter().find(|tool| {
            tool.resume_provider_key.map(str::to_lowercase).as_deref() == Some(trimmed.as_str())
                || tool.display_name.to_lowercase() == trimmed
                || tool.command_names.contains(&trimmed.as_str())
        })?;
        tool.event_source_raw_value.map(Self::new)
    }
}

impl From<&str> for AiEventSource {
    fn from(raw_value: &str) -> Self {
        Self::new(raw_value)
    }
}

/// Confidence class used for routing and fallback suppression.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum AiEventReliability {
    Authoritative,
    Fallback,
    Heuristic,
}

impl AiEventReliability {
    /// Swift raw value (the lower-case case name).
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Authoritative => "authoritative",
            Self::Fallback => "fallback",
            Self::Heuristic => "heuristic",
        }
    }
}

/// A tool-agnostic event from any monitored source (`AIEvent`).
#[derive(Debug, Clone, PartialEq)]
pub struct AiEvent {
    pub id: Uuid,
    pub source: AiEventSource,
    pub event_type: String,
    /// Optional provider-native type before canonical notification mapping.
    pub raw_type: Option<String>,
    pub tool: String,
    /// Optional provider-supplied title for notification-like payloads.
    pub title: Option<String>,
    pub message: String,
    /// Optional provider-supplied notification subtype (for example Claude
    /// `permission_prompt` / `idle_prompt`).
    pub notification_type: Option<String>,
    /// ISO8601 timestamp string.
    pub ts: String,
    pub directory: Option<String>,
    pub tab_id: Option<Uuid>,
    /// AI session ID for tab disambiguation.
    pub session_id: Option<String>,
    /// Which subsystem emitted the event (for audit and debugging).
    pub producer: Option<String>,
    pub reliability: AiEventReliability,
}

impl AiEvent {
    /// Creates an event with a fresh id and the source's default reliability.
    /// Optional fields start as `None`; set them on the result.
    pub fn new(
        source: AiEventSource,
        event_type: impl Into<String>,
        tool: impl Into<String>,
        message: impl Into<String>,
        ts: impl Into<String>,
    ) -> Self {
        let reliability = Self::default_reliability(&source);
        Self {
            id: Uuid::new_v4(),
            source,
            event_type: event_type.into(),
            raw_type: None,
            tool: tool.into(),
            title: None,
            message: message.into(),
            notification_type: None,
            ts: ts.into(),
            directory: None,
            tab_id: None,
            session_id: None,
            producer: None,
            reliability,
        }
    }

    /// Returns a copy with `tab_id` filled in, if it was previously `None`.
    pub fn resolving_tab_id(&self, tab_id: Option<Uuid>) -> AiEvent {
        match tab_id {
            Some(id) if self.tab_id.is_none() => {
                let mut copy = self.clone();
                copy.tab_id = Some(id);
                copy
            }
            _ => self.clone(),
        }
    }

    /// Returns the routing target for tab resolution from this event's fields.
    pub fn tab_target(&self) -> TabTarget {
        TabTarget {
            tool: self.tool.clone(),
            directory: self.directory.clone(),
            tab_id: self.tab_id,
            session_id: self.session_id.clone(),
        }
    }

    pub fn normalized_type(&self) -> String {
        self.event_type.trim().to_lowercase()
    }

    pub fn default_reliability(source: &AiEventSource) -> AiEventReliability {
        match source.raw_value() {
            AiEventSource::RUNTIME
            | AiEventSource::CLAUDE_CODE
            | AiEventSource::TERMINAL_SESSION
            | AiEventSource::SHELL
            | AiEventSource::APP => AiEventReliability::Authoritative,
            AiEventSource::HISTORY_MONITOR => AiEventReliability::Fallback,
            _ => AiEventReliability::Heuristic,
        }
    }

    /// Returns the notification title for this event.
    pub fn notification_title(&self) -> String {
        self.notification_title_with(None, None)
    }

    /// Returns the notification title with optional tool and repo overrides.
    pub fn notification_title_with(
        &self,
        tool_override: Option<&str>,
        repo_name: Option<&str>,
    ) -> String {
        let tool_name = tool_override.unwrap_or(&self.tool).trim();
        let name = if tool_name.is_empty() {
            self.tool.as_str()
        } else {
            tool_name
        };
        let prefix = match repo_name {
            Some(repo) if !repo.is_empty() && repo != name => {
                format!("{repo} \u{2014} {name}")
            }
            _ => name.to_string(),
        };
        let suffix = match self.event_type.to_lowercase().as_str() {
            "needs_validation" => "Needs review",
            "idle" | "waiting_input" => "Waiting for input",
            "attention_required" => "Needs attention",
            "finished" => "Finished",
            "failed" => "Failed",
            "permission" => "Permission needed",
            "error" => "Error",
            "context_limit" => "Context limit reached",
            "file_conflict" => "File conflict",
            "tool_called" => "Tool called",
            "file_edited" => "File edited",
            "token_threshold" => "Token threshold",
            "cost_threshold" => "Cost threshold",
            _ => "Update",
        };
        format!("{prefix}: {suffix}")
    }

    /// Returns the notification body for this event.
    pub fn notification_body(&self) -> String {
        let message = &self.message;
        let or_default = |default: &str| {
            if message.is_empty() {
                default.to_string()
            } else {
                message.clone()
            }
        };
        match self.event_type.to_lowercase().as_str() {
            "needs_validation" => or_default("Your input is required."),
            "idle" => or_default("No new history entries for a while."),
            "waiting_input" => or_default("Ready for your input."),
            "attention_required" => or_default("Needs your attention."),
            "finished" => or_default("Done."),
            "failed" => or_default("Check the logs."),
            "permission" => or_default("Needs your permission to continue."),
            "error" => or_default("An error occurred."),
            "context_limit" => or_default("Approaching context window limit."),
            "token_threshold" | "cost_threshold" => or_default("Usage threshold exceeded."),
            _ => {
                if message.is_empty() {
                    self.event_type.clone()
                } else {
                    format!("{}: {}", self.event_type, message)
                }
            }
        }
    }

    /// Serializes to one event log JSON line using the keys [`parse_line`]
    /// accepts (`tabID`, `sessionID`). Rust-only helper: Swift does not
    /// encode `AIEvent`. Optional fields that are `None` are omitted.
    pub fn to_json_line(&self) -> String {
        let mut map = Map::new();
        map.insert("source".into(), Value::String(self.source.0.clone()));
        map.insert("type".into(), Value::String(self.event_type.clone()));
        map.insert("tool".into(), Value::String(self.tool.clone()));
        map.insert("message".into(), Value::String(self.message.clone()));
        map.insert("ts".into(), Value::String(self.ts.clone()));
        if let Some(directory) = &self.directory {
            map.insert("directory".into(), Value::String(directory.clone()));
        }
        if let Some(tab_id) = self.tab_id {
            map.insert(
                "tabID".into(),
                Value::String(tab_id.hyphenated().to_string().to_uppercase()),
            );
        }
        if let Some(session_id) = &self.session_id {
            map.insert("sessionID".into(), Value::String(session_id.clone()));
        }
        Value::Object(map).to_string()
    }
}

/// Error from [`parse_line`] (`AIEventParseError`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AiEventParseError {
    /// The line is JSON but not an object (or an array / scalar).
    NotJsonObject,
    MissingField(String),
    InvalidFieldType(String),
    /// The line is not valid JSON. Swift surfaces the Foundation error here.
    InvalidJson(String),
}

impl std::fmt::Display for AiEventParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotJsonObject => write!(f, "AI event data is not a JSON object"),
            Self::MissingField(field) => {
                write!(f, "AI event missing required field: {field}")
            }
            Self::InvalidFieldType(field) => {
                write!(f, "AI event field has invalid type: {field}")
            }
            Self::InvalidJson(detail) => write!(f, "AI event is not valid JSON: {detail}"),
        }
    }
}

impl std::error::Error for AiEventParseError {}

/// Current time as an ISO8601 string with fractional seconds
/// (`DateFormatters.nowISO8601`), for example `2025-01-14T12:00:00.123Z`.
pub fn now_iso8601() -> String {
    Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
}

fn string_field(
    dict: &Map<String, Value>,
    key: &str,
    default: Option<&str>,
) -> Result<String, AiEventParseError> {
    match dict.get(key) {
        Some(Value::String(s)) => Ok(s.clone()),
        Some(_) => Err(AiEventParseError::InvalidFieldType(key.to_string())),
        None => match default {
            Some(d) => Ok(d.to_string()),
            None => Err(AiEventParseError::MissingField(key.to_string())),
        },
    }
}

/// First of `keys` whose value is a JSON string (Swift `as? String ?? ...`).
fn first_string(dict: &Map<String, Value>, keys: &[&str]) -> Option<String> {
    keys.iter()
        .find_map(|k| dict.get(*k).and_then(Value::as_str))
        .map(str::to_string)
}

/// Parses one event log line (`AIEventParser.parse(line:)`).
pub fn parse_line(line: &str) -> Result<AiEvent, AiEventParseError> {
    let value: Value =
        serde_json::from_str(line).map_err(|e| AiEventParseError::InvalidJson(e.to_string()))?;
    let dict = match value {
        Value::Object(map) => map,
        Value::Array(_) => return Err(AiEventParseError::NotJsonObject),
        _ => return Err(AiEventParseError::NotJsonObject),
    };

    let source_raw = string_field(&dict, "source", Some(AiEventSource::EVENTS_LOG))?;
    let source = AiEventSource::new(source_raw);
    let event_type = string_field(&dict, "type", None)?;
    let tool = string_field(&dict, "tool", Some("CLI"))?;
    let message = string_field(&dict, "message", Some(""))?;
    let ts = match dict.get("ts") {
        Some(Value::String(s)) => s.clone(),
        Some(_) => return Err(AiEventParseError::InvalidFieldType("ts".to_string())),
        None => now_iso8601(),
    };

    let directory = first_string(&dict, &["directory", "cwd"]);
    let tab_id =
        first_string(&dict, &["tabID", "tabId", "tab_id"]).and_then(|raw| parse_uuid_string(&raw));
    let session_id =
        first_string(&dict, &["sessionID", "sessionId", "session_id"]).and_then(|raw| {
            let trimmed = raw.trim().to_string();
            is_valid_session_id(&trimmed).then_some(trimmed)
        });

    let mut event = AiEvent::new(source, event_type, tool, message, ts);
    event.directory = directory;
    event.tab_id = tab_id;
    event.session_id = session_id;
    Ok(event)
}

/// `UUID(uuidString:)`: only the canonical 36 character hyphenated form.
fn parse_uuid_string(raw: &str) -> Option<Uuid> {
    if raw.len() != 36 {
        return None;
    }
    Uuid::parse_str(raw).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ev(tool: &str) -> AiEvent {
        AiEvent::new(AiEventSource::claude_code(), "finished", tool, "", "now")
    }

    // MARK: AIEventTests

    #[test]
    fn resolving_tab_id_fills_missing_id() {
        let event = ev("Claude");
        assert_eq!(event.tab_id, None);
        let tab_id = Uuid::new_v4();
        let resolved = event.resolving_tab_id(Some(tab_id));
        assert_eq!(resolved.tab_id, Some(tab_id));
        assert_eq!(resolved.id, event.id);
        assert_eq!(resolved.source, event.source);
        assert_eq!(resolved.event_type, event.event_type);
    }

    #[test]
    fn resolving_tab_id_does_not_override_existing() {
        let existing = Uuid::new_v4();
        let mut event = ev("Claude");
        event.tab_id = Some(existing);
        let resolved = event.resolving_tab_id(Some(Uuid::new_v4()));
        assert_eq!(resolved.tab_id, Some(existing));
    }

    #[test]
    fn resolving_tab_id_with_nil_is_no_op() {
        let event = ev("Claude");
        let resolved = event.resolving_tab_id(None);
        assert_eq!(resolved.tab_id, None);
        assert_eq!(resolved.id, event.id);
    }

    #[test]
    fn tab_target_includes_all_fields() {
        let tab_id = Uuid::new_v4();
        let mut event = ev("Claude");
        event.directory = Some("/tmp/project".into());
        event.tab_id = Some(tab_id);
        let target = event.tab_target();
        assert_eq!(target.tool, "Claude");
        assert_eq!(target.directory.as_deref(), Some("/tmp/project"));
        assert_eq!(target.tab_id, Some(tab_id));
    }

    // MARK: AIEventParserTests, valid parsing

    #[test]
    fn parse_valid_json_all_fields() {
        let json = r#"{"source":"app","type":"finished","tool":"Claude","message":"All done","ts":"2025-01-14T12:00:00Z"}"#;
        let event = parse_line(json).unwrap();
        assert_eq!(event.source, AiEventSource::app());
        assert_eq!(event.event_type, "finished");
        assert_eq!(event.tool, "Claude");
        assert_eq!(event.message, "All done");
        assert_eq!(event.ts, "2025-01-14T12:00:00Z");
    }

    #[test]
    fn parse_minimal_json() {
        let event = parse_line(r#"{"type":"idle"}"#).unwrap();
        assert_eq!(event.event_type, "idle");
        assert_eq!(event.source, AiEventSource::events_log());
        assert_eq!(event.tool, "CLI");
        assert_eq!(event.message, "");
        assert!(!event.ts.is_empty());
    }

    #[test]
    fn parse_different_sources() {
        for source in [
            "app",
            "terminal_session",
            "api_proxy",
            "claude_code",
            "shell",
        ] {
            let json = format!(r#"{{"source":"{source}","type":"update"}}"#);
            let event = parse_line(&json).unwrap();
            assert_eq!(event.source.raw_value(), source);
        }
    }

    #[test]
    fn parse_unknown_source_preserved() {
        let event = parse_line(r#"{"source":"custom_integration","type":"update"}"#).unwrap();
        assert_eq!(event.source.raw_value(), "custom_integration");
    }

    // MARK: error cases

    #[test]
    fn parse_missing_required_type() {
        let err = parse_line(r#"{"source":"app","tool":"Claude"}"#).unwrap_err();
        assert_eq!(err, AiEventParseError::MissingField("type".into()));
    }

    #[test]
    fn parse_invalid_field_type() {
        let err = parse_line(r#"{"type": 123}"#).unwrap_err();
        assert_eq!(err, AiEventParseError::InvalidFieldType("type".into()));
    }

    #[test]
    fn parse_json_array_throws_not_json_object() {
        assert_eq!(
            parse_line("[1, 2, 3]").unwrap_err(),
            AiEventParseError::NotJsonObject
        );
    }

    #[test]
    fn parse_non_json_string_throws() {
        assert!(parse_line("this is not json").is_err());
    }

    #[test]
    fn parse_empty_string_throws() {
        assert!(parse_line("").is_err());
    }

    #[test]
    fn parse_invalid_source_field_type() {
        let err = parse_line(r#"{"source": 42, "type": "update"}"#).unwrap_err();
        assert_eq!(err, AiEventParseError::InvalidFieldType("source".into()));
    }

    // MARK: edge cases

    #[test]
    fn parse_unicode_content() {
        let json = "{\"type\":\"update\",\"message\":\"T\u{e2}che termin\u{e9}e \u{1F389}\",\"tool\":\"Claude\"}";
        let event = parse_line(json).unwrap();
        assert_eq!(event.message, "T\u{e2}che termin\u{e9}e \u{1F389}");
    }

    #[test]
    fn parse_empty_type_string() {
        let event = parse_line(r#"{"type":""}"#).unwrap();
        assert_eq!(event.event_type, "");
    }

    #[test]
    fn parse_extra_fields_ignored() {
        let event =
            parse_line(r#"{"type":"idle","extra_field":"ignored","nested":{"a":1}}"#).unwrap();
        assert_eq!(event.event_type, "idle");
    }

    // MARK: extra branch coverage

    #[test]
    fn parse_directory_cwd_tab_and_session_aliases() {
        let id = Uuid::new_v4().to_string();
        let json =
            format!(r#"{{"type":"x","cwd":"/tmp/p","tab_id":"{id}","session_id":"  abc-1  "}}"#);
        let event = parse_line(&json).unwrap();
        assert_eq!(event.directory.as_deref(), Some("/tmp/p"));
        assert_eq!(event.tab_id.map(|u| u.to_string()), Some(id));
        assert_eq!(event.session_id.as_deref(), Some("abc-1"));
    }

    #[test]
    fn parse_directory_wins_over_cwd_and_bad_ids_are_dropped() {
        let json = r#"{"type":"x","directory":"/a","cwd":"/b","tabID":"not-a-uuid","sessionID":"bad id!"}"#;
        let event = parse_line(json).unwrap();
        assert_eq!(event.directory.as_deref(), Some("/a"));
        assert_eq!(event.tab_id, None);
        assert_eq!(event.session_id, None);
    }

    #[test]
    fn parse_non_string_ts_is_invalid() {
        let err = parse_line(r#"{"type":"x","ts":5}"#).unwrap_err();
        assert_eq!(err, AiEventParseError::InvalidFieldType("ts".into()));
    }

    #[test]
    fn default_reliability_by_source() {
        for s in ["runtime", "claude_code", "terminal_session", "shell", "app"] {
            assert_eq!(
                AiEvent::default_reliability(&AiEventSource::new(s)),
                AiEventReliability::Authoritative
            );
        }
        assert_eq!(
            AiEvent::default_reliability(&AiEventSource::history_monitor()),
            AiEventReliability::Fallback
        );
        assert_eq!(
            AiEvent::default_reliability(&AiEventSource::new("codex")),
            AiEventReliability::Heuristic
        );
    }

    #[test]
    fn reliability_serializes_lowercase() {
        assert_eq!(
            serde_json::to_string(&AiEventReliability::Authoritative).unwrap(),
            "\"authoritative\""
        );
        assert_eq!(
            serde_json::to_string(&AiEventSource::new("x")).unwrap(),
            "\"x\""
        );
    }

    #[test]
    fn for_provider_uses_registry() {
        assert_eq!(
            AiEventSource::for_provider(Some(" Claude ")),
            Some(AiEventSource::claude_code())
        );
        assert_eq!(
            AiEventSource::for_provider(Some("codex")),
            Some(AiEventSource::codex())
        );
        assert_eq!(AiEventSource::for_provider(Some("gemini")), None);
        assert_eq!(AiEventSource::for_provider(Some("  ")), None);
        assert_eq!(AiEventSource::for_provider(None), None);
    }

    #[test]
    fn notification_titles() {
        let mut event = ev("Claude");
        assert_eq!(event.notification_title(), "Claude: Finished");
        event.event_type = "WAITING_INPUT".into();
        assert_eq!(event.notification_title(), "Claude: Waiting for input");
        event.event_type = "weird".into();
        assert_eq!(event.notification_title(), "Claude: Update");
        assert_eq!(
            event.notification_title_with(Some(" Codex "), Some("Mockup")),
            "Mockup \u{2014} Codex: Update"
        );
        // Repo equal to the tool name is not prefixed; blank override falls back.
        assert_eq!(
            event.notification_title_with(Some("  "), Some("Claude")),
            "Claude: Update"
        );
    }

    #[test]
    fn notification_bodies() {
        let mut event = ev("Claude");
        assert_eq!(event.notification_body(), "Done.");
        event.message = "custom".into();
        assert_eq!(event.notification_body(), "custom");
        event.event_type = "mystery".into();
        assert_eq!(event.notification_body(), "mystery: custom");
        event.message = String::new();
        assert_eq!(event.notification_body(), "mystery");
        event.event_type = "cost_threshold".into();
        assert_eq!(event.notification_body(), "Usage threshold exceeded.");
    }

    #[test]
    fn json_line_round_trips_through_parser() {
        let mut event = AiEvent::new(AiEventSource::app(), "finished", "Claude", "done", "t");
        event.directory = Some("/tmp/x".into());
        event.tab_id = Some(Uuid::new_v4());
        event.session_id = Some("abc-123".into());
        let parsed = parse_line(&event.to_json_line()).unwrap();
        assert_eq!(parsed.source, event.source);
        assert_eq!(parsed.event_type, event.event_type);
        assert_eq!(parsed.directory, event.directory);
        assert_eq!(parsed.tab_id, event.tab_id);
        assert_eq!(parsed.session_id, event.session_id);
        assert_eq!(parsed.ts, "t");
    }

    #[test]
    fn normalized_type_trims_and_lowercases() {
        let mut event = ev("Claude");
        event.event_type = "  Finished ".into();
        assert_eq!(event.normalized_type(), "finished");
    }

    #[test]
    fn now_iso8601_has_fractional_seconds_and_z() {
        let ts = now_iso8601();
        assert!(ts.ends_with('Z'));
        assert_eq!(ts.len(), 24);
    }
}
