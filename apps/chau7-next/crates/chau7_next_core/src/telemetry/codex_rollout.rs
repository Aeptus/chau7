//! Port of `Telemetry/CodexRolloutParser.swift`: parse Codex rollout JSONL
//! into model, turns, tool calls and run-local token usage.

use chrono::{DateTime, Utc};
use serde_json::{Map, Value};

use super::date_codec;
use super::run::new_uuid_string;
use super::token_metrics::TokenUsage;
use super::transcript_util::{as_int, as_object_array, as_string, split_newlines};
use super::turn::{TelemetryToolCall, TelemetryTurn, ToolCallStatus, TurnRole};

#[derive(Debug, Clone, Default)]
pub struct ParseResult {
    pub model: Option<String>,
    pub turns: Vec<TelemetryTurn>,
    pub tool_calls: Vec<TelemetryToolCall>,
    pub token_usage: TokenUsage,
}

pub fn parse(jsonl: &str, run_id: &str, started_at: DateTime<Utc>) -> ParseResult {
    let mut model: Option<String> = None;
    let mut turns: Vec<TelemetryTurn> = Vec::new();
    let mut tool_calls: Vec<TelemetryToolCall> = Vec::new();
    let mut token_usage = TokenUsage::default();
    let mut turn_index: i64 = 0;
    let mut call_index: i64 = 0;
    let empty = Map::new();

    for line in split_newlines(jsonl).filter(|l| !l.is_empty()) {
        let Ok(Value::Object(obj)) = serde_json::from_str::<Value>(line) else {
            continue;
        };

        let kind = obj.get("type").and_then(Value::as_str).unwrap_or("");
        let payload = match obj.get("payload") {
            Some(Value::Object(p)) => p,
            _ => &empty,
        };
        let timestamp = parse_date(obj.get("timestamp").and_then(Value::as_str));
        let in_run_window = timestamp.is_none_or(|t| t >= started_at);

        match kind {
            "turn_context" => {
                if model.is_none()
                    && let Some(value) = payload.get("model").and_then(Value::as_str)
                {
                    model = Some(value.to_string());
                }
            }
            "response_item" => {
                if !in_run_window {
                    continue;
                }
                let role = match payload.get("role").and_then(Value::as_str).unwrap_or("") {
                    "user" => TurnRole::Human,
                    "assistant" => TurnRole::Assistant,
                    "developer" | "system" => TurnRole::System,
                    _ => continue,
                };

                let mut content_text = String::new();
                let mut turn_tool_calls: Vec<TelemetryToolCall> = Vec::new();
                if let Some(blocks) = as_object_array(payload.get("content")) {
                    for block in blocks {
                        let block_type = block.get("type").and_then(Value::as_str).unwrap_or("");
                        match block_type {
                            "output_text" | "input_text" => {
                                if let Some(text) = block.get("text").and_then(Value::as_str) {
                                    if !content_text.is_empty() {
                                        content_text.push('\n');
                                    }
                                    content_text.push_str(text);
                                }
                            }
                            "function_call" => {
                                let mut call = TelemetryToolCall::new(
                                    run_id,
                                    format!("{}-t{}", run_id, turn_index),
                                    as_string(block.get("name"))
                                        .unwrap_or_else(|| "unknown".to_string()),
                                );
                                call.id =
                                    as_string(block.get("call_id")).unwrap_or_else(new_uuid_string);
                                call.arguments = as_string(block.get("arguments"));
                                call.status = ToolCallStatus::Success;
                                call.call_index = call_index;
                                turn_tool_calls.push(call.clone());
                                tool_calls.push(call);
                                call_index += 1;
                            }
                            "function_call_output" => {
                                if let Some(output) = block.get("output").and_then(Value::as_str) {
                                    if !content_text.is_empty() {
                                        content_text.push('\n');
                                    }
                                    content_text.push_str("[tool_result] ");
                                    content_text.push_str(output);
                                }
                            }
                            _ => {}
                        }
                    }
                }

                let mut turn = TelemetryTurn::new(run_id, turn_index, role);
                turn.id = format!("{}-t{}", run_id, turn_index);
                turn.content = if content_text.is_empty() {
                    None
                } else {
                    Some(content_text)
                };
                turn.tool_calls = turn_tool_calls;
                turn.timestamp = timestamp;
                turns.push(turn);
                turn_index += 1;
            }
            "event_msg" => {
                if !in_run_window
                    || payload.get("type").and_then(Value::as_str) != Some("token_count")
                {
                    continue;
                }
                let Some(Value::Object(info)) = payload.get("info") else {
                    continue;
                };
                let Some(Value::Object(last)) = info.get("last_token_usage") else {
                    continue;
                };
                token_usage.add(&TokenUsage::provider(
                    "codex",
                    as_int(last.get("input_tokens")),
                    as_int(last.get("output_tokens")),
                    None,
                    as_int(last.get("cached_input_tokens")),
                    as_int(last.get("reasoning_output_tokens")),
                ));
            }
            _ => {}
        }
    }

    ParseResult {
        model,
        turns,
        tool_calls,
        token_usage,
    }
}

pub fn parse_date(value: Option<&str>) -> Option<DateTime<Utc>> {
    date_codec::parse_iso8601(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_counts_only_run_local_token_deltas() {
        let started_at = parse_date(Some("2026-04-01T10:00:00.000Z")).unwrap();
        let jsonl = r#"{"timestamp":"2026-04-01T09:59:58.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":0,"output_tokens":200,"reasoning_output_tokens":10},"total_token_usage":{"input_tokens":500,"output_tokens":200}}}}
{"timestamp":"2026-04-01T10:00:01.000Z","type":"turn_context","payload":{"model":"gpt-5-codex"}}
{"timestamp":"2026-04-01T10:00:02.000Z","type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"commit"}]}}
{"timestamp":"2026-04-01T10:00:03.000Z","type":"response_item","payload":{"role":"assistant","content":[{"type":"output_text","text":"done"},{"type":"function_call","call_id":"call-1","name":"apply_patch","arguments":"{}"}]}}
{"timestamp":"2026-04-01T10:00:04.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":50,"cached_input_tokens":8,"output_tokens":20,"reasoning_output_tokens":3},"total_token_usage":{"input_tokens":550,"output_tokens":220}}}}
{"timestamp":"2026-04-01T10:00:05.000Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":30,"cached_input_tokens":2,"output_tokens":10,"reasoning_output_tokens":1},"total_token_usage":{"input_tokens":580,"output_tokens":230}}}}"#;

        let parsed = parse(jsonl, "run-1", started_at);

        assert_eq!(parsed.model.as_deref(), Some("gpt-5-codex"));
        assert_eq!(parsed.turns.len(), 2);
        assert_eq!(parsed.tool_calls.len(), 1);
        assert_eq!(parsed.token_usage.input_tokens, 70);
        assert_eq!(parsed.token_usage.cached_input_tokens, 10);
        assert_eq!(parsed.token_usage.output_tokens, 26);
        assert_eq!(parsed.token_usage.reasoning_output_tokens, 4);
    }

    #[test]
    fn parse_maps_roles_ids_and_tool_output() {
        let started_at = parse_date(Some("2026-04-01T10:00:00Z")).unwrap();
        let jsonl = [
            r#"{"type":"response_item","payload":{"role":"developer","content":[{"type":"input_text","text":"rules"}]}}"#,
            r#"{"type":"response_item","payload":{"role":"assistant","content":[{"type":"function_call","name":"shell","arguments":"{\"a\":1}"},{"type":"function_call_output","output":"fine"}]}}"#,
            r#"{"type":"response_item","payload":{"role":"tool","content":[]}}"#,
            r#"{"timestamp":"2026-04-01T09:00:00Z","type":"response_item","payload":{"role":"user","content":[{"type":"input_text","text":"old"}]}}"#,
        ]
        .join("\n");

        let parsed = parse(&jsonl, "r", started_at);

        assert_eq!(parsed.turns.len(), 2);
        assert_eq!(parsed.turns[0].role, TurnRole::System);
        assert_eq!(parsed.turns[0].id, "r-t0");
        assert_eq!(
            parsed.turns[1].content.as_deref(),
            Some("[tool_result] fine")
        );
        assert_eq!(parsed.tool_calls[0].tool_name, "shell");
        assert_eq!(
            parsed.tool_calls[0].arguments.as_deref(),
            Some(r#"{"a":1}"#)
        );
        assert_eq!(parsed.tool_calls[0].turn_id, "r-t1");
        assert!(parsed.model.is_none());
    }
}
