//! AI integration and monitoring (`AIIntegrationSettingsView.swift`,
//! `LLMSettingsView.swift`, the monitor settings of `AppModel` and
//! `FeatureSettings.shellEventConfig`). Every key lives in `[next]`:
//!
//! - `ai_custom_detection_rules`: JSON list of `{pattern, displayName,
//!   colorName}` (Swift `ai.customDetectionRules`).
//! - `llm_provider`, `llm_endpoint`, `llm_model`, `llm_max_tokens`: the LLM
//!   provider (Swift keeps only the API key; the key stays in the Keychain).
//! - `error_explain_enabled` (`feature.errorExplainEnabled`, default off).
//!
//! The `AppModel` monitor switches live with the screens that edit them:
//! "Monitor AI Events" and the event log path in `settings::notifications`,
//! history and terminal log monitoring in `settings::history`, and the
//! shell event config (`shell.eventConfig`) in `settings::notifications`.

use chau7_next_core::config::RawValue;
use chau7_next_core::llm_provider::{LLMProviderConfig, LLMProviderType};
use chau7_next_core::tabs_state::TabColor;
use serde::{Deserialize, Serialize};

use super::{ConfigSink, ConfigSource, SettingsDomain};

/// `CustomAIDetectionRule`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CustomAiRule {
    #[serde(default = "new_id")]
    pub id: String,
    pub pattern: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default = "gray")]
    pub color_name: String,
}

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string().to_uppercase()
}

fn gray() -> String {
    "gray".into()
}

impl CustomAiRule {
    pub fn new(pattern: &str, display_name: &str, color: TabColor) -> Self {
        Self {
            id: new_id(),
            pattern: pattern.trim().to_string(),
            display_name: display_name.trim().to_string(),
            color_name: color.name().to_string(),
        }
    }

    /// `tabColor`: gray when the name is unknown.
    pub fn color(&self) -> TabColor {
        TabColor::from_name(&self.color_name).unwrap_or(TabColor::Gray)
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct AiSettings {
    pub custom_rules: Vec<CustomAiRule>,
    pub llm_provider: LLMProviderType,
    /// Empty: the provider default.
    pub llm_endpoint: String,
    /// Empty: the provider default.
    pub llm_model: String,
    pub llm_max_tokens: i64,
    pub error_explain_enabled: bool,
}

impl Default for AiSettings {
    fn default() -> Self {
        Self {
            custom_rules: Vec::new(),
            llm_provider: LLMProviderType::Openai,
            llm_endpoint: String::new(),
            llm_model: String::new(),
            llm_max_tokens: 1024,
            error_explain_enabled: false,
        }
    }
}

impl AiSettings {
    /// (pattern, display name) pairs for the shell tracker.
    pub fn detection_rules(&self) -> Vec<(String, String)> {
        self.custom_rules
            .iter()
            .map(|r| (r.pattern.clone(), r.display_name.clone()))
            .collect()
    }

    /// (pattern, color) pairs for the automatic tab color.
    pub fn color_rules(&self) -> Vec<(String, TabColor)> {
        self.custom_rules
            .iter()
            .map(|r| (r.pattern.clone(), r.color()))
            .collect()
    }

    /// The provider config without its key (empty fields take the defaults).
    pub fn llm_config(&self, api_key: &str) -> LLMProviderConfig {
        LLMProviderConfig::new(
            self.llm_provider,
            api_key,
            Some(self.llm_endpoint.trim()).filter(|e| !e.is_empty()),
            Some(self.llm_model.trim()).filter(|m| !m.is_empty()),
            self.llm_max_tokens.max(1),
        )
    }
}

/// TOML literal string (JSON keeps its double quotes).
fn literal(s: &str) -> String {
    format!("'{}'", s.replace('\'', "\u{2019}"))
}

fn quoted(s: &str) -> String {
    format!("\"{}\"", s.replace(['"', '\n', '\r', '\\'], ""))
}

impl SettingsDomain for AiSettings {
    fn load(&mut self, src: &ConfigSource) {
        if let Some(json) = src
            .next("ai_custom_detection_rules")
            .and_then(RawValue::as_str)
            && let Ok(rules) = serde_json::from_str::<Vec<CustomAiRule>>(json)
        {
            self.custom_rules = rules;
        }
        if let Some(raw) = src.next("llm_provider").and_then(RawValue::as_str)
            && let Some(provider) = LLMProviderType::ALL
                .into_iter()
                .find(|p| p.raw_value() == raw)
        {
            self.llm_provider = provider;
        }
        if let Some(v) = src.next("llm_endpoint").and_then(RawValue::as_str) {
            self.llm_endpoint = v.to_string();
        }
        if let Some(v) = src.next("llm_model").and_then(RawValue::as_str) {
            self.llm_model = v.to_string();
        }
        if let Some(v) = src.next("llm_max_tokens").and_then(RawValue::as_int) {
            self.llm_max_tokens = v.max(1);
        }
        if let Some(v) = src
            .next("error_explain_enabled")
            .and_then(RawValue::as_bool)
        {
            self.error_explain_enabled = v;
        }
    }

    fn save(&self, out: &mut ConfigSink) {
        let rules = serde_json::to_string(&self.custom_rules).unwrap_or_else(|_| "[]".into());
        out.set_next("ai_custom_detection_rules", literal(&rules));
        out.set_next("llm_provider", quoted(self.llm_provider.raw_value()));
        out.set_next("llm_endpoint", quoted(&self.llm_endpoint));
        out.set_next("llm_model", quoted(&self.llm_model));
        out.set_next("llm_max_tokens", self.llm_max_tokens);
        out.set_next("error_explain_enabled", self.error_explain_enabled);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::round_trip;

    #[test]
    fn defaults_round_trip() {
        assert_eq!(round_trip(&AiSettings::default()), AiSettings::default());
    }

    #[test]
    fn edited_values_round_trip() {
        let mut s = AiSettings::default();
        s.custom_rules.push(CustomAiRule::new(
            " mytool ",
            "My Tool's AI",
            TabColor::Pink,
        ));
        s.llm_provider = LLMProviderType::Anthropic;
        s.llm_model = "claude-x".into();
        s.llm_endpoint = "https://example.com/v1".into();
        s.llm_max_tokens = 512;
        s.error_explain_enabled = true;
        let back = round_trip(&s);
        assert_eq!(back.custom_rules.len(), 1);
        assert_eq!(back.custom_rules[0].pattern, "mytool");
        assert_eq!(back.custom_rules[0].color(), TabColor::Pink);
        assert_eq!(back.llm_provider, LLMProviderType::Anthropic);
        assert_eq!(back.llm_model, "claude-x");
        assert_eq!(back.llm_max_tokens, 512);
        assert!(back.error_explain_enabled);
        assert_eq!(back.detection_rules()[0].0, "mytool");
    }

    #[test]
    fn llm_config_uses_defaults_for_empty_fields() {
        let s = AiSettings::default();
        let config = s.llm_config("k");
        assert_eq!(config.model, "gpt-4o");
        assert!(config.endpoint.contains("openai.com"));
        assert!(config.is_valid());
    }
}
