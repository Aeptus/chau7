//! Port of `Telemetry/RunContentProvider.swift`: the `RunContentProvider`
//! trait (per-provider transcript extraction) and `ExtractedRunContent`.

use chrono::{DateTime, Utc};

use super::token_metrics::{CostSource, TelemetryMetricState, TokenUsageSource};
use super::turn::{TelemetryToolCall, TelemetryTurn};

/// Provider-specific content extraction. Each AI tool (Claude Code, Codex,
/// ...) stores conversation data differently; implementations read the tool's
/// native storage and return normalized content.
pub trait RunContentProvider: Send + Sync {
    /// Provider identifier this adapter handles (e.g. "claude", "codex").
    fn provider_name(&self) -> &str;

    /// Whether this adapter can handle content extraction for the given provider string.
    fn can_handle(&self, provider: &str) -> bool;

    /// Extract structured content from the provider's storage. Called when a
    /// run completes.
    ///
    /// - `run_id`: the telemetry run's id; use it as the parent id on all
    ///   turns and tool calls.
    /// - `session_id`: the AI tool's session id (e.g. Claude's resume id).
    /// - `cwd`: working directory of the run.
    /// - `started_at`: run start time (disambiguates multiple sessions).
    fn extract_content(
        &self,
        run_id: &str,
        session_id: Option<&str>,
        cwd: &str,
        started_at: DateTime<Utc>,
    ) -> Option<ExtractedRunContent>;
}

/// Normalized content extracted from a provider's native storage.
#[derive(Debug, Clone, PartialEq)]
pub struct ExtractedRunContent {
    pub model: Option<String>,
    pub turns: Vec<TelemetryTurn>,
    pub total_input_tokens: Option<i64>,
    pub total_cached_input_tokens: Option<i64>,
    pub total_output_tokens: Option<i64>,
    pub total_reasoning_output_tokens: Option<i64>,
    pub cost_usd: Option<f64>,
    pub token_usage_source: Option<TokenUsageSource>,
    pub token_usage_state: TelemetryMetricState,
    pub cost_source: Option<CostSource>,
    pub cost_state: TelemetryMetricState,
    pub raw_transcript_ref: Option<String>,
    pub tool_calls: Vec<TelemetryToolCall>,
}

impl Default for ExtractedRunContent {
    /// Same defaults as the Swift initializer (metric states `missing`).
    fn default() -> Self {
        Self {
            model: None,
            turns: Vec::new(),
            total_input_tokens: None,
            total_cached_input_tokens: None,
            total_output_tokens: None,
            total_reasoning_output_tokens: None,
            cost_usd: None,
            token_usage_source: None,
            token_usage_state: TelemetryMetricState::Missing,
            cost_source: None,
            cost_state: TelemetryMetricState::Missing,
            raw_transcript_ref: None,
            tool_calls: Vec::new(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_content_is_missing() {
        let c = ExtractedRunContent::default();
        assert_eq!(c.token_usage_state, TelemetryMetricState::Missing);
        assert_eq!(c.cost_state, TelemetryMetricState::Missing);
        assert!(c.turns.is_empty());
    }

    struct Fixed;
    impl RunContentProvider for Fixed {
        fn provider_name(&self) -> &str {
            "claude"
        }
        fn can_handle(&self, provider: &str) -> bool {
            provider == "claude"
        }
        fn extract_content(
            &self,
            _run_id: &str,
            _session_id: Option<&str>,
            _cwd: &str,
            _started_at: DateTime<Utc>,
        ) -> Option<ExtractedRunContent> {
            None
        }
    }

    #[test]
    fn provider_trait_is_object_safe() {
        let p: Box<dyn RunContentProvider> = Box::new(Fixed);
        assert!(p.can_handle("claude"));
        assert!(!p.can_handle("codex"));
        assert_eq!(p.provider_name(), "claude");
        assert!(p.extract_content("r", None, "/", Utc::now()).is_none());
    }
}
