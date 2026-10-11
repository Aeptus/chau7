//! Terminal color scheme presets.
//!
//! Mirrors the presets in `apps/chau7-macos/Sources/Chau7/Appearance/TerminalColorScheme.swift`
//! (`allPresets`, same order). Colors are kept as hex strings, exactly as in
//! Swift, and parsed with [`crate::color_parsing`].

use std::sync::Mutex;

use crate::color_parsing::{Rgb, parse_hex};

/// One preset: background, foreground, cursor, selection and the 16 ANSI colors
/// (black, red, green, yellow, blue, magenta, cyan, white, then the bright variants).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ColorScheme {
    pub name: &'static str,
    pub background: &'static str,
    pub foreground: &'static str,
    pub cursor: &'static str,
    pub selection: &'static str,
    pub ansi: [&'static str; 16],
}

/// All presets, `Default` first.
pub const PRESETS: &[ColorScheme] = &[
    ColorScheme {
        name: "Default",
        background: "#1E1E1E",
        foreground: "#D4D4D4",
        cursor: "#FFFFFF",
        selection: "#264F78",
        ansi: [
            "#000000", "#CD3131", "#0DBC79", "#E5E510", "#2472C8", "#BC3FBC", "#11A8CD", "#E5E5E5",
            "#666666", "#F14C4C", "#23D18B", "#F5F543", "#3B8EEA", "#D670D6", "#29B8DB", "#FFFFFF",
        ],
    },
    ColorScheme {
        name: "Solarized Dark",
        background: "#002B36",
        foreground: "#839496",
        cursor: "#93A1A1",
        selection: "#073642",
        ansi: [
            "#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
            "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
        ],
    },
    ColorScheme {
        name: "Solarized Light",
        background: "#FDF6E3",
        foreground: "#657B83",
        cursor: "#586E75",
        selection: "#EEE8D5",
        ansi: [
            "#073642", "#DC322F", "#859900", "#B58900", "#268BD2", "#D33682", "#2AA198", "#EEE8D5",
            "#002B36", "#CB4B16", "#586E75", "#657B83", "#839496", "#6C71C4", "#93A1A1", "#FDF6E3",
        ],
    },
    ColorScheme {
        name: "Dracula",
        background: "#282A36",
        foreground: "#F8F8F2",
        cursor: "#F8F8F2",
        selection: "#44475A",
        ansi: [
            "#21222C", "#FF5555", "#50FA7B", "#F1FA8C", "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
            "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5", "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF",
        ],
    },
    ColorScheme {
        name: "Nord",
        background: "#2E3440",
        foreground: "#D8DEE9",
        cursor: "#D8DEE9",
        selection: "#434C5E",
        ansi: [
            "#3B4252", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#88C0D0", "#E5E9F0",
            "#4C566A", "#BF616A", "#A3BE8C", "#EBCB8B", "#81A1C1", "#B48EAD", "#8FBCBB", "#ECEFF4",
        ],
    },
    ColorScheme {
        name: "Monokai",
        background: "#272822",
        foreground: "#F8F8F2",
        cursor: "#F8F8F2",
        selection: "#49483E",
        ansi: [
            "#272822", "#F92672", "#A6E22E", "#F4BF75", "#66D9EF", "#AE81FF", "#A1EFE4", "#F8F8F2",
            "#75715E", "#F92672", "#A6E22E", "#F4BF75", "#66D9EF", "#AE81FF", "#A1EFE4", "#F9F8F5",
        ],
    },
    ColorScheme {
        name: "Gruvbox Dark",
        background: "#282828",
        foreground: "#EBDBB2",
        cursor: "#EBDBB2",
        selection: "#504945",
        ansi: [
            "#282828", "#CC241D", "#98971A", "#D79921", "#458588", "#B16286", "#689D6A", "#A89984",
            "#928374", "#FB4934", "#B8BB26", "#FABD2F", "#83A598", "#D3869B", "#8EC07C", "#EBDBB2",
        ],
    },
    ColorScheme {
        name: "Tokyo Night",
        background: "#1A1B26",
        foreground: "#A9B1D6",
        cursor: "#C0CAF5",
        selection: "#33467C",
        ansi: [
            "#15161E", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#A9B1D6",
            "#414868", "#F7768E", "#9ECE6A", "#E0AF68", "#7AA2F7", "#BB9AF7", "#7DCFFF", "#C0CAF5",
        ],
    },
];

impl ColorScheme {
    /// Preset by name (case-insensitive), falling back to `Default` like
    /// `FeatureSettings.currentColorScheme` does in Swift.
    pub fn named(name: &str) -> &'static ColorScheme {
        PRESETS
            .iter()
            .find(|scheme| scheme.name.eq_ignore_ascii_case(name.trim()))
            .unwrap_or(&PRESETS[0])
    }

    /// Parse a hex field; presets are known-good, so failures fall back to black.
    pub fn rgb(hex: &str) -> (u8, u8, u8) {
        parse_hex(hex)
            .map(|Rgb { red, green, blue }| {
                (
                    (red * 255.0).round() as u8,
                    (green * 255.0).round() as u8,
                    (blue * 255.0).round() as u8,
                )
            })
            .unwrap_or((0, 0, 0))
    }

    pub fn ansi_rgb(&self) -> [(u8, u8, u8); 16] {
        self.ansi.map(Self::rgb)
    }

    /// `FeatureSettings.currentColorScheme`: "Custom" uses the user's scheme
    /// (`terminal.customColorScheme`, JSON) when one is set, any other name a
    /// preset.
    pub fn resolve(name: &str, custom_json: Option<&str>) -> &'static ColorScheme {
        if name.trim() == CUSTOM_NAME
            && let Some(custom) = custom_json.and_then(Self::from_json)
        {
            return custom;
        }
        Self::named(name)
    }

    /// Parse a scheme saved by Swift (`TerminalColorScheme` Codable: `name`,
    /// `background`, ..., `brightWhite`). The result is named "Custom" so it
    /// round-trips through the scheme name. Schemes are interned: the same
    /// JSON always gives the same reference, so reloading settings does not
    /// grow memory.
    pub fn from_json(json: &str) -> Option<&'static ColorScheme> {
        static CACHE: Mutex<Vec<(String, &'static ColorScheme)>> = Mutex::new(Vec::new());
        let mut cache = CACHE.lock().ok()?;
        if let Some((_, scheme)) = cache.iter().find(|(j, _)| j == json) {
            return Some(scheme);
        }
        let value: serde_json::Value = serde_json::from_str(json).ok()?;
        let field = |key: &str| -> Option<&'static str> {
            let hex = value.get(key)?.as_str()?;
            parse_hex(hex)?;
            Some(Box::leak(hex.to_string().into_boxed_str()))
        };
        let mut ansi = [""; 16];
        for (slot, key) in ansi.iter_mut().zip(JSON_ANSI_KEYS) {
            *slot = field(key)?;
        }
        let scheme: &'static ColorScheme = Box::leak(Box::new(ColorScheme {
            name: CUSTOM_NAME,
            background: field("background")?,
            foreground: field("foreground")?,
            cursor: field("cursor")?,
            selection: field("selection")?,
            ansi,
        }));
        cache.push((json.to_string(), scheme));
        Some(scheme)
    }

    /// The scheme as Swift's `TerminalColorScheme` JSON (one line).
    pub fn to_json(&self) -> String {
        let mut map = serde_json::Map::new();
        map.insert("name".into(), self.name.into());
        map.insert("background".into(), self.background.into());
        map.insert("foreground".into(), self.foreground.into());
        map.insert("cursor".into(), self.cursor.into());
        map.insert("selection".into(), self.selection.into());
        for (key, hex) in JSON_ANSI_KEYS.iter().zip(self.ansi) {
            map.insert((*key).into(), hex.into());
        }
        serde_json::Value::Object(map).to_string()
    }
}

/// Scheme name that selects the user's custom scheme.
pub const CUSTOM_NAME: &str = "Custom";

/// ANSI color keys of Swift's `TerminalColorScheme`, in palette order.
const JSON_ANSI_KEYS: [&str; 16] = [
    "black",
    "red",
    "green",
    "yellow",
    "blue",
    "magenta",
    "cyan",
    "white",
    "brightBlack",
    "brightRed",
    "brightGreen",
    "brightYellow",
    "brightBlue",
    "brightMagenta",
    "brightCyan",
    "brightWhite",
];

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn has_all_swift_presets_in_order() {
        let names: Vec<_> = PRESETS.iter().map(|p| p.name).collect();
        assert_eq!(
            names,
            [
                "Default",
                "Solarized Dark",
                "Solarized Light",
                "Dracula",
                "Nord",
                "Monokai",
                "Gruvbox Dark",
                "Tokyo Night"
            ]
        );
    }

    #[test]
    fn default_scheme_colors_parse() {
        let scheme = ColorScheme::named("default");
        assert_eq!(ColorScheme::rgb(scheme.background), (0x1E, 0x1E, 0x1E));
        assert_eq!(scheme.ansi_rgb()[1], (0xCD, 0x31, 0x31));
    }

    #[test]
    fn custom_scheme_round_trips_through_json() {
        let json = ColorScheme::named("Nord").to_json();
        assert!(json.contains("\"brightWhite\""));
        let custom = ColorScheme::resolve("Custom", Some(&json));
        assert_eq!(custom.name, "Custom");
        assert_eq!(custom.background, ColorScheme::named("Nord").background);
        assert_eq!(custom.ansi, ColorScheme::named("Nord").ansi);
        // Interned: same JSON, same scheme.
        assert!(std::ptr::eq(
            custom,
            ColorScheme::resolve("Custom", Some(&json))
        ));
    }

    #[test]
    fn custom_without_a_valid_scheme_falls_back() {
        assert_eq!(ColorScheme::resolve("Custom", None).name, "Default");
        assert_eq!(ColorScheme::resolve("Custom", Some("{}")).name, "Default");
        assert_eq!(ColorScheme::resolve("Dracula", Some("{}")).name, "Dracula");
    }

    #[test]
    fn unknown_name_falls_back_to_default() {
        assert_eq!(ColorScheme::named("nope").name, "Default");
    }
}
