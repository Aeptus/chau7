//! Keyboard Shortcuts window (Help menu, Cmd+/): search, shortcuts grouped
//! by Tabs / Edit / View / Window, click a shortcut and press the new keys,
//! Save; a shortcut already in use is refused with a conflict alert.
//!
//! Mirrors `Settings/KeyboardShortcutsEditor.swift`. Edits are stored as
//! `[keybindings]` in config.toml and bound at once.

use chau7_next_core::input::shortcuts::{self, KeyboardShortcut};
use gpui::{
    AnyWindowHandle, App, Bounds, Context, Entity, Global, KeystrokeEvent, Render, SharedString,
    Subscription, Window, WindowBounds, WindowOptions, div, prelude::*, px, size,
};
use gpui_kit::component::TitleBar;
use gpui_kit::component::input::{Input, InputEvent, InputState};

use super::update;
use crate::settings::Settings;
use crate::theme::Chrome;

#[derive(Default)]
struct ShortcutsWindowHandle(Option<AnyWindowHandle>);
impl Global for ShortcutsWindowHandle {}

pub fn open(cx: &mut App) {
    if let Some(handle) = cx.try_global::<ShortcutsWindowHandle>().and_then(|h| h.0)
        && handle
            .update(cx, |_, window, _| window.activate_window())
            .is_ok()
    {
        return;
    }
    let bounds = Bounds::centered(None, size(px(500.0), px(600.0)), cx);
    let options = WindowOptions {
        window_bounds: Some(WindowBounds::Windowed(bounds)),
        window_min_size: Some(size(px(420.0), px(360.0))),
        ..TitleBar::window_options()
    };
    match gpui_kit::open_window(options, cx, |window, cx| {
        cx.new(|cx| ShortcutsView::new(window, cx))
    }) {
        Ok((handle, _)) => cx.set_global(ShortcutsWindowHandle(Some(handle))),
        Err(err) => log::error!("keyboard shortcuts window: {err}"),
    }
}

pub struct ShortcutsView {
    search: Entity<InputState>,
    /// Action being edited, and the keys recorded so far.
    editing: Option<String>,
    recorded: Option<(String, Vec<String>)>,
    _subscriptions: Vec<Subscription>,
}

impl ShortcutsView {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let search = cx.new(|cx| {
            InputState::new(window, cx).placeholder(crate::l10n::tr("Search shortcuts..."))
        });
        let changed = cx.subscribe(&search, |_, _, event: &InputEvent, cx| {
            if matches!(event, InputEvent::Change) {
                cx.notify();
            }
        });
        let me = cx.entity().downgrade();
        let own_window = window.window_handle();
        // Record before key bindings run, so Cmd+T is captured, not acted on.
        let recorder = cx.intercept_keystrokes(move |event: &KeystrokeEvent, window, cx| {
            if window.window_handle() != own_window {
                return;
            }
            let Some(me) = me.upgrade() else {
                return;
            };
            let recorded = me.update(cx, |this, cx| this.record(event, cx));
            if recorded {
                cx.stop_propagation();
            } else if event.keystroke.key == "escape" && !event.keystroke.modifiers.modified() {
                // Escape closes the window (when no shortcut is being recorded).
                cx.stop_propagation();
                window.remove_window();
            }
        });
        Self {
            search,
            editing: None,
            recorded: None,
            _subscriptions: vec![changed, recorder],
        }
    }

    fn record(&mut self, event: &KeystrokeEvent, cx: &mut Context<Self>) -> bool {
        if self.editing.is_none() {
            return false;
        }
        let keystroke = &event.keystroke;
        if keystroke.key == "escape" && !keystroke.modifiers.modified() {
            self.editing = None;
            self.recorded = None;
            cx.notify();
            return true;
        }
        self.recorded = Some(recorded_keys(keystroke));
        cx.notify();
        true
    }

    fn save(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let (Some(action), Some((key, modifiers))) = (self.editing.clone(), self.recorded.clone())
        else {
            return;
        };
        let updated = KeyboardShortcut {
            action,
            key,
            modifiers,
        };
        let list = Settings::get(cx).input.shortcuts();
        let conflicts = shortcuts::conflicts(&list, &updated);
        if !conflicts.is_empty() {
            let names: Vec<String> = conflicts
                .iter()
                .map(|s| shortcuts::action_display_name(&s.action))
                .collect();
            let detail = format!("This shortcut is already used by: {}", names.join(", "));
            let answer = crate::l10n::prompt(
                window,
                gpui::PromptLevel::Warning,
                "Shortcut Conflict",
                Some(&detail),
                &["OK"],
                cx,
            );
            cx.spawn(async move |_, _| {
                let _ = answer.await;
            })
            .detach();
            return;
        }
        let mut list = list;
        shortcuts::update(&mut list, updated);
        update(cx, |s| s.input.set_shortcuts(&list));
        self.editing = None;
        self.recorded = None;
        cx.notify();
    }
}

/// Key and modifier names (Swift `ShortcutRecorderField`: ctrl, opt, shift,
/// cmd). macOS folds Shift into punctuation ("cmd-}"); it is stored as the
/// unshifted key plus Shift, like Swift does.
fn recorded_keys(keystroke: &gpui::Keystroke) -> (String, Vec<String>) {
    let mut key = keystroke.key.to_lowercase();
    let mut shift = keystroke.modifiers.shift;
    if let Some(base) = unshifted_punctuation(&key) {
        key = base.to_string();
        shift = true;
    }
    let mods = &keystroke.modifiers;
    let mut names = Vec::new();
    for (on, name) in [
        (mods.control, "ctrl"),
        (mods.alt, "opt"),
        (shift, "shift"),
        (mods.platform, "cmd"),
    ] {
        if on {
            names.push(name.to_string());
        }
    }
    (key, names)
}

fn unshifted_punctuation(key: &str) -> Option<&'static str> {
    Some(match key {
        "}" => "]",
        "{" => "[",
        "<" => ",",
        ">" => ".",
        "?" => "/",
        ":" => ";",
        "\"" => "'",
        "|" => "\\",
        "_" => "-",
        "+" => "=",
        "~" => "`",
        _ => return None,
    })
}

impl Render for ShortcutsView {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        window.set_window_title(&crate::l10n::tr("Keyboard Shortcuts"));
        let chrome = Chrome::get(cx);
        let list = Settings::get(cx).input.shortcuts();
        let query = self.search.read(cx).value().to_string();
        let filtered = shortcuts::filter(&list, &query);
        let mut groups = Vec::new();
        for (name, actions) in shortcuts::EDITOR_GROUPS {
            let rows: Vec<gpui::AnyElement> = filtered
                .iter()
                .filter(|s| actions.contains(&s.action.as_str()))
                .map(|s| self.render_row(s, &list, chrome, cx))
                .collect();
            if rows.is_empty() {
                continue;
            }
            groups.push(
                div()
                    .flex()
                    .flex_col()
                    .gap_1()
                    .child(
                        div()
                            .text_xs()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .text_color(chrome.text_muted)
                            .child(name.to_uppercase()),
                    )
                    .child(
                        div()
                            .flex()
                            .flex_col()
                            .rounded_md()
                            .bg(chrome.tab_bg)
                            .children(rows),
                    ),
            );
        }
        div()
            .size_full()
            .flex()
            .flex_col()
            .bg(chrome.panel_bg)
            .text_color(chrome.text)
            .child(
                TitleBar::new().child(div().text_sm().child(crate::l10n::tr("Keyboard Shortcuts"))),
            )
            .child(
                div()
                    .flex()
                    .justify_between()
                    .items_center()
                    .px_4()
                    .pt_3()
                    .child(
                        div()
                            .font_weight(gpui::FontWeight::SEMIBOLD)
                            .child(crate::l10n::tr("Keyboard Shortcuts")),
                    )
                    .child(
                        div()
                            .id("reset-shortcuts")
                            .text_sm()
                            .text_color(chrome.accent)
                            .child(crate::l10n::tr("Reset to Defaults"))
                            .on_click(|_, _, cx| {
                                // Swift `resetShortcutsToDefaults`: the preset's list.
                                update(cx, |s| {
                                    let preset =
                                        shortcuts::shortcuts_for_preset(&s.input.keybinding_preset);
                                    s.input.set_shortcuts(&preset)
                                })
                            }),
                    ),
            )
            .child(div().px_4().py_2().child(Input::new(&self.search)))
            .child(
                div()
                    .id("shortcut-list")
                    .flex_1()
                    .overflow_y_scroll()
                    .px_4()
                    .py_2()
                    .flex()
                    .flex_col()
                    .gap_4()
                    .children(groups),
            )
            .child(
                div()
                    .px_4()
                    .py_3()
                    .text_xs()
                    .text_color(chrome.text_muted)
                    .bg(chrome.tab_bg)
                    .child(crate::l10n::tr(
                        "Click a shortcut to edit. Press the new key combination to change it.",
                    )),
            )
    }
}

impl ShortcutsView {
    fn render_row(
        &self,
        shortcut: &KeyboardShortcut,
        list: &[KeyboardShortcut],
        chrome: Chrome,
        cx: &mut Context<Self>,
    ) -> gpui::AnyElement {
        let action = shortcut.action.clone();
        let editing = self.editing.as_deref() == Some(action.as_str());
        let conflicts: Vec<String> = {
            let mut names: Vec<String> = shortcuts::conflicts(list, shortcut)
                .iter()
                .map(|s| shortcuts::action_display_name(&s.action))
                .collect();
            names.sort();
            names
        };
        let keys = if editing {
            match &self.recorded {
                Some((key, modifiers)) => KeyboardShortcut {
                    action: action.clone(),
                    key: key.clone(),
                    modifiers: modifiers.clone(),
                }
                .display_string(),
                None => "Press shortcut...".to_string(),
            }
        } else {
            shortcut.display_string()
        };
        let keys = crate::l10n::platform(&keys);
        let pill = div()
            .id(SharedString::from(format!("keys-{action}")))
            .px_2()
            .py_0p5()
            .rounded_sm()
            .text_sm()
            .border_1()
            .border_color(if editing {
                chrome.accent
            } else {
                chrome.border
            })
            .child(keys);
        let controls = if editing {
            let save_enabled = self.recorded.is_some();
            div()
                .flex()
                .gap_2()
                .items_center()
                .child(pill)
                .child(
                    div()
                        .id(SharedString::from(format!("save-{action}")))
                        .px_2()
                        .rounded_sm()
                        .text_sm()
                        .bg(if save_enabled {
                            chrome.accent
                        } else {
                            chrome.border
                        })
                        .text_color(gpui::white())
                        .child(crate::l10n::tr("Save"))
                        .on_click(cx.listener(|this, _, window, cx| this.save(window, cx))),
                )
                .child(
                    div()
                        .id(SharedString::from(format!("cancel-{action}")))
                        .px_2()
                        .rounded_sm()
                        .text_sm()
                        .bg(chrome.panel_bg)
                        .child(crate::l10n::tr("Cancel"))
                        .on_click(cx.listener(|this, _, _, cx| {
                            this.editing = None;
                            this.recorded = None;
                            cx.notify();
                        })),
                )
        } else {
            let start = action.clone();
            div().child(pill.on_click(cx.listener(move |this, _, _, cx| {
                this.editing = Some(start.clone());
                this.recorded = None;
                cx.notify();
            })))
        };
        div()
            .flex()
            .flex_col()
            .px_3()
            .py_2()
            .child(
                div()
                    .flex()
                    .justify_between()
                    .items_center()
                    .child(
                        div()
                            .text_sm()
                            .child(shortcuts::action_display_name(&shortcut.action)),
                    )
                    .child(controls),
            )
            .when(!conflicts.is_empty(), |d| {
                d.child(
                    div()
                        .text_xs()
                        .text_color(gpui::hsla(0.08, 0.9, 0.55, 1.0))
                        .child(format!("Conflict: {}", conflicts.join(", "))),
                )
            })
            .into_any_element()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn records_folded_shift_as_shift_plus_key() {
        let keystroke = gpui::Keystroke::parse("cmd-}").unwrap();
        assert_eq!(
            recorded_keys(&keystroke),
            (
                "]".to_string(),
                vec!["shift".to_string(), "cmd".to_string()]
            )
        );
        let keystroke = gpui::Keystroke::parse("ctrl-alt-k").unwrap();
        assert_eq!(
            recorded_keys(&keystroke),
            ("k".to_string(), vec!["ctrl".to_string(), "opt".to_string()])
        );
    }
}
