//! Ports of the history monitor files of
//! `apps/chau7-macos/Sources/Chau7Core`:
//!
//! - `HistoryEntry.swift` (`HistoryEntry`, `HistoryEntryParser`)
//! - `HistoryEventContextResolver.swift`
//! - `HistorySessionLifecycle.swift`
//! - `HistorySummarySanitizer.swift`
//!
//! `HistorySummarySanitizer` depends on `EscapeSequenceSanitizer.swift`
//! (COR-013, ported separately). [`sanitize_for_logging`] below is a private
//! copy of just the pieces it needs; replace it with the COR-013 module when
//! that lands.

use crate::ai::resume::{is_valid_session_id, normalize_provider_name};
use regex::Regex;
use serde_json::{Map, Value};
use std::sync::LazyLock;

// MARK: - HistoryEntry

/// What kind of history line this is (`HistoryEntryActivityKind`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HistoryEntryActivityKind {
    Prompt,
    Response,
    Unknown,
}

impl HistoryEntryActivityKind {
    /// Only responses can end a session with a "finished" event.
    pub fn supports_finished_event(self) -> bool {
        self == Self::Response
    }
}

/// One parsed provider history line.
#[derive(Debug, Clone, PartialEq)]
pub struct HistoryEntry {
    pub session_id: String,
    /// Seconds since the Unix epoch.
    pub timestamp: f64,
    pub summary: String,
    pub is_exit: bool,
    pub activity_kind: HistoryEntryActivityKind,
}

impl HistoryEntry {
    /// Creates an entry with the default `Prompt` activity kind.
    pub fn new(session_id: &str, timestamp: f64, summary: &str, is_exit: bool) -> Self {
        Self {
            session_id: session_id.to_string(),
            timestamp,
            summary: summary.to_string(),
            is_exit,
            activity_kind: HistoryEntryActivityKind::Prompt,
        }
    }
}

/// Error from [`parse_entry`] (`HistoryEntryParseError`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HistoryEntryParseError {
    NotJsonObject,
    MissingField(String),
    InvalidFieldType(String),
    /// The line is not valid JSON (Swift surfaces the Foundation error).
    InvalidJson(String),
}

impl std::fmt::Display for HistoryEntryParseError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::NotJsonObject => write!(f, "History entry data is not a JSON object"),
            Self::MissingField(field) => {
                write!(f, "History entry missing required field: {field}")
            }
            Self::InvalidFieldType(field) => {
                write!(f, "History entry field has invalid type: {field}")
            }
            Self::InvalidJson(detail) => write!(f, "History entry is not valid JSON: {detail}"),
        }
    }
}

impl std::error::Error for HistoryEntryParseError {}

/// `getString`: strings as is, other values stringified like Swift's
/// `String(describing:)` (integers plain, booleans `1`/`0`, null `<null>`).
/// Arrays and objects use compact JSON; Swift prints a Foundation
/// description instead, which is not reproducible.
fn get_string(dict: &Map<String, Value>, key: &str) -> Option<String> {
    let value = dict.get(key)?;
    Some(match value {
        Value::String(s) => s.clone(),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                i.to_string()
            } else if let Some(u) = n.as_u64() {
                u.to_string()
            } else {
                n.as_f64().map(|f| f.to_string()).unwrap_or_default()
            }
        }
        Value::Bool(b) => if *b { "1" } else { "0" }.to_string(),
        Value::Null => "<null>".to_string(),
        other => other.to_string(),
    })
}

fn get_number(dict: &Map<String, Value>, key: &str) -> Option<f64> {
    dict.get(key)?.as_f64()
}

fn normalize_timestamp(value: f64) -> f64 {
    if value > 1_000_000_000_000.0 {
        value / 1000.0
    } else {
        value
    }
}

fn is_exit_marker(raw_text: &str, raw_display: &str) -> bool {
    let candidate = if raw_display.is_empty() {
        raw_text
    } else {
        raw_display
    };
    matches!(
        candidate.trim().to_lowercase().as_str(),
        "exit" | "/exit" | "quit" | "/quit"
    )
}

fn normalize_role(role: Option<&Value>) -> Option<String> {
    role.and_then(Value::as_str)
        .map(|r| r.trim().to_lowercase())
}

fn infer_activity_kind(dict: &Map<String, Value>) -> HistoryEntryActivityKind {
    let top_level_role = normalize_role(dict.get("role"));
    let message_role = normalize_role(
        dict.get("message")
            .and_then(Value::as_object)
            .and_then(|m| m.get("role")),
    );
    match top_level_role.or(message_role).as_deref() {
        Some("assistant") => return HistoryEntryActivityKind::Response,
        Some("user") => return HistoryEntryActivityKind::Prompt,
        _ => {}
    }

    // Current Codex and Claude history files only record user prompts, so
    // untyped text/display entries default to prompt rather than producing
    // false "finished" events on idle.
    if dict.contains_key("text") || dict.contains_key("display") {
        return HistoryEntryActivityKind::Prompt;
    }
    HistoryEntryActivityKind::Unknown
}

/// Parses one Claude/Codex history JSON line (`HistoryEntryParser.parse(line:)`).
pub fn parse_entry(line: &str) -> Result<HistoryEntry, HistoryEntryParseError> {
    let value: Value = serde_json::from_str(line)
        .map_err(|e| HistoryEntryParseError::InvalidJson(e.to_string()))?;
    let Value::Object(dict) = value else {
        return Err(HistoryEntryParseError::NotJsonObject);
    };

    let session_id = get_string(&dict, "session_id")
        .or_else(|| get_string(&dict, "sessionId"))
        .ok_or_else(|| HistoryEntryParseError::MissingField("session_id".into()))?;

    let raw_timestamp = get_number(&dict, "ts")
        .or_else(|| get_number(&dict, "timestamp"))
        .ok_or_else(|| HistoryEntryParseError::MissingField("ts".into()))?;

    let raw_text = get_string(&dict, "text").unwrap_or_default();
    let raw_display = get_string(&dict, "display").unwrap_or_default();
    let summary = if raw_text.is_empty() {
        raw_display.clone()
    } else {
        raw_text.clone()
    };

    Ok(HistoryEntry {
        session_id,
        timestamp: normalize_timestamp(raw_timestamp),
        summary,
        is_exit: is_exit_marker(&raw_text, &raw_display),
        activity_kind: infer_activity_kind(&dict),
    })
}

// MARK: - HistoryEventContextResolver

/// Resolves a working directory hint for a history-monitor event from
/// provider session metadata (`HistoryEventContextResolver.directory`).
pub fn resolve_directory(
    tool_name: &str,
    session_id: Option<&str>,
    claude_directory_provider: impl Fn(&str) -> Option<String>,
    codex_directory_provider: impl Fn(&str) -> Option<String>,
) -> Option<String> {
    let session_id = session_id?.trim();
    if !is_valid_session_id(session_id) {
        return None;
    }
    let provider = normalize_provider_name(tool_name)?;
    match provider.as_str() {
        "claude" => claude_directory_provider(session_id),
        "codex" => codex_directory_provider(session_id),
        _ => None,
    }
}

// MARK: - HistorySessionLifecycle

/// Session state tracked by the history monitor (`HistorySessionState`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HistorySessionState {
    Active,
    Idle,
    Closed,
}

impl HistorySessionState {
    /// The Swift raw value.
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Idle => "idle",
            Self::Closed => "closed",
        }
    }
}

/// What to do for a session state transition (`HistorySessionTransitionDecision`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HistorySessionTransitionDecision {
    pub should_persist_state: bool,
    pub emits_finished_event: bool,
    pub is_reactivation: bool,
}

/// `HistorySessionLifecycle.evaluate`.
pub fn evaluate_session_transition(
    previous_state: Option<HistorySessionState>,
    next_state: HistorySessionState,
    last_activity_kind: HistoryEntryActivityKind,
) -> HistorySessionTransitionDecision {
    let is_reactivation = previous_state == Some(HistorySessionState::Closed)
        && next_state == HistorySessionState::Active;
    let session_ended = matches!(
        next_state,
        HistorySessionState::Idle | HistorySessionState::Closed
    );
    let was_active_or_new =
        previous_state == Some(HistorySessionState::Active) || previous_state.is_none();
    HistorySessionTransitionDecision {
        should_persist_state: true,
        emits_finished_event: was_active_or_new
            && session_ended
            && last_activity_kind.supports_finished_event(),
        is_reactivation,
    }
}

// MARK: - HistorySummarySanitizer

fn re(pattern: &str) -> Regex {
    Regex::new(pattern).expect("valid regex")
}

static OSC: LazyLock<Regex> = LazyLock::new(|| re(r"\x{1b}\][^\x{07}\x{1b}]*(?:\x{07}|\x{1b}\\)?"));
static BARE_OSC: LazyLock<Regex> = LazyLock::new(|| re(r"\][0-9;]*[^\x{07}\x{1b}]*(?:\x{07})?"));
static CSI: LazyLock<Regex> = LazyLock::new(|| re(r"\x{1b}\[[0-9;?]*[@-~]"));
static BARE_CSI: LazyLock<Regex> = LazyLock::new(|| re(r"\[[0-9;?]*[A-Za-z]"));
static PASTE: LazyLock<Regex> = LazyLock::new(|| re(r"\x{1b}\[20[01]~"));
static BARE_PASTE: LazyLock<Regex> = LazyLock::new(|| re(r"\[20[01]~"));
static SIMPLE_ESC: LazyLock<Regex> = LazyLock::new(|| re(r"\x{1b}[^\[\]]"));

/// Unicode space separators plus tab (`CharacterSet.whitespaces`).
fn is_horizontal_whitespace(c: char) -> bool {
    matches!(
        c,
        '\t' | ' ' | '\u{a0}' | '\u{1680}' | '\u{2000}'
            ..='\u{200a}' | '\u{202f}' | '\u{205f}' | '\u{3000}'
    )
}

/// Strips terminal escape sequences and control characters, collapses runs
/// of spaces and trims (`EscapeSequenceSanitizer.sanitize`).
fn sanitize_escapes(text: &str) -> String {
    let mut result = text.to_string();
    for pattern in [
        &*OSC,
        &*BARE_OSC,
        &*CSI,
        &*BARE_CSI,
        &*PASTE,
        &*BARE_PASTE,
        &*SIMPLE_ESC,
    ] {
        result = pattern.replace_all(&result, "").into_owned();
    }
    let mut collapsed = String::with_capacity(result.len());
    let mut last_was_space = false;
    for ch in result.chars() {
        let value = ch as u32;
        if !matches!(value, 0x0A | 0x0D | 0x09) && (value < 0x20 || value == 0x7F) {
            continue;
        }
        if ch == ' ' {
            if !last_was_space {
                collapsed.push(ch);
            }
            last_was_space = true;
        } else {
            collapsed.push(ch);
            last_was_space = false;
        }
    }
    collapsed.trim_matches(is_horizontal_whitespace).to_string()
}

/// `EscapeSequenceSanitizer.sanitizeForLogging` with the default 500 limit.
fn sanitize_for_logging(text: &str) -> String {
    const MAX_LENGTH: usize = 500;
    let sanitized = sanitize_escapes(text);
    if sanitized.chars().count() <= MAX_LENGTH {
        return sanitized;
    }
    let prefix: String = sanitized.chars().take(MAX_LENGTH - 3).collect();
    format!("{prefix}...")
}

/// Sanitizes an upstream history summary before it is logged or stored.
/// Truncated fragments such as `rror` (4 characters or fewer after
/// sanitizing) are dropped unless the entry is an exit marker
/// (`HistorySummarySanitizer.sanitize`).
pub fn sanitize_summary(summary: &str, is_exit: bool) -> String {
    let sanitized = sanitize_for_logging(summary);
    if is_exit || sanitized.is_empty() || sanitized.chars().count() > 4 {
        return sanitized;
    }
    String::new()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn p(json: &str) -> HistoryEntry {
        parse_entry(json).unwrap()
    }

    // MARK: HistoryEntryParserTests

    #[test]
    fn parse_all_fields() {
        let entry = p(
            r#"{"session_id":"abc123","ts":1700000000,"text":"hello world","display":"Hello World"}"#,
        );
        assert_eq!(entry.session_id, "abc123");
        assert_eq!(entry.timestamp, 1_700_000_000.0);
        assert_eq!(entry.summary, "hello world");
        assert!(!entry.is_exit);
        assert_eq!(entry.activity_kind, HistoryEntryActivityKind::Prompt);
    }

    #[test]
    fn parse_uses_text_over_display() {
        let entry =
            p(r#"{"session_id":"s1","ts":100,"text":"from text","display":"from display"}"#);
        assert_eq!(entry.summary, "from text");
    }

    #[test]
    fn parse_falls_back_to_display_when_text_empty() {
        let entry = p(r#"{"session_id":"s1","ts":100,"text":"","display":"from display"}"#);
        assert_eq!(entry.summary, "from display");
    }

    #[test]
    fn parse_falls_back_to_display_when_text_missing() {
        let entry = p(r#"{"session_id":"s1","ts":100,"display":"fallback"}"#);
        assert_eq!(entry.summary, "fallback");
    }

    #[test]
    fn parse_missing_text_and_display() {
        let entry = p(r#"{"session_id":"s1","ts":100}"#);
        assert_eq!(entry.summary, "");
    }

    #[test]
    fn parse_session_id_alternative_key() {
        let entry = p(r#"{"sessionId":"alt-id","ts":100}"#);
        assert_eq!(entry.session_id, "alt-id");
    }

    #[test]
    fn parse_timestamp_alternative_key() {
        let entry = p(r#"{"session_id":"s1","timestamp":1700000000}"#);
        assert_eq!(entry.timestamp, 1_700_000_000.0);
    }

    #[test]
    fn parse_normalizes_millisecond_timestamp() {
        let entry = p(r#"{"session_id":"s1","ts":1700000000000}"#);
        assert!((entry.timestamp - 1_700_000_000.0).abs() < 0.001);
    }

    #[test]
    fn parse_keeps_second_timestamp_as_is() {
        let entry = p(r#"{"session_id":"s1","ts":1700000000}"#);
        assert_eq!(entry.timestamp, 1_700_000_000.0);
    }

    #[test]
    fn parse_boundary_timestamp_not_normalized() {
        let entry = p(r#"{"session_id":"s1","ts":1000000000000}"#);
        assert!((entry.timestamp - 1_000_000_000_000.0).abs() < 0.001);
    }

    #[test]
    fn parse_below_boundary_not_normalized() {
        let entry = p(r#"{"session_id":"s1","ts":999999999999}"#);
        assert_eq!(entry.timestamp, 999_999_999_999.0);
    }

    #[test]
    fn parse_exit_marker_from_display() {
        assert!(p(r#"{"session_id":"s1","ts":100,"text":"","display":"exit"}"#).is_exit);
    }

    #[test]
    fn parse_exit_marker_from_text() {
        assert!(p(r#"{"session_id":"s1","ts":100,"text":"exit","display":""}"#).is_exit);
    }

    #[test]
    fn parse_exit_marker_slash_exit() {
        assert!(p(r#"{"session_id":"s1","ts":100,"display":"/exit"}"#).is_exit);
    }

    #[test]
    fn parse_exit_marker_quit() {
        assert!(p(r#"{"session_id":"s1","ts":100,"display":"quit"}"#).is_exit);
    }

    #[test]
    fn parse_exit_marker_slash_quit() {
        assert!(p(r#"{"session_id":"s1","ts":100,"display":"/quit"}"#).is_exit);
    }

    #[test]
    fn parse_exit_marker_case_insensitive() {
        assert!(p(r#"{"session_id":"s1","ts":100,"display":"EXIT"}"#).is_exit);
    }

    #[test]
    fn parse_exit_marker_trimmed() {
        assert!(p(r#"{"session_id":"s1","ts":100,"display":"  exit  "}"#).is_exit);
    }

    #[test]
    fn parse_non_exit_text() {
        let entry = p(r#"{"session_id":"s1","ts":100,"text":"ls -la"}"#);
        assert!(!entry.is_exit);
        assert_eq!(entry.activity_kind, HistoryEntryActivityKind::Prompt);
    }

    #[test]
    fn parse_assistant_role_marks_response_activity() {
        let entry = p(r#"{"session_id":"s1","ts":100,"text":"Done","role":"assistant"}"#);
        assert_eq!(entry.activity_kind, HistoryEntryActivityKind::Response);
    }

    #[test]
    fn parse_nested_assistant_role_marks_response_activity() {
        let entry =
            p(r#"{"session_id":"s1","ts":100,"message":{"role":"assistant"},"display":"Done"}"#);
        assert_eq!(entry.activity_kind, HistoryEntryActivityKind::Response);
    }

    #[test]
    fn parse_exit_marker_prefers_display_over_text() {
        let entry = p(r#"{"session_id":"s1","ts":100,"text":"exit","display":"not exit"}"#);
        assert!(!entry.is_exit);
    }

    #[test]
    fn parse_timestamp_as_int() {
        assert_eq!(p(r#"{"session_id":"s1","ts":100}"#).timestamp, 100.0);
    }

    #[test]
    fn parse_timestamp_as_double() {
        assert_eq!(p(r#"{"session_id":"s1","ts":100.5}"#).timestamp, 100.5);
    }

    #[test]
    fn parse_session_id_from_non_string_coerced() {
        assert_eq!(p(r#"{"session_id":42,"ts":100}"#).session_id, "42");
    }

    #[test]
    fn parse_missing_session_id_throws() {
        assert_eq!(
            parse_entry(r#"{"ts":100}"#).unwrap_err(),
            HistoryEntryParseError::MissingField("session_id".into())
        );
    }

    #[test]
    fn parse_missing_timestamp_throws() {
        assert_eq!(
            parse_entry(r#"{"session_id":"s1"}"#).unwrap_err(),
            HistoryEntryParseError::MissingField("ts".into())
        );
    }

    #[test]
    fn parse_invalid_json_throws() {
        assert!(parse_entry("not json").is_err());
    }

    #[test]
    fn parse_empty_string_throws() {
        assert!(parse_entry("").is_err());
    }

    #[test]
    fn parse_json_array_throws() {
        assert_eq!(
            parse_entry("[1,2,3]").unwrap_err(),
            HistoryEntryParseError::NotJsonObject
        );
    }

    #[test]
    fn history_entry_equality() {
        let a = HistoryEntry::new("s1", 100.0, "hello", false);
        let b = HistoryEntry::new("s1", 100.0, "hello", false);
        assert_eq!(a, b);
    }

    #[test]
    fn history_entry_inequality() {
        let a = HistoryEntry::new("s1", 100.0, "hello", false);
        let b = HistoryEntry::new("s2", 100.0, "hello", false);
        assert_ne!(a, b);
    }

    // Extra branches

    #[test]
    fn activity_kind_unknown_without_role_text_or_display() {
        assert_eq!(
            p(r#"{"session_id":"s1","ts":1}"#).activity_kind,
            HistoryEntryActivityKind::Unknown
        );
    }

    #[test]
    fn activity_kind_user_role_is_prompt_and_unknown_role_falls_to_text() {
        assert_eq!(
            p(r#"{"session_id":"s1","ts":1,"role":"user"}"#).activity_kind,
            HistoryEntryActivityKind::Prompt
        );
        assert_eq!(
            p(r#"{"session_id":"s1","ts":1,"role":"system","text":"x"}"#).activity_kind,
            HistoryEntryActivityKind::Prompt
        );
    }

    #[test]
    fn string_timestamp_is_not_a_number() {
        assert_eq!(
            parse_entry(r#"{"session_id":"s1","ts":"100"}"#).unwrap_err(),
            HistoryEntryParseError::MissingField("ts".into())
        );
    }

    // MARK: HistoryEventContextResolverTests

    #[test]
    fn directory_uses_claude_provider_lookup() {
        let directory = resolve_directory(
            "Claude",
            Some("b026411b-4e80-4228-b824-3fb1826aa0c9"),
            |id| {
                assert_eq!(id, "b026411b-4e80-4228-b824-3fb1826aa0c9");
                Some("/tmp/sp42".to_string())
            },
            |_| panic!("Codex lookup should not be used for Claude"),
        );
        assert_eq!(directory.as_deref(), Some("/tmp/sp42"));
    }

    #[test]
    fn directory_uses_codex_provider_lookup() {
        let directory = resolve_directory(
            "Codex",
            Some("019d25d0-d0bd-7501-99ba-1f937c17b29b"),
            |_| panic!("Claude lookup should not be used for Codex"),
            |id| {
                assert_eq!(id, "019d25d0-d0bd-7501-99ba-1f937c17b29b");
                Some("/tmp/chau7".to_string())
            },
        );
        assert_eq!(directory.as_deref(), Some("/tmp/chau7"));
    }

    #[test]
    fn directory_returns_nil_for_unknown_provider() {
        let directory = resolve_directory(
            "Aider",
            Some("session"),
            |_| panic!("Claude lookup should not be used"),
            |_| panic!("Codex lookup should not be used"),
        );
        assert_eq!(directory, None);
    }

    #[test]
    fn directory_returns_nil_for_invalid_session_id() {
        let directory = resolve_directory(
            "Codex",
            Some("invalid session id with spaces"),
            |_| panic!("Provider lookup should not be used"),
            |_| panic!("Provider lookup should not be used"),
        );
        assert_eq!(directory, None);
    }

    #[test]
    fn directory_returns_nil_without_session_id_and_trims_it() {
        assert_eq!(
            resolve_directory("Claude", None, |_| panic!(), |_| panic!()),
            None
        );
        let directory = resolve_directory(
            "Claude",
            Some("  abc  "),
            |id| {
                assert_eq!(id, "abc");
                Some("/x".to_string())
            },
            |_| None,
        );
        assert_eq!(directory.as_deref(), Some("/x"));
    }

    // MARK: HistorySessionLifecycleTests

    use HistoryEntryActivityKind as K;
    use HistorySessionState as S;

    #[test]
    fn closed_session_can_reactivate() {
        let d = evaluate_session_transition(Some(S::Closed), S::Active, K::Prompt);
        assert!(d.should_persist_state);
        assert!(d.is_reactivation);
        assert!(!d.emits_finished_event);
    }

    #[test]
    fn active_to_idle_from_prompt_does_not_emit_finished_event() {
        let d = evaluate_session_transition(Some(S::Active), S::Idle, K::Prompt);
        assert!(d.should_persist_state);
        assert!(!d.is_reactivation);
        assert!(!d.emits_finished_event);
    }

    #[test]
    fn active_to_idle_from_response_emits_finished_event() {
        let d = evaluate_session_transition(Some(S::Active), S::Idle, K::Response);
        assert!(d.should_persist_state);
        assert!(!d.is_reactivation);
        assert!(d.emits_finished_event);
    }

    #[test]
    fn newly_observed_closed_prompt_session_does_not_emit_finished_event() {
        let d = evaluate_session_transition(None, S::Closed, K::Prompt);
        assert!(d.should_persist_state);
        assert!(!d.is_reactivation);
        assert!(!d.emits_finished_event);
    }

    #[test]
    fn newly_observed_closed_response_session_emits_finished_event() {
        let d = evaluate_session_transition(None, S::Closed, K::Response);
        assert!(d.should_persist_state);
        assert!(!d.is_reactivation);
        assert!(d.emits_finished_event);
    }

    #[test]
    fn idle_session_does_not_emit_again_and_state_raw_values() {
        let d = evaluate_session_transition(Some(S::Idle), S::Closed, K::Response);
        assert!(!d.emits_finished_event);
        assert_eq!(S::Active.raw_value(), "active");
        assert_eq!(S::Idle.raw_value(), "idle");
        assert_eq!(S::Closed.raw_value(), "closed");
    }

    // MARK: HistorySummarySanitizerTests

    #[test]
    fn drops_suspiciously_short_non_exit_summary() {
        assert_eq!(sanitize_summary("rror", false), "");
    }

    #[test]
    fn preserves_exit_summary_even_when_short() {
        assert_eq!(sanitize_summary("err", true), "err");
    }

    #[test]
    fn preserves_normal_summary() {
        assert_eq!(sanitize_summary("Error", false), "Error");
    }

    #[test]
    fn sanitizes_escape_sequences_before_length_check() {
        assert_eq!(sanitize_summary("\u{1b}[31mrror\u{1b}[0m", false), "");
    }

    #[test]
    fn sanitizer_collapses_spaces_strips_controls_and_truncates() {
        assert_eq!(
            sanitize_summary("  hello   world\u{7} ", false),
            "hello world"
        );
        let long = "x".repeat(600);
        let out = sanitize_summary(&long, false);
        assert_eq!(out.chars().count(), 500);
        assert!(out.ends_with("..."));
    }

    #[test]
    fn empty_summary_stays_empty() {
        assert_eq!(sanitize_summary("", false), "");
    }
}
