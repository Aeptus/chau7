//! Minimal mode (`MinimalModeSettingsView.swift`): master toggle, the
//! shortcut, which elements hide, and a status list.

use gpui::{div, prelude::*, px};

use super::SectionContext;
use super::widgets::{row, section as titled, toggle};
use crate::theme::Chrome;

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let m = &ctx.settings.minimal_mode;
    let enabled = m.enabled;
    let dim = |el: gpui::Div| if enabled { el } else { el.opacity(0.45) };
    let shortcut = if cfg!(target_os = "macos") {
        "Cmd+Shift+M"
    } else {
        "Ctrl+Shift+Alt+M"
    };
    let mut status = div()
        .flex()
        .flex_col()
        .gap(px(6.0))
        .p_3()
        .rounded_lg()
        .bg(chrome.tab_bg)
        .child(status_row("Minimal Mode", enabled, chrome));
    if enabled {
        for (label, hidden) in [
            ("Tab Bar", m.hide_tab_bar),
            ("Title Bar", m.hide_title_bar),
            ("Status Bar", m.hide_status_bar),
            ("Sidebar", m.hide_sidebar),
        ] {
            status = status.child(status_row(label, hidden, chrome));
        }
    }
    titled("Minimal Mode", chrome)
        .child(
            div()
                .text_xs()
                .text_color(chrome.text_muted)
                .child(crate::l10n::tr("Minimal mode hides non-essential UI chrome to maximize terminal real estate. Toggle it quickly with a keyboard shortcut.")),
        )
        .child(row(
            "Enable Minimal Mode",
            toggle("minimal-on", enabled, chrome, |s, v| s.minimal_mode.enabled = v),
            chrome,
        ))
        .child(row(
            "Toggle Minimal Mode",
            div()
                .px_2()
                .py(px(2.0))
                .rounded_md()
                .bg(chrome.tab_bg)
                .text_xs()
                .text_color(chrome.text_muted)
                .child(shortcut),
            chrome,
        ))
        .child(dim(row(
            "Hide Tab Bar",
            toggle("minimal-tabs", m.hide_tab_bar, chrome, |s, v| {
                if s.minimal_mode.enabled {
                    s.minimal_mode.hide_tab_bar = v
                }
            }),
            chrome,
        )))
        .child(dim(row(
            "Hide Title Bar",
            toggle("minimal-title", m.hide_title_bar, chrome, |s, v| {
                if s.minimal_mode.enabled {
                    s.minimal_mode.hide_title_bar = v
                }
            }),
            chrome,
        )))
        .child(dim(row(
            "Hide Status Bar",
            toggle("minimal-status", m.hide_status_bar, chrome, |s, v| {
                if s.minimal_mode.enabled {
                    s.minimal_mode.hide_status_bar = v
                }
            }),
            chrome,
        )))
        .child(dim(row(
            "Hide Sidebar",
            toggle("minimal-sidebar", m.hide_sidebar, chrome, |s, v| {
                if s.minimal_mode.enabled {
                    s.minimal_mode.hide_sidebar = v
                }
            }),
            chrome,
        )))
        .child(status)
}

fn status_row(label: &'static str, active: bool, chrome: Chrome) -> gpui::Div {
    let green = gpui::hsla(0.36, 0.65, 0.5, 1.0);
    div()
        .flex()
        .items_center()
        .gap_2()
        .child(div().size(px(8.0)).rounded_full().bg(if active {
            green
        } else {
            chrome.text_muted.opacity(0.4)
        }))
        .child(div().flex_1().text_xs().child(label))
        .child(
            div()
                .text_xs()
                .text_color(if active { green } else { chrome.text_muted })
                .child(if active { "Hidden" } else { "Visible" }),
        )
}
