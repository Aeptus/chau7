//! Port of `Telemetry/ClaudeTranscriptUsageParser.swift`: parse Claude Code
//! transcript JSONL into model, turns, tool calls and deduplicated token usage.
//!
//! Differences from Swift: tool-call `arguments` are re-serialized with
//! `serde_json` (compact, keys sorted) instead of `JSONSerialization` (key
//! order unspecified, `/` escaped as `\/`); both are valid JSON for the same
//! value.

use std::collections::HashSet;

use chrono::{DateTime, Utc};
use serde_json::{Map, Value};

use super::date_codec;
use super::run::new_uuid_string;
use super::token_metrics::TokenUsage;
use super::transcript_util::{as_int, as_object_array, as_string, split_newlines};
use super::turn::{TelemetryToolCall, TelemetryTurn, ToolCallStatus, TurnRole};

/// Accumulated parse state. Pass the same state to successive `ingest` calls
/// to parse a transcript incrementally.
#[derive(Debug, Clone, Default)]
pub struct State {
    pub model: Option<String>,
    pub turns: Vec<TelemetryTurn>,
    pub tool_calls: Vec<TelemetryToolCall>,
    pub token_usage: TokenUsage,
    pub turn_index: i64,
    pub call_index: i64,
    pub seen_usage_keys: HashSet<String>,
}

impl State {
    pub fn new() -> Self {
        Self::default()
    }
}

pub fn ingest(jsonl: &str, run_id: &str, started_at: DateTime<Utc>, state: &mut State) {
    for line in split_newlines(jsonl).filter(|l| !l.is_empty()) {
        let Ok(Value::Object(obj)) = serde_json::from_str::<Value>(line) else {
            continue;
        };
        let Some(Value::Object(message)) = obj.get("message") else {
            continue;
        };

        let timestamp = parse_date(obj.get("timestamp").and_then(Value::as_str));
        if let Some(ts) = timestamp
            && ts < started_at
        {
            continue;
        }

        let role_str = message
            .get("role")
            .and_then(Value::as_str)
            .or_else(|| obj.get("type").and_then(Value::as_str))
            .unwrap_or("");
        let role = match role_str {
            "user" => TurnRole::Human,
            "assistant" => TurnRole::Assistant,
            "system" => TurnRole::System,
            _ => continue,
        };

        if let Some(model) = message.get("model").and_then(Value::as_str)
            && state.model.is_none()
        {
            state.model = Some(model.to_string());
        }

        let usage_key = request_usage_key(&obj, message);
        let should_count_usage = role == TurnRole::Assistant
            && match usage_key {
                Some(key) => state.seen_usage_keys.insert(key),
                None => true,
            };

        let mut turn_usage = TokenUsage::default();
        if should_count_usage && let Some(Value::Object(usage)) = message.get("usage") {
            turn_usage = TokenUsage::provider(
                "anthropic",
                as_int(usage.get("input_tokens")),
                as_int(usage.get("output_tokens")),
                as_int(usage.get("cache_creation_input_tokens")),
                as_int(usage.get("cache_read_input_tokens")),
                as_int(usage.get("reasoning_output_tokens")),
            );
            state.token_usage.add(&turn_usage);
        }

        let mut content_text = String::new();
        let mut turn_tool_calls: Vec<TelemetryToolCall> = Vec::new();

        if let Some(blocks) = as_object_array(message.get("content")) {
            for block in blocks {
                let block_type = block.get("type").and_then(Value::as_str).unwrap_or("");
                match block_type {
                    "text" => {
                        if let Some(text) = block.get("text").and_then(Value::as_str) {
                            if !content_text.is_empty() {
                                content_text.push('\n');
                            }
                            content_text.push_str(text);
                        }
                    }
                    "tool_use" => {
                        let call = tool_use_call(block, run_id, state);
                        turn_tool_calls.push(call.clone());
                        state.tool_calls.push(call);
                        state.call_index += 1;
                    }
                    "tool_result" => {
                        if let Some(result) = block.get("content").and_then(Value::as_str) {
                            if !content_text.is_empty() {
                                content_text.push('\n');
                            }
                            content_text.push_str("[tool_result] ");
                            content_text.push_str(result);
                        }
                    }
                    _ => {}
                }
            }
        } else if let Some(content) = message.get("content").and_then(Value::as_str) {
            content_text = content.to_string();
        }

        let turn_id = format!("{}-t{}", run_id, state.turn_index);
        let mut turn = TelemetryTurn::new(run_id, state.turn_index, role);
        turn.id = turn_id;
        turn.content = if content_text.is_empty() {
            None
        } else {
            Some(content_text)
        };
        if should_count_usage {
            turn.input_tokens = Some(turn_usage.input_tokens);
            turn.cached_input_tokens = Some(turn_usage.cached_input_tokens);
            turn.output_tokens = Some(turn_usage.output_tokens);
            turn.reasoning_output_tokens = Some(turn_usage.reasoning_output_tokens);
        }
        turn.tool_calls = turn_tool_calls;
        turn.timestamp = timestamp;
        state.turns.push(turn);
        state.turn_index += 1;
    }
}

fn tool_use_call(block: &Map<String, Value>, run_id: &str, state: &State) -> TelemetryToolCall {
    let arguments = match block.get("input") {
        Some(input @ (Value::Object(_) | Value::Array(_))) => serde_json::to_string(input).ok(),
        _ => None,
    };
    let mut call = TelemetryToolCall::new(
        run_id,
        format!("{}-t{}", run_id, state.turn_index),
        as_string(block.get("name")).unwrap_or_else(|| "unknown".to_string()),
    );
    call.id = as_string(block.get("id")).unwrap_or_else(new_uuid_string);
    call.arguments = arguments;
    call.status = ToolCallStatus::Success;
    call.call_index = state.call_index;
    call
}

/// Identity used to count a request's usage once: `requestId`, then
/// `message.id`, then `uuid` (empty strings are skipped).
pub fn request_usage_key(obj: &Map<String, Value>, message: &Map<String, Value>) -> Option<String> {
    for source in [obj.get("requestId"), message.get("id"), obj.get("uuid")] {
        if let Some(s) = source.and_then(Value::as_str)
            && !s.is_empty()
        {
            return Some(s.to_string());
        }
    }
    None
}

pub fn parse_date(value: Option<&str>) -> Option<DateTime<Utc>> {
    date_codec::parse_iso8601(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ingest_deduplicates_repeated_assistant_usage_by_request_identity() {
        let started_at = parse_date(Some("2026-04-01T09:00:00.000Z")).unwrap();
        let jsonl = [
            concat!(
                r#"{"timestamp":"2026-04-01T08:59:59.000Z","message":{"role":"assistant","model":"claude-sonnet","usage":{"input_tokens":999,"cache_creation_input_tokens":1,"cache_read_input_tokens":2,"output_tokens":3,"reasoning_output_tokens":4},"content":["#,
                r#"{"type":"text","text":"old"}]},"requestId":"req-old"}"#
            ),
            concat!(
                r#"{"timestamp":"2026-04-01T09:00:01.000Z","message":{"id":"msg-1","role":"assistant","model":"claude-sonnet","usage":{"input_tokens":100,"cache_creation_input_tokens":10,"cache_read_input_tokens":5,"output_tokens":20,"reasoning_output_tokens":7},"content":["#,
                r#"{"type":"text","text":"answer"}]},"requestId":"req-1"}"#
            ),
            concat!(
                r#"{"timestamp":"2026-04-01T09:00:02.000Z","message":{"id":"msg-1","role":"assistant","model":"claude-sonnet","usage":{"input_tokens":100,"cache_creation_input_tokens":10,"cache_read_input_tokens":5,"output_tokens":20,"reasoning_output_tokens":7},"content":["#,
                r#"{"type":"tool_use","id":"tool-1","name":"Read","input":{"path":"README.md"}}]},"requestId":"req-1"}"#
            ),
            r#"{"timestamp":"2026-04-01T09:00:03.000Z","message":{"role":"user","content":"thanks"}}"#,
        ]
        .join("\n");

        let mut state = State::new();
        ingest(&jsonl, "run-1", started_at, &mut state);

        assert_eq!(state.model.as_deref(), Some("claude-sonnet"));
        assert_eq!(state.turns.len(), 3);
        assert_eq!(state.tool_calls.len(), 1);
        assert_eq!(state.token_usage.input_tokens, 100);
        assert_eq!(state.token_usage.cached_input_tokens, 15);
        assert_eq!(state.token_usage.output_tokens, 20);
        assert_eq!(state.token_usage.reasoning_output_tokens, 7);
        assert_eq!(state.turns[0].input_tokens, Some(100));
        assert_eq!(
            state.turns[1].input_tokens, None,
            "duplicate assistant fragment should not count usage twice"
        );
    }

    #[test]
    fn ingest_builds_turn_ids_tool_calls_and_user_string_content() {
        let started_at = parse_date(Some("2026-04-01T09:00:00Z")).unwrap();
        let jsonl = [
            r#"{"type":"user","message":{"content":"hello"}}"#,
            r#"{"message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"path":"a"}},{"type":"tool_result","content":"ok"}]},"uuid":"u1"}"#,
            "not json",
            r#"{"message":{"role":"other","content":"x"}}"#,
        ]
        .join("\r\n");

        let mut state = State::new();
        ingest(&jsonl, "run-9", started_at, &mut state);

        assert_eq!(state.turns.len(), 2);
        assert_eq!(state.turns[0].id, "run-9-t0");
        assert_eq!(state.turns[0].role, TurnRole::Human);
        assert_eq!(state.turns[0].content.as_deref(), Some("hello"));
        assert_eq!(state.turns[1].id, "run-9-t1");
        assert_eq!(state.turns[1].content.as_deref(), Some("[tool_result] ok"));
        let call = &state.tool_calls[0];
        assert_eq!(call.id, "t1");
        assert_eq!(call.turn_id, "run-9-t1");
        assert_eq!(call.arguments.as_deref(), Some(r#"{"path":"a"}"#));
        assert_eq!(call.call_index, 0);
        assert_eq!(state.turn_index, 2);
        assert_eq!(state.call_index, 1);
    }

    #[test]
    fn request_usage_key_prefers_request_id_then_message_id_then_uuid() {
        let obj: Value = serde_json::json!({"requestId":"", "uuid":"u"});
        let msg: Value = serde_json::json!({"id":"m"});
        let (obj, msg) = (obj.as_object().unwrap(), msg.as_object().unwrap());
        assert_eq!(request_usage_key(obj, msg).as_deref(), Some("m"));
        let msg2: Value = serde_json::json!({});
        assert_eq!(
            request_usage_key(obj, msg2.as_object().unwrap()).as_deref(),
            Some("u")
        );
        let empty: Value = serde_json::json!({});
        assert_eq!(
            request_usage_key(empty.as_object().unwrap(), msg2.as_object().unwrap()),
            None
        );
    }
}
