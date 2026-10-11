//! Settings sections for snippets, clipboard, links, the command guard and
//! profiles (`ProductivitySettingsView`, `InputSettingsView`,
//! `DangerousCommandSettingsView`, `ProfileSelectorBar`).

pub(super) mod dangerous;
pub(super) mod links;
pub(super) mod productivity;
pub(super) mod profiles;

use chau7_next_core::command_risk::DangerousCommandGuard;
use chau7_next_core::snippet_store;
use gpui::{App, Context, Entity, SharedString, Subscription, Window, div, prelude::*, px};
use gpui_kit::component::input::{InputEvent, InputState};

use super::SettingsView;
use crate::settings::Settings;
use crate::terminal::command_guard::{self, GuardState};
use crate::workspace::AppData;

/// Inputs and snapshots the sections draw from.
pub(super) struct MineState {
    pub repo_path: Entity<InputState>,
    pub editor: Entity<InputState>,
    pub pattern: Entity<InputState>,
    pub block: Entity<InputState>,
    /// Sorted copies of the guard's lists, refreshed on each render.
    pub allow: Vec<String>,
    pub blocked: Vec<String>,
    pub user_snippets: usize,
    pub profiles: profiles::ProfilesPane,
    _subscriptions: Vec<Subscription>,
}

/// An input that commits its text on Enter or when it loses focus.
fn commit_input(
    value: String,
    placeholder: &'static str,
    window: &mut Window,
    cx: &mut Context<SettingsView>,
    on_commit: impl Fn(String, &mut App) + 'static,
) -> (Entity<InputState>, Subscription) {
    let input = cx.new(|cx| {
        InputState::new(window, cx)
            .default_value(value)
            .placeholder(placeholder)
    });
    let sub = cx.subscribe(&input, move |_, input, event: &InputEvent, cx| {
        if matches!(event, InputEvent::PressEnter { .. } | InputEvent::Blur) {
            let text = input.read(cx).value().trim().to_string();
            on_commit(text, cx);
        }
    });
    (input, sub)
}

impl MineState {
    pub(super) fn new(window: &mut Window, cx: &mut Context<SettingsView>) -> Self {
        let s = Settings::get(cx).productivity.clone();
        let mut subs = Vec::new();
        let (repo_path, sub) = commit_input(
            s.repo_snippet_path.clone(),
            chau7_next_core::data_root::DEFAULT_REPO_SNIPPET_PATH,
            window,
            cx,
            |text, cx| {
                let cleaned = text.trim_matches('/').to_string();
                let value = if cleaned.is_empty() {
                    chau7_next_core::data_root::DEFAULT_REPO_SNIPPET_PATH.to_string()
                } else {
                    cleaned
                };
                super::update(cx, |s| s.productivity.repo_snippet_path = value);
            },
        );
        subs.push(sub);
        let (editor, sub) = commit_input(
            s.default_editor.clone(),
            "$EDITOR",
            window,
            cx,
            |text, cx| super::update(cx, |s| s.productivity.default_editor = text),
        );
        subs.push(sub);
        let (pattern, sub) = commit_input(
            String::new(),
            "Add a risky pattern",
            window,
            cx,
            |text, cx| {
                if text.is_empty() {
                    return;
                }
                super::update(cx, |s| {
                    let patterns = &mut s.dangerous_commands.patterns;
                    if !patterns.iter().any(|p| p.eq_ignore_ascii_case(&text)) {
                        patterns.push(text);
                    }
                });
            },
        );
        subs.push(sub);
        let (block, sub) = commit_input(
            String::new(),
            "Add a command to block",
            window,
            cx,
            |text, cx| {
                if !text.is_empty() {
                    guard_update(cx, |g| g.add_to_block_list(&text));
                }
            },
        );
        subs.push(sub);
        let plain =
            |placeholder: &'static str, window: &mut Window, cx: &mut Context<SettingsView>| {
                cx.new(|cx| InputState::new(window, cx).placeholder(placeholder))
            };
        let profile_name = plain("Profile Name", window, cx);
        let rule_name = plain("Rule name", window, cx);
        let rule_value = plain("Value", window, cx);
        let rule_value2 = plain("Value", window, cx);
        Self {
            profiles: profiles::ProfilesPane::new(profile_name, rule_name, rule_value, rule_value2),
            repo_path,
            editor,
            pattern,
            block,
            allow: Vec::new(),
            blocked: Vec::new(),
            user_snippets: 0,
            _subscriptions: subs,
        }
    }

    /// Copy what the sections show from the app state. Called from render.
    pub(super) fn refresh(&mut self, cx: &App) {
        if let Some(state) = cx.try_global::<GuardState>() {
            let mut allow: Vec<String> = state.0.allow_list.iter().cloned().collect();
            allow.sort();
            let mut blocked: Vec<String> = state.0.block_list.iter().cloned().collect();
            blocked.sort();
            self.allow = allow;
            self.blocked = blocked;
        }
        self.profiles.refresh(cx);
        let root = &cx.global::<AppData>().root;
        self.user_snippets = snippet_store::load_dir(&root.user_snippets_dir()).len();
    }
}

/// Change the guard's lists, save them and redraw.
pub(super) fn guard_update(cx: &mut App, change: impl FnOnce(&mut DangerousCommandGuard)) {
    change(&mut cx.global_mut::<GuardState>().0);
    command_guard::save(cx);
    cx.refresh_windows();
}

/// A small text button.
pub(super) fn small_button(
    id: impl Into<gpui::ElementId>,
    label: impl Into<SharedString>,
    chrome: crate::theme::Chrome,
) -> gpui::Stateful<gpui::Div> {
    div()
        .id(id)
        .px_2()
        .py_0p5()
        .rounded_md()
        .text_xs()
        .cursor_pointer()
        .bg(chrome.tab_bg)
        .text_color(chrome.text)
        .hover(|d| d.bg(chrome.tab_hover_bg))
        .child(label.into())
}

/// A note under a control.
pub(super) fn hint(text: &'static str, chrome: crate::theme::Chrome) -> gpui::Div {
    div()
        .text_xs()
        .text_color(chrome.text_muted)
        .max_w(px(480.0))
        .child(text)
}
