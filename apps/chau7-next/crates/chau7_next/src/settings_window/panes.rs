//! Panes and restore: split panes on or off, lines of scrollback restored.

use crate::settings::Settings;
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
            stepper(
                "restored-scrollback",
                lines,
                chrome,
                change_restored_scrollback,
            ),
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

fn change_restored_scrollback(settings: &mut Settings, delta: i32) {
    let lines = settings.terminal.restored_scrollback_lines as i128 + i128::from(delta);
    settings.terminal.set_restored_scrollback_lines(lines);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn actual_restore_control_preserves_zero_and_current_swift_upper_bound() {
        for (start, delta, expected) in [
            (0, -1, 0),
            (0, 1, 1),
            (1, -1, 0),
            (333, -1, 332),
            (10_000, 1, 10_000),
            (10_000, -1, 9999),
            (500, i32::MIN, 0),
            (500, i32::MAX, 10_000),
        ] {
            let mut settings = Settings::default();
            settings.terminal.restored_scrollback_lines = start;
            change_restored_scrollback(&mut settings, delta);
            assert_eq!(settings.terminal.restored_scrollback_lines, expected);
        }
    }
}
