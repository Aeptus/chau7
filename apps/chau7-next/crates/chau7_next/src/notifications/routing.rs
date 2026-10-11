//! Tabs across windows, by the `Uuid` events carry
//! (`TerminalControlService.*AcrossWindows` and the providers wired in
//! `Chau7App.swift`): resolve an event's tab, tell whether it is selected,
//! and run the tab-scoped actions on it.

use std::collections::HashMap;

use chau7_next_core::notifications::tab_resolver::{self, TabRoute, tab_id_from_uuid};
use chau7_next_core::tab_target::TabTarget;
use gpui::{AnyWindowHandle, App, Entity};
use uuid::Uuid;

use crate::tab_bar::{StyleColor, TabId};
use crate::workspace::{AppData, Workspace};

/// The window and workspace holding a tab.
fn find(tab: Uuid, cx: &App) -> Option<(AnyWindowHandle, Entity<Workspace>, TabId)> {
    let id = tab_id_from_uuid(tab)?;
    AppData::live(cx)
        .into_iter()
        .find(|(_, ws)| ws.read(cx).has_tab(id))
        .map(|(h, ws)| (h, ws, id))
}

/// Every tab of every window, for the resolver.
pub fn all_routes(cx: &App) -> Vec<TabRoute> {
    AppData::live(cx)
        .into_iter()
        .flat_map(|(_, ws)| ws.read(cx).tab_routes(cx))
        .collect()
}

/// `TabResolver.resolve` over every window.
pub fn resolve(target: &TabTarget, cx: &App) -> Option<Uuid> {
    tab_resolver::resolve(target, &all_routes(cx))
}

/// `activeTabChecker`: the event's tab is the selected tab of some window.
pub fn is_selected_anywhere(target: &TabTarget, cx: &App) -> bool {
    let Some(tab) = resolve(target, cx).and_then(tab_id_from_uuid) else {
        return false;
    };
    AppData::live(cx)
        .iter()
        .any(|(_, ws)| ws.read(cx).selected_tab_id() == Some(tab))
}

/// `tabTitleProvider`: the title of the event's tab.
pub fn tab_title(target: &TabTarget, cx: &App) -> Option<String> {
    let (_, ws, id) = find(resolve(target, cx)?, cx)?;
    Some(ws.read(cx).tab_title(id, cx))
}

/// `repoNameProvider`: the repository of the event's tab.
pub fn repo_name(target: &TabTarget, cx: &App) -> Option<String> {
    let (_, ws, id) = find(resolve(target, cx)?, cx)?;
    ws.read(cx).tab_repo_name(id, cx)
}

/// `focusTabAcrossWindows`: bring the window to front and select the tab.
pub fn focus_tab(tab: Uuid, cx: &mut App) -> bool {
    let Some((handle, ws, id)) = find(tab, cx) else {
        return false;
    };
    handle
        .update(cx, |_, window, cx| {
            window.activate_window();
            ws.update(cx, |ws, cx| ws.select_tab(id, window, cx));
        })
        .is_ok()
}

/// `applyNotificationStyleAcrossWindows`.
pub fn style_tab(tab: Uuid, preset: &str, config: &HashMap<String, String>, cx: &mut App) -> bool {
    let Some((_, ws, id)) = find(tab, cx) else {
        return false;
    };
    ws.update(cx, |ws, cx| {
        ws.apply_notification_style(id, preset, config, cx)
    })
}

/// `badgeTabAcrossWindows`.
pub fn badge_tab(tab: Uuid, text: &str, color: &str, cx: &mut App) -> bool {
    let Some((_, ws, id)) = find(tab, cx) else {
        return false;
    };
    let color = StyleColor::from_name(color);
    ws.update(cx, |ws, cx| {
        ws.set_tab_badge(id, Some(text.to_string()), Some(color), cx)
    });
    true
}

/// `insertSnippetAcrossWindows`.
pub fn insert_snippet(tab: Uuid, snippet_id: &str, auto_execute: bool, cx: &mut App) -> bool {
    let Some((handle, ws, id)) = find(tab, cx) else {
        return false;
    };
    handle
        .update(cx, |_, window, cx| {
            ws.update(cx, |ws, cx| {
                ws.insert_snippet_in_tab(id, snippet_id, auto_execute, window, cx)
            })
        })
        .unwrap_or(false)
}

/// `clearPersistentNotificationStyleAcrossWindows`: the permission prompt
/// was answered. For the AI event monitor (permission resolved).
#[allow(dead_code)]
pub fn clear_persistent_style(tab: Uuid, cx: &mut App) -> bool {
    let Some((_, ws, id)) = find(tab, cx) else {
        log::warn!("clearPersistentStyle: Explicit tabID not found across windows for tab {tab}");
        return false;
    };
    ws.update(cx, |ws, cx| ws.clear_persistent_style(id, cx))
}
