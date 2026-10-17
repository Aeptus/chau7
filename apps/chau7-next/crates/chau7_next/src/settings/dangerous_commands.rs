//! Dangerous commands (`DangerousCommandSettingsView.swift`): highlight risky
//! commands in the terminal, and the guard that asks before running them.
//!
//! The allow and block lists change while the app runs ("Always Allow"), so
//! they live in `dangerous_guard.json` (see `crate::guard`), not here.

use chau7_next_core::command_risk::DEFAULT_DANGEROUS_COMMAND_PATTERNS;
pub use chau7_next_core::command_risk::self_protect::ProtectionLevel;
use chau7_next_core::config::RawValue;

use super::{ConfigSink, ConfigSource, SettingsDomain};

/// `terminal.dangerousCommandHighlightScope`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HighlightScope {
    /// Nothing is highlighted.
    Disabled,
    /// Only while an AI CLI runs in the tab.
    AiOutputs,
    AllOutputs,
}

impl HighlightScope {
    pub const ALL: [HighlightScope; 3] = [Self::Disabled, Self::AiOutputs, Self::AllOutputs];

    /// Swift raw values: `none`, `ai_outputs`, `all_outputs`.
    pub fn raw(self) -> &'static str {
        match self {
            Self::Disabled => "none",
            Self::AiOutputs => "ai_outputs",
            Self::AllOutputs => "all_outputs",
        }
    }

    pub fn from_raw(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|s| s.raw() == raw)
    }

    pub fn label(self) -> &'static str {
        match self {
            Self::Disabled => "Disabled",
            Self::AiOutputs => "AI Outputs Only",
            Self::AllOutputs => "All Outputs",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct DangerousCommandSettings {
    pub scope: HighlightScope,
    /// `DangerousCommandGuard.isEnabled`: ask before running a risky command.
    pub guard_enabled: bool,
    pub protect_chau7_enabled: bool,
    pub protect_chau7_level: ProtectionLevel,
    pub protected_process_patterns: Vec<String>,
    /// Risky patterns; the Swift defaults until the user edits them.
    pub patterns: Vec<String>,
    /// `terminal.dangerousOutputHighlightLowPowerEnabled`
    /// (`[next] dangerous_highlight_low_power`): scan output less often.
    /// Set in the Debug Console (State tab).
    pub highlight_low_power: bool,
    /// `terminal.dangerousOutputHighlightIdleDelayMs`
    /// (`[next] dangerous_highlight_idle_delay_ms`), 0 to 5000.
    pub highlight_idle_delay_ms: u32,
    /// `terminal.dangerousOutputHighlightMaxIntervalMs`
    /// (`[next] dangerous_highlight_max_interval_ms`), 250 to 10000.
    pub highlight_max_interval_ms: u32,
}

/// Range of the highlight idle delay (ms).
pub const HIGHLIGHT_IDLE_DELAY_RANGE: (u32, u32) = (0, 5000);
/// Range of the highlight max interval (ms).
pub const HIGHLIGHT_MAX_INTERVAL_RANGE: (u32, u32) = (250, 10_000);

impl Default for DangerousCommandSettings {
    fn default() -> Self {
        Self {
            scope: HighlightScope::AllOutputs,
            guard_enabled: true,
            protect_chau7_enabled: true,
            protect_chau7_level: ProtectionLevel::Blocking,
            protected_process_patterns: vec!["chau7".into(), "chau7-mcp-bridge".into()],
            patterns: default_patterns(),
            highlight_low_power: true,
            highlight_idle_delay_ms: 500,
            highlight_max_interval_ms: 2000,
        }
    }
}

pub fn default_patterns() -> Vec<String> {
    DEFAULT_DANGEROUS_COMMAND_PATTERNS
        .iter()
        .map(|p| p.to_string())
        .collect()
}

impl DangerousCommandSettings {
    /// Whether rows are highlighted, given whether an AI CLI runs in the tab.
    pub fn highlights(&self, ai_running: bool) -> bool {
        match self.scope {
            HighlightScope::Disabled => false,
            HighlightScope::AiOutputs => ai_running,
            HighlightScope::AllOutputs => true,
        }
    }

    pub fn uses_default_patterns(&self) -> bool {
        self.patterns == default_patterns()
    }
}

fn raw_to_string(v: &RawValue) -> String {
    match v {
        RawValue::String(s) => s.clone(),
        RawValue::Int(i) => i.to_string(),
        RawValue::Double(d) => d.to_string(),
        RawValue::Bool(b) => b.to_string(),
    }
}

impl SettingsDomain for DangerousCommandSettings {
    fn load(&mut self, src: &ConfigSource) {
        if let Some(enabled) = src
            .next("dangerous_protect_chau7_enabled")
            .and_then(RawValue::as_bool)
        {
            self.protect_chau7_enabled = enabled;
        }
        if let Some(level) = src
            .next("dangerous_protect_chau7_level")
            .and_then(RawValue::as_str)
            .and_then(ProtectionLevel::from_raw)
        {
            self.protect_chau7_level = level;
        }
        if let Some(count) = src
            .next("dangerous_protected_process_count")
            .and_then(RawValue::as_int)
        {
            self.protected_process_patterns = (0..count.clamp(0, 10_000))
                .filter_map(|i| {
                    src.next(&format!("dangerous_protected_process_{i}"))
                        .and_then(RawValue::as_str)
                })
                .map(str::trim)
                .filter(|s| !s.is_empty())
                .map(str::to_string)
                .collect();
        }
        // The shared Swift-style raw parser deliberately does not unescape
        // quoted strings. A JSON-compatible TOML array preserves literal
        // quotes/backslashes without changing that shared parser contract.
        if let Some(patterns) = src
            .next("dangerous_protected_process_patterns")
            .and_then(RawValue::as_str)
            .and_then(|text| serde_json::from_str::<Vec<String>>(text).ok())
        {
            self.protected_process_patterns = patterns
                .into_iter()
                .take(10_000)
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
        }
        // Older Chau7 Next files had an on/off key only.
        if let Some(enabled) = src
            .next("highlight_dangerous_commands")
            .and_then(RawValue::as_bool)
        {
            self.scope = if enabled {
                HighlightScope::AllOutputs
            } else {
                HighlightScope::Disabled
            };
        }
        if let Some(scope) = src
            .next("dangerous_highlight_scope")
            .and_then(RawValue::as_str)
            .and_then(HighlightScope::from_raw)
        {
            self.scope = scope;
        }
        if let Some(v) = src
            .next("dangerous_guard_enabled")
            .and_then(RawValue::as_bool)
        {
            self.guard_enabled = v;
        }
        if let Some(v) = src
            .next("dangerous_highlight_low_power")
            .and_then(RawValue::as_bool)
        {
            self.highlight_low_power = v;
        }
        if let Some(v) = src
            .next("dangerous_highlight_idle_delay_ms")
            .and_then(RawValue::as_int)
        {
            let (min, max) = HIGHLIGHT_IDLE_DELAY_RANGE;
            self.highlight_idle_delay_ms = v.clamp(min as i64, max as i64) as u32;
        }
        if let Some(v) = src
            .next("dangerous_highlight_max_interval_ms")
            .and_then(RawValue::as_int)
        {
            let (min, max) = HIGHLIGHT_MAX_INTERVAL_RANGE;
            self.highlight_max_interval_ms = v.clamp(min as i64, max as i64) as u32;
        }
        if src
            .next("dangerous_patterns_custom")
            .and_then(RawValue::as_bool)
            == Some(true)
        {
            let count = src
                .next("dangerous_pattern_count")
                .and_then(RawValue::as_int)
                .unwrap_or(0)
                .clamp(0, 10_000);
            self.patterns = (0..count)
                .filter_map(|i| src.next(&format!("dangerous_pattern_{i}")))
                .map(raw_to_string)
                .map(|p| p.trim().to_string())
                .filter(|p| !p.is_empty())
                .collect();
        }
    }

    fn save(&self, out: &mut ConfigSink) {
        out.set_next(
            "dangerous_protect_chau7_enabled",
            self.protect_chau7_enabled,
        );
        out.set_next(
            "dangerous_protect_chau7_level",
            format!("\"{}\"", self.protect_chau7_level.raw()),
        );
        let patterns: Vec<_> = self
            .protected_process_patterns
            .iter()
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .collect();
        out.set_next(
            "dangerous_protected_process_patterns",
            serde_json::to_string(&patterns).expect("string list serialization"),
        );
        out.set_next(
            "dangerous_highlight_scope",
            format!("\"{}\"", self.scope.raw()),
        );
        out.set_next("dangerous_guard_enabled", self.guard_enabled);
        out.set_next("dangerous_highlight_low_power", self.highlight_low_power);
        out.set_next(
            "dangerous_highlight_idle_delay_ms",
            self.highlight_idle_delay_ms,
        );
        out.set_next(
            "dangerous_highlight_max_interval_ms",
            self.highlight_max_interval_ms,
        );
        if self.uses_default_patterns() {
            out.set_next("dangerous_patterns_custom", false);
        } else {
            out.set_next("dangerous_patterns_custom", true);
            let patterns: Vec<String> = self
                .patterns
                .iter()
                .map(|p| p.replace(['\n', '\r'], " ").trim().to_string())
                .filter(|p| !p.is_empty())
                .collect();
            out.set_next("dangerous_pattern_count", patterns.len());
            for (i, pattern) in patterns.iter().enumerate() {
                out.set_next_owned(format!("dangerous_pattern_{i}"), format!("\"{pattern}\""));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{load_text, round_trip};

    #[test]
    fn round_trips() {
        let d = DangerousCommandSettings {
            scope: HighlightScope::AiOutputs,
            guard_enabled: false,
            ..Default::default()
        };
        assert_eq!(round_trip(&d), d);
        assert!(!d.patterns.is_empty());
    }

    #[test]
    fn current_managed_process_defaults_and_owned_round_trip() {
        let defaults = DangerousCommandSettings::default();
        assert!(defaults.protect_chau7_enabled);
        assert_eq!(defaults.protect_chau7_level, ProtectionLevel::Blocking);
        assert_eq!(
            defaults.protected_process_patterns,
            ["chau7", "chau7-mcp-bridge"]
        );
        for level in ProtectionLevel::ALL {
            let settings = DangerousCommandSettings {
                protect_chau7_enabled: false,
                protect_chau7_level: level,
                protected_process_patterns: vec!["worker \"quoted\"".into(), "path\\helper".into()],
                ..Default::default()
            };
            assert_eq!(round_trip(&settings), settings);
        }
        let empty = DangerousCommandSettings {
            protected_process_patterns: vec![],
            ..Default::default()
        };
        assert_eq!(round_trip(&empty), empty);
        let invalid: DangerousCommandSettings = load_text(
            "[next]\ndangerous_protect_chau7_level=\"invalid\"\ndangerous_protected_process_count=2\ndangerous_protected_process_0=\"  helper  \"\ndangerous_protected_process_1=\" \"\n",
        );
        assert_eq!(invalid.protect_chau7_level, ProtectionLevel::Blocking);
        assert_eq!(invalid.protected_process_patterns, ["helper"]);
    }

    #[test]
    fn highlight_tuning_round_trips_and_clamps() {
        let d = DangerousCommandSettings::default();
        assert!(d.highlight_low_power);
        assert_eq!(d.highlight_idle_delay_ms, 500);
        assert_eq!(d.highlight_max_interval_ms, 2000);
        let tuned = DangerousCommandSettings {
            highlight_low_power: false,
            highlight_idle_delay_ms: 1200,
            highlight_max_interval_ms: 4000,
            ..Default::default()
        };
        assert_eq!(round_trip(&tuned), tuned);
        let clamped: DangerousCommandSettings = load_text(
            "[next]\ndangerous_highlight_idle_delay_ms = 99999\ndangerous_highlight_max_interval_ms = 1\n",
        );
        assert_eq!(clamped.highlight_idle_delay_ms, 5000);
        assert_eq!(clamped.highlight_max_interval_ms, 250);
    }

    #[test]
    fn custom_patterns_round_trip() {
        let d = DangerousCommandSettings {
            patterns: vec!["rm -rf".into(), "say \"hi\"".into(), "123".into()],
            ..Default::default()
        };
        assert_eq!(round_trip(&d), d);
    }

    #[test]
    fn default_patterns_are_not_written() {
        let mut file = Default::default();
        let mut sink = crate::settings::ConfigSink {
            file: &mut file,
            next: Vec::new(),
        };
        DangerousCommandSettings::default().save(&mut sink);
        assert!(
            sink.next
                .iter()
                .all(|(k, _)| !k.starts_with("dangerous_pattern_0"))
        );
    }

    #[test]
    fn old_highlight_key_still_loads() {
        let d: DangerousCommandSettings =
            load_text("[next]\nhighlight_dangerous_commands = false\n");
        assert_eq!(d.scope, HighlightScope::Disabled);
    }

    #[test]
    fn scope_decides_what_is_highlighted() {
        let mut d = DangerousCommandSettings::default();
        assert!(d.highlights(false));
        d.scope = HighlightScope::AiOutputs;
        assert!(!d.highlights(false) && d.highlights(true));
        d.scope = HighlightScope::Disabled;
        assert!(!d.highlights(true));
    }
}
