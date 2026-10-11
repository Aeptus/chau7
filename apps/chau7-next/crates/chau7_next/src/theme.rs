//! Colors for terminal content and app chrome.
//!
//! Terminal colors come from the selected color scheme (see
//! `chau7_next_core::color_schemes`). Terminal window chrome (tab bar,
//! overlays) is derived from the scheme background so the window looks like
//! one surface, as the Swift app's dark toolbar does. Other windows
//! (settings) follow the app theme, System, Light or Dark
//! ([`Chrome::panels`], `AppTheme.swift`). With macOS "Increase contrast"
//! on, chrome text and borders get stronger (`HighContrastModifier`).

use std::cell::Cell;
use std::time::{Duration, Instant};

use chau7_next_core::color_schemes::ColorScheme;
use chau7_next_core::tabs_state::TabColor;
use gpui::{App, Hsla, Rgba};

use crate::platform::{system, window_style};
use crate::settings::{AppTheme, Settings};

pub fn rgb_tuple((r, g, b): (u8, u8, u8)) -> Hsla {
    Rgba {
        r: r as f32 / 255.0,
        g: g as f32 / 255.0,
        b: b as f32 / 255.0,
        a: 1.0,
    }
    .into()
}

pub fn scheme_color(hex: &str) -> Hsla {
    rgb_tuple(ColorScheme::rgb(hex))
}

pub fn tab_color(color: TabColor) -> Hsla {
    let (r, g, b) = color.rgb();
    Rgba { r, g, b, a: 1.0 }.into()
}

/// Chrome palette for the current settings.
#[derive(Debug, Clone, Copy)]
pub struct Chrome {
    pub is_dark: bool,
    pub terminal_bg: Hsla,
    pub tab_bg: Hsla,
    pub tab_hover_bg: Hsla,
    pub tab_selected_bg: Hsla,
    pub text: Hsla,
    pub text_muted: Hsla,
    pub border: Hsla,
    pub panel_bg: Hsla,
    pub accent: Hsla,
    pub danger: Hsla,
}

impl Chrome {
    /// Terminal window chrome, from the color scheme background.
    pub fn get(cx: &App) -> Chrome {
        let appearance = &Settings::get(cx).appearance;
        let bg = scheme_color(appearance.color_scheme.background);
        Self::from_background(bg, content_opacity(cx), high_contrast())
    }

    /// Chrome of the other windows (settings): a light or dark palette
    /// following [`app_is_dark`].
    pub fn panels(cx: &App) -> Chrome {
        let bg = if app_is_dark(cx) {
            gpui::hsla(0.0, 0.0, 0.13, 1.0)
        } else {
            gpui::hsla(0.0, 0.0, 0.95, 1.0)
        };
        Self::from_background(bg, 1.0, high_contrast())
    }

    /// Chrome of the tab bar and title bar (APR-011). Swift draws its
    /// toolbar on the HUD material, which is dark whatever the color
    /// scheme, so the tab bar uses a fixed dark palette wherever
    /// [`tab_bar_uses_hud`] says so, and the scheme's chrome elsewhere.
    pub fn tab_bar(cx: &App) -> Chrome {
        if tab_bar_uses_hud(cx) {
            Self::hud(high_contrast())
        } else {
            Self::get(cx)
        }
    }

    /// The HUD palette: light text on the dark HUD gray.
    pub fn hud(high_contrast: bool) -> Chrome {
        Self::from_background(HUD_GRAY, 1.0, high_contrast)
    }

    fn from_background(bg: Hsla, opacity: f32, high_contrast: bool) -> Chrome {
        let is_dark = bg.l < 0.5;
        let shift = |l: f32| Hsla {
            l: if is_dark {
                (bg.l + l).min(1.0)
            } else {
                (bg.l - l).max(0.0)
            },
            ..bg
        };
        let fg = match (is_dark, high_contrast) {
            (true, false) => gpui::hsla(0.0, 0.0, 0.92, 1.0),
            (true, true) => gpui::hsla(0.0, 0.0, 1.0, 1.0),
            (false, false) => gpui::hsla(0.0, 0.0, 0.12, 1.0),
            (false, true) => gpui::hsla(0.0, 0.0, 0.0, 1.0),
        };
        let border = if high_contrast { 0.35 } else { 0.12 };
        Chrome {
            is_dark,
            terminal_bg: bg.opacity(opacity),
            tab_bg: shift(0.04),
            tab_hover_bg: shift(0.08),
            tab_selected_bg: shift(0.14),
            text: fg,
            text_muted: fg.opacity(if high_contrast { 0.85 } else { 0.6 }),
            border: shift(border),
            panel_bg: shift(0.06),
            accent: gpui::hsla(0.58, 0.85, 0.6, 1.0),
            danger: gpui::hsla(0.0, 0.75, 0.55, 1.0),
        }
    }
}

/// Gray of the HUD material (`NSVisualEffectView.Material.hudWindow`).
const HUD_GRAY: Hsla = Hsla {
    h: 0.0,
    s: 0.0,
    l: 0.11,
    a: 1.0,
};

/// Whether the tab bar is drawn as the dark HUD (APR-011). Always on macOS,
/// like Swift, where the window buttons are the system's. On Linux and
/// Windows the window buttons are drawn by gpui-component in the app
/// theme's colors (dark icons in a light theme), so the HUD is used only
/// when the app is dark and the scheme's chrome otherwise.
pub fn tab_bar_uses_hud(cx: &App) -> bool {
    cfg!(target_os = "macos") || app_is_dark(cx)
}

/// The tab bar and titlebar background (`ToolbarBackgroundView`,
/// `TitlebarBackgroundInstaller`: an NSVisualEffectView with the HUD
/// material). On macOS the window is always the blurred material, so a
/// translucent HUD tint here shows the blurred desktop through the tab bar
/// only; the terminal area stays opaque. Elsewhere the tint is opaque.
pub fn hud_titlebar_background(chrome: &Chrome) -> Hsla {
    let alpha = if cfg!(target_os = "macos") { 0.72 } else { 1.0 };
    if chrome.is_dark {
        gpui::hsla(0.0, 0.0, 0.11, alpha)
    } else {
        gpui::hsla(0.0, 0.0, 0.93, alpha)
    }
}

/// Whether the app's windows are dark: Light or Dark when the app theme
/// says so (`app.theme`, every window follows it), else the terminal
/// chrome's, which comes from the color scheme. GPUI components (title
/// bars, inputs) and the settings window use it.
pub fn app_is_dark(cx: &App) -> bool {
    match Settings::get(cx).appearance.app_theme {
        AppTheme::Light => false,
        AppTheme::Dark => true,
        AppTheme::System => Chrome::get(cx).is_dark,
    }
}

/// Opacity of the terminal background. On macOS the whole window fades
/// instead (`NSWindow.alphaValue`, like Swift), so the content stays opaque.
pub fn content_opacity(cx: &App) -> f32 {
    content_opacity_for(Settings::get(cx))
}

pub fn content_opacity_for(settings: &Settings) -> f32 {
    if window_style::supports_window_alpha() {
        1.0
    } else {
        settings.appearance.opacity
    }
}

/// macOS "Increase contrast", read at most once a second.
pub fn high_contrast() -> bool {
    thread_local! {
        static CACHE: Cell<Option<(Instant, bool)>> = const { Cell::new(None) };
    }
    CACHE.with(|cache| match cache.get() {
        Some((at, value)) if at.elapsed() < Duration::from_secs(1) => value,
        _ => {
            let value = system::increase_contrast();
            cache.set(Some((Instant::now(), value)));
            value
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hud_chrome_is_dark_with_light_text() {
        for high_contrast in [false, true] {
            let hud = Chrome::hud(high_contrast);
            assert!(hud.is_dark);
            assert!(hud.text.l > 0.9, "tab titles must read on the HUD");
            assert!(hud.text_muted.l > 0.9 && hud.text_muted.a >= 0.6);
            assert!(hud.tab_selected_bg.l > hud.tab_bg.l);
        }
    }
}
