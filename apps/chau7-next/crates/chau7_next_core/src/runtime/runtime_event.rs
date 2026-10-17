//! Port of `Runtime/RuntimeEvent.swift`: the structured runtime event
//! consumed by `runtime_events_poll`, and the well-known event type names.
//!
//! Two JSON shapes exist in Swift and both are kept:
//!
//! - the synthesized `Codable` form (`sessionID`, `turnID`, timestamp as
//!   seconds since 2001) via serde on [`RuntimeEvent`];
//! - the MCP `runtime_events_poll` form built by hand in
//!   `RuntimeControlService.pollEvents` (`session_id`, `turn_id`, ISO 8601
//!   timestamp with milliseconds, `data` only when non-empty), via
//!   [`RuntimeEvent::poll_json`] and [`poll_response_json`]. This is the MCP
//!   API: keep the keys identical.

use std::borrow::Cow;
use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::telemetry::date_codec;

/// A structured event from the agent runtime.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RuntimeEvent {
    /// Monotonically increasing sequence number (unique within a journal).
    pub seq: u64,
    /// Runtime session that produced this event.
    #[serde(rename = "sessionID")]
    pub session_id: String,
    /// Turn within the session (`None` for session-level events).
    #[serde(default, rename = "turnID", skip_serializing_if = "Option::is_none")]
    pub turn_id: Option<String>,
    /// When the event occurred.
    #[serde(with = "date_codec::swift_reference")]
    pub timestamp: DateTime<Utc>,
    /// Event category. Uses the [`RuntimeEventType`] constants.
    #[serde(rename = "type")]
    pub event_type: String,
    /// Arbitrary key-value payload (tool name, summary, token count, etc.)
    pub data: HashMap<String, String>,
}

impl RuntimeEvent {
    /// The dictionary `runtime_events_poll` returns for one event.
    pub fn poll_json(&self) -> Value {
        let mut dict = Map::new();
        dict.insert("seq".into(), json!(self.seq));
        dict.insert("session_id".into(), json!(self.session_id));
        dict.insert(
            "timestamp".into(),
            json!(date_codec::format_iso8601_fractional(&self.timestamp)),
        );
        dict.insert("type".into(), json!(self.event_type));
        if let Some(turn_id) = &self.turn_id {
            dict.insert("turn_id".into(), json!(turn_id));
        }
        if !self.data.is_empty() {
            dict.insert("data".into(), json!(self.data));
        }
        Value::Object(dict)
    }
}

/// The full `runtime_events_poll` response body.
pub fn poll_response_json(
    events: &[RuntimeEvent],
    cursor: u64,
    has_more: bool,
    session_state: &str,
) -> Value {
    json!({
        "events": events.iter().map(RuntimeEvent::poll_json).collect::<Vec<_>>(),
        "cursor": cursor,
        "has_more": has_more,
        "session_state": session_state,
    })
}

/// Well-known event type constants (an extensible raw-string wrapper, like
/// the Swift `RawRepresentable` struct).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RuntimeEventType(Cow<'static, str>);

impl RuntimeEventType {
    pub fn new(raw_value: impl Into<String>) -> Self {
        Self(Cow::Owned(raw_value.into()))
    }

    const fn well_known(raw_value: &'static str) -> Self {
        Self(Cow::Borrowed(raw_value))
    }

    pub fn raw_value(&self) -> &str {
        &self.0
    }

    // Session lifecycle
    pub const SESSION_STARTING: Self = Self::well_known("session_starting");
    pub const SESSION_READY: Self = Self::well_known("session_ready");
    pub const SESSION_STOPPED: Self = Self::well_known("session_stopped");
    pub const SESSION_ERROR: Self = Self::well_known("session_error");
    pub const STATE_CHANGED: Self = Self::well_known("state_changed");

    // Turn lifecycle
    pub const TURN_STARTED: Self = Self::well_known("turn_started");
    pub const TURN_COMPLETED: Self = Self::well_known("turn_completed");
    pub const TURN_FAILED: Self = Self::well_known("turn_failed");

    // Agent activity
    pub const AGENT_RESPONDING: Self = Self::well_known("agent_responding");
    pub const NOTIFICATION: Self = Self::well_known("notification");
    pub const TOOL_USE: Self = Self::well_known("tool_use");
    pub const TOOL_RESULT: Self = Self::well_known("tool_result");
    pub const OUTPUT_CHUNK: Self = Self::well_known("output_chunk");

    // Approval
    pub const APPROVAL_NEEDED: Self = Self::well_known("approval_needed");
    pub const APPROVAL_RESOLVED: Self = Self::well_known("approval_resolved");

    // Stall detection
    pub const STALL_DETECTED: Self = Self::well_known("stall_detected");

    // Turn enrichment
    pub const TOKEN_THRESHOLD: Self = Self::well_known("token_threshold");
    pub const COST_THRESHOLD: Self = Self::well_known("cost_threshold");
    pub const EXIT_CLASSIFIED: Self = Self::well_known("exit_classified");
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(turn: Option<&str>, data: &[(&str, &str)]) -> RuntimeEvent {
        RuntimeEvent {
            seq: 7,
            session_id: "s1".into(),
            turn_id: turn.map(str::to_string),
            timestamp: date_codec::parse_iso8601(Some("2026-04-01T09:00:00.125Z")).unwrap(),
            event_type: "tool_use".into(),
            data: data
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        }
    }

    #[test]
    fn poll_json_keys_match_mcp_api() {
        let json = sample(Some("t1"), &[("tool", "Write")]).poll_json();
        assert_eq!(json["seq"], 7);
        assert_eq!(json["session_id"], "s1");
        assert_eq!(json["turn_id"], "t1");
        assert_eq!(json["timestamp"], "2026-04-01T09:00:00.125Z");
        assert_eq!(json["type"], "tool_use");
        assert_eq!(json["data"]["tool"], "Write");
    }

    #[test]
    fn poll_json_omits_empty_data_and_missing_turn() {
        let json = sample(None, &[]).poll_json();
        assert!(json.get("turn_id").is_none());
        assert!(json.get("data").is_none());
    }

    #[test]
    fn poll_response_shape() {
        let body = poll_response_json(&[sample(None, &[])], 7, true, "awaitingApproval");
        assert_eq!(body["cursor"], 7);
        assert_eq!(body["has_more"], true);
        assert_eq!(body["session_state"], "awaitingApproval");
        assert_eq!(body["events"][0]["seq"], 7);
    }

    #[test]
    fn codable_form_uses_swift_keys() {
        let event = sample(Some("t1"), &[]);
        let json = serde_json::to_value(&event).unwrap();
        assert_eq!(json["sessionID"], "s1");
        assert_eq!(json["turnID"], "t1");
        assert!(json["timestamp"].is_f64());
        let back: RuntimeEvent = serde_json::from_value(json).unwrap();
        assert_eq!(back, event);
    }

    #[test]
    fn event_type_constants() {
        assert_eq!(
            RuntimeEventType::SESSION_STARTING.raw_value(),
            "session_starting"
        );
        assert_eq!(
            RuntimeEventType::EXIT_CLASSIFIED.raw_value(),
            "exit_classified"
        );
        assert_eq!(
            RuntimeEventType::new("turn_completed"),
            RuntimeEventType::TURN_COMPLETED
        );
    }
}
