//! Tab notification styles (`TabNotificationStyle` in
//! `Overlay/OverlayTabsModel.swift`): the look a tab takes when a
//! notification action styles it (waiting, error, success, attention, or a
//! custom style), and `buildNotificationStyle(preset:config:)`.

use std::collections::HashMap;

/// Named colors a style can use (`colorFromString` plus `.primary`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum StyleColor {
    Red,
    Orange,
    Yellow,
    Green,
    Blue,
    Purple,
    Pink,
    /// The default text color.
    Primary,
}

impl StyleColor {
    /// `colorFromString`: unknown names give `Primary`.
    pub fn from_name(name: &str) -> StyleColor {
        match name.to_lowercase().as_str() {
            "red" => StyleColor::Red,
            "orange" => StyleColor::Orange,
            "yellow" => StyleColor::Yellow,
            "green" => StyleColor::Green,
            "blue" => StyleColor::Blue,
            "purple" => StyleColor::Purple,
            "pink" => StyleColor::Pink,
            _ => StyleColor::Primary,
        }
    }
}

/// Border dash pattern.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum BorderStyle {
    #[default]
    Solid,
    /// 3 on, 3 off.
    Dotted,
    /// 6 on, 4 off.
    Dashed,
}

impl BorderStyle {
    /// Dash lengths in points, empty for solid.
    pub fn dash(self) -> &'static [f32] {
        match self {
            BorderStyle::Solid => &[],
            BorderStyle::Dotted => &[3.0, 3.0],
            BorderStyle::Dashed => &[6.0, 4.0],
        }
    }
}

/// Glyphs standing in for the Swift SF Symbols.
pub mod icons {
    /// `ellipsis.circle`
    pub const WAITING: &str = "…";
    /// `exclamationmark.triangle.fill`
    pub const ERROR: &str = "⚠";
    /// `checkmark.circle.fill`
    pub const SUCCESS: &str = "✓";
    /// `bell.fill`
    pub const BELL: &str = "🔔︎";
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct TabNotificationStyle {
    pub title_color: Option<StyleColor>,
    pub italic: bool,
    pub bold: bool,
    pub pulse: bool,
    pub icon: Option<&'static str>,
    pub icon_color: Option<StyleColor>,
    pub border_color: Option<StyleColor>,
    pub border_width: f32,
    pub border_style: BorderStyle,
    /// Feeds the hover card summary; Swift does not draw it on the tab.
    pub badge_text: Option<String>,
    /// Default red.
    pub badge_color: Option<StyleColor>,
    /// Stays when the tab is selected (permission requests).
    pub persistent: bool,
}

impl TabNotificationStyle {
    pub fn waiting() -> Self {
        Self {
            title_color: Some(StyleColor::Orange),
            italic: true,
            pulse: true,
            icon: Some(icons::WAITING),
            border_color: Some(StyleColor::Orange),
            border_width: 1.5,
            ..Default::default()
        }
    }

    pub fn error() -> Self {
        Self {
            title_color: Some(StyleColor::Red),
            bold: true,
            icon: Some(icons::ERROR),
            icon_color: Some(StyleColor::Red),
            border_color: Some(StyleColor::Red),
            border_width: 1.5,
            ..Default::default()
        }
    }

    pub fn success() -> Self {
        Self {
            title_color: Some(StyleColor::Green),
            icon: Some(icons::SUCCESS),
            icon_color: Some(StyleColor::Green),
            ..Default::default()
        }
    }

    pub fn attention() -> Self {
        Self {
            title_color: Some(StyleColor::Yellow),
            bold: true,
            pulse: true,
            icon: Some(icons::BELL),
            icon_color: Some(StyleColor::Yellow),
            border_color: Some(StyleColor::Yellow),
            border_width: 1.5,
            ..Default::default()
        }
    }

    /// Hover card notification row (`TabHoverCard.notificationSummary`):
    /// label and color. `None` color means secondary text.
    pub fn summary(&self) -> (&'static str, Option<StyleColor>) {
        let is = |c: StyleColor| {
            self.title_color == Some(c)
                || self.icon_color == Some(c)
                || self.border_color == Some(c)
        };
        if self.icon == Some(icons::ERROR) || is(StyleColor::Red) {
            return ("Error", Some(StyleColor::Red));
        }
        if self.icon == Some(icons::SUCCESS)
            || self.title_color == Some(StyleColor::Green)
            || self.icon_color == Some(StyleColor::Green)
        {
            return ("Success", Some(StyleColor::Green));
        }
        if self.icon == Some(icons::BELL)
            || self.persistent
            || self.badge_text.is_some()
            || self.border_width > 0.0
            || self.title_color == Some(StyleColor::Yellow)
            || self.icon_color == Some(StyleColor::Yellow)
        {
            return ("Attention", Some(StyleColor::Yellow));
        }
        if self.icon == Some(icons::WAITING) || self.italic {
            return ("Waiting", Some(StyleColor::Orange));
        }
        ("Active", self.title_color)
    }
}

fn config_flag(config: &HashMap<String, String>, key: &str) -> Option<bool> {
    config.get(key).map(|v| {
        let v = v.to_lowercase();
        v == "true" || v == "1"
    })
}

/// `buildNotificationStyle(preset:config:)`; `None` for the "clear" preset.
pub fn build_notification_style(
    preset: &str,
    config: &HashMap<String, String>,
) -> Option<TabNotificationStyle> {
    let mut style = match preset {
        "clear" => return None,
        "waiting" => TabNotificationStyle::waiting(),
        "error" => TabNotificationStyle::error(),
        "success" => TabNotificationStyle::success(),
        "attention" => TabNotificationStyle::attention(),
        _ => TabNotificationStyle::default(),
    };
    let custom = config
        .get("customColor")
        .filter(|c| !c.is_empty())
        .map(|c| StyleColor::from_name(c));
    if let Some(color) = custom {
        style.title_color = Some(color);
        style.icon_color = Some(color);
    }
    if let Some(v) = config_flag(config, "italic") {
        style.italic = v;
    }
    if let Some(v) = config_flag(config, "bold") {
        style.bold = v;
    }
    if let Some(v) = config_flag(config, "pulse") {
        style.pulse = v;
    }
    if let Some(width) = config
        .get("borderWidth")
        .and_then(|w| w.trim().parse::<f64>().ok())
        .filter(|w| *w > 0.0)
    {
        style.border_width = width as f32;
        style.border_color = Some(custom.or(style.title_color).unwrap_or(StyleColor::Red));
        style.border_style = match config
            .get("borderStyle")
            .map(|s| s.to_lowercase())
            .as_deref()
        {
            Some("dotted") => BorderStyle::Dotted,
            Some("dashed") => BorderStyle::Dashed,
            _ => style.border_style,
        };
    }
    if let Some(v) = config_flag(config, "persistent") {
        style.persistent = v;
    }
    Some(style)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn config(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn clear_preset_removes_the_style() {
        assert_eq!(build_notification_style("clear", &config(&[])), None);
    }

    #[test]
    fn presets_match_swift() {
        let waiting = build_notification_style("waiting", &config(&[])).unwrap();
        assert_eq!(waiting, TabNotificationStyle::waiting());
        assert!(waiting.italic && waiting.pulse);
        assert_eq!(waiting.border_width, 1.5);
        let unknown = build_notification_style("nope", &config(&[])).unwrap();
        assert_eq!(unknown, TabNotificationStyle::default());
    }

    #[test]
    fn custom_overrides() {
        let style = build_notification_style(
            "custom",
            &config(&[
                ("customColor", "Purple"),
                ("italic", "1"),
                ("bold", "TRUE"),
                ("pulse", "false"),
                ("borderWidth", "2"),
                ("borderStyle", "dotted"),
                ("persistent", "true"),
            ]),
        )
        .unwrap();
        assert_eq!(style.title_color, Some(StyleColor::Purple));
        assert_eq!(style.icon_color, Some(StyleColor::Purple));
        assert_eq!(style.border_color, Some(StyleColor::Purple));
        assert!(style.italic && style.bold && !style.pulse && style.persistent);
        assert_eq!(style.border_width, 2.0);
        assert_eq!(style.border_style.dash(), &[3.0, 3.0]);
    }

    #[test]
    fn border_color_falls_back_to_title_then_red() {
        let style = build_notification_style("success", &config(&[("borderWidth", "1")])).unwrap();
        assert_eq!(style.border_color, Some(StyleColor::Green));
        let style = build_notification_style(
            "custom",
            &config(&[("borderWidth", "1"), ("borderStyle", "dashed")]),
        )
        .unwrap();
        assert_eq!(style.border_color, Some(StyleColor::Red));
        assert_eq!(style.border_style, BorderStyle::Dashed);
        // A zero width keeps the preset's border.
        let style = build_notification_style("error", &config(&[("borderWidth", "0")])).unwrap();
        assert_eq!(style.border_width, 1.5);
    }

    #[test]
    fn hover_card_summary_order() {
        assert_eq!(TabNotificationStyle::error().summary().0, "Error");
        assert_eq!(TabNotificationStyle::success().summary().0, "Success");
        assert_eq!(TabNotificationStyle::attention().summary().0, "Attention");
        // Waiting has an orange border, which counts as "Attention" first.
        assert_eq!(TabNotificationStyle::waiting().summary().0, "Attention");
        let italic = TabNotificationStyle {
            italic: true,
            ..Default::default()
        };
        assert_eq!(italic.summary().0, "Waiting");
        assert_eq!(TabNotificationStyle::default().summary(), ("Active", None));
    }

    #[test]
    fn unknown_color_name_is_primary() {
        assert_eq!(StyleColor::from_name("teal"), StyleColor::Primary);
        assert_eq!(StyleColor::from_name("RED"), StyleColor::Red);
    }
}
