//! What the menu bar command center (`crate::status_bar`) reads from and
//! does in a window: the AI sessions of its tabs, selecting the tab of a
//! session, and inserting a pinned snippet in the selected tab
//! (`CommandCenterSessionSummary.collectLiveSessions`, `focusSession`,
//! `executeSnippet`).

use chau7_next_core::command_center::SessionCandidate;
use gpui::{App, Context, Window};

use super::{AppData, Workspace};
use crate::tab_bar::TabId;

impl Workspace {
    /// Every terminal session of this window, with what the command center
    /// needs to decide whether it is an AI session worth listing.
    pub fn command_center_candidates(&self, cx: &App) -> Vec<SessionCandidate> {
        let started = cx.global::<AppData>().started;
        let mut out = Vec::new();
        for meta in self.state.tabs() {
            let Some(entry) = self.entries.get(&meta.id) else {
                continue;
            };
            let title = self.tab_title(meta.id, cx);
            for (pane_id, session) in entry.panes.read(cx).pane_sessions(cx) {
                let s = session.read(cx);
                let shell = s.shell();
                out.push(SessionCandidate {
                    tab_id: meta.id,
                    pane_id,
                    ai_display_app_name: s.ai_app.clone(),
                    effective_ai_provider: shell.effective_provider(),
                    effective_ai_session_id: shell.ai_session_id().map(str::to_string),
                    status: if s.exited.is_some() {
                        chau7_next_core::shell_session::CommandStatus::Exited
                    } else {
                        s.status()
                    },
                    tab_custom_title: meta.custom_title.clone(),
                    tab_display_title: title.clone(),
                    current_directory: s
                        .cwd
                        .as_ref()
                        .map(|p| p.to_string_lossy().into_owned())
                        .unwrap_or_default(),
                    last_output: s
                        .last_activity
                        .saturating_duration_since(started)
                        .as_secs_f64(),
                    tab_created: meta.created_at,
                });
            }
        }
        out
    }

    /// Select the tab of a session (`OverlayTabsModel.focusTab`). False when
    /// the tab is not in this window.
    pub fn command_center_focus_tab(
        &mut self,
        tab: TabId,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> bool {
        if !self.has_tab(tab) {
            return false;
        }
        self.select_tab(tab, window, cx);
        window.activate_window();
        true
    }

    /// Insert snippet text in the focused terminal of the selected tab.
    pub fn command_center_insert(&mut self, body: &str, cx: &mut Context<Self>) -> bool {
        if self
            .selected_panes()
            .and_then(|panes| panes.read(cx).focused_view())
            .is_none()
        {
            return false;
        }
        self.insert_snippet_text(body, None, cx);
        true
    }
}
