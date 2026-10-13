//! What the MCP server (`crate::mcp`) needs from a window: tab lookup by
//! UUID, tab summaries, background tab creation, close, rename, CTO
//! override (`TerminalControlService.swift`, `OverlayTabsModel`).

use std::path::PathBuf;

use chau7_next_core::history_monitor::{
    SessionStatus, latest_session_status, resolve_effective_prompt_state, resolve_effective_status,
};
use chau7_next_core::shell_session::{CommandStatus, display_name_from_provider};
use chau7_next_core::token_optimization::{
    TabTokenOptOverride, TokenOptimizationMode, should_be_active,
};
use gpui::{App, Context, Entity, Window};
use serde_json::{Map, Value, json};
use uuid::Uuid;

use super::{AppData, Workspace};
use crate::pane::PaneTree;
use crate::session_store::SavedTab;
use crate::tab_bar::TabId;
use crate::terminal::session::TerminalSession;

/// Process sampling of the hover card, reused by `tab_status`.
pub(crate) use crate::monitoring::processes::{CpuSamples, sample as sample_processes};

/// The global token optimization mode.
pub(crate) fn token_optimization_mode(cx: &App) -> TokenOptimizationMode {
    super::hover_card::token_optimization_mode(cx)
}

impl Workspace {
    /// The tab with this UUID in this window.
    pub(crate) fn mcp_find(&self, uuid: Uuid) -> Option<TabId> {
        self.state
            .tabs()
            .iter()
            .find(|t| t.uuid == uuid)
            .map(|t| t.id)
    }

    /// UUIDs of the tabs, in tab bar order.
    pub(crate) fn mcp_tab_uuids(&self) -> Vec<Uuid> {
        self.state.tabs().iter().map(|t| t.uuid).collect()
    }

    /// Process-local MCP control indicator; grants live in mcp::control.
    pub(crate) fn mcp_set_control(&mut self, id: TabId, controlled: bool) -> bool {
        let Some(meta) = self.state.get_mut(id) else {
            return false;
        };
        meta.mcp_controlled = controlled;
        true
    }

    /// Tabs opened by MCP clients (`isMCPControlled`).
    pub(crate) fn mcp_tab_count(&self) -> usize {
        self.state
            .tabs()
            .iter()
            .filter(|t| t.mcp_controlled)
            .count()
    }

    pub(crate) fn mcp_panes(&self, id: TabId) -> Option<Entity<PaneTree>> {
        self.entries.get(&id).map(|e| e.panes.clone())
    }

    /// Saved data for a restored tab whose pane tree is still parked. This is
    /// metadata-only; callers must not use it to construct a terminal session.
    pub(crate) fn mcp_deferred_saved(&self, id: TabId, cx: &App) -> Option<SavedTab> {
        self.entries.get(&id).and_then(|entry| {
            let panes = entry.panes.read(cx);
            if panes.has_terminal() {
                panes.deferred_saved().cloned()
            } else {
                None
            }
        })
    }

    /// The session shown for the tab (`displaySession ?? session`): the
    /// focused pane.
    pub(crate) fn mcp_session(&self, id: TabId, cx: &App) -> Option<Entity<TerminalSession>> {
        self.entries
            .get(&id)
            .and_then(|e| e.panes.read(cx).focused_session(cx))
    }

    pub(crate) fn mcp_controlled(&self, id: TabId) -> bool {
        self.state.get(id).is_some_and(|meta| meta.mcp_controlled)
    }

    /// `tabSummary`: the keys agents parse.
    pub(crate) fn mcp_summary(&self, id: TabId, cx: &App) -> Map<String, Value> {
        self.mcp_summary_with_metadata(id, cx, true)
    }

    /// Readiness polls share the live projection without reading repo files.
    pub(crate) fn mcp_readiness_summary(&self, id: TabId, cx: &App) -> Map<String, Value> {
        self.mcp_summary_with_metadata(id, cx, false)
    }

    fn mcp_summary_with_metadata(
        &self,
        id: TabId,
        cx: &App,
        include_metadata: bool,
    ) -> Map<String, Value> {
        let mut out = Map::new();
        let Some(meta) = self.state.get(id) else {
            return out;
        };
        let session = self.mcp_session(id, cx);
        let session = session.as_ref().map(|s| s.read(cx));
        let deferred_saved = if session.is_none() {
            self.mcp_deferred_saved(id, cx)
        } else {
            None
        };
        let mode = token_optimization_mode(cx);
        let is_ai = session.is_some_and(|s| s.is_ai_running());
        out.insert("tab_id".into(), json!(uuid_string(meta.uuid)));
        out.insert("title".into(), json!(self.tab_title(id, cx)));
        // The AI CLI's history state wins over the shell's (`effectiveStatus`,
        // `effectiveIsAtPrompt`).
        let statuses = if session.is_some() {
            crate::history::monitor::session_statuses(cx)
        } else {
            Vec::new()
        };
        let effective = session.map(|s| effective_state(s, &statuses));
        let status = effective.map(|(st, _)| st.as_str()).unwrap_or("unknown");
        out.insert("status".into(), json!(status));
        let cwd = session
            .and_then(|s| s.cwd.as_ref())
            .map(|p| p.to_string_lossy().into_owned())
            .or_else(|| {
                deferred_saved.as_ref().and_then(|saved| {
                    saved
                        .focused_terminal()
                        .and_then(|pane| pane.directory.clone())
                        .filter(|path| !path.trim().is_empty())
                        .or_else(|| {
                            saved
                                .cwd
                                .as_ref()
                                .map(|path| path.to_string_lossy().into_owned())
                        })
                })
            })
            .unwrap_or_default();
        out.insert("cwd".into(), json!(cwd));
        if deferred_saved.is_some() {
            out.insert("restore_state".into(), json!("deferred"));
        }
        let at_prompt = effective.is_some_and(|(_, p)| p);
        out.insert("is_at_prompt".into(), json!(at_prompt));
        out.insert(
            "is_mcp_controlled".into(),
            json!(deferred_saved.is_none() && meta.mcp_controlled),
        );
        out.insert(
            "cto_active".into(),
            json!(should_be_active(mode, meta.token_opt_override, is_ai)),
        );
        out.insert(
            "cto_override".into(),
            json!(meta.token_opt_override.raw_value()),
        );
        if let Some(s) = session {
            out.insert("raw_status".into(), json!(s.status().as_str()));
            out.insert("raw_is_at_prompt".into(), json!(s.is_at_prompt()));
            if let Some(app) = s.ai_display_app_name() {
                out.insert("active_app".into(), json!(app));
            }
            if let Some(app) = &s.ai_app {
                out.insert("raw_active_app".into(), json!(app));
            }
            out.insert("is_ai_running".into(), json!(s.is_ai_running()));
            out.insert("live_agent_name".into(), json!(s.shell().live_agent_name()));
            if let Some(branch) = &s.git_branch {
                out.insert("git_branch".into(), json!(branch));
            }
            if let Some(root) = &s.git_root {
                out.insert("repo_root".into(), json!(root.to_string_lossy()));
                if include_metadata {
                    let metadata =
                        chau7_next_core::repo_metadata::load(&cx.global::<AppData>().root, root);
                    if let Some(description) = metadata.description {
                        out.insert("repo_description".into(), json!(description));
                    }
                    if !metadata.labels.is_empty() {
                        out.insert("repo_labels".into(), json!(metadata.labels));
                    }
                }
            }
        }
        out
    }

    /// `newTab(at:selectNewTab: false)` for an MCP client: a background tab,
    /// marked MCP-controlled and grouped by repository
    /// (`setupRepoGroupingForTab`). Returns its UUID.
    pub(crate) fn mcp_create_tab(
        &mut self,
        directory: Option<PathBuf>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<Uuid> {
        self.create_automation_tab(directory, true, window, cx)
    }

    /// Explicit trusted UI agent launch creates an ordinary tab.
    pub(crate) fn runtime_create_tab(
        &mut self,
        directory: Option<PathBuf>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<Uuid> {
        self.create_automation_tab(directory, false, window, cx)
    }
    fn create_automation_tab(
        &mut self,
        directory: Option<PathBuf>,
        controlled: bool,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Option<Uuid> {
        let directory = directory.or_else(|| self.inherited_start_directory(cx));
        let id = self.new_tab_at(directory, false, window, cx);
        let meta = self.state.get_mut(id)?;
        meta.mcp_controlled = controlled;
        let group = meta.repo_group_id.clone().or_else(|| meta.git_root.clone());
        meta.repo_group_id = group.clone();
        let uuid = meta.uuid;
        if let Some(group) = group {
            self.state.coalesce_group(&group);
        }
        cx.notify();
        Some(uuid)
    }

    /// `closeTab(id:skipWarning: true)`: no confirmation; the window's last
    /// tab is replaced by a fresh one.
    pub(crate) fn mcp_close_tab(&mut self, id: TabId, window: &mut Window, cx: &mut Context<Self>) {
        if self.state.len() == 1 {
            self.replace_with_fresh_tab(id, window, cx);
        } else {
            self.close_tab(id, false, window, cx);
        }
    }

    /// `tab_rename`: trimmed custom title, cleared when empty. Returns the
    /// title now set ("" when cleared).
    pub(crate) fn mcp_rename(&mut self, id: TabId, title: &str, cx: &mut Context<Self>) -> String {
        let trimmed = title.trim();
        let Some(meta) = self.state.get_mut(id) else {
            return String::new();
        };
        meta.custom_title = (!trimmed.is_empty()).then(|| trimmed.to_string());
        cx.notify();
        trimmed.to_string()
    }

    /// `tab_set_cto`: set the override; returns (`cto_active`, override).
    pub(crate) fn mcp_set_cto(
        &mut self,
        id: TabId,
        value: TabTokenOptOverride,
        cx: &mut Context<Self>,
    ) -> Option<(bool, TabTokenOptOverride)> {
        let mode = token_optimization_mode(cx);
        let is_ai = self
            .mcp_session(id, cx)
            .is_some_and(|s| s.read(cx).is_ai_running());
        self.state.get(id)?;
        self.apply_token_opt_override(id, value, true, cx);
        cx.notify();
        Some((should_be_active(mode, value, is_ai), value))
    }

    /// The tabs of this window for the token optimization settings: the
    /// shell id (`tabIdentifier`) and the title of each.
    pub(crate) fn cto_tabs(&self, cx: &App) -> Vec<(String, String)> {
        self.state
            .tabs()
            .iter()
            .filter_map(|t| {
                let session = self.mcp_session(t.id, cx)?;
                let id = session.read(cx).cto_id().to_string();
                Some((id, self.tab_title(t.id, cx)))
            })
            .collect()
    }

    /// Set a tab's token optimization override and tell every shell of the
    /// tab, which recalculates its flag file (`recalculate`; a saved override
    /// coming back at restore only sets it).
    pub(crate) fn apply_token_opt_override(
        &mut self,
        id: TabId,
        value: TabTokenOptOverride,
        recalculate: bool,
        cx: &mut Context<Self>,
    ) {
        if let Some(meta) = self.state.get_mut(id) {
            meta.token_opt_override = value;
        }
        self.sync_token_opt_override(id, recalculate, cx);
    }

    /// Give the tab's override to its shells.
    pub(crate) fn sync_token_opt_override(
        &self,
        id: TabId,
        recalculate: bool,
        cx: &mut Context<Self>,
    ) {
        let (Some(meta), Some(entry)) = (self.state.get(id), self.entries.get(&id)) else {
            return;
        };
        let value = meta.token_opt_override;
        for view in entry.panes.read(cx).views() {
            let session = view.read(cx).session.clone();
            session.update(cx, |s, _| s.set_token_opt_override(value, recalculate));
        }
    }
}

/// `effectiveStatus` and `effectiveIsAtPrompt`: the shell's status and
/// prompt state, overridden by the history state of the tab's AI session
/// (`matchedAIHistoryState`).
fn effective_state(session: &TerminalSession, statuses: &[SessionStatus]) -> (CommandStatus, bool) {
    let (status, at_prompt) = (session.status(), session.is_at_prompt());
    let shell = session.shell();
    let matched = shell.effective_provider().and_then(|provider| {
        let session_id = shell.ai_session_id()?;
        let tool = display_name_from_provider(Some(&provider)).unwrap_or(provider);
        latest_session_status(statuses, &tool, session_id).map(|s| s.state)
    });
    match matched {
        Some(state) => (
            resolve_effective_status(state, status),
            resolve_effective_prompt_state(state, at_prompt),
        ),
        None => (status, at_prompt),
    }
}

/// UUIDs as Swift prints them (`uuidString`: upper case).
pub(crate) fn uuid_string(uuid: Uuid) -> String {
    uuid.hyphenated().to_string().to_uppercase()
}
