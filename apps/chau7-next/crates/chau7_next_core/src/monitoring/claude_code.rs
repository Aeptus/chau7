//! Claude Code hook events and sessions: ports of
//! `Monitoring/ClaudeCodeEvent.swift` (`ClaudeCodeEvent`,
//! `ClaudeCodeEventParser`, `ClaudeTranscriptParser`) and the state of
//! `Monitoring/ClaudeCodeMonitor.swift` (sessions, idle detection, session
//! lookup by directory), without the file polling.
//!
//! The hook scripts append one JSON line per event to the events file
//! (`type`, `hook`, `sessionId`, `transcriptPath`, `toolName`, `title`,
//! `message`, `notificationType`, `cwd`, `timestamp`). Session state per
//! event: user prompt -> active, tool start or complete -> responding,
//! permission request -> waiting permission, response complete -> waiting
//! input, session end -> closed. An active or responding session silent for
//! 60 s becomes idle (one idle callback).

use std::collections::HashMap;

use serde_json::Value;

use crate::command_detection::event_parsing::EventType;
use crate::iso8601;
use crate::shell_session::standardize_path;

/// `maxRecentEvents`.
pub const MAX_RECENT_EVENTS: usize = 50;
/// `idleThreshold` (60 s).
pub const IDLE_THRESHOLD: f64 = 60.0;
/// `minimumIdleCheckInterval`.
pub const MINIMUM_IDLE_CHECK_INTERVAL: f64 = 1.0;
/// `claudeWaitingInputFallbackDelay` in `AppModel`.
pub const WAITING_INPUT_FALLBACK_DELAY: f64 = 0.75;

/// One hook event (`ClaudeCodeEvent`). Times are Unix seconds.
#[derive(Debug, Clone, PartialEq)]
pub struct ClaudeCodeEvent {
    pub event_type: EventType,
    pub hook: String,
    pub session_id: String,
    pub transcript_path: String,
    pub tool_name: String,
    pub title: Option<String>,
    pub message: String,
    pub notification_type: Option<String>,
    pub cwd: String,
    pub timestamp: f64,
}

impl ClaudeCodeEvent {
    /// Last component of `cwd`, "Unknown" when empty (`projectName`).
    pub fn project_name(&self) -> String {
        project_name(&self.cwd)
    }

    /// First 8 characters of the session id.
    pub fn short_session_id(&self) -> String {
        self.session_id.chars().take(8).collect()
    }
}

/// Unix seconds of a date, with milliseconds.
pub fn unix_seconds(date: chrono::DateTime<chrono::Utc>) -> f64 {
    date.timestamp_millis() as f64 / 1000.0
}

/// ISO 8601 date (with or without fractional seconds) as Unix seconds.
pub fn parse_date(text: &str) -> Option<f64> {
    iso8601::parse_iso8601(text)
        .or_else(|| {
            chrono::DateTime::parse_from_rfc3339(text)
                .ok()
                .map(|d| d.with_timezone(&chrono::Utc))
        })
        .map(unix_seconds)
}

fn project_name(cwd: &str) -> String {
    if cwd.is_empty() {
        return "Unknown".into();
    }
    let name = cwd
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or_default();
    if name.is_empty() {
        "Unknown".into()
    } else {
        name.to_string()
    }
}

/// Parses one line of the events file (`ClaudeCodeEventParser.parse`).
/// `now` is used when the timestamp is missing or invalid.
pub fn parse_event_line(line: &str, now: f64) -> Option<ClaudeCodeEvent> {
    let json: Value = serde_json::from_str(line).ok()?;
    let obj = json.as_object()?;
    let string = |key: &str| obj.get(key).and_then(Value::as_str);
    let owned = |key: &str| string(key).unwrap_or_default().to_string();
    let event_type = EventType::from_raw_value(string("type").unwrap_or("unknown"))
        .unwrap_or(EventType::Unknown);
    let timestamp = string("timestamp").and_then(parse_date).unwrap_or(now);
    Some(ClaudeCodeEvent {
        event_type,
        hook: owned("hook"),
        session_id: owned("sessionId"),
        transcript_path: owned("transcriptPath"),
        tool_name: owned("toolName"),
        title: string("title").map(str::to_string),
        message: owned("message"),
        notification_type: string("notificationType")
            .or_else(|| string("notification_type"))
            .map(str::to_string),
        cwd: owned("cwd"),
        timestamp,
    })
}

/// `ClaudeSessionInfo.SessionState`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Active,
    Responding,
    WaitingPermission,
    WaitingInput,
    Idle,
    Closed,
}

impl SessionState {
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Active => "active",
            Self::Responding => "responding",
            Self::WaitingPermission => "waitingPermission",
            Self::WaitingInput => "waitingInput",
            Self::Idle => "idle",
            Self::Closed => "closed",
        }
    }

    /// `stateForEvent`.
    pub fn for_event(event_type: EventType) -> Self {
        match event_type {
            EventType::UserPrompt => Self::Active,
            EventType::ToolStart | EventType::ToolComplete => Self::Responding,
            EventType::PermissionRequest => Self::WaitingPermission,
            EventType::ResponseComplete => Self::WaitingInput,
            EventType::SessionEnd => Self::Closed,
            EventType::Notification | EventType::Unknown => Self::Active,
        }
    }
}

/// `ClaudeSessionInfo`.
#[derive(Debug, Clone, PartialEq)]
pub struct ClaudeSessionInfo {
    pub id: String,
    pub project_name: String,
    pub cwd: String,
    pub transcript_path: String,
    pub last_activity: f64,
    pub state: SessionState,
    pub last_tool_name: Option<String>,
}

/// The monitor's state (`ClaudeCodeMonitor` minus the tailer and timers).
#[derive(Debug, Default, Clone)]
pub struct ClaudeSessionTracker {
    pub recent_events: Vec<ClaudeCodeEvent>,
    pub sessions: HashMap<String, ClaudeSessionInfo>,
}

impl ClaudeSessionTracker {
    pub fn new() -> Self {
        Self::default()
    }

    /// Records an event (`handleEvent`, `updateSession`).
    pub fn handle_event(&mut self, event: &ClaudeCodeEvent) {
        if !event.session_id.is_empty() {
            let tool = (!event.tool_name.is_empty()).then(|| event.tool_name.clone());
            let state = SessionState::for_event(event.event_type);
            match self.sessions.get_mut(&event.session_id) {
                Some(session) => {
                    session.last_activity = event.timestamp;
                    session.state = state;
                    if tool.is_some() {
                        session.last_tool_name = tool;
                    }
                }
                None => {
                    self.sessions.insert(
                        event.session_id.clone(),
                        ClaudeSessionInfo {
                            id: event.session_id.clone(),
                            project_name: event.project_name(),
                            cwd: event.cwd.clone(),
                            transcript_path: event.transcript_path.clone(),
                            last_activity: event.timestamp,
                            state,
                            last_tool_name: tool,
                        },
                    );
                }
            }
        }
        self.recent_events.push(event.clone());
        if self.recent_events.len() > MAX_RECENT_EVENTS {
            let extra = self.recent_events.len() - MAX_RECENT_EVENTS;
            self.recent_events.drain(..extra);
        }
        if event.event_type == EventType::SessionEnd
            && let Some(session) = self.sessions.get_mut(&event.session_id)
        {
            session.state = SessionState::Closed;
        }
    }

    /// Delay until the next idle check, `None` when nothing is active.
    pub fn next_idle_check_delay(&self, now: f64) -> Option<f64> {
        let dates: Vec<f64> = self
            .sessions
            .values()
            .filter(|s| matches!(s.state, SessionState::Active | SessionState::Responding))
            .map(|s| s.last_activity)
            .collect();
        crate::notifications::schedule::next_idle_check_delay(
            now,
            MINIMUM_IDLE_CHECK_INTERVAL,
            IDLE_THRESHOLD,
            &dates,
        )
    }

    /// Marks silent active or responding sessions idle and returns them
    /// (`checkIdleSessions`).
    pub fn check_idle(&mut self, now: f64) -> Vec<ClaudeSessionInfo> {
        let threshold = MINIMUM_IDLE_CHECK_INTERVAL.max(IDLE_THRESHOLD);
        let mut idle = Vec::new();
        for session in self.sessions.values_mut() {
            if !matches!(
                session.state,
                SessionState::Active | SessionState::Responding
            ) {
                continue;
            }
            if now - session.last_activity >= threshold {
                session.state = SessionState::Idle;
                idle.push(session.clone());
            }
        }
        idle
    }

    /// Sessions whose directory is `dir` or a parent of it: not closed
    /// first, then newest (`sessionCandidates(forDirectory:)`).
    pub fn session_candidates(&self, dir: &str) -> Vec<(String, f64)> {
        let Some(target) = normalized_path(dir) else {
            return Vec::new();
        };
        let mut matches: Vec<(&ClaudeSessionInfo, bool)> = self
            .sessions
            .values()
            .filter_map(|s| {
                let session_dir = normalized_path(&s.cwd)?;
                let matched =
                    target == session_dir || target.starts_with(&format!("{session_dir}/"));
                matched.then_some((s, s.state == SessionState::Closed))
            })
            .collect();
        matches.sort_by(|a, b| {
            a.1.cmp(&b.1)
                .then(b.0.last_activity.total_cmp(&a.0.last_activity))
        });
        matches
            .into_iter()
            .map(|(s, _)| (s.id.clone(), s.last_activity))
            .collect()
    }

    /// The most recent session for a directory (`sessionId(forDirectory:)`).
    pub fn session_id_for_directory(&self, dir: &str) -> Option<String> {
        self.session_candidates(dir).into_iter().next().map(|c| c.0)
    }

    /// Sessions, newest first (`claudeCodeSessions`).
    pub fn sorted_sessions(&self) -> Vec<ClaudeSessionInfo> {
        let mut sessions: Vec<ClaudeSessionInfo> = self.sessions.values().cloned().collect();
        sessions.sort_by(|a, b| b.last_activity.total_cmp(&a.last_activity));
        sessions
    }
}

fn normalized_path(value: &str) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    let expanded = if let Some(rest) = trimmed.strip_prefix('~') {
        let home = std::env::var("HOME").unwrap_or_default();
        format!("{home}{rest}")
    } else {
        trimmed.to_string()
    };
    Some(standardize_path(&expanded))
}

/// "Claude is waiting for your input in <project>" (or "in Claude" when the
/// project is unknown), the response-complete fallback message.
pub fn waiting_input_message(event: &ClaudeCodeEvent) -> String {
    let project = event.project_name();
    let location = if project == "Unknown" {
        "Claude".to_string()
    } else {
        project
    };
    format!("Claude is waiting for your input in {location}")
}

// MARK: - Transcripts

/// `ClaudeMessageRole`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MessageRole {
    User,
    Assistant,
    System,
}

/// `ClaudeContentType`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ContentType {
    Text,
    ToolUse,
    ToolResult,
    Thinking,
}

/// One block of a transcript message (`ClaudeTranscriptMessage`).
#[derive(Debug, Clone, PartialEq)]
pub struct TranscriptMessage {
    pub id: String,
    pub role: MessageRole,
    pub content_type: ContentType,
    pub content: String,
    pub tool_name: Option<String>,
    pub timestamp: f64,
    pub session_id: String,
}

impl TranscriptMessage {
    /// INPUT, OUTPUT, TOOL, THINKING, RESULT or OTHER (`displayCategory`).
    pub fn display_category(&self) -> &'static str {
        match (self.role, self.content_type) {
            (MessageRole::User, _) => "INPUT",
            (MessageRole::Assistant, ContentType::Text) => "OUTPUT",
            (MessageRole::Assistant, ContentType::ToolUse) => "TOOL",
            (MessageRole::Assistant, ContentType::Thinking) => "THINKING",
            (_, ContentType::ToolResult) => "RESULT",
            _ => "OTHER",
        }
    }
}

/// Parses a transcript JSONL text (`parseTranscript`): user and assistant
/// lines, one message per text, tool use, tool result or thinking block.
/// IDE notices and empty texts are skipped, tool results cut at 200
/// characters.
pub fn parse_transcript(text: &str, now: f64) -> Vec<TranscriptMessage> {
    let mut messages = Vec::new();
    for line in text.lines() {
        if line.is_empty() {
            continue;
        }
        let Ok(json) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let Some(kind) = json.get("type").and_then(Value::as_str) else {
            continue;
        };
        if kind != "user" && kind != "assistant" {
            continue;
        }
        let Some(uuid) = json.get("uuid").and_then(Value::as_str) else {
            continue;
        };
        let Some(message) = json.get("message") else {
            continue;
        };
        let role = match message.get("role").and_then(Value::as_str) {
            Some("user") => MessageRole::User,
            Some("assistant") => MessageRole::Assistant,
            Some("system") => MessageRole::System,
            _ => continue,
        };
        let Some(blocks) = message.get("content").and_then(Value::as_array) else {
            continue;
        };
        let session_id = json
            .get("sessionId")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_string();
        let timestamp = json
            .get("timestamp")
            .and_then(Value::as_str)
            .and_then(parse_date)
            .unwrap_or(now);
        for block in blocks {
            let Some(block_type) = block.get("type").and_then(Value::as_str) else {
                continue;
            };
            let text_of = |key: &str| {
                block
                    .get(key)
                    .and_then(Value::as_str)
                    .unwrap_or_default()
                    .to_string()
            };
            let (content_type, content, tool_name) = match block_type {
                "text" => {
                    let content = text_of("text");
                    if content.starts_with("<ide_") || content.is_empty() {
                        continue;
                    }
                    (ContentType::Text, content, None)
                }
                "tool_use" => {
                    let name = block
                        .get("name")
                        .and_then(Value::as_str)
                        .map(str::to_string);
                    (
                        ContentType::ToolUse,
                        name.clone().unwrap_or_else(|| "Unknown tool".into()),
                        name,
                    )
                }
                "tool_result" => {
                    let mut content = text_of("content");
                    if content.chars().count() > 200 {
                        content = content.chars().take(200).collect::<String>() + "...";
                    }
                    (ContentType::ToolResult, content, None)
                }
                "thinking" => (ContentType::Thinking, text_of("thinking"), None),
                _ => continue,
            };
            messages.push(TranscriptMessage {
                id: format!("{uuid}-{block_type}"),
                role,
                content_type,
                content,
                tool_name,
                timestamp,
                session_id: session_id.clone(),
            });
        }
    }
    messages
}

/// The last `count` messages of a transcript file (`latestMessages`).
pub fn latest_messages(path: &std::path::Path, count: usize, now: f64) -> Vec<TranscriptMessage> {
    let Ok(text) = std::fs::read_to_string(path) else {
        log::warn!("Failed to read transcript at {}", path.display());
        return Vec::new();
    };
    let all = parse_transcript(&text, now);
    let start = all.len().saturating_sub(count);
    all[start..].to_vec()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn line(kind: &str, session: &str, cwd: &str, ts: &str) -> String {
        format!(
            r#"{{"type":"{kind}","hook":"h","sessionId":"{session}","transcriptPath":"/t/{session}.jsonl","toolName":"Bash","message":"m","cwd":"{cwd}","timestamp":"{ts}"}}"#
        )
    }

    #[test]
    fn parses_event_lines() {
        let event = parse_event_line(
            &line(
                "tool_start",
                "abc12345xyz",
                "/Users/me/proj",
                "2026-01-02T03:04:05Z",
            ),
            0.0,
        )
        .unwrap();
        assert_eq!(event.event_type, EventType::ToolStart);
        assert_eq!(event.project_name(), "proj");
        assert_eq!(event.short_session_id(), "abc12345");
        assert!(event.timestamp > 1.7e9);
        let event =
            parse_event_line(r#"{"type":"nope","notification_type":"idle_prompt"}"#, 5.0).unwrap();
        assert_eq!(event.event_type, EventType::Unknown);
        assert_eq!(event.timestamp, 5.0);
        assert_eq!(event.project_name(), "Unknown");
        assert_eq!(event.notification_type.as_deref(), Some("idle_prompt"));
        assert!(parse_event_line("not json", 0.0).is_none());
    }

    #[test]
    fn session_states_follow_events() {
        let mut tracker = ClaudeSessionTracker::new();
        let mut event = parse_event_line(
            &line("user_prompt", "s1", "/p", "2026-01-01T00:00:00Z"),
            0.0,
        )
        .unwrap();
        tracker.handle_event(&event);
        assert_eq!(tracker.sessions["s1"].state, SessionState::Active);
        event.event_type = EventType::PermissionRequest;
        tracker.handle_event(&event);
        assert_eq!(
            tracker.sessions["s1"].state,
            SessionState::WaitingPermission
        );
        event.event_type = EventType::ResponseComplete;
        tracker.handle_event(&event);
        assert_eq!(tracker.sessions["s1"].state, SessionState::WaitingInput);
        event.event_type = EventType::SessionEnd;
        tracker.handle_event(&event);
        assert_eq!(tracker.sessions["s1"].state, SessionState::Closed);
        assert_eq!(
            tracker.sessions["s1"].last_tool_name.as_deref(),
            Some("Bash")
        );
        assert_eq!(tracker.recent_events.len(), 4);
    }

    #[test]
    fn idle_after_sixty_seconds_once() {
        let mut tracker = ClaudeSessionTracker::new();
        let mut event = parse_event_line(&line("tool_start", "s1", "/p", ""), 100.0).unwrap();
        event.timestamp = 100.0;
        tracker.handle_event(&event);
        assert_eq!(tracker.next_idle_check_delay(110.0), Some(50.0));
        assert!(tracker.check_idle(150.0).is_empty());
        let idle = tracker.check_idle(160.0);
        assert_eq!(idle.len(), 1);
        assert_eq!(idle[0].state, SessionState::Idle);
        assert!(tracker.check_idle(200.0).is_empty());
        assert_eq!(tracker.next_idle_check_delay(200.0), None);
    }

    #[test]
    fn candidates_by_directory() {
        let mut tracker = ClaudeSessionTracker::new();
        for (id, cwd, ts, kind) in [
            ("old", "/repo", 10.0, "user_prompt"),
            ("new", "/repo", 20.0, "user_prompt"),
            ("closed", "/repo", 30.0, "session_end"),
            ("other", "/elsewhere", 40.0, "user_prompt"),
        ] {
            let mut event = parse_event_line(&line(kind, id, cwd, ""), ts).unwrap();
            event.timestamp = ts;
            tracker.handle_event(&event);
        }
        let ids: Vec<String> = tracker
            .session_candidates("/repo/sub/../sub")
            .into_iter()
            .map(|c| c.0)
            .collect();
        assert_eq!(ids, vec!["new", "old", "closed"]);
        assert_eq!(
            tracker.session_id_for_directory("/repo").as_deref(),
            Some("new")
        );
        assert!(tracker.session_candidates("/rep").is_empty());
        assert!(tracker.session_candidates(" ").is_empty());
    }

    #[test]
    fn waiting_message() {
        let mut event =
            parse_event_line(&line("response_complete", "s", "/x/app", ""), 0.0).unwrap();
        assert_eq!(
            waiting_input_message(&event),
            "Claude is waiting for your input in app"
        );
        event.cwd.clear();
        assert_eq!(
            waiting_input_message(&event),
            "Claude is waiting for your input in Claude"
        );
    }

    #[test]
    fn transcript_messages() {
        let long = "r".repeat(250);
        let result_line = format!(
            r#"{{"type":"user","uuid":"r1","message":{{"role":"user","content":[{{"type":"tool_result","content":"{long}"}}]}}}}"#
        );
        let text = format!(
            "{}\n{}\n{}\nnot json\n",
            r#"{"type":"user","uuid":"u1","sessionId":"s","timestamp":"2026-01-01T00:00:00Z","message":{"role":"user","content":[{"type":"text","text":"hello"},{"type":"text","text":"<ide_opened_file>x"}]}}"#,
            r#"{"type":"assistant","uuid":"a1","message":{"role":"assistant","content":[{"type":"thinking","thinking":"hmm"},{"type":"tool_use","name":"Read"},{"type":"text","text":"done"}]}}"#,
            result_line,
        );
        let messages = parse_transcript(&text, 1.0);
        let cats: Vec<&str> = messages.iter().map(|m| m.display_category()).collect();
        assert_eq!(cats, vec!["INPUT", "THINKING", "TOOL", "OUTPUT", "INPUT"]);
        assert_eq!(messages[2].tool_name.as_deref(), Some("Read"));
        assert_eq!(messages[4].content.chars().count(), 203);
        assert_eq!(messages[0].id, "u1-text");
        assert_eq!(messages[1].timestamp, 1.0);
    }
}
