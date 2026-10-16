//! Keyboard and mouse (`InputSettingsView.swift`): keybinding preset, mouse
//! options, the list of keyboard shortcuts (conflicts in orange), the
//! shortcut helper hint, clipboard history, bell.

use chau7_next_core::input::clipboard_history::MAX_ITEMS_LIMIT;
use chau7_next_core::input::shortcuts;
use gpui::{SharedString, div, prelude::*, px};

use super::SectionContext;
use super::update;
use super::widgets::{chip, description, row, section as titled, stepper, toggle};

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let s = ctx.settings;
    let presets = [("Default", "default"), ("Vim", "vim"), ("Emacs", "emacs")]
        .into_iter()
        .map(|(label, preset)| {
            chip(
                SharedString::from(format!("preset-{preset}")),
                label,
                s.input.keybinding_preset == preset,
                chrome,
            )
            .on_click(move |_, _, cx| update(cx, |s| apply_preset(s, preset)))
        });
    let list = s.input.shortcuts();
    let shortcut_rows = list.iter().map(|shortcut| {
        let conflict = !shortcuts::conflicts(&list, shortcut).is_empty();
        let color = if conflict {
            gpui::hsla(0.08, 0.9, 0.55, 1.0)
        } else {
            chrome.text
        };
        div()
            .flex()
            .justify_between()
            .min_h(px(24.0))
            .child(
                div()
                    .text_sm()
                    .text_color(color)
                    .child(shortcuts::action_display_name(&shortcut.action)),
            )
            .child(
                div()
                    .px_2()
                    .rounded_sm()
                    .text_sm()
                    .text_color(color)
                    .bg(if conflict {
                        gpui::hsla(0.08, 0.9, 0.55, 0.2)
                    } else {
                        chrome.tab_bg
                    })
                    .child(crate::l10n::platform(&shortcut.display_string())),
            )
    });
    titled("Keyboard and mouse", chrome)
        .child(row(
            "Keybinding preset",
            div().flex().gap_1().children(presets),
            chrome,
        ))
        .child(row(
            "Copy on select",
            toggle("copy-select", s.input.copy_on_select, chrome, |s, v| {
                s.input.copy_on_select = v
            }),
            chrome,
        ))
        .child(row(
            "Option+click moves the cursor",
            toggle(
                "option-click",
                s.input.option_click_cursor,
                chrome,
                |s, v| s.input.option_click_cursor = v,
            ),
            chrome,
        ))
        .child(row(
            "Mouse reporting (hold Shift to select text)",
            toggle("mouse-report", s.input.mouse_reporting, chrome, |s, v| {
                s.input.mouse_reporting = v
            }),
            chrome,
        ))
        .child(description(
            "Full-screen apps that request wheel input receive it automatically. This setting also sends clicks and drags; hold Shift for local selection.",
            chrome,
        ))
        .child(row(
            "Click to position cursor",
            toggle(
                "click-position",
                s.input.click_to_position,
                chrome,
                |s, v| s.input.click_to_position = v,
            ),
            chrome,
        ))
        .child(row(
            "Local echo (show typed characters at once)",
            toggle("local-echo", s.input.local_echo, chrome, |s, v| {
                s.input.local_echo = v
            }),
            chrome,
        ))
        .child(row(
            "Bell",
            toggle("bell", s.terminal.bell_enabled, chrome, |s, v| {
                s.terminal.bell_enabled = v
            }),
            chrome,
        ))
        .child(row(
            "Clipboard history",
            toggle(
                "clip-history",
                s.productivity.clipboard_history_enabled,
                chrome,
                |s, v| s.productivity.clipboard_history_enabled = v,
            ),
            chrome,
        ))
        .child(row(
            "Clipboard history size",
            stepper(
                "clip-max",
                s.productivity.clipboard_history_max.to_string(),
                chrome,
                |s, d| {
                    let step = if s.productivity.clipboard_history_max >= 100 {
                        50
                    } else {
                        10
                    };
                    s.productivity.clipboard_history_max =
                        (s.productivity.clipboard_history_max as i64 + d as i64 * step)
                            .clamp(1, MAX_ITEMS_LIMIT as i64) as usize;
                },
            ),
            chrome,
        ))
        .child(row(
            "Broadcast Input",
            toggle(
                "broadcast-enabled",
                s.input.broadcast_enabled,
                chrome,
                |s, v| s.input.broadcast_enabled = v,
            ),
            chrome,
        ))
        .child(
            div()
                .text_xs()
                .text_color(chrome.text_muted)
                .child(crate::l10n::tr("Send keyboard input to all open tabs simultaneously (useful for multi-server commands)")),
        )
        .child(row(
            "Shortcut helper hint",
            toggle(
                "shortcut-hint",
                s.input.shortcut_helper_hint,
                chrome,
                |s, v| s.input.shortcut_helper_hint = v,
            ),
            chrome,
        ))
        .child(
            div()
                .flex()
                .justify_between()
                .items_center()
                .pt_2()
                .child(
                    div()
                        .text_xs()
                        .text_color(chrome.text_muted)
                        .child(crate::l10n::tr("Keyboard shortcuts. Conflicts are highlighted.")),
                )
                .child(
                    chip("edit-shortcuts", "Edit...", false, chrome)
                        .on_click(|_, _, cx| super::open_shortcuts(cx)),
                ),
        )
        .children(shortcut_rows)
}

/// Swift `applyKeybindingPreset`: the preset's list replaces the shortcuts
/// edited so far; `[keybindings]` entries for actions outside the list stay.
fn apply_preset(s: &mut crate::settings::Settings, preset: &str) {
    s.input.keybinding_preset = preset.to_string();
    let listed: Vec<String> = shortcuts::default_shortcuts()
        .into_iter()
        .map(|d| shortcuts::canonical_action(&d.action).to_string())
        .collect();
    s.input.keybindings.retain(|(_, action)| {
        !listed
            .iter()
            .any(|l| l == shortcuts::canonical_action(action))
    });
}
