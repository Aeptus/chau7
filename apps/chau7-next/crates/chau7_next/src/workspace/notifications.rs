//! What the notification engine (`crate::notifications`) needs from a
//! window: a routing snapshot of its tabs, the selected tab, repo names, and
//! running a snippet in a tab (the tab-scoped actions use
//! `apply_notification_style`, `set_tab_badge` and `select_tab`).

use chau7_next_core::notifications::tab_resolver::{SessionRoute, TabRoute, tab_uuid};
use gpui::{App, Context, Window};

use super::pickers::{PickerItem, PickerKind};
use super::{AppData, Workspace};
use crate::tab_bar::TabId;

impl Workspace {
    /// Every tab of this window as the tab resolver sees it.
    pub fn tab_routes(&self, cx: &App) -> Vec<TabRoute> {
        let started = cx.global::<AppData>().started;
        self.state
            .tabs()
            .iter()
            .filter_map(|meta| {
                let entry = self.entries.get(&meta.id)?;
                let panes = entry.panes.read(cx);
                let focused = panes.focused_session(cx);
                let sessions = panes
                    .pane_sessions(cx)
                    .into_iter()
                    .map(|(_, session)| {
                        let s = session.read(cx);
                        let shell = s.shell();
                        SessionRoute {
                            ai_display_app_name: s.ai_app.clone(),
                            active_app_name: shell.active_app().map(str::to_string),
                            last_ai_provider: shell.ai_provider().map(str::to_string),
                            effective_ai_provider: shell.effective_provider(),
                            effective_ai_session_id: shell.ai_session_id().map(str::to_string),
                            current_directory: s
                                .cwd
                                .as_ref()
                                .map(|p| p.to_string_lossy().into_owned())
                                .unwrap_or_default(),
                            last_activity: s
                                .last_activity
                                .saturating_duration_since(started)
                                .as_secs_f64(),
                        }
                    })
                    .collect();
                Some(TabRoute {
                    id: tab_uuid(meta.id),
                    display_app_name: focused.and_then(|s| s.read(cx).ai_app.clone()),
                    display_title: self.tab_title(meta.id, cx),
                    sessions,
                    created_at: meta.created_at,
                })
            })
            .collect()
    }

    pub fn has_tab(&self, id: TabId) -> bool {
        self.entries.contains_key(&id)
    }

    pub fn selected_tab_id(&self) -> Option<TabId> {
        self.state.selected()
    }

    /// Name of the repository the tab's focused pane is in.
    pub fn tab_repo_name(&self, id: TabId, cx: &App) -> Option<String> {
        let session = self.entries.get(&id)?.panes.read(cx).focused_session(cx)?;
        let root = session.read(cx).git_root.clone()?;
        root.file_name().map(|n| n.to_string_lossy().into_owned())
    }

    /// "Execute snippet" action: select the tab, then insert the snippet
    /// with this id into it; `auto_execute` presses Return after it.
    pub fn insert_snippet_in_tab(
        &mut self,
        id: TabId,
        snippet_id: &str,
        auto_execute: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.has_tab(id) {
            return false;
        }
        let entry = self
            .all_picker_items(PickerKind::Snippets, cx)
            .into_iter()
            .find_map(|item| match item {
                PickerItem::Snippet(entry) if entry.snippet.id == snippet_id => Some(entry),
                _ => None,
            });
        let Some(entry) = entry else {
            log::warn!("insertSnippet: Snippet '{snippet_id}' not found");
            return false;
        };
        self.select_tab(id, window, cx);
        self.insert_snippet_text(&entry.snippet.body, None, cx);
        if auto_execute
            && let Some(view) = self
                .selected_panes()
                .and_then(|p| p.read(cx).focused_view())
        {
            view.update(cx, |v, cx| v.send_text("\r", cx));
        }
        log::info!("insertSnippet: Inserted snippet '{snippet_id}' for tab {id}");
        true
    }
}
