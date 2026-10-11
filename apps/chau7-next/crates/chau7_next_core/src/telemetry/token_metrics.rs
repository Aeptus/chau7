//! Port of `Telemetry/TokenMetrics.swift`: canonical token accounting and the
//! metric and cost state enums.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TelemetryMetricState {
    Complete,
    Estimated,
    Partial,
    Missing,
    Invalid,
}

impl TelemetryMetricState {
    pub const ALL: [Self; 5] = [
        Self::Complete,
        Self::Estimated,
        Self::Partial,
        Self::Missing,
        Self::Invalid,
    ];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum TokenUsageSource {
    #[serde(rename = "proxy")]
    Proxy,
    #[serde(rename = "transcriptDelta")]
    TranscriptDelta,
    #[serde(rename = "transcriptSnapshot")]
    TranscriptSnapshot,
    #[serde(rename = "providerEstimate")]
    ProviderEstimate,
    #[serde(rename = "unknown")]
    Unknown,
}

impl TokenUsageSource {
    pub const ALL: [Self; 5] = [
        Self::Proxy,
        Self::TranscriptDelta,
        Self::TranscriptSnapshot,
        Self::ProviderEstimate,
        Self::Unknown,
    ];
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum CostSource {
    Observed,
    Estimated,
    Unavailable,
}

impl CostSource {
    pub const ALL: [Self; 3] = [Self::Observed, Self::Estimated, Self::Unavailable];
}

/// Canonical token accounting shared across runtime, proxy, and telemetry persistence.
///
/// - `input_tokens`: uncached input tokens sent to the model
/// - `cached_input_tokens`: provider-reported cached or cache-read input tokens
/// - `output_tokens`: normal model output tokens
/// - `reasoning_output_tokens`: hidden or reasoning-only output tokens when reported
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TokenUsage {
    pub input_tokens: i64,
    pub cached_input_tokens: i64,
    #[serde(default)]
    pub cache_creation_input_tokens: i64,
    #[serde(default)]
    pub cache_read_input_tokens: i64,
    pub output_tokens: i64,
    pub reasoning_output_tokens: i64,
}

impl TokenUsage {
    /// Negative inputs are clamped to zero, like the Swift initializer.
    pub fn new(input: i64, cached_input: i64, output: i64, reasoning_output: i64) -> Self {
        Self {
            input_tokens: input.max(0),
            cached_input_tokens: cached_input.max(0),
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
            output_tokens: output.max(0),
            reasoning_output_tokens: reasoning_output.max(0),
        }
    }

    /// Already canonical counters from persistence. Preserve uncategorized
    /// legacy cache without subtracting inclusive input a second time.
    pub fn canonical(
        input: i64,
        cached: i64,
        creation: i64,
        read: i64,
        output: i64,
        reasoning: i64,
    ) -> Self {
        let mut usage = Self::new(input, cached, output, reasoning);
        usage.cache_creation_input_tokens = creation.max(0);
        usage.cache_read_input_tokens = read.max(0);
        usage.cached_input_tokens = usage
            .cached_input_tokens
            .max(usage.cache_creation_input_tokens + usage.cache_read_input_tokens);
        usage
    }
    pub fn provider(
        provider: &str,
        input: Option<i64>,
        output: Option<i64>,
        creation: Option<i64>,
        read: Option<i64>,
        reasoning: Option<i64>,
    ) -> Self {
        let key = provider.trim().to_ascii_lowercase();
        let read = read.unwrap_or(0).max(0);
        let creation = creation.unwrap_or(0).max(0);
        let reasoning = reasoning.unwrap_or(0).max(0);
        let input = input.unwrap_or(0).max(0);
        let output = output.unwrap_or(0).max(0);
        Self {
            input_tokens: if matches!(
                key.as_str(),
                "openai" | "codex" | "chatgpt" | "gemini" | "google"
            ) {
                (input - read).max(0)
            } else {
                input
            },
            output_tokens: if matches!(key.as_str(), "openai" | "codex" | "chatgpt") {
                (output - reasoning).max(0)
            } else {
                output
            },
            cache_creation_input_tokens: creation,
            cache_read_input_tokens: read,
            cached_input_tokens: creation + read,
            reasoning_output_tokens: reasoning,
        }
    }
    pub fn uncategorized_cache(&self) -> i64 {
        (self.cached_input_tokens - self.cache_creation_input_tokens - self.cache_read_input_tokens)
            .max(0)
    }
    pub fn has_any_tokens(&self) -> bool {
        self.total_tokens() > 0
    }

    /// Input + output shown in most user-facing summaries.
    pub fn total_visible_tokens(&self) -> i64 {
        self.input_tokens + self.output_tokens
    }

    /// Best effort billable total when providers expose cache and reasoning counters.
    pub fn total_billable_tokens(&self) -> i64 {
        self.input_tokens
            + self.cached_input_tokens
            + self.output_tokens
            + self.reasoning_output_tokens
    }

    /// Backward-compatible aggregate used by older surfaces.
    pub fn total_tokens(&self) -> i64 {
        self.total_visible_tokens()
    }

    pub fn add(&mut self, other: &TokenUsage) {
        self.input_tokens += other.input_tokens;
        self.cached_input_tokens += other.cached_input_tokens;
        self.cache_creation_input_tokens += other.cache_creation_input_tokens;
        self.cache_read_input_tokens += other.cache_read_input_tokens;
        self.output_tokens += other.output_tokens;
        self.reasoning_output_tokens += other.reasoning_output_tokens;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_inclusive_counters_are_normalized_once() {
        let codex = TokenUsage::provider(" CODEX ", Some(100), Some(40), None, Some(30), Some(10));
        assert_eq!(codex.input_tokens, 70);
        assert_eq!(codex.output_tokens, 30);
        assert_eq!(codex.cache_read_input_tokens, 30);
        assert_eq!(codex.reasoning_output_tokens, 10);
        assert_eq!(codex.total_billable_tokens(), 140);
        let claude = TokenUsage::provider(
            "anthropic",
            Some(100),
            Some(40),
            Some(20),
            Some(30),
            Some(10),
        );
        assert_eq!(claude.input_tokens, 100);
        assert_eq!(claude.output_tokens, 40);
        assert_eq!(claude.cached_input_tokens, 50);
        assert_eq!(claude.total_billable_tokens(), 200);
        let gemini = TokenUsage::provider("google", Some(10), Some(5), None, Some(20), Some(9));
        assert_eq!(gemini.input_tokens, 0);
        assert_eq!(gemini.output_tokens, 5);
    }

    #[test]
    fn new_clamps_negatives() {
        let u = TokenUsage::new(-1, -2, 3, -4);
        assert_eq!(u, TokenUsage::new(0, 0, 3, 0));
    }

    #[test]
    fn totals_and_add() {
        let mut u = TokenUsage::new(1, 2, 3, 4);
        assert_eq!(u.total_tokens(), 4);
        assert_eq!(u.total_billable_tokens(), 10);
        u.add(&TokenUsage::new(1, 1, 1, 1));
        assert_eq!(u.total_billable_tokens(), 14);
        assert!(u.has_any_tokens());
        assert!(!TokenUsage::default().has_any_tokens());
    }

    #[test]
    fn json_keys_and_enum_raw_values() {
        let json = serde_json::to_value(TokenUsage::new(1, 2, 3, 4)).unwrap();
        assert_eq!(json["cachedInputTokens"], 2);
        assert_eq!(json["reasoningOutputTokens"], 4);
        assert_eq!(
            serde_json::to_string(&TokenUsageSource::TranscriptDelta).unwrap(),
            "\"transcriptDelta\""
        );
        assert_eq!(
            serde_json::to_string(&CostSource::Unavailable).unwrap(),
            "\"unavailable\""
        );
        assert_eq!(
            serde_json::to_string(&TelemetryMetricState::Invalid).unwrap(),
            "\"invalid\""
        );
    }
}
