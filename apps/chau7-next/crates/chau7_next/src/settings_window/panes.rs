//! Panes and restore: split panes on or off, lines of scrollback restored.

use chau7_next_core::session_restore::MAX_RESTORED_SCROLLBACK_LINES;
use gpui::{div, prelude::*};

use super::SectionContext;
use super::widgets::{row, section as titled, stepper, toggle};

pub(super) fn splits(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    titled("Split Panes", chrome).child(row(
        "Enable Split Panes",
        toggle(
            "split-panes",
            ctx.settings.terminal.split_panes_enabled,
            chrome,
            |s, v| s.terminal.split_panes_enabled = v,
        ),
        chrome,
    ))
}

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let s = &ctx.settings.terminal;
    let lines = if s.restored_scrollback_lines == 0 {
        "Off".to_string()
    } else {
        format!("{} lines", s.restored_scrollback_lines)
    };
    titled("Scrollback", chrome)
        .child(row(
            "Scrollback lines",
            stepper(
                "scrollback",
                format!("{}", s.scrollback_lines),
                chrome,
                |s, d| {
                    s.terminal.scrollback_lines =
                        super::shell::scrollback_step(s.terminal.scrollback_lines, d)
                },
            ),
            chrome,
        ))
        .child(row(
            "Smart scroll",
            toggle("smart-scroll", s.smart_scroll, chrome, |s, v| {
                s.terminal.smart_scroll = v
            }),
            chrome,
        ))
        .child(row(
            "Restored scrollback when tabs are recovered",
            stepper("restored-scrollback", lines, chrome, |s, d| {
                let step = 100_i64;
                let lines = s.terminal.restored_scrollback_lines as i64 + step * d as i64;
                s.terminal.restored_scrollback_lines =
                    lines.clamp(0, MAX_RESTORED_SCROLLBACK_LINES as i64) as usize;
            }),
            chrome,
        ))
        .child(
            div()
                .text_xs()
                .text_color(chrome.text_muted)
                .child(crate::l10n::tr(
                    "Set to 0 to restore tabs without their scrollback.",
                )),
        )
}
