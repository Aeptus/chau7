//! Tabs (`TabsSettingsView.swift`): behavior, tab display, appearance and
//! the keyboard shortcut list. "Always Show Toolbar in Fullscreen" comes
//! from `WindowsSettingsView.swift`, which no Swift sidebar section shows.

use chau7_next_core::tabs_state::NewTabPosition;
use gpui::{SharedString, div, prelude::*, px};

use super::SectionContext;
use super::update;
use super::widgets::{chip, row, section as titled, stepper, toggle};
use crate::settings::{LastTabClose, RepoGroupingMode};
use crate::theme::Chrome;

pub(super) fn section(ctx: &SectionContext) -> gpui::Div {
    let chrome = ctx.chrome;
    let s = &ctx.settings.tabs;
    let positions = [
        ("At End", NewTabPosition::End),
        ("After Current", NewTabPosition::AfterCurrent),
    ]
    .into_iter()
    .map(|(label, position)| {
        chip(
            SharedString::from(format!("pos-{label}")),
            label,
            s.new_tab_position == position,
            chrome,
        )
        .on_click(move |_, _, cx| update(cx, |s| s.tabs.new_tab_position = position))
    });
    let last_close = LastTabClose::ALL.into_iter().map(|b| {
        chip(
            SharedString::from(format!("last-close-{}", b.raw())),
            b.label(),
            s.last_tab_close == b,
            chrome,
        )
        .on_click(move |_, _, cx| update(cx, |s| s.tabs.last_tab_close = b))
    });
    let grouping = RepoGroupingMode::ALL.into_iter().map(|mode| {
        chip(
            SharedString::from(format!("repo-group-{}", mode.raw())),
            mode.label(),
            s.repo_grouping == mode,
            chrome,
        )
        .on_click(move |_, _, cx| update(cx, |s| s.tabs.repo_grouping = mode))
    });
    let title_only = s.custom_title_only;
    // Display toggles are disabled while "Custom Title Only" is on.
    let dimmed = |el: gpui::Div| {
        if title_only { el.opacity(0.45) } else { el }
    };

    let behavior = titled("Tabs", chrome)
        .child(row(
            "New Tab Position",
            div().flex().gap_1().children(positions),
            chrome,
        ))
        .child(row(
            "New Tabs Use Current Directory",
            toggle(
                "new-tab-cwd",
                s.new_tabs_use_current_directory,
                chrome,
                |s, v| s.tabs.new_tabs_use_current_directory = v,
            ),
            chrome,
        ))
        .child(row(
            "Last Tab Close",
            div().flex().gap_1().children(last_close),
            chrome,
        ))
        .child(row(
            "Warn When Closing Tab with Running Process",
            toggle("warn-close", s.warn_on_close_running, chrome, |s, v| {
                s.tabs.warn_on_close_running = v
            }),
            chrome,
        ))
        .child(row(
            "Always Warn Before Closing Tab",
            toggle("always-warn", s.confirm_close, chrome, |s, v| {
                s.tabs.confirm_close = v
            }),
            chrome,
        ))
        .child(row(
            "Always Show Tab Bar",
            toggle("always-tab-bar", s.always_show_tab_bar, chrome, |s, v| {
                s.tabs.always_show_tab_bar = v
            }),
            chrome,
        ))
        .child(row(
            "Group Idle Tabs in Dropdown",
            toggle("idle", s.group_idle_tabs, chrome, |s, v| {
                s.tabs.group_idle_tabs = v
            }),
            chrome,
        ))
        .when(s.group_idle_tabs, |d| {
            d.child(row(
                "Idle Threshold",
                stepper(
                    "idle-min",
                    format!("{} min", s.idle_threshold_minutes),
                    chrome,
                    |s, d| {
                        s.tabs.idle_threshold_minutes =
                            (s.tabs.idle_threshold_minutes as i32 + d).clamp(1, 60) as u32
                    },
                ),
                chrome,
            ))
        })
        .child(row(
            "Repo Grouping",
            div().flex().gap_1().children(grouping),
            chrome,
        ))
        .child(row(
            "Close the tab when the shell exits",
            toggle("close-exit", s.close_on_exit, chrome, |s, v| {
                s.tabs.close_on_exit = v
            }),
            chrome,
        ));

    let display = titled("Tab Display", chrome)
        .child(row(
            "Custom Title Only",
            toggle("title-only", s.custom_title_only, chrome, |s, v| {
                s.tabs.custom_title_only = v
            }),
            chrome,
        ))
        .child(dimmed(row(
            "Tab Icons",
            toggle_unless("show-icons", s.show_icons, title_only, chrome, |s, v| {
                s.tabs.show_icons = v
            }),
            chrome,
        )))
        .child(dimmed(row(
            "Working Directory",
            toggle_unless("show-path", s.show_path, title_only, chrome, |s, v| {
                s.tabs.show_path = v
            }),
            chrome,
        )))
        .child(dimmed(row(
            "Git Indicator",
            toggle_unless(
                "show-git",
                s.show_git_indicator,
                title_only,
                chrome,
                |s, v| s.tabs.show_git_indicator = v,
            ),
            chrome,
        )))
        .child(dimmed(row(
            "Allow CTO Toggle in Hover Card",
            toggle_unless(
                "cto-toggle",
                s.allow_cto_toggle,
                title_only,
                chrome,
                |s, v| s.tabs.allow_cto_toggle = v,
            ),
            chrome,
        )))
        .child(dimmed(row(
            "Broadcast Indicator",
            toggle_unless(
                "show-broadcast",
                s.show_broadcast_indicator,
                title_only,
                chrome,
                |s, v| s.tabs.show_broadcast_indicator = v,
            ),
            chrome,
        )));

    let appearance = titled("Tab Appearance", chrome)
        .child(row(
            "Last Command Badge",
            toggle("cmd-badge", s.last_command_badge, chrome, |s, v| {
                s.tabs.last_command_badge = v
            }),
            chrome,
        ))
        .child(row(
            "AI Product Logos",
            toggle("ai-logos", s.auto_tab_theme, chrome, |s, v| {
                s.tabs.auto_tab_theme = v
            }),
            chrome,
        ));

    let shortcuts = TAB_SHORTCUTS.iter().fold(
        titled("Keyboard Navigation", chrome),
        |d, (label, mac, other)| {
            d.child(shortcut_row(
                label,
                if cfg!(target_os = "macos") {
                    mac
                } else {
                    other
                },
                chrome,
            ))
        },
    );

    div()
        .flex()
        .flex_col()
        .child(behavior)
        .child(display)
        .child(appearance)
        .child(shortcuts)
        .child(
            div().flex().justify_end().pb_4().child(
                chip("tabs-reset", "Reset Tabs to Defaults", false, chrome)
                    .on_click(|_, _, cx| update(cx, reset_tabs)),
            ),
        )
}

/// `resetTabsToDefaults`.
fn reset_tabs(s: &mut crate::settings::Settings) {
    let close_on_exit = s.tabs.close_on_exit;
    s.tabs = Default::default();
    // Not a Swift tab setting: kept.
    s.tabs.close_on_exit = close_on_exit;
}

/// A toggle that does nothing while `disabled`.
fn toggle_unless(
    id: &'static str,
    on: bool,
    disabled: bool,
    chrome: Chrome,
    apply: fn(&mut crate::settings::Settings, bool),
) -> gpui::Stateful<gpui::Div> {
    if disabled {
        toggle(id, on, chrome, |_, _| {})
    } else {
        toggle(id, on, chrome, apply)
    }
}

/// Read-only shortcut list (Swift `SettingsShortcutRow`): label, macOS
/// text, Linux and Windows text.
const TAB_SHORTCUTS: &[(&str, &str, &str)] = &[
    ("New Tab", "⌘T", "Ctrl+Shift+T"),
    ("Close Tab", "⌘W", "Ctrl+Shift+W"),
    (
        "Next Tab",
        "⇧⌘] or ⌃Tab or ⌥⌘→",
        "Ctrl+Tab or Ctrl+PageDown",
    ),
    (
        "Previous Tab",
        "⇧⌘[ or ⌃⇧Tab or ⌥⌘←",
        "Ctrl+Shift+Tab or Ctrl+PageUp",
    ),
    ("Switch to Tab 1-9", "⌘1-9", "Alt+1-9"),
    ("Rename Tab", "⌘⌥R", "Ctrl+Shift+R"),
];

fn shortcut_row(label: &'static str, keys: &'static str, chrome: Chrome) -> gpui::Div {
    row(
        label,
        div()
            .px_2()
            .py(px(2.0))
            .rounded_md()
            .bg(chrome.tab_bg)
            .text_xs()
            .text_color(chrome.text_muted)
            .child(keys),
        chrome,
    )
}
