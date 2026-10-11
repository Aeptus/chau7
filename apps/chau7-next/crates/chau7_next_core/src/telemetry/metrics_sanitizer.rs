//! Port of `Telemetry/TelemetryMetricsSanitizer.swift`: drop missing or
//! implausible token totals from extracted run content.

use super::run_content::ExtractedRunContent;
use super::token_metrics::{CostSource, TelemetryMetricState, TokenUsage};

const MAX_SINGLE_FIELD_TOKENS: i64 = 100_000_000;
const MAX_BILLABLE_TOKENS: i64 = 150_000_000;

/// Returns the sanitized content and an optional warning.
pub fn sanitize(
    content: &ExtractedRunContent,
    provider: &str,
) -> (ExtractedRunContent, Option<String>) {
    let mut sanitized = content.clone();

    let usage = TokenUsage::new(
        sanitized.total_input_tokens.unwrap_or(0),
        sanitized.total_cached_input_tokens.unwrap_or(0),
        sanitized.total_output_tokens.unwrap_or(0),
        sanitized.total_reasoning_output_tokens.unwrap_or(0),
    );

    if !usage.has_any_tokens() {
        sanitized.total_input_tokens = None;
        sanitized.total_cached_input_tokens = None;
        sanitized.total_output_tokens = None;
        sanitized.total_reasoning_output_tokens = None;
        sanitized.token_usage_state = TelemetryMetricState::Missing;
    } else if is_implausible(&usage) {
        sanitized.total_input_tokens = None;
        sanitized.total_cached_input_tokens = None;
        sanitized.total_output_tokens = None;
        sanitized.total_reasoning_output_tokens = None;
        sanitized.cost_usd = None;
        sanitized.token_usage_state = TelemetryMetricState::Invalid;
        sanitized.cost_state = TelemetryMetricState::Missing;
        sanitized.cost_source = Some(CostSource::Unavailable);
        let warning = format!(
            "invalidated implausible token totals for provider={} total={}",
            provider,
            usage.total_billable_tokens()
        );
        return (sanitized, Some(warning));
    }

    if sanitized.cost_usd.is_none() {
        sanitized.cost_state = TelemetryMetricState::Missing;
        sanitized.cost_source = Some(CostSource::Unavailable);
    } else if sanitized.cost_state == TelemetryMetricState::Missing {
        sanitized.cost_state = TelemetryMetricState::Complete;
        sanitized.cost_source = Some(sanitized.cost_source.unwrap_or(CostSource::Observed));
    }

    (sanitized, None)
}

fn is_implausible(usage: &TokenUsage) -> bool {
    usage.input_tokens > MAX_SINGLE_FIELD_TOKENS
        || usage.cached_input_tokens > MAX_SINGLE_FIELD_TOKENS
        || usage.output_tokens > MAX_SINGLE_FIELD_TOKENS
        || usage.reasoning_output_tokens > MAX_SINGLE_FIELD_TOKENS
        || usage.total_billable_tokens() > MAX_BILLABLE_TOKENS
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::telemetry::token_metrics::TokenUsageSource;
    use crate::telemetry::turn::{TelemetryTurn, TurnRole};

    fn one_turn() -> Vec<TelemetryTurn> {
        let mut turn = TelemetryTurn::new("run-1", 0, TurnRole::Assistant);
        turn.content = Some("hi".into());
        vec![turn]
    }

    #[test]
    fn sanitize_marks_missing_when_no_tokens_are_present() {
        let content = ExtractedRunContent {
            turns: one_turn(),
            token_usage_source: Some(TokenUsageSource::TranscriptDelta),
            token_usage_state: TelemetryMetricState::Complete,
            cost_source: Some(CostSource::Unavailable),
            cost_state: TelemetryMetricState::Missing,
            ..Default::default()
        };

        let (sanitized, warning) = sanitize(&content, "claude");

        assert_eq!(sanitized.total_input_tokens, None);
        assert_eq!(sanitized.token_usage_state, TelemetryMetricState::Missing);
        assert!(warning.is_none());
    }

    #[test]
    fn sanitize_invalidates_implausible_token_totals() {
        let content = ExtractedRunContent {
            turns: one_turn(),
            total_input_tokens: Some(120_000_000),
            total_output_tokens: Some(10),
            cost_usd: Some(12.34),
            token_usage_source: Some(TokenUsageSource::TranscriptDelta),
            token_usage_state: TelemetryMetricState::Complete,
            cost_source: Some(CostSource::Estimated),
            cost_state: TelemetryMetricState::Complete,
            ..Default::default()
        };

        let (sanitized, warning) = sanitize(&content, "codex");

        assert_eq!(sanitized.token_usage_state, TelemetryMetricState::Invalid);
        assert_eq!(sanitized.cost_state, TelemetryMetricState::Missing);
        assert_eq!(sanitized.total_input_tokens, None);
        assert_eq!(sanitized.cost_usd, None);
        assert_eq!(
            warning.as_deref(),
            Some("invalidated implausible token totals for provider=codex total=120000010")
        );
    }

    #[test]
    fn sanitize_completes_observed_cost_when_state_was_missing() {
        let content = ExtractedRunContent {
            total_input_tokens: Some(10),
            cost_usd: Some(0.5),
            ..Default::default()
        };
        let (sanitized, warning) = sanitize(&content, "claude");
        assert!(warning.is_none());
        assert_eq!(sanitized.cost_state, TelemetryMetricState::Complete);
        assert_eq!(sanitized.cost_source, Some(CostSource::Observed));
    }

    #[test]
    fn sanitize_flags_billable_total_over_limit() {
        let content = ExtractedRunContent {
            total_input_tokens: Some(90_000_000),
            total_cached_input_tokens: Some(90_000_000),
            ..Default::default()
        };
        let (sanitized, warning) = sanitize(&content, "claude");
        assert_eq!(sanitized.token_usage_state, TelemetryMetricState::Invalid);
        assert!(warning.is_some());
    }
}
