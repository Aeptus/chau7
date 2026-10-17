//! API analytics proxy (`ProxySettingsView.swift`, `FeatureSettings`
//! `analytics.api.*`). Swift keeps these in UserDefaults, not in its config
//! file, so they live in `[next]`. The default port is Chau7 Next's own
//! (`proxy::DEFAULT_PORT`), so its proxy runs next to the Swift app's.

use chau7_next_core::config::RawValue;
use chau7_next_core::proxy::{self, DEFAULT_PORT};

use super::{ConfigSink, ConfigSource, SettingsDomain};

#[derive(Debug, Clone, PartialEq)]
pub struct ProxySettings {
    /// `analytics.api.enabled`: run the proxy and route AI CLIs through it.
    pub enabled: bool,
    /// `analytics.api.port` (1024 to 65534; TLS is port + 1).
    pub port: u16,
    /// `analytics.api.logPrompts`: keep the first 500 characters of prompts.
    pub log_prompts: bool,
    /// `analytics.api.includeOpenAI`: set `OPENAI_BASE_URL` too.
    pub include_openai: bool,
}

impl Default for ProxySettings {
    fn default() -> Self {
        Self {
            enabled: false,
            port: DEFAULT_PORT,
            log_prompts: false,
            include_openai: true,
        }
    }
}

impl SettingsDomain for ProxySettings {
    fn load(&mut self, src: &ConfigSource) {
        if let Some(v) = src
            .next("api_analytics_enabled")
            .and_then(RawValue::as_bool)
        {
            self.enabled = v;
        }
        if let Some(v) = src.next("api_analytics_port").and_then(RawValue::as_int) {
            self.port = proxy::clamp_port(v);
        }
        if let Some(v) = src
            .next("api_analytics_log_prompts")
            .and_then(RawValue::as_bool)
        {
            self.log_prompts = v;
        }
        if let Some(v) = src
            .next("api_analytics_include_openai")
            .and_then(RawValue::as_bool)
        {
            self.include_openai = v;
        }
    }

    fn save(&self, out: &mut ConfigSink) {
        out.set_next("api_analytics_enabled", self.enabled);
        out.set_next("api_analytics_port", self.port);
        out.set_next("api_analytics_log_prompts", self.log_prompts);
        out.set_next("api_analytics_include_openai", self.include_openai);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{load_text, round_trip};

    #[test]
    fn round_trips_with_swift_defaults() {
        let d = ProxySettings::default();
        assert!(!d.enabled && !d.log_prompts && d.include_openai);
        assert_eq!(d.port, DEFAULT_PORT);
        assert_eq!(round_trip(&d), d);
        let s = ProxySettings {
            enabled: true,
            port: 20000,
            log_prompts: true,
            include_openai: false,
        };
        assert_eq!(round_trip(&s), s);
    }

    #[test]
    fn port_is_clamped() {
        let loaded: ProxySettings = load_text("[next]\napi_analytics_port = 80\n");
        assert_eq!(loaded.port, 1024);
        let loaded: ProxySettings = load_text("[next]\napi_analytics_port = 99999\n");
        assert_eq!(loaded.port, 65534);
    }
}
