//! Token optimization (`TokenOptimizationSettingsView.swift`, CTO): the mode,
//! the input prefix and the per-tab prefix overrides.
//!
//! Swift keeps these in UserDefaults (`cto.mode`, `feature.ctoEnabled`,
//! `feature.ctoPrefix`, `feature.ctoTabOverrides`); its config.toml has no CTO
//! section, so Chau7 Next stores them under `[next]`: `cto_mode` (Swift raw
//! value: `off`, `allTabs`, `aiOnly`, `manual`), `cto_prefix_enabled`,
//! `cto_prefix` and `cto_tab_overrides` (JSON object, session id to bool).

use std::collections::BTreeMap;

use chau7_next_core::config::RawValue;
use chau7_next_core::token_optimization::TokenOptimizationMode;

use super::{ConfigSink, ConfigSource, SettingsDomain};

#[derive(Debug, Clone, PartialEq, Default)]
pub struct TokenOptimizationSettings {
    /// `cto.mode` (default off).
    pub mode: TokenOptimizationMode,
    /// `feature.ctoEnabled` (default off): "Enable Input Prefix".
    pub prefix_enabled: bool,
    /// `feature.ctoPrefix` (default empty), one line.
    pub prefix: String,
    /// `feature.ctoTabOverrides`: tab (session) id to "prefix on" for that tab.
    pub tab_overrides: BTreeMap<String, bool>,
}

/// `ctoPrefix` setter: new lines become spaces, the ends lose newlines.
pub fn clean_prefix(text: &str) -> String {
    text.replace('\n', " ")
        .trim_matches(|c| c == '\n' || c == '\r')
        .to_string()
}

impl TokenOptimizationSettings {
    /// `isCTOEnabled(forTabIdentifier:)`: the tab's override, else the
    /// global switch.
    pub fn prefix_enabled_for(&self, tab: &str) -> bool {
        self.tab_overrides
            .get(tab.trim())
            .copied()
            .unwrap_or(self.prefix_enabled)
    }

    /// `ctoOverride(forTabIdentifier:)`.
    pub fn override_for(&self, tab: &str) -> Option<bool> {
        self.tab_overrides.get(tab.trim()).copied()
    }

    pub fn set_override(&mut self, tab: &str, enabled: bool) {
        let tab = tab.trim();
        if !tab.is_empty() {
            self.tab_overrides.insert(tab.to_string(), enabled);
        }
    }

    pub fn clear_override(&mut self, tab: &str) {
        self.tab_overrides.remove(tab.trim());
    }

    /// The prefix to add to a typed line in `tab`, if any
    /// (`applyCTOPrefixIfNeeded`): enabled for the tab and not blank.
    pub fn prefix_for(&self, tab: &str) -> Option<&str> {
        let prefix = self.prefix.trim();
        (self.prefix_enabled_for(tab) && !prefix.is_empty()).then_some(prefix)
    }
}

fn quote(text: &str) -> String {
    let escaped = text
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
        .replace('\r', "\\r");
    format!("\"{escaped}\"")
}

fn unescape(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '\\' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('n') => out.push('\n'),
            Some('r') => out.push('\r'),
            Some('t') => out.push('\t'),
            Some(other) => out.push(other),
            None => out.push('\\'),
        }
    }
    out
}

pub fn mode_from_raw(raw: &str) -> Option<TokenOptimizationMode> {
    TokenOptimizationMode::ALL
        .into_iter()
        .find(|m| m.raw_value() == raw)
}

impl SettingsDomain for TokenOptimizationSettings {
    fn load(&mut self, src: &ConfigSource) {
        if let Some(mode) = src
            .next("cto_mode")
            .and_then(RawValue::as_str)
            .and_then(mode_from_raw)
        {
            self.mode = mode;
        }
        if let Some(v) = src.next("cto_prefix_enabled").and_then(RawValue::as_bool) {
            self.prefix_enabled = v;
        }
        if let Some(v) = src.next("cto_prefix").and_then(RawValue::as_str) {
            self.prefix = clean_prefix(&unescape(v));
        }
        if let Some(text) = src.next("cto_tab_overrides").and_then(RawValue::as_str)
            && let Ok(map) = serde_json::from_str::<BTreeMap<String, bool>>(&unescape(text))
        {
            self.tab_overrides = map;
        }
    }

    fn save(&self, out: &mut ConfigSink) {
        out.set_next("cto_mode", format!("\"{}\"", self.mode.raw_value()));
        out.set_next("cto_prefix_enabled", self.prefix_enabled);
        out.set_next("cto_prefix", quote(&self.prefix));
        out.set_next(
            "cto_tab_overrides",
            quote(&serde_json::to_string(&self.tab_overrides).unwrap_or_else(|_| "{}".into())),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{load_text, round_trip};

    #[test]
    fn defaults_match_swift() {
        let s = TokenOptimizationSettings::default();
        assert_eq!(s.mode, TokenOptimizationMode::Off);
        assert!(!s.prefix_enabled);
        assert_eq!(s.prefix, "");
        assert!(s.tab_overrides.is_empty());
    }

    #[test]
    fn values_survive_a_save_and_load() {
        let mut settings = TokenOptimizationSettings {
            mode: TokenOptimizationMode::AiOnly,
            prefix_enabled: true,
            prefix: "/think \"hard\"".into(),
            ..Default::default()
        };
        settings.set_override("TAB-1", false);
        settings.set_override("TAB-2", true);
        assert_eq!(round_trip(&settings), settings);
    }

    #[test]
    fn every_mode_loads_from_its_swift_raw_value() {
        for mode in TokenOptimizationMode::ALL {
            let text = format!("[next]\ncto_mode = \"{}\"\n", mode.raw_value());
            assert_eq!(load_text::<TokenOptimizationSettings>(&text).mode, mode);
        }
        assert_eq!(
            load_text::<TokenOptimizationSettings>("[next]\ncto_mode = \"nonsense\"\n").mode,
            TokenOptimizationMode::Off
        );
    }

    #[test]
    fn tab_override_beats_the_global_switch() {
        let mut s = TokenOptimizationSettings {
            prefix_enabled: true,
            prefix: "/think".into(),
            ..Default::default()
        };
        assert!(s.prefix_enabled_for("A"));
        s.set_override("A", false);
        assert!(!s.prefix_enabled_for("A"));
        assert_eq!(s.prefix_for("A"), None);
        assert_eq!(s.prefix_for("B"), Some("/think"));
        s.clear_override("A");
        assert_eq!(s.override_for("A"), None);
        s.prefix_enabled = false;
        s.set_override("B", true);
        assert_eq!(s.prefix_for("B"), Some("/think"));
        assert_eq!(s.prefix_for("C"), None);
        s.set_override("  ", true);
        assert_eq!(s.tab_overrides.len(), 1, "blank ids are ignored");
    }

    #[test]
    fn blank_prefix_adds_nothing() {
        let s = TokenOptimizationSettings {
            prefix_enabled: true,
            prefix: "   ".into(),
            ..Default::default()
        };
        assert_eq!(s.prefix_for("A"), None);
    }

    #[test]
    fn prefix_is_one_line() {
        assert_eq!(clean_prefix("a\nb"), "a b");
        assert_eq!(clean_prefix("a\n"), "a ");
    }
}
