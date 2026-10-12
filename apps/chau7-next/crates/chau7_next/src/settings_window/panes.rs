//! Panes and restore: split panes on or off, lines of scrollback restored.

use super::SettingsView;
use crate::settings::Settings;
use crate::settings::config_files::ConfigFiles;
use gpui::{Context, Entity, Subscription, Window, div, prelude::*, px};
use gpui_kit::component::input::{Input, InputEvent, InputState};

#[path = "panes_number.rs"]
mod number;

/// Own the edit buffer independently of refreshed settings snapshots.
pub(crate) struct PaneInputs {
    scrollback: Entity<InputState>,
    number_format: number::NumberFormat,
    edit_baseline: usize,
    last_displayed: String,
    editing: bool,
    _subscription: Subscription,
}

impl PaneInputs {
    pub(crate) fn new(window: &mut Window, cx: &mut Context<SettingsView>) -> Self {
        let value = Settings::get(cx).terminal.scrollback_lines;
        let baseline = cx.global::<ConfigFiles>().base.terminal.scrollback_lines;
        let number_format = number::NumberFormat::current();
        let displayed = number_format.format(value);
        let scrollback = cx.new(|cx| InputState::new(window, cx).default_value(displayed.clone()));
        let subscription = cx.subscribe_in(
            &scrollback,
            window,
            |view, input, event: &InputEvent, window, cx| {
                let current_base = cx.global::<ConfigFiles>().base.terminal.scrollback_lines;
                match event {
                    InputEvent::Focus => {
                        if !view.pane_inputs.editing {
                            let actual = view
                                .pane_inputs
                                .number_format
                                .format(Settings::get(cx).terminal.scrollback_lines);
                            // A text edit may already be queued behind Focus. Only
                            // refresh the previous displayed value, never that draft.
                            if input.read(cx).value().as_str() == view.pane_inputs.last_displayed {
                                input.update(cx, |state, cx| {
                                    state.set_value(actual.clone(), window, cx)
                                });
                            }
                            view.pane_inputs.last_displayed = actual;
                            view.pane_inputs.edit_baseline = current_base;
                        }
                        view.pane_inputs.editing = true;
                    }
                    InputEvent::Change => {
                        // Partial digits and signs remain draft text until submission.
                        view.pane_inputs.editing = true;
                    }
                    InputEvent::PressEnter { .. } | InputEvent::Blur => {
                        let raw = input.read(cx).value().to_string();
                        if view.pane_inputs.edit_baseline == current_base
                            && let Some(lines) = view.pane_inputs.number_format.parse(&raw)
                        {
                            super::update(cx, |settings| {
                                settings.terminal.set_scrollback_lines(i128::from(lines))
                            });
                        }
                        let actual = view
                            .pane_inputs
                            .number_format
                            .format(Settings::get(cx).terminal.scrollback_lines);
                        if raw != actual {
                            input.update(cx, |state, cx| {
                                state.set_value(actual.clone(), window, cx)
                            });
                        }
                        view.pane_inputs.last_displayed = actual;
                        view.pane_inputs.edit_baseline =
                            cx.global::<ConfigFiles>().base.terminal.scrollback_lines;
                        view.pane_inputs.editing = !matches!(event, InputEvent::Blur);
                    }
                }
            },
        );
        Self {
            scrollback,
            number_format,
            edit_baseline: baseline,
            last_displayed: displayed,
            editing: false,
            _subscription: subscription,
        }
    }
}

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
            div()
                .w(px(100.0))
                .child(Input::new(&ctx.view.pane_inputs.scrollback)),
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

#[cfg(test)]
#[path = "panes_input_test.rs"]
mod input_test;
