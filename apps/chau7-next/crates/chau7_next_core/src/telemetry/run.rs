//! Port of `Telemetry/TelemetryRun.swift`: `TelemetryRun` (one AI tool
//! invocation from process start to exit) and `TelemetryRunFilter`.
//!
//! JSON keys match the Swift synthesized `Codable` (camelCase, `nil` fields
//! omitted). Dates use the `.iso8601` strategy of the telemetry query service.

use std::collections::HashMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

use super::date_codec;
use super::token_metrics::{CostSource, TelemetryMetricState, TokenUsage, TokenUsageSource};

/// `UUID().uuidString`: uppercase hyphenated.
pub fn new_uuid_string() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}

fn default_missing() -> TelemetryMetricState {
    TelemetryMetricState::Missing
}

/// A single AI tool invocation from process start to exit.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TelemetryRun {
    pub id: String,
    #[serde(default, rename = "sessionID", skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    #[serde(default, rename = "tabID", skip_serializing_if = "Option::is_none")]
    pub tab_id: Option<String>,
    pub provider: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    pub cwd: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repo_path: Option<String>,
    #[serde(with = "date_codec::iso8601")]
    pub started_at: DateTime<Utc>,
    #[serde(
        default,
        with = "date_codec::iso8601_opt",
        skip_serializing_if = "Option::is_none"
    )]
    pub ended_at: Option<DateTime<Utc>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub exit_status: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_input_tokens: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_cached_input_tokens: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_output_tokens: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub total_reasoning_output_tokens: Option<i64>,
    #[serde(default, rename = "costUSD", skip_serializing_if = "Option::is_none")]
    pub cost_usd: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub token_usage_source: Option<TokenUsageSource>,
    #[serde(default = "default_missing")]
    pub token_usage_state: TelemetryMetricState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cost_source: Option<CostSource>,
    #[serde(default = "default_missing")]
    pub cost_state: TelemetryMetricState,
    pub turn_count: i64,
    pub tags: Vec<String>,
    pub metadata: HashMap<String, String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raw_transcript_ref: Option<String>,
    #[serde(
        default,
        rename = "parentRunID",
        skip_serializing_if = "Option::is_none"
    )]
    pub parent_run_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_message: Option<String>,
}

impl TelemetryRun {
    /// Same defaults as the Swift initializer: fresh uppercase UUID id,
    /// `started_at` now, metric states `missing`, no turns, tags or metadata.
    pub fn new(provider: impl Into<String>, cwd: impl Into<String>) -> Self {
        Self {
            id: new_uuid_string(),
            session_id: None,
            tab_id: None,
            provider: provider.into(),
            model: None,
            cwd: cwd.into(),
            repo_path: None,
            started_at: Utc::now(),
            ended_at: None,
            duration_ms: None,
            exit_status: None,
            total_input_tokens: None,
            total_cached_input_tokens: None,
            total_output_tokens: None,
            total_reasoning_output_tokens: None,
            cost_usd: None,
            token_usage_source: None,
            token_usage_state: TelemetryMetricState::Missing,
            cost_source: None,
            cost_state: TelemetryMetricState::Missing,
            turn_count: 0,
            tags: Vec::new(),
            metadata: HashMap::new(),
            raw_transcript_ref: None,
            parent_run_id: None,
            error_message: None,
        }
    }

    pub fn token_usage(&self) -> TokenUsage {
        TokenUsage::new(
            self.total_input_tokens.unwrap_or(0),
            self.total_cached_input_tokens.unwrap_or(0),
            self.total_output_tokens.unwrap_or(0),
            self.total_reasoning_output_tokens.unwrap_or(0),
        )
    }
}

/// Filter criteria for querying runs.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TelemetryRunFilter {
    pub session_id: Option<String>,
    pub repo_path: Option<String>,
    pub provider: Option<String>,
    pub after: Option<DateTime<Utc>>,
    pub before: Option<DateTime<Utc>>,
    pub tags: Option<Vec<String>>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_run_has_swift_defaults() {
        let run = TelemetryRun::new("claude", "/tmp");
        assert_eq!(run.token_usage_state, TelemetryMetricState::Missing);
        assert_eq!(run.cost_state, TelemetryMetricState::Missing);
        assert_eq!(run.turn_count, 0);
        assert_eq!(run.id, run.id.to_uppercase());
        assert_eq!(run.id.len(), 36);
        assert_eq!(run.token_usage(), TokenUsage::default());
    }

    #[test]
    fn json_keys_match_swift_codable() {
        let mut run = TelemetryRun::new("claude", "/tmp");
        run.session_id = Some("s".into());
        run.cost_usd = Some(1.5);
        run.parent_run_id = Some("p".into());
        run.started_at = date_codec::parse_iso8601(Some("2026-04-01T09:00:00.250Z")).unwrap();
        let json = serde_json::to_value(&run).unwrap();
        assert_eq!(json["sessionID"], "s");
        assert_eq!(json["costUSD"], 1.5);
        assert_eq!(json["parentRunID"], "p");
        assert_eq!(json["startedAt"], "2026-04-01T09:00:00Z");
        assert_eq!(json["tokenUsageState"], "missing");
        assert!(json.get("model").is_none());
        let back: TelemetryRun = serde_json::from_value(json).unwrap();
        assert_eq!(back.session_id.as_deref(), Some("s"));
    }
}
