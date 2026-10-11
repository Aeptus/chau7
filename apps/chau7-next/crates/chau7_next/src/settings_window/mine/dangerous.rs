//! Dangerous commands: highlight scope, the command guard, its pattern list
//! and its allow and block lists (`DangerousCommandSettingsView.swift`).

use chau7_next_core::command_risk::DangerousCommandGuard;
use gpui::{SharedString, div, prelude::*, px};
use gpui_kit::component::input::Input;

use super::super::widgets::{chip, row, section as titled, toggle};
use super::super::{SectionContext, update};
use super::{guard_update, hint, small_button};
use crate::settings::{DangerousCommandSettings, HighlightScope};

pub(in super::super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let d = &ctx.settings.dangerous_commands;
    let mine = &ctx.view.mine;

    let scopes = HighlightScope::ALL.into_iter().map(|scope| {
        chip(
            SharedString::from(format!("scope-{}", scope.raw())),
            scope.label(),
            d.scope == scope,
            chrome,
        )
        .on_click(move |_, _, cx| update(cx, |s| s.dangerous_commands.scope = scope))
    });

    let list_box = |id: &'static str| {
        div()
            .id(id)
            .max_h(px(160.0))
            .overflow_y_scroll()
            .rounded_md()
            .border_1()
            .border_color(chrome.border)
            .p_1()
            .flex()
            .flex_col()
            .gap_0p5()
    };
    let item_row = |text: String| {
        div()
            .flex()
            .items_center()
            .justify_between()
            .gap_2()
            .text_xs()
            .child(
                div()
                    .flex_1()
                    .min_w_0()
                    .overflow_hidden()
                    .font_family("monospace")
                    .child(SharedString::from(text)),
            )
    };

    let patterns = d.patterns.iter().enumerate().map(|(i, text)| {
        let edit_text = text.clone();
        let input = ctx.view.mine.pattern.clone();
        item_row(text.clone()).child(
            div()
                .flex()
                .gap_1()
                .child(
                    small_button(SharedString::from(format!("pat-edit-{i}")), "Edit", chrome)
                        .on_click(move |_, window, cx| {
                            let value = edit_text.clone();
                            input
                                .update(cx, |state, cx| state.set_value(value.clone(), window, cx));
                            update(cx, |s| {
                                s.dangerous_commands.patterns.retain(|p| *p != value)
                            });
                        }),
                )
                .child(
                    small_button(SharedString::from(format!("pat-del-{i}")), "Remove", chrome)
                        .on_click({
                            let text = text.clone();
                            move |_, _, cx| {
                                update(cx, |s| s.dangerous_commands.patterns.retain(|p| *p != text))
                            }
                        }),
                ),
        )
    });

    let allowed = mine.allow.iter().enumerate().map(|(i, text)| {
        let text = text.clone();
        item_row(text.clone()).child(
            small_button(
                SharedString::from(format!("allow-del-{i}")),
                "Remove",
                chrome,
            )
            .on_click(move |_, _, cx| guard_update(cx, |g| g.remove_from_allow_list(&text))),
        )
    });
    let blocked = mine.blocked.iter().enumerate().map(|(i, text)| {
        let text = text.clone();
        item_row(text.clone()).child(
            small_button(
                SharedString::from(format!("block-del-{i}")),
                "Remove",
                chrome,
            )
            .on_click(move |_, _, cx| guard_update(cx, |g| g.remove_from_block_list(&text))),
        )
    });

    let mut guard = titled("Dangerous commands", chrome)
        .child(row(
            "Highlight risky commands",
            div().flex().gap_1().children(scopes),
            chrome,
        ))
        .child(row(
            "Ask before running a risky command",
            toggle("guard-enabled", d.guard_enabled, chrome, |s, v| {
                s.dangerous_commands.guard_enabled = v
            }),
            chrome,
        ))
        .child(hint(
            "Enter on a command that matches a pattern, contains look-alike characters, or a multi-line paste waits for your confirmation.",
            chrome,
        ));
    if d.guard_enabled {
        guard = guard
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_sm()
                            .child(format!("Risky patterns ({})", d.patterns.len())),
                    )
                    .child(
                        small_button("patterns-reset", "Reset to Defaults", chrome).on_click(
                            |_, _, cx| {
                                update(cx, |s| {
                                    s.dangerous_commands.patterns =
                                        DangerousCommandSettings::default().patterns
                                })
                            },
                        ),
                    ),
            )
            .child(div().w(px(320.0)).child(Input::new(&mine.pattern)))
            .child(list_box("patterns").children(patterns))
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_sm()
                            .child(format!("Always allowed ({})", mine.allow.len())),
                    )
                    .child(small_button("allow-clear", "Clear All", chrome).on_click(
                        |_, _, cx| guard_update(cx, DangerousCommandGuard::clear_allow_list),
                    )),
            )
            .child(list_box("allow-list").children(allowed))
            .child(
                div()
                    .flex()
                    .items_center()
                    .justify_between()
                    .child(
                        div()
                            .text_sm()
                            .child(format!("Always blocked ({})", mine.blocked.len())),
                    )
                    .child(small_button("block-clear", "Clear All", chrome).on_click(
                        |_, _, cx| guard_update(cx, DangerousCommandGuard::clear_block_list),
                    )),
            )
            .child(div().w(px(320.0)).child(Input::new(&mine.block)))
            .child(list_box("block-list").children(blocked));
    }
    guard
}
