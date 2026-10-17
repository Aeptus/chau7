//! Port of `Telemetry/TelemetryTurn.swift`: `TelemetryTurn`,
//! `TelemetryToolCall` and their role and status enums.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::date_codec;
use super::run::new_uuid_string;
use super::token_metrics::TokenUsage;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TurnRole {
    #[serde(rename = "human")]
    Human,
    #[serde(rename = "assistant")]
    Assistant,
    #[serde(rename = "system")]
    System,
    #[serde(rename = "tool_result")]
    ToolResult,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ToolCallStatus {
    Success,
    Error,
    Denied,
}

/// A single prompt-response cycle within a run.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TelemetryTurn {
    pub id: String,
    #[serde(rename = "runID")]
    pub run_id: String,
    pub turn_index: i64,
    pub role: TurnRole,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub content: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub input_tokens: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cached_input_tokens: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_creation_input_tokens: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cache_read_input_tokens: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub output_tokens: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reasoning_output_tokens: Option<i64>,
    pub tool_calls: Vec<TelemetryToolCall>,
    #[serde(
        default,
        with = "date_codec::iso8601_opt",
        skip_serializing_if = "Option::is_none"
    )]
    pub timestamp: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
}

impl TelemetryTurn {
    /// Same defaults as the Swift initializer (fresh uppercase UUID id).
    pub fn new(run_id: impl Into<String>, turn_index: i64, role: TurnRole) -> Self {
        Self {
            id: new_uuid_string(),
            run_id: run_id.into(),
            turn_index,
            role,
            content: None,
            input_tokens: None,
            cached_input_tokens: None,
            cache_creation_input_tokens: None,
            cache_read_input_tokens: None,
            output_tokens: None,
            reasoning_output_tokens: None,
            tool_calls: Vec::new(),
            timestamp: None,
            duration_ms: None,
        }
    }

    pub fn token_usage(&self) -> TokenUsage {
        TokenUsage::canonical(
            self.input_tokens.unwrap_or(0),
            self.cached_input_tokens.unwrap_or(0),
            self.cache_creation_input_tokens.unwrap_or(0),
            self.cache_read_input_tokens.unwrap_or(0),
            self.output_tokens.unwrap_or(0),
            self.reasoning_output_tokens.unwrap_or(0),
        )
    }
}

/// A single tool invocation within a turn.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TelemetryToolCall {
    pub id: String,
    #[serde(rename = "runID")]
    pub run_id: String,
    #[serde(rename = "turnID")]
    pub turn_id: String,
    pub tool_name: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub arguments: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub result: Option<String>,
    pub status: ToolCallStatus,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    pub call_index: i64,
}

impl TelemetryToolCall {
    /// Same defaults as the Swift initializer: fresh uppercase UUID id,
    /// status `success`, call index 0.
    pub fn new(
        run_id: impl Into<String>,
        turn_id: impl Into<String>,
        tool_name: impl Into<String>,
    ) -> Self {
        Self {
            id: new_uuid_string(),
            run_id: run_id.into(),
            turn_id: turn_id.into(),
            tool_name: tool_name.into(),
            arguments: None,
            result: None,
            status: ToolCallStatus::Success,
            duration_ms: None,
            call_index: 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn turn_defaults_and_token_usage() {
        let mut turn = TelemetryTurn::new("run-1", 0, TurnRole::Assistant);
        assert_eq!(turn.token_usage(), TokenUsage::default());
        turn.input_tokens = Some(5);
        assert_eq!(turn.token_usage().input_tokens, 5);
    }

    #[test]
    fn json_keys_and_enum_raw_values() {
        let mut turn = TelemetryTurn::new("run-1", 2, TurnRole::ToolResult);
        turn.tool_calls
            .push(TelemetryToolCall::new("run-1", "run-1-t2", "Read"));
        let json = serde_json::to_value(&turn).unwrap();
        assert_eq!(json["runID"], "run-1");
        assert_eq!(json["turnIndex"], 2);
        assert_eq!(json["role"], "tool_result");
        assert_eq!(json["toolCalls"][0]["turnID"], "run-1-t2");
        assert_eq!(json["toolCalls"][0]["status"], "success");
        assert_eq!(json["toolCalls"][0]["callIndex"], 0);
    }
}
