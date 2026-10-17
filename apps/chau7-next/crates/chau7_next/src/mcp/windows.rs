//! Stable `window_id`s (`TerminalControlService.register`): 0, 1, 2... in
//! the order windows open, never reused, so an id does not shift when
//! another window closes. Ids are given when a window is first seen (a
//! one-second sweep, and every MCP request), and tab lookups search every
//! window.

use gpui::{AnyWindowHandle, App, Entity, Global};
use uuid::Uuid;

use crate::tab_bar::TabId;
use crate::workspace::{AppData, Workspace};

#[derive(Default)]
struct WindowIds {
    ids: Vec<(AnyWindowHandle, usize)>,
    next: usize,
}

impl Global for WindowIds {}

/// One open window with its MCP id.
#[derive(Clone)]
pub struct McpWindow {
    pub id: usize,
    pub handle: AnyWindowHandle,
    pub workspace: Entity<Workspace>,
}

/// A tab found by UUID.
#[derive(Clone)]
pub struct McpTab {
    pub window: McpWindow,
    pub tab: TabId,
}

/// Give ids to new windows every second, so they follow the opening order
/// even when no request arrives in between.
pub(super) fn start(cx: &mut App) {
    cx.set_global(WindowIds::default());
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor()
                .timer(std::time::Duration::from_secs(1))
                .await;
            cx.update(|cx| {
                windows(cx);
            });
        }
    })
    .detach();
}

/// The open windows in opening order, with their ids.
pub fn windows(cx: &mut App) -> Vec<McpWindow> {
    let live = AppData::live(cx);
    let mut ids = if cx.try_global::<WindowIds>().is_some() {
        cx.remove_global::<WindowIds>()
    } else {
        WindowIds::default()
    };
    ids.ids.retain(|(h, _)| live.iter().any(|(l, _)| l == h));
    let mut out = Vec::new();
    for (handle, workspace) in live {
        let id = match ids.ids.iter().find(|(h, _)| *h == handle) {
            Some((_, id)) => *id,
            None => {
                let id = ids.next;
                ids.next += 1;
                ids.ids.push((handle, id));
                id
            }
        };
        out.push(McpWindow {
            id,
            handle,
            workspace,
        });
    }
    cx.set_global(ids);
    out
}

/// Parse a tab id: a UUID in any case (`UUID(uuidString:)`).
pub fn parse_tab_id(tab_id: &str) -> Option<Uuid> {
    Uuid::try_parse(tab_id.trim()).ok()
}

/// The tab with this id in any window (`resolveTab`).
pub fn find_tab(tab_id: &str, cx: &mut App) -> Option<McpTab> {
    let uuid = parse_tab_id(tab_id)?;
    windows(cx).into_iter().find_map(|window| {
        let tab = window.workspace.read(cx).mcp_find(uuid)?;
        Some(McpTab { window, tab })
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tab_ids_parse_in_any_case() {
        let uuid = Uuid::new_v4();
        let upper = uuid.hyphenated().to_string().to_uppercase();
        assert_eq!(parse_tab_id(&upper), Some(uuid));
        assert_eq!(parse_tab_id(&uuid.to_string()), Some(uuid));
        assert_eq!(parse_tab_id("not-a-uuid"), None);
    }
}
