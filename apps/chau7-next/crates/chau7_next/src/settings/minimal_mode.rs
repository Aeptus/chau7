//! Minimal mode (`Appearance/MinimalMode.swift`,
//! `MinimalModeSettingsView.swift`): hides chrome to give the terminal more
//! room. Enabled by `[appearance] minimal_mode` (the key the Swift config
//! file already has) or Cmd+Shift+M; which elements hide is in `[next]`.

use chau7_next_core::config::RawValue;

use super::{ConfigSink, ConfigSource, SettingsDomain};

#[derive(Debug, Clone, PartialEq)]
pub struct MinimalModeSettings {
    /// `feature.minimalMode`, default off.
    pub enabled: bool,
    /// `minimal.hideTabBar`: hide the tab bar while a single tab is open.
    pub hide_tab_bar: bool,
    /// `minimal.hideTitleBar`: hide the title bar row too (with the tab bar).
    pub hide_title_bar: bool,
    /// `minimal.hideStatusBar` (Chau7 Next has no status bar yet).
    pub hide_status_bar: bool,
    /// `minimal.hideSidebar` (Chau7 Next has no sidebar yet).
    pub hide_sidebar: bool,
}

impl Default for MinimalModeSettings {
    fn default() -> Self {
        Self {
            enabled: false,
            hide_tab_bar: true,
            hide_title_bar: true,
            hide_status_bar: true,
            hide_sidebar: true,
        }
    }
}

type Field = (
    &'static str,
    fn(&MinimalModeSettings) -> bool,
    fn(&mut MinimalModeSettings, bool),
);

const FIELDS: [Field; 4] = [
    (
        "minimal_hide_tab_bar",
        |s| s.hide_tab_bar,
        |s, v| s.hide_tab_bar = v,
    ),
    (
        "minimal_hide_title_bar",
        |s| s.hide_title_bar,
        |s, v| s.hide_title_bar = v,
    ),
    (
        "minimal_hide_status_bar",
        |s| s.hide_status_bar,
        |s, v| s.hide_status_bar = v,
    ),
    (
        "minimal_hide_sidebar",
        |s| s.hide_sidebar,
        |s, v| s.hide_sidebar = v,
    ),
];

impl SettingsDomain for MinimalModeSettings {
    fn load(&mut self, src: &ConfigSource) {
        if let Some(enabled) = src.file.appearance.as_ref().and_then(|a| a.minimal_mode) {
            self.enabled = enabled;
        }
        for (key, _, set) in FIELDS {
            if let Some(v) = src.next(key).and_then(RawValue::as_bool) {
                set(self, v);
            }
        }
    }

    fn save(&self, out: &mut ConfigSink) {
        let appearance = out.file.appearance.get_or_insert_with(Default::default);
        appearance.minimal_mode = Some(self.enabled);
        for (key, get, _) in FIELDS {
            out.set_next(key, get(self));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{load_text, round_trip};

    #[test]
    fn round_trips_and_reads_the_swift_key() {
        let settings = MinimalModeSettings {
            enabled: true,
            hide_tab_bar: false,
            hide_title_bar: true,
            hide_status_bar: false,
            hide_sidebar: true,
        };
        assert_eq!(round_trip(&settings), settings);
        let loaded: MinimalModeSettings = load_text("[appearance]\nminimal_mode = true\n");
        assert!(loaded.enabled);
        assert!(loaded.hide_tab_bar);
    }
}
