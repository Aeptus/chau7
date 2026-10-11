//! Appearance (`AppearanceSettingsView.swift`, `FontColorsSettingsView.swift`,
//! `DisplaySettingsView.swift`, `GraphicsSettingsView.swift`,
//! the rendering part of
//! `ScrollbackPerfSettingsView.swift`): font, color scheme, cursor, padding,
//! window, display enhancements, image protocols, rendering.
//!
//! Keys shared with the Swift `config.toml` keep their names (`[appearance]`,
//! `[terminal] sixel_enabled`); keys Swift keeps in UserDefaults go under
//! `[next]` with the UserDefaults name in snake case.

use chau7_next_core::color_schemes::ColorScheme;
use chau7_next_core::config::RawValue;

use super::{ConfigSink, ConfigSource, SettingsDomain};

#[derive(Debug, Clone, PartialEq)]
pub enum CursorShape {
    Block,
    Bar,
    Underline,
}

/// `AppTheme` (`app.theme`): the appearance of every window.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum AppTheme {
    #[default]
    System,
    Light,
    Dark,
}

impl AppTheme {
    pub const ALL: [AppTheme; 3] = [AppTheme::System, AppTheme::Light, AppTheme::Dark];

    pub fn raw(self) -> &'static str {
        match self {
            AppTheme::System => "system",
            AppTheme::Light => "light",
            AppTheme::Dark => "dark",
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            AppTheme::System => "System",
            AppTheme::Light => "Light",
            AppTheme::Dark => "Dark",
        }
    }

    fn parse(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|t| t.raw() == raw)
    }

    /// Raw value in config and settings JSON (`AppTheme.rawValue`).
    pub fn id(self) -> &'static str {
        self.raw()
    }

    pub fn from_id(id: &str) -> Option<Self> {
        Self::parse(id)
    }
}

/// Display enhancements (`DisplaySettingsView.swift`).
#[derive(Debug, Clone, PartialEq)]
pub struct DisplayOptions {
    /// `feature.syntaxHighlight` (on): highlighting in the log and editor views.
    pub syntax_highlight: bool,
    /// `feature.clickableURLs` (on): URLs open on Cmd+click.
    pub clickable_urls: bool,
    /// `feature.inlineImages` (on): iTerm2 inline images (imgcat).
    pub inline_images: bool,
    /// `feature.jsonPrettyPrint` (off): JSON lines formatted in the log view.
    pub json_pretty_print: bool,
    /// `feature.lineTimestamps` (off): time each line arrived, in the right margin.
    pub line_timestamps: bool,
    /// `feature.timestampFormat` (`HH:mm:ss`, a Unicode date pattern).
    pub timestamp_format: String,
}

impl Default for DisplayOptions {
    fn default() -> Self {
        Self {
            syntax_highlight: true,
            clickable_urls: true,
            inline_images: true,
            json_pretty_print: false,
            line_timestamps: false,
            timestamp_format: "HH:mm:ss".into(),
        }
    }
}

/// Sixel and Kitty images (`GraphicsSettingsView.swift`, `SixelKittyBridge`).
#[derive(Debug, Clone, PartialEq)]
pub struct GraphicsOptions {
    /// `feature.sixelEnabled`, `[terminal] sixel_enabled` (off).
    pub sixel: bool,
    /// `feature.kittyGraphicsEnabled`, `[terminal] kitty_graphics` (off).
    pub kitty: bool,
    /// `feature.kittyCacheLimitMB` (256, 64 to 1024): memory kept for images per terminal.
    pub kitty_cache_limit_mb: u32,
}

impl Default for GraphicsOptions {
    fn default() -> Self {
        Self {
            sixel: false,
            kitty: false,
            kitty_cache_limit_mb: 256,
        }
    }
}

/// Rendering options (`ScrollbackPerfSettingsView.swift`).
#[derive(Debug, Clone, PartialEq)]
pub struct RenderingOptions {
    /// `feature.useMetalRenderer` (on). GPUI always draws on the GPU (Metal
    /// on macOS); off draws new tabs without GPU-only extras (no ligatures,
    /// no image layer), the closest thing to Swift's CPU renderer.
    pub gpu_renderer: bool,
    /// `isSuspendBackgroundRendering` (off).
    pub suspend_background: bool,
    /// `suspendRenderDelaySeconds` (5): time a tab stays live after it is hidden.
    pub suspend_delay_secs: f32,
}

impl Default for RenderingOptions {
    fn default() -> Self {
        Self {
            gpu_renderer: true,
            suspend_background: false,
            suspend_delay_secs: 5.0,
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct AppearanceSettings {
    pub font_family: String,
    pub font_size: f32,
    pub line_height: f32,
    /// `terminal.colorSchemeName` (`[appearance] color_scheme`); "Custom" is
    /// resolved from `custom_color_scheme`.
    pub color_scheme: &'static ColorScheme,
    /// `terminal.customColorScheme`: Swift `TerminalColorScheme` JSON.
    pub custom_color_scheme: Option<String>,
    pub cursor_shape: CursorShape,
    pub cursor_blink: bool,
    /// `[next] padding`, in points around the terminal grid.
    pub padding: f32,
    pub opacity: f32,
    /// `terminal.customFontFamily`: a font typed by hand, listed first in the picker.
    pub custom_font_family: String,
    /// `terminal.fontWeight`: NSFontManager weight 0 (ultralight) to 14, 5 regular.
    pub font_weight: i32,
    /// `terminal.enableLigatures` (off).
    pub ligatures: bool,
    /// `terminal.defaultZoomPercent` (100, 50 to 200): new tabs and Actual Size.
    pub default_zoom_percent: u32,
    /// `terminal.cursorColor`: hex override of the scheme's cursor color, empty for none.
    pub cursor_color: String,
    /// `terminal.cursorBlinkRate`: seconds per blink phase (0.3 to 2). Unset
    /// keeps the Swift renderer's 0.5 s.
    pub cursor_blink_rate: Option<f32>,
    /// `app.theme`.
    pub app_theme: AppTheme,
    /// `window.floating`: windows stay above other apps.
    pub window_floating: bool,
    pub display: DisplayOptions,
    pub graphics: GraphicsOptions,
    pub rendering: RenderingOptions,
}

impl Default for AppearanceSettings {
    fn default() -> Self {
        Self {
            font_family: default_font_family().into(),
            font_size: 11.0,
            line_height: 1.25,
            color_scheme: ColorScheme::named("Default"),
            custom_color_scheme: None,
            cursor_shape: CursorShape::Block,
            cursor_blink: true,
            padding: 4.0,
            opacity: 1.0,
            custom_font_family: String::new(),
            font_weight: 5,
            ligatures: false,
            default_zoom_percent: 100,
            cursor_color: String::new(),
            cursor_blink_rate: None,
            app_theme: AppTheme::System,
            window_floating: false,
            display: DisplayOptions::default(),
            graphics: GraphicsOptions::default(),
            rendering: RenderingOptions::default(),
        }
    }
}

impl AppearanceSettings {
    /// Font size for new tabs and Actual Size: the font size scaled by the
    /// default zoom (`applyDefaultFontSize`), within 6 to 72 pt.
    pub fn zoomed_font_size(&self) -> f32 {
        (self.font_size * self.default_zoom_percent as f32 / 100.0)
            .round()
            .clamp(6.0, 72.0)
    }

    /// Cursor blink phase length.
    pub fn blink_interval(&self) -> std::time::Duration {
        std::time::Duration::from_secs_f32(self.cursor_blink_rate.unwrap_or(0.5))
    }
}

fn default_font_family() -> &'static str {
    if cfg!(target_os = "macos") {
        "SF Mono"
    } else if cfg!(windows) {
        "Consolas"
    } else {
        "DejaVu Sans Mono"
    }
}

/// Fonts tried when the configured family is missing.
pub fn fallback_fonts() -> Vec<String> {
    let list: &[&str] = if cfg!(target_os = "macos") {
        &["SF Mono", "Menlo", "Monaco", "Courier New"]
    } else if cfg!(windows) {
        &["Cascadia Mono", "Consolas", "Courier New"]
    } else {
        &[
            "DejaVu Sans Mono",
            "Liberation Mono",
            "Noto Sans Mono",
            "monospace",
        ]
    };
    list.iter().map(|s| s.to_string()).collect()
}

fn number(v: &RawValue) -> Option<f64> {
    v.as_double().or(v.as_int().map(|i| i as f64))
}

/// TOML literal string for a `[next]` value (no escapes are read back).
fn literal(s: &str) -> String {
    format!("'{}'", s.replace('\'', "\u{2019}"))
}

impl SettingsDomain for AppearanceSettings {
    fn load(&mut self, src: &ConfigSource) {
        if let Some(json) = src.next("custom_color_scheme").and_then(RawValue::as_str) {
            self.custom_color_scheme = Some(json.to_string()).filter(|j| !j.trim().is_empty());
        }
        if let Some(appearance) = &src.file.appearance {
            if let Some(family) = appearance.font_family.clone().filter(|f| !f.is_empty()) {
                self.font_family = family;
            }
            if let Some(size) = appearance.font_size.filter(|s| (6..=72).contains(s)) {
                self.font_size = size as f32;
            }
            if let Some(scheme) = &appearance.color_scheme {
                self.color_scheme =
                    ColorScheme::resolve(scheme, self.custom_color_scheme.as_deref());
            }
            if let Some(style) = &appearance.cursor_style {
                self.cursor_shape = match style.to_ascii_lowercase().as_str() {
                    "bar" | "beam" | "line" => CursorShape::Bar,
                    "underline" => CursorShape::Underline,
                    _ => CursorShape::Block,
                };
            }
            if let Some(blink) = appearance.cursor_blink {
                self.cursor_blink = blink;
            }
            if let Some(opacity) = appearance.opacity {
                self.opacity = (opacity as f32).clamp(0.3, 1.0);
            }
        }
        if let Some(terminal) = &src.file.terminal {
            if let Some(sixel) = terminal.sixel_enabled {
                self.graphics.sixel = sixel;
            }
            if let Some(kitty) = terminal.kitty_graphics {
                self.graphics.kitty = kitty;
            }
        }
        let num = |key: &str| src.next(key).and_then(number);
        let flag = |key: &str| src.next(key).and_then(RawValue::as_bool);
        let text = |key: &str| src.next(key).and_then(RawValue::as_str).map(str::to_string);
        if let Some(v) = num("padding") {
            self.padding = (v as f32).clamp(0.0, 40.0);
        }
        if let Some(v) = text("custom_font_family") {
            self.custom_font_family = v.trim().to_string();
        }
        if let Some(v) = num("font_weight") {
            self.font_weight = (v as i32).clamp(0, 14);
        }
        if let Some(v) = flag("enable_ligatures") {
            self.ligatures = v;
        }
        if let Some(v) = num("default_zoom_percent") {
            self.default_zoom_percent = (v as u32).clamp(50, 200);
        }
        if let Some(v) = text("cursor_color") {
            self.cursor_color = v.trim().to_string();
        }
        if let Some(v) = num("cursor_blink_rate") {
            self.cursor_blink_rate = Some((v as f32).clamp(0.3, 2.0));
        }
        if let Some(v) = text("app_theme").and_then(|t| AppTheme::parse(&t)) {
            self.app_theme = v;
        }
        if let Some(v) = flag("window_floating") {
            self.window_floating = v;
        }
        let d = &mut self.display;
        if let Some(v) = flag("syntax_highlight") {
            d.syntax_highlight = v;
        }
        if let Some(v) = flag("clickable_urls") {
            d.clickable_urls = v;
        }
        if let Some(v) = flag("inline_images") {
            d.inline_images = v;
        }
        if let Some(v) = flag("json_pretty_print") {
            d.json_pretty_print = v;
        }
        if let Some(v) = flag("line_timestamps") {
            d.line_timestamps = v;
        }
        if let Some(v) = text("timestamp_format").filter(|f| !f.trim().is_empty()) {
            d.timestamp_format = v;
        }
        if let Some(v) = num("kitty_cache_limit_mb") {
            self.graphics.kitty_cache_limit_mb = (v as u32).clamp(64, 1024);
        }
        if let Some(v) = flag("use_metal_renderer") {
            self.rendering.gpu_renderer = v;
        }
        if let Some(v) = flag("suspend_background_rendering") {
            self.rendering.suspend_background = v;
        }
        if let Some(v) = num("suspend_render_delay_seconds") {
            self.rendering.suspend_delay_secs = (v as f32).max(0.0);
        }
    }

    fn save(&self, out: &mut ConfigSink) {
        let appearance = out.file.appearance.get_or_insert_with(Default::default);
        appearance.font_family = Some(self.font_family.clone());
        appearance.font_size = Some(self.font_size.round() as i64);
        appearance.color_scheme = Some(self.color_scheme.name.to_string());
        appearance.cursor_style = Some(
            match self.cursor_shape {
                CursorShape::Block => "block",
                CursorShape::Bar => "bar",
                CursorShape::Underline => "underline",
            }
            .to_string(),
        );
        appearance.cursor_blink = Some(self.cursor_blink);
        appearance.opacity = Some((self.opacity as f64 * 100.0).round() / 100.0);
        let terminal = out.file.terminal.get_or_insert_with(Default::default);
        terminal.sixel_enabled = Some(self.graphics.sixel);
        terminal.kitty_graphics = Some(self.graphics.kitty);

        out.set_next("padding", self.padding.round() as i64);
        if let Some(json) = &self.custom_color_scheme {
            out.set_next("custom_color_scheme", literal(json));
        }
        out.set_next("custom_font_family", literal(&self.custom_font_family));
        out.set_next("font_weight", self.font_weight);
        out.set_next("enable_ligatures", self.ligatures);
        out.set_next("default_zoom_percent", self.default_zoom_percent);
        out.set_next("cursor_color", literal(&self.cursor_color));
        if let Some(rate) = self.cursor_blink_rate {
            out.set_next("cursor_blink_rate", format!("{:.2}", rate));
        }
        out.set_next("app_theme", literal(self.app_theme.raw()));
        out.set_next("window_floating", self.window_floating);
        let d = &self.display;
        out.set_next("syntax_highlight", d.syntax_highlight);
        out.set_next("clickable_urls", d.clickable_urls);
        out.set_next("inline_images", d.inline_images);
        out.set_next("json_pretty_print", d.json_pretty_print);
        out.set_next("line_timestamps", d.line_timestamps);
        out.set_next("timestamp_format", literal(&d.timestamp_format));
        out.set_next("kitty_cache_limit_mb", self.graphics.kitty_cache_limit_mb);
        let r = &self.rendering;
        out.set_next("use_metal_renderer", r.gpu_renderer);
        out.set_next("suspend_background_rendering", r.suspend_background);
        out.set_next(
            "suspend_render_delay_seconds",
            format!("{:.1}", r.suspend_delay_secs),
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::settings::{load_text, round_trip};
    use chau7_next_core::color_schemes::CUSTOM_NAME;

    #[test]
    fn round_trips() {
        let appearance = AppearanceSettings {
            font_family: "Menlo".into(),
            font_size: 14.0,
            color_scheme: ColorScheme::named("Nord"),
            cursor_shape: CursorShape::Underline,
            cursor_blink: false,
            padding: 8.0,
            opacity: 0.85,
            custom_font_family: "Fira Code".into(),
            font_weight: 7,
            ligatures: true,
            default_zoom_percent: 150,
            cursor_color: "#FF0000".into(),
            cursor_blink_rate: Some(0.8),
            app_theme: AppTheme::Light,
            window_floating: true,
            display: DisplayOptions {
                syntax_highlight: false,
                clickable_urls: false,
                inline_images: false,
                json_pretty_print: true,
                line_timestamps: true,
                timestamp_format: "yyyy-MM-dd HH:mm".into(),
            },
            graphics: GraphicsOptions {
                sixel: true,
                kitty: true,
                kitty_cache_limit_mb: 512,
            },
            rendering: RenderingOptions {
                gpu_renderer: false,
                suspend_background: true,
                suspend_delay_secs: 2.5,
            },
            ..Default::default()
        };
        assert_eq!(round_trip(&appearance), appearance);
    }

    #[test]
    fn custom_color_scheme_round_trips() {
        let json = ColorScheme::named("Dracula").to_json();
        let appearance = AppearanceSettings {
            color_scheme: ColorScheme::resolve(CUSTOM_NAME, Some(&json)),
            custom_color_scheme: Some(json.clone()),
            ..Default::default()
        };
        let loaded = round_trip(&appearance);
        assert_eq!(loaded.color_scheme.name, CUSTOM_NAME);
        assert_eq!(
            loaded.color_scheme.background,
            ColorScheme::named("Dracula").background
        );
    }

    #[test]
    fn clamps_and_aliases() {
        let a: AppearanceSettings = load_text(
            "[appearance]\nfont_size = 200\ncursor_style = \"beam\"\nopacity = 0.1\n\n[next]\npadding = 99\ndefault_zoom_percent = 900\nfont_weight = -3\nkitty_cache_limit_mb = 10\n",
        );
        assert_eq!(a.font_size, 11.0);
        assert_eq!(a.cursor_shape, CursorShape::Bar);
        assert_eq!(a.opacity, 0.3);
        assert_eq!(a.padding, 40.0);
        assert_eq!(a.default_zoom_percent, 200);
        assert_eq!(a.font_weight, 0);
        assert_eq!(a.graphics.kitty_cache_limit_mb, 64);
    }

    #[test]
    fn swift_defaults() {
        let a = AppearanceSettings::default();
        assert_eq!(a.display.timestamp_format, "HH:mm:ss");
        assert!(a.display.inline_images && a.display.clickable_urls);
        assert!(!a.graphics.sixel && !a.graphics.kitty);
        assert_eq!(a.graphics.kitty_cache_limit_mb, 256);
        assert_eq!(a.app_theme, AppTheme::System);
        assert_eq!(a.blink_interval().as_millis(), 500);
    }

    #[test]
    fn default_zoom_scales_the_font() {
        let mut a = AppearanceSettings {
            font_size: 12.0,
            default_zoom_percent: 150,
            ..Default::default()
        };
        assert_eq!(a.zoomed_font_size(), 18.0);
        a.default_zoom_percent = 50;
        assert_eq!(a.zoomed_font_size(), 6.0);
    }
}
