//! LLM provider types for the "Explain This Error" / BYOAI feature.
//!
//! Port of `LLMProvider.swift` from `apps/chau7-macos/Sources/Chau7Core`.
//!
//! Differences from Swift: the Keychain service name is built from a
//! caller-supplied namespace (Chau7 Next must not share Keychain entries with
//! the Swift app) and an explicit environment map instead of the process
//! environment. The API key is never serialized and decodes as an empty string.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;

/// Environment variable that prefixes Keychain service names in isolated runs
/// (mirrors `RuntimeIsolation.keychainServiceName`).
pub const KEYCHAIN_PREFIX_ENV: &str = "CHAU7_KEYCHAIN_SERVICE_PREFIX";

/// Supported LLM provider backends. Raw values are persisted.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum LLMProviderType {
    Openai,
    Anthropic,
    Ollama,
    Custom,
}

impl LLMProviderType {
    /// Every provider, in declaration order.
    pub const ALL: [LLMProviderType; 4] = [
        LLMProviderType::Openai,
        LLMProviderType::Anthropic,
        LLMProviderType::Ollama,
        LLMProviderType::Custom,
    ];

    /// Persisted raw value (also the `Identifiable` id).
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Openai => "openai",
            Self::Anthropic => "anthropic",
            Self::Ollama => "ollama",
            Self::Custom => "custom",
        }
    }

    pub fn id(self) -> &'static str {
        self.raw_value()
    }

    pub fn display_name(self) -> &'static str {
        match self {
            Self::Openai => "OpenAI",
            Self::Anthropic => "Anthropic",
            Self::Ollama => "Ollama",
            Self::Custom => "Custom",
        }
    }

    pub fn default_endpoint(self) -> &'static str {
        match self {
            Self::Openai => "https://api.openai.com/v1/chat/completions",
            Self::Anthropic => "https://api.anthropic.com/v1/messages",
            Self::Ollama => "http://localhost:11434/api/chat",
            Self::Custom => "",
        }
    }

    /// Whether this provider requires an API key.
    pub fn requires_api_key(self) -> bool {
        !matches!(self, Self::Ollama)
    }

    pub fn default_model(self) -> &'static str {
        match self {
            Self::Openai => "gpt-4o",
            Self::Anthropic => "claude-sonnet-4-20250514",
            Self::Ollama => "llama3.2",
            Self::Custom => "",
        }
    }
}

/// Configuration for an LLM provider. The API key lives in the Keychain and is
/// excluded from serialization.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LLMProviderConfig {
    pub provider: LLMProviderType,
    #[serde(skip)]
    pub api_key: String,
    pub endpoint: String,
    pub model: String,
    pub max_tokens: i64,
}

impl LLMProviderConfig {
    /// Mirrors `init(provider:apiKey:endpoint:model:maxTokens:)`.
    pub fn new(
        provider: LLMProviderType,
        api_key: &str,
        endpoint: Option<&str>,
        model: Option<&str>,
        max_tokens: i64,
    ) -> Self {
        Self {
            provider,
            api_key: api_key.to_string(),
            endpoint: endpoint.unwrap_or(provider.default_endpoint()).to_string(),
            model: model.unwrap_or(provider.default_model()).to_string(),
            max_tokens,
        }
    }

    /// Defaults for a provider (empty key, default endpoint/model, 1024 tokens).
    pub fn with_defaults(provider: LLMProviderType) -> Self {
        Self::new(provider, "", None, None, 1024)
    }

    /// Default configuration for each provider type.
    pub fn default_configs() -> HashMap<LLMProviderType, LLMProviderConfig> {
        LLMProviderType::ALL
            .iter()
            .map(|p| (*p, Self::with_defaults(*p)))
            .collect()
    }

    /// Keychain service identifier for this provider's API key:
    /// `<namespace>.llm.<provider>.apikey`, with the isolation prefix from
    /// `env` applied. Swift uses the namespace `com.chau7`; Chau7 Next passes
    /// its own.
    pub fn keychain_service(&self, namespace: &str, env: &HashMap<String, String>) -> String {
        keychain_service_name(
            &format!("{namespace}.llm.{}.apikey", self.provider.raw_value()),
            env,
        )
    }

    /// Minimum required fields are present.
    pub fn is_valid(&self) -> bool {
        if self.provider.requires_api_key() && self.api_key.is_empty() {
            return false;
        }
        !self.endpoint.is_empty() && !self.model.is_empty() && self.max_tokens >= 1
    }
}

/// Port of `RuntimeIsolation.keychainServiceName(base:environment:)`.
pub fn keychain_service_name(base: &str, env: &HashMap<String, String>) -> String {
    let prefix = env.get(KEYCHAIN_PREFIX_ENV).map(|s| s.trim()).unwrap_or("");
    if prefix.is_empty() {
        base.to_string()
    } else {
        format!("{prefix}.{base}")
    }
}

/// A request to send to an LLM provider.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LLMRequest {
    pub system_prompt: String,
    pub user_message: String,
    pub max_tokens: i64,
}

impl LLMRequest {
    pub fn new(system_prompt: &str, user_message: &str, max_tokens: i64) -> Self {
        Self {
            system_prompt: system_prompt.to_string(),
            user_message: user_message.to_string(),
            max_tokens,
        }
    }

    /// Default `maxTokens` is 1024.
    pub fn with_defaults(system_prompt: &str, user_message: &str) -> Self {
        Self::new(system_prompt, user_message, 1024)
    }
}

/// A response received from an LLM provider.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LLMResponse {
    pub content: String,
    pub tokens_used: Option<i64>,
    pub model: String,
}

impl LLMResponse {
    pub fn new(content: &str, tokens_used: Option<i64>, model: &str) -> Self {
        Self {
            content: content.to_string(),
            tokens_used,
            model: model.to_string(),
        }
    }
}

/// Confidence level for an error explanation.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ExplanationConfidence {
    High,
    Medium,
    Low,
}

/// Risk level for a suggested fix.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum FixRiskLevel {
    /// Read-only or reversible.
    Safe,
    /// Modifies files but recoverable.
    Moderate,
    /// Could cause data loss or system changes.
    Dangerous,
}

/// Structured explanation of a terminal error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ErrorExplanation {
    pub summary: String,
    pub details: String,
    pub suggested_fix: Option<String>,
    pub confidence: ExplanationConfidence,
}

impl ErrorExplanation {
    /// Defaults: no suggested fix, `medium` confidence.
    pub fn new(summary: &str, details: &str) -> Self {
        Self {
            summary: summary.to_string(),
            details: details.to_string(),
            suggested_fix: None,
            confidence: ExplanationConfidence::Medium,
        }
    }
}

/// A suggested fix for a terminal error.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FixSuggestion {
    pub description: String,
    pub command: String,
    pub risk_level: FixRiskLevel,
}

impl FixSuggestion {
    /// Default risk level is `safe`.
    pub fn new(description: &str, command: &str) -> Self {
        Self {
            description: description.to_string(),
            command: command.to_string(),
            risk_level: FixRiskLevel::Safe,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn env(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    // LLMProviderType

    #[test]
    fn test_all_cases_count() {
        assert_eq!(LLMProviderType::ALL.len(), 4);
    }

    #[test]
    fn test_identifiable() {
        assert_eq!(LLMProviderType::Openai.id(), "openai");
        assert_eq!(LLMProviderType::Anthropic.id(), "anthropic");
    }

    #[test]
    fn test_display_names() {
        assert_eq!(LLMProviderType::Openai.display_name(), "OpenAI");
        assert_eq!(LLMProviderType::Anthropic.display_name(), "Anthropic");
        assert_eq!(LLMProviderType::Ollama.display_name(), "Ollama");
        assert_eq!(LLMProviderType::Custom.display_name(), "Custom");
    }

    #[test]
    fn test_default_endpoints() {
        assert!(
            LLMProviderType::Openai
                .default_endpoint()
                .contains("openai.com")
        );
        assert!(
            LLMProviderType::Anthropic
                .default_endpoint()
                .contains("anthropic.com")
        );
        assert!(
            LLMProviderType::Ollama
                .default_endpoint()
                .contains("localhost")
        );
        assert_eq!(LLMProviderType::Custom.default_endpoint(), "");
    }

    #[test]
    fn test_requires_api_key() {
        assert!(LLMProviderType::Openai.requires_api_key());
        assert!(LLMProviderType::Anthropic.requires_api_key());
        assert!(!LLMProviderType::Ollama.requires_api_key());
        assert!(LLMProviderType::Custom.requires_api_key());
    }

    #[test]
    fn test_default_models() {
        assert!(!LLMProviderType::Openai.default_model().is_empty());
        assert!(!LLMProviderType::Anthropic.default_model().is_empty());
        assert!(!LLMProviderType::Ollama.default_model().is_empty());
        assert_eq!(LLMProviderType::Custom.default_model(), "");
    }

    #[test]
    fn test_provider_type_codable_round_trip() {
        let original = LLMProviderType::Anthropic;
        let json = serde_json::to_string(&original).unwrap();
        assert_eq!(json, "\"anthropic\"");
        let decoded: LLMProviderType = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, original);
        for p in LLMProviderType::ALL {
            assert_eq!(
                serde_json::to_string(&p).unwrap(),
                format!("\"{}\"", p.raw_value())
            );
        }
    }

    // LLMProviderConfig

    #[test]
    fn test_init_with_defaults() {
        let config = LLMProviderConfig::with_defaults(LLMProviderType::Openai);
        assert_eq!(config.provider, LLMProviderType::Openai);
        assert_eq!(config.api_key, "");
        assert_eq!(config.endpoint, LLMProviderType::Openai.default_endpoint());
        assert_eq!(config.model, LLMProviderType::Openai.default_model());
        assert_eq!(config.max_tokens, 1024);
    }

    #[test]
    fn test_init_with_custom_values() {
        let config = LLMProviderConfig::new(
            LLMProviderType::Custom,
            "sk-test",
            Some("https://my-llm.com/api"),
            Some("my-model"),
            2048,
        );
        assert_eq!(config.endpoint, "https://my-llm.com/api");
        assert_eq!(config.model, "my-model");
        assert_eq!(config.max_tokens, 2048);
    }

    #[test]
    fn test_keychain_service() {
        let config = LLMProviderConfig::with_defaults(LLMProviderType::Anthropic);
        assert_eq!(
            config.keychain_service("com.chau7.next", &HashMap::new()),
            "com.chau7.next.llm.anthropic.apikey"
        );
    }

    #[test]
    fn test_keychain_service_uses_isolation_prefix_when_configured() {
        let e = env(&[("CHAU7_KEYCHAIN_SERVICE_PREFIX", "com.chau7.isolated")]);
        let service = keychain_service_name("com.chau7.llm.anthropic.apikey", &e);
        assert_eq!(service, "com.chau7.isolated.com.chau7.llm.anthropic.apikey");
    }

    #[test]
    fn test_keychain_service_ignores_blank_isolation_prefix() {
        let e = env(&[("CHAU7_KEYCHAIN_SERVICE_PREFIX", "  ")]);
        let service = keychain_service_name("com.chau7.llm.anthropic.apikey", &e);
        assert_eq!(service, "com.chau7.llm.anthropic.apikey");
    }

    #[test]
    fn test_is_valid_with_api_key() {
        let config = LLMProviderConfig::new(LLMProviderType::Openai, "sk-test", None, None, 1024);
        assert!(config.is_valid());
    }

    #[test]
    fn test_is_invalid_without_required_api_key() {
        let config = LLMProviderConfig::new(LLMProviderType::Openai, "", None, None, 1024);
        assert!(!config.is_valid());
    }

    #[test]
    fn test_is_valid_ollama_without_api_key() {
        assert!(LLMProviderConfig::with_defaults(LLMProviderType::Ollama).is_valid());
    }

    #[test]
    fn test_is_invalid_with_empty_endpoint() {
        let mut config = LLMProviderConfig::with_defaults(LLMProviderType::Ollama);
        config.endpoint = String::new();
        assert!(!config.is_valid());
    }

    #[test]
    fn test_is_invalid_with_empty_model() {
        let mut config = LLMProviderConfig::with_defaults(LLMProviderType::Ollama);
        config.model = String::new();
        assert!(!config.is_valid());
    }

    #[test]
    fn test_is_invalid_with_zero_max_tokens() {
        let mut config = LLMProviderConfig::with_defaults(LLMProviderType::Ollama);
        config.max_tokens = 0;
        assert!(!config.is_valid());
    }

    #[test]
    fn test_default_configs_covers_all_providers() {
        let configs = LLMProviderConfig::default_configs();
        for p in LLMProviderType::ALL {
            assert!(
                configs.contains_key(&p),
                "{p:?} should have a default config"
            );
        }
    }

    #[test]
    fn test_config_codable_round_trip() {
        let original = LLMProviderConfig::new(LLMProviderType::Anthropic, "key", None, None, 512);
        let json = serde_json::to_string(&original).unwrap();
        assert!(!json.contains("apiKey"));
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert!(value.get("maxTokens").is_some());
        let decoded: LLMProviderConfig = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded.provider, original.provider);
        assert_eq!(decoded.endpoint, original.endpoint);
        assert_eq!(decoded.model, original.model);
        assert_eq!(decoded.max_tokens, original.max_tokens);
        assert_eq!(decoded.api_key, "", "apiKey must not survive a round-trip");
    }

    // LLMRequest / LLMResponse

    #[test]
    fn test_request_init() {
        let req = LLMRequest::with_defaults("You are helpful", "Explain this error");
        assert_eq!(req.system_prompt, "You are helpful");
        assert_eq!(req.user_message, "Explain this error");
        assert_eq!(req.max_tokens, 1024);
    }

    #[test]
    fn test_request_custom_max_tokens() {
        assert_eq!(LLMRequest::new("", "", 256).max_tokens, 256);
    }

    #[test]
    fn test_response_init() {
        let resp = LLMResponse::new("The error means...", Some(150), "gpt-4o");
        assert_eq!(resp.content, "The error means...");
        assert_eq!(resp.tokens_used, Some(150));
        assert_eq!(resp.model, "gpt-4o");
    }

    #[test]
    fn test_response_nil_tokens() {
        assert_eq!(LLMResponse::new("answer", None, "model").tokens_used, None);
    }

    // ExplanationConfidence / FixRiskLevel

    #[test]
    fn test_confidence_codable_round_trip() {
        for c in [
            ExplanationConfidence::High,
            ExplanationConfidence::Medium,
            ExplanationConfidence::Low,
        ] {
            let json = serde_json::to_string(&c).unwrap();
            let decoded: ExplanationConfidence = serde_json::from_str(&json).unwrap();
            assert_eq!(decoded, c);
        }
        assert_eq!(
            serde_json::to_string(&ExplanationConfidence::High).unwrap(),
            "\"high\""
        );
    }

    #[test]
    fn test_fix_risk_level_codable_round_trip() {
        for l in [
            FixRiskLevel::Safe,
            FixRiskLevel::Moderate,
            FixRiskLevel::Dangerous,
        ] {
            let json = serde_json::to_string(&l).unwrap();
            let decoded: FixRiskLevel = serde_json::from_str(&json).unwrap();
            assert_eq!(decoded, l);
        }
        assert_eq!(
            serde_json::to_string(&FixRiskLevel::Dangerous).unwrap(),
            "\"dangerous\""
        );
    }

    #[test]
    fn test_error_explanation_init() {
        let e = ErrorExplanation {
            summary: "Permission denied".into(),
            details: "The file is read-only".into(),
            suggested_fix: Some("chmod +w file.txt".into()),
            confidence: ExplanationConfidence::High,
        };
        assert_eq!(e.summary, "Permission denied");
        assert_eq!(e.details, "The file is read-only");
        assert_eq!(e.suggested_fix.as_deref(), Some("chmod +w file.txt"));
        assert_eq!(e.confidence, ExplanationConfidence::High);
    }

    #[test]
    fn test_error_explanation_defaults() {
        let e = ErrorExplanation::new("Error", "Details");
        assert!(e.suggested_fix.is_none());
        assert_eq!(e.confidence, ExplanationConfidence::Medium);
    }

    #[test]
    fn test_error_explanation_equality() {
        let mut a = ErrorExplanation::new("E", "D");
        a.confidence = ExplanationConfidence::Low;
        let b = a.clone();
        assert_eq!(a, b);
    }

    #[test]
    fn test_fix_suggestion_init() {
        let mut fix = FixSuggestion::new("Change permissions", "chmod 644 file.txt");
        fix.risk_level = FixRiskLevel::Moderate;
        assert_eq!(fix.description, "Change permissions");
        assert_eq!(fix.command, "chmod 644 file.txt");
        assert_eq!(fix.risk_level, FixRiskLevel::Moderate);
    }

    #[test]
    fn test_fix_suggestion_default_risk() {
        assert_eq!(
            FixSuggestion::new("List files", "ls").risk_level,
            FixRiskLevel::Safe
        );
    }

    #[test]
    fn test_fix_suggestion_equality() {
        let mut a = FixSuggestion::new("d", "c");
        a.risk_level = FixRiskLevel::Dangerous;
        assert_eq!(a, a.clone());
    }
}
