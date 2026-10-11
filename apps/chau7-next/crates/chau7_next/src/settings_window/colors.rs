//! Colors and window (`FontColorsSettingsView.swift`, `AppearanceSettingsView.swift`):
//! live terminal preview, color scheme (presets and "Custom"), window
//! opacity, app theme, floating window. Dangerous command highlighting is in
//! the Dangerous Commands section.

use chau7_next_core::color_schemes::{CUSTOM_NAME, ColorScheme, PRESETS};
use gpui::{SharedString, div, prelude::*, px};

use super::SectionContext;
use super::update;
use super::widgets::{chip, row, section as titled, stepper, toggle};
use crate::settings::{AppTheme, AppearanceSettings};
use crate::theme::{Chrome, scheme_color};

fn scheme_tile(
    index: usize,
    scheme: &'static ColorScheme,
    active: bool,
    chrome: Chrome,
    on_click: impl Fn(&mut gpui::App) + 'static,
) -> impl IntoElement {
    div()
        .id(("scheme", index))
        .w(px(116.0))
        .p_2()
        .rounded_md()
        .border_1()
        .border_color(if active { chrome.accent } else { chrome.border })
        .bg(scheme_color(scheme.background))
        .text_xs()
        .text_color(scheme_color(scheme.foreground))
        .child(scheme.name)
        .child(
            div().flex().gap_0p5().mt_1().children(
                scheme.ansi[1..7]
                    .iter()
                    .map(|hex| div().size(px(10.0)).rounded_sm().bg(scheme_color(hex))),
            ),
        )
        .on_click(move |_, _, cx| on_click(cx))
}

/// `LiveTerminalPreview`: a small terminal drawn with the current scheme,
/// font and opacity.
fn live_preview(s: &AppearanceSettings, chrome: Chrome) -> gpui::Div {
    let scheme = s.color_scheme;
    let c = |hex: &str| scheme_color(hex);
    let fg = c(scheme.foreground);
    let font = SharedString::from(s.font_family.clone());
    let size = px((s.font_size * 0.85).max(8.0));
    let line = |parts: Vec<(&'static str, gpui::Hsla)>| {
        div().flex().children(
            parts
                .into_iter()
                .map(|(text, color)| div().text_color(color).child(text)),
        )
    };
    let prompt = |cmd: &'static str| {
        line(vec![
            ("user@mac", c(scheme.ansi[2])),
            (":", fg),
            ("~/Projects", c(scheme.ansi[4])),
            ("$ ", fg),
            (cmd, fg),
        ])
    };
    let dim = c(scheme.ansi[8]);
    let cursor = crate::terminal::paint::cursor_color(scheme, &s.cursor_color);
    div()
        .w_full()
        .rounded_lg()
        .border_1()
        .border_color(chrome.border)
        .overflow_hidden()
        .child(
            div()
                .flex()
                .items_center()
                .gap_1p5()
                .px_2p5()
                .py_1p5()
                .bg(chrome.tab_bg)
                .text_xs()
                .text_color(chrome.text_muted)
                .child(div().size(px(10.0)).rounded_full().bg(gpui::rgb(0xFF5F57)))
                .child(div().size(px(10.0)).rounded_full().bg(gpui::rgb(0xFEBC2E)))
                .child(div().size(px(10.0)).rounded_full().bg(gpui::rgb(0x28C840)))
                .child(
                    div()
                        .flex_1()
                        .text_center()
                        .child(crate::l10n::tr("Terminal Preview - zsh")),
                ),
        )
        .child(
            div()
                .p_3()
                .flex()
                .flex_col()
                .gap_0p5()
                .bg(c(scheme.background).opacity(s.opacity))
                .font_family(font)
                .text_size(size)
                .child(prompt("ls -la"))
                .child(line(vec![("total 32", fg)]))
                .child(line(vec![(
                    "drwxr-xr-x  5 user  staff   160 Jan 11 14:30 .",
                    dim,
                )]))
                .child(line(vec![
                    ("-rw-r--r--  ", fg),
                    ("main.swift", c(scheme.ansi[6])),
                ]))
                .child(line(vec![
                    ("drwxr-xr-x  ", fg),
                    ("Sources/", c(scheme.ansi[4])),
                ]))
                .child(
                    div()
                        .flex()
                        .items_center()
                        .child(prompt(""))
                        .child(div().w(size * 0.6).h(size * 1.2).bg(cursor)),
                ),
        )
}

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let s = ctx.settings;
    let a = &s.appearance;
    let mut tiles: Vec<gpui::AnyElement> = PRESETS
        .iter()
        .enumerate()
        .map(|(i, scheme)| {
            let name = scheme.name;
            scheme_tile(i, scheme, a.color_scheme.name == name, chrome, move |cx| {
                update(cx, |s| s.appearance.color_scheme = ColorScheme::named(name))
            })
            .into_any_element()
        })
        .collect();
    // "Custom" (`terminal.customColorScheme`), set by import or profiles.
    if let Some(custom) = a
        .custom_color_scheme
        .as_deref()
        .and_then(ColorScheme::from_json)
    {
        tiles.push(
            scheme_tile(
                PRESETS.len(),
                custom,
                a.color_scheme.name == CUSTOM_NAME,
                chrome,
                move |cx| update(cx, |s| s.appearance.color_scheme = custom),
            )
            .into_any_element(),
        );
    }
    titled("Colors", chrome)
        .child(live_preview(a, chrome))
        .child(div().flex().flex_wrap().gap_2().children(tiles))
}

pub(super) fn windows(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let a = &ctx.settings.appearance;
    let themes = AppTheme::ALL.into_iter().map(|theme| {
        chip(
            SharedString::from(format!("theme-{}", theme.raw())),
            theme.label(),
            a.app_theme == theme,
            chrome,
        )
        .on_click(move |_, _, cx| update(cx, |s| s.appearance.app_theme = theme))
    });
    titled("Interface", chrome)
        .child(row(
            "Window opacity",
            stepper(
                "opacity",
                format!("{:.0}%", a.opacity * 100.0),
                chrome,
                |s, d| {
                    s.appearance.opacity = (s.appearance.opacity + 0.05 * d as f32).clamp(0.3, 1.0)
                },
            ),
            chrome,
        ))
        .child(row(
            "Appearance",
            div().flex().gap_1().children(themes),
            chrome,
        ))
        .child(row(
            "Floating window",
            toggle("floating", a.window_floating, chrome, |s, v| {
                s.appearance.window_floating = v
            }),
            chrome,
        ))
}
