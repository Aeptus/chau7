//! Editor settings (`Settings/EditorConfig.swift`) and the color themes of
//! the "Editor Theme" setting.
//!
//! Swift keeps these as JSON in UserDefaults (`editor.config`) and nothing
//! reads them; Chau7 Next stores them in `[next]` of its config file and the
//! editor pane applies every one of them.

use serde::{Deserialize, Serialize};

use super::HighlightColor;

/// Smallest and largest font size of the settings stepper.
pub const FONT_SIZE_RANGE: (u32, u32) = (8, 36);
/// Smallest and largest tab size of the settings stepper.
pub const TAB_SIZE_RANGE: (u32, u32) = (2, 8);

/// `EditorConfig`, with Swift's defaults.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct EditorConfig {
    pub font_size: u32,
    pub tab_size: u32,
    pub use_spaces_for_tabs: bool,
    pub word_wrap: bool,
    pub show_line_numbers: bool,
    pub auto_indent: bool,
    pub bracket_matching: bool,
    pub show_minimap: bool,
    pub highlight_current_line: bool,
    pub theme: EditorTheme,
}

impl Default for EditorConfig {
    fn default() -> Self {
        Self {
            font_size: 13,
            tab_size: 4,
            use_spaces_for_tabs: true,
            word_wrap: true,
            show_line_numbers: true,
            auto_indent: true,
            bracket_matching: true,
            show_minimap: false,
            highlight_current_line: true,
            theme: EditorTheme::Default,
        }
    }
}

impl EditorConfig {
    /// What Tab inserts (`tabString`): `tab_size` spaces, or a tab.
    pub fn tab_string(&self) -> String {
        if self.use_spaces_for_tabs {
            " ".repeat(self.tab_size as usize)
        } else {
            "\t".to_string()
        }
    }

    /// Clamp values read from a file to the ranges of the settings controls.
    pub fn clamped(mut self) -> Self {
        self.font_size = self.font_size.clamp(FONT_SIZE_RANGE.0, FONT_SIZE_RANGE.1);
        self.tab_size = self.tab_size.clamp(TAB_SIZE_RANGE.0, TAB_SIZE_RANGE.1);
        self
    }
}

/// "Editor Theme" (`theme`: default, dark, light, solarized, monokai).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum EditorTheme {
    #[default]
    Default,
    Dark,
    Light,
    Solarized,
    Monokai,
}

impl EditorTheme {
    pub const ALL: [EditorTheme; 5] = [
        EditorTheme::Default,
        EditorTheme::Dark,
        EditorTheme::Light,
        EditorTheme::Solarized,
        EditorTheme::Monokai,
    ];

    /// The value stored in the config file.
    pub fn key(self) -> &'static str {
        match self {
            EditorTheme::Default => "default",
            EditorTheme::Dark => "dark",
            EditorTheme::Light => "light",
            EditorTheme::Solarized => "solarized",
            EditorTheme::Monokai => "monokai",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            EditorTheme::Default => "Default",
            EditorTheme::Dark => "Dark",
            EditorTheme::Light => "Light",
            EditorTheme::Solarized => "Solarized",
            EditorTheme::Monokai => "Monokai",
        }
    }

    pub fn from_key(key: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|t| t.key() == key)
    }

    /// Background and chrome colors (Default and Solarized follow the window
    /// appearance, the others are fixed).
    pub fn colors(self, dark_appearance: bool) -> ThemeColors {
        let dark = match self {
            EditorTheme::Default => dark_appearance,
            EditorTheme::Dark | EditorTheme::Monokai => true,
            EditorTheme::Light => false,
            EditorTheme::Solarized => dark_appearance,
        };
        match (self, dark) {
            (EditorTheme::Solarized, true) => ThemeColors {
                background: 0x002b36,
                foreground: 0x839496,
                gutter: 0x073642,
                line_number: 0x586e75,
                current_line: 0x073642,
                dark: true,
            },
            (EditorTheme::Solarized, false) => ThemeColors {
                background: 0xfdf6e3,
                foreground: 0x657b83,
                gutter: 0xeee8d5,
                line_number: 0x93a1a1,
                current_line: 0xeee8d5,
                dark: false,
            },
            (EditorTheme::Monokai, _) => ThemeColors {
                background: 0x272822,
                foreground: 0xf8f8f2,
                gutter: 0x2f3129,
                line_number: 0x90908a,
                current_line: 0x3e3d32,
                dark: true,
            },
            (_, true) => ThemeColors {
                background: 0x1e1e1e,
                foreground: 0xdcdcdc,
                gutter: 0x252526,
                line_number: 0x858585,
                current_line: 0x2a2d2e,
                dark: true,
            },
            (_, false) => ThemeColors {
                background: 0xffffff,
                foreground: 0x1f1f1f,
                gutter: 0xf3f3f3,
                line_number: 0x8a8a8a,
                current_line: 0xf0f4fa,
                dark: false,
            },
        }
    }

    /// RGB of a highlight color in this theme. Default, Dark and Light use
    /// the macOS system colors (`NSColor.system*`, light or dark variant).
    pub fn syntax_rgb(self, color: HighlightColor, dark_appearance: bool) -> u32 {
        use HighlightColor::*;
        let dark = self.colors(dark_appearance).dark;
        match self {
            EditorTheme::Solarized => match color {
                Pink => 0x859900,
                Purple => 0x6c71c4,
                Red => 0x2aa198,
                Green => 0x93a1a1,
                Blue => 0xd33682,
                Teal => 0x268bd2,
                Orange => 0xcb4b16,
                Yellow => 0xb58900,
                Cyan => 0x2aa198,
                Gray => 0x839496,
                Label => self.colors(dark_appearance).foreground,
            },
            EditorTheme::Monokai => match color {
                Pink => 0xf92672,
                Purple => 0xae81ff,
                Red => 0xe6db74,
                Green => 0x75715e,
                Blue => 0xae81ff,
                Teal => 0x66d9ef,
                Orange => 0xfd971f,
                Yellow => 0xe6db74,
                Cyan => 0x66d9ef,
                Gray => 0x90908a,
                Label => 0xf8f8f2,
            },
            _ => system_rgb(color, dark),
        }
    }
}

/// `NSColor.system*` in the light and dark appearance.
pub fn system_rgb(color: HighlightColor, dark: bool) -> u32 {
    use HighlightColor::*;
    match (color, dark) {
        (Pink, false) => 0xff2d55,
        (Pink, true) => 0xff375f,
        (Purple, false) => 0xaf52de,
        (Purple, true) => 0xbf5af2,
        (Red, false) => 0xff3b30,
        (Red, true) => 0xff453a,
        (Green, false) => 0x28cd41,
        (Green, true) => 0x32d74b,
        (Blue, false) => 0x007aff,
        (Blue, true) => 0x0a84ff,
        (Teal, false) => 0x59adc4,
        (Teal, true) => 0x6ac4dc,
        (Orange, false) => 0xff9500,
        (Orange, true) => 0xff9f0a,
        (Yellow, false) => 0xffcc00,
        (Yellow, true) => 0xffd60a,
        (Cyan, false) => 0x55bef0,
        (Cyan, true) => 0x5ac8f5,
        (Gray, false) => 0x8e8e93,
        (Gray, true) => 0x98989d,
        (Label, false) => 0x000000,
        (Label, true) => 0xffffff,
    }
}

/// Background and chrome colors of an editor theme (RGB).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ThemeColors {
    pub background: u32,
    pub foreground: u32,
    pub gutter: u32,
    pub line_number: u32,
    pub current_line: u32,
    pub dark: bool,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_swift() {
        let c = EditorConfig::default();
        assert_eq!((c.font_size, c.tab_size), (13, 4));
        assert!(c.use_spaces_for_tabs && c.word_wrap && c.show_line_numbers);
        assert!(c.auto_indent && c.bracket_matching && c.highlight_current_line);
        assert!(!c.show_minimap);
        assert_eq!(c.theme, EditorTheme::Default);
    }

    #[test]
    fn tab_string() {
        let mut c = EditorConfig::default();
        assert_eq!(c.tab_string(), "    ");
        c.tab_size = 2;
        assert_eq!(c.tab_string(), "  ");
        c.use_spaces_for_tabs = false;
        assert_eq!(c.tab_string(), "\t");
    }

    #[test]
    fn json_round_trip_uses_swift_keys() {
        let c = EditorConfig {
            theme: EditorTheme::Monokai,
            word_wrap: false,
            ..Default::default()
        };
        let json = serde_json::to_string(&c).unwrap();
        assert!(json.contains("\"useSpacesForTabs\":true"));
        assert!(json.contains("\"theme\":\"monokai\""));
        assert_eq!(serde_json::from_str::<EditorConfig>(&json).unwrap(), c);
        // Missing keys keep their defaults.
        let partial: EditorConfig = serde_json::from_str(r#"{"fontSize":20}"#).unwrap();
        assert_eq!(partial.font_size, 20);
        assert_eq!(partial.tab_size, 4);
    }

    #[test]
    fn clamps_and_theme_keys() {
        let c = EditorConfig {
            font_size: 100,
            tab_size: 1,
            ..Default::default()
        }
        .clamped();
        assert_eq!((c.font_size, c.tab_size), (36, 2));
        for theme in EditorTheme::ALL {
            assert_eq!(EditorTheme::from_key(theme.key()), Some(theme));
        }
        assert!(EditorTheme::Monokai.colors(false).dark);
        assert!(!EditorTheme::Light.colors(true).dark);
        assert!(EditorTheme::Default.colors(true).dark);
    }
}
