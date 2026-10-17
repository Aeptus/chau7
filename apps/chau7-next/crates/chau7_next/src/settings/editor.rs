//! Built-in text editor settings (`Settings/EditorConfig.swift`,
//! `EditorSettingsView.swift`). Swift keeps them as JSON in UserDefaults
//! (`editor.config`); here they are `[next]` keys named `editor_*`.

use chau7_next_core::config::RawValue;
use chau7_next_core::editor::config::{EditorConfig, EditorTheme};

use super::{ConfigSink, ConfigSource, SettingsDomain};

/// The editor settings domain.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct EditorSettings {
    pub config: EditorConfig,
}

type BoolField = (
    &'static str,
    fn(&EditorConfig) -> bool,
    fn(&mut EditorConfig, bool),
);

const BOOLS: [BoolField; 7] = [
    (
        "editor_use_spaces",
        |c| c.use_spaces_for_tabs,
        |c, v| c.use_spaces_for_tabs = v,
    ),
    ("editor_word_wrap", |c| c.word_wrap, |c, v| c.word_wrap = v),
    (
        "editor_line_numbers",
        |c| c.show_line_numbers,
        |c, v| c.show_line_numbers = v,
    ),
    (
        "editor_auto_indent",
        |c| c.auto_indent,
        |c, v| c.auto_indent = v,
    ),
    (
        "editor_bracket_matching",
        |c| c.bracket_matching,
        |c, v| c.bracket_matching = v,
    ),
    (
        "editor_minimap",
        |c| c.show_minimap,
        |c, v| c.show_minimap = v,
    ),
    (
        "editor_highlight_current_line",
        |c| c.highlight_current_line,
        |c, v| c.highlight_current_line = v,
    ),
];

impl SettingsDomain for EditorSettings {
    fn load(&mut self, src: &ConfigSource) {
        let c = &mut self.config;
        if let Some(v) = src.next("editor_font_size").and_then(RawValue::as_int) {
            c.font_size = v.max(0) as u32;
        }
        if let Some(v) = src.next("editor_tab_size").and_then(RawValue::as_int) {
            c.tab_size = v.max(0) as u32;
        }
        for (key, _, set) in BOOLS {
            if let Some(v) = src.next(key).and_then(RawValue::as_bool) {
                set(c, v);
            }
        }
        if let Some(theme) = src
            .next("editor_theme")
            .and_then(RawValue::as_str)
            .and_then(EditorTheme::from_key)
        {
            c.theme = theme;
        }
        self.config = self.config.clone().clamped();
    }

    fn save(&self, out: &mut ConfigSink) {
        let c = &self.config;
        out.set_next("editor_font_size", c.font_size);
        out.set_next("editor_tab_size", c.tab_size);
        for (key, get, _) in BOOLS {
            out.set_next(key, get(c));
        }
        out.set_next("editor_theme", format!("\"{}\"", c.theme.key()));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{load_text, round_trip};

    #[test]
    fn round_trips() {
        let settings = EditorSettings {
            config: EditorConfig {
                font_size: 18,
                tab_size: 2,
                use_spaces_for_tabs: false,
                word_wrap: false,
                show_line_numbers: false,
                auto_indent: false,
                bracket_matching: false,
                show_minimap: true,
                highlight_current_line: false,
                theme: EditorTheme::Solarized,
            },
        };
        assert_eq!(round_trip(&settings), settings);
        assert_eq!(
            round_trip(&EditorSettings::default()),
            EditorSettings::default()
        );
    }

    #[test]
    fn out_of_range_values_are_clamped() {
        let loaded: EditorSettings = load_text(
            "[next]\neditor_font_size = 99\neditor_tab_size = 0\neditor_theme = \"nope\"\n",
        );
        assert_eq!(loaded.config.font_size, 36);
        assert_eq!(loaded.config.tab_size, 2);
        assert_eq!(loaded.config.theme, EditorTheme::Default);
    }
}
