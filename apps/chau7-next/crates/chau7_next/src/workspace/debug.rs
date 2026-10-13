//! Demo tabs for checking every tab state by eye.

use std::time::Duration;

use chau7_next_core::shell_latency::{LagEvent, LagKind};
use gpui::{App, Context, Div, Stateful, Window, prelude::*};

use super::{AppData, Workspace};
use crate::actions::SeedDebugTabs;
use crate::tab_bar::TabId;

pub(super) fn register_debug_actions(
    div: Stateful<Div>,
    cx: &mut Context<Workspace>,
) -> Stateful<Div> {
    div.on_action(
        cx.listener(|this, _: &SeedDebugTabs, window, cx| this.seed_debug_tabs(window, cx)),
    )
}

impl Workspace {
    /// Demo data for checking every tab state (Window > Load Demo Tabs).
    fn seed_debug_tabs(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let home = cx.global::<AppData>().root.home().to_path_buf();
        let mut ids = Vec::new();
        for _ in 0..12 {
            // Background tabs, as MCP opens them.
            ids.push(self.new_tab_at(Some(home.clone()), false, window, cx));
        }
        let groups = ["/demo/chau7", "/demo/website"];
        for (g, group) in groups.iter().enumerate() {
            for id in &ids[g * 3..g * 3 + 3] {
                if let Some(meta) = self.state.get_mut(*id) {
                    meta.repo_group_id = Some(group.to_string());
                    meta.git_root = Some(group.to_string());
                    meta.primary_git_root = Some(group.to_string());
                    meta.presentation_git_root = Some(group.to_string());
                }
            }
            self.state.coalesce_group(group);
        }
        // Shells print their prompt right after starting, which counts as
        // activity; mark the idle demo tabs once that has happened.
        let idle_ids = ids[6..9].to_vec();
        cx.spawn(async move |this, cx| {
            cx.background_executor().timer(Duration::from_secs(2)).await;
            let _ = this.update(cx, |this, cx| {
                for id in &idle_ids {
                    this.state.force_idle(*id);
                }
                cx.notify();
            });
        })
        .detach();
        // Styles as notification actions build them.
        let config = |pairs: &[(&str, &str)]| -> std::collections::HashMap<String, String> {
            pairs
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect()
        };
        let styles = [
            ("waiting", config(&[])),
            ("error", config(&[])),
            (
                "attention",
                config(&[("borderStyle", "dotted"), ("borderWidth", "1.5")]),
            ),
            (
                "success",
                config(&[
                    ("borderWidth", "1"),
                    ("borderStyle", "dashed"),
                    ("pulse", "true"),
                ]),
            ),
        ];
        for (id, (preset, config)) in ids[9..].iter().chain(&ids[..1]).zip(styles) {
            self.apply_notification_style(*id, preset, &config, cx);
        }
        self.set_tab_badge(ids[0], Some("3".into()), None, cx);
        if let Some(meta) = self.state.get_mut(ids[2]) {
            meta.mcp_controlled = true;
        }
        if let Some(meta) = self.state.get_mut(ids[1]) {
            meta.custom_title = Some("renamed tab".into());
        }
        cx.notify();
    }
}

/// What the Debug Console and the bug reports need to know about one tab
/// (`TabState` of `StateSnapshot`, the State, Lag and Health tabs).
#[derive(Debug, Clone)]
pub struct TabDebugInfo {
    pub id: TabId,
    /// Window the tab is in (position in `AppData::workspaces`).
    pub window: usize,
    pub title: String,
    pub custom_title: Option<String>,
    pub ai_app: Option<String>,
    /// `CommandStatus::as_str`.
    pub status: String,
    pub cwd: String,
    pub git_branch: Option<String>,
    pub is_git_repo: bool,
    pub selected: bool,
    /// Not selected and no activity for more than 10 minutes.
    pub idle: bool,
    pub shell_integration: bool,
    pub render_suspended: bool,
    /// `"12ms (avg 9ms)"` per kind, or `"n/a"`.
    pub input_lag: String,
    pub output_lag: String,
    pub highlight_lag: String,
    /// `"p50ms / p95ms (n=N)"` per kind.
    pub input_percentiles: String,
    pub output_percentiles: String,
    pub highlight_percentiles: String,
    pub lag_timeline: Vec<LagEvent>,
    pub last_command: Option<String>,
    pub changed_files: Vec<String>,
}

/// Seconds without activity after which a tab counts as idle in the Health tab.
const IDLE_AFTER_SECS: f64 = 600.0;

impl Workspace {
    /// The tabs of this window in order, for the Debug Console.
    pub fn debug_tabs(&self, window_index: usize, cx: &App) -> Vec<TabDebugInfo> {
        let now = AppData::now(cx);
        let selected = self.state.selected();
        self.state
            .tabs()
            .iter()
            .map(|meta| {
                let session = self
                    .entries
                    .get(&meta.id)
                    .and_then(|entry| entry.panes.read(cx).focused_session(cx));
                let is_selected = Some(meta.id) == selected;
                let mut info = TabDebugInfo {
                    id: meta.id,
                    window: window_index,
                    title: self.tab_title(meta.id, cx),
                    custom_title: meta.custom_title.clone(),
                    ai_app: None,
                    status: "idle".into(),
                    cwd: String::new(),
                    git_branch: None,
                    is_git_repo: meta.git_root.is_some(),
                    selected: is_selected,
                    idle: !is_selected && now - meta.last_activity > IDLE_AFTER_SECS,
                    shell_integration: false,
                    render_suspended: false,
                    input_lag: "n/a".into(),
                    output_lag: "n/a".into(),
                    highlight_lag: "n/a".into(),
                    input_percentiles: "n/a".into(),
                    output_percentiles: "n/a".into(),
                    highlight_percentiles: "n/a".into(),
                    lag_timeline: Vec::new(),
                    last_command: None,
                    changed_files: Vec::new(),
                };
                if let Some(session) = session {
                    let session = session.read(cx);
                    info.ai_app = session.ai_app.clone();
                    info.status = session.status().as_str().to_string();
                    info.cwd = session
                        .cwd
                        .as_ref()
                        .map(|p| p.to_string_lossy().into_owned())
                        .unwrap_or_default();
                    info.git_branch = session.git_branch.clone();
                    info.is_git_repo = session.git_root.is_some();
                    info.shell_integration = session.has_shell_integration();
                    info.render_suspended = session.is_render_suspended();
                    let latency = session.latency();
                    info.input_lag = latency.summary(LagKind::Input);
                    info.output_lag = latency.summary(LagKind::Output);
                    info.highlight_lag = latency.summary(LagKind::Highlight);
                    info.input_percentiles = latency.percentiles(LagKind::Input);
                    info.output_percentiles = latency.percentiles(LagKind::Output);
                    info.highlight_percentiles = latency.percentiles(LagKind::Highlight);
                    info.lag_timeline = latency.timeline().to_vec();
                    drop(latency);
                    info.last_command = session.last_command_text();
                    info.changed_files = session.blocks().last_changed_files().to_vec();
                }
                info
            })
            .collect()
    }

    /// Numeric measurements for every terminal pane, without copying terminal text.
    pub fn performance_terminals(&self, window_index: usize, cx: &App) -> Vec<serde_json::Value> {
        let mut terminals = Vec::new();
        for meta in self.state.tabs() {
            let Some(entry) = self.entries.get(&meta.id) else {
                continue;
            };
            for (pane_id, entity) in entry.panes.read(cx).pane_sessions(cx) {
                let session = entity.read(cx);
                let latency = session.latency();
                let lag = latency
                    .timeline()
                    .iter()
                    .rev()
                    .take(16)
                    .map(|event| {
                        serde_json::json!({"kind": event.kind.as_str(),
                        "elapsed_ms": event.elapsed_ms, "average_ms": event.average_ms,
                        "p50_ms": event.p50, "p95_ms": event.p95,
                        "sample_count": event.sample_count, "at_monotonic_seconds": event.at})
                    })
                    .collect::<Vec<_>>();
                terminals.push(serde_json::json!({
                    "tab_id": meta.id.to_string(), "pane_id": pane_id.to_string(),
                    "window_id": window_index, "selected": self.state.selected() == Some(meta.id),
                    "render_suspended": session.is_render_suspended(),
                    "session_id":session.id, "memory":session.allocation_snapshot(),
                    "input": latency.statistics(LagKind::Input),
                    "output": latency.statistics(LagKind::Output),
                    "highlight": latency.statistics(LagKind::Highlight), "lag_events": lag
                }));
            }
        }
        terminals
    }

    /// The window is the key window (the Debug Console shows this window's
    /// tabs while it is in front).
    pub fn is_window_active(&self) -> bool {
        self.window_active
    }

    /// Broadcast input is on (`broadcastMode` feature flag of snapshots).
    pub fn broadcast_on(&self) -> bool {
        self.broadcast
    }

    /// The session of a tab's focused pane.
    pub fn debug_session(
        &self,
        id: TabId,
        cx: &App,
    ) -> Option<gpui::Entity<crate::terminal::session::TerminalSession>> {
        self.entries.get(&id)?.panes.read(cx).focused_session(cx)
    }

    /// The selected tab's session (Changed Files, Lag tab).
    pub fn selected_debug_session(
        &self,
        cx: &App,
    ) -> Option<gpui::Entity<crate::terminal::session::TerminalSession>> {
        let id = self.state.selected()?;
        self.entries.get(&id)?.panes.read(cx).focused_session(cx)
    }

    /// Forget the lag timelines of all tabs, or of the selected tab.
    pub fn clear_lag_timelines(&self, only_selected: bool, cx: &App) {
        let selected = self.state.selected();
        for (id, entry) in &self.entries {
            if only_selected && Some(*id) != selected {
                continue;
            }
            if let Some(session) = entry.panes.read(cx).focused_session(cx) {
                session.read(cx).clear_lag_timeline();
            }
        }
    }

    /// (dev) `logVisualState`: one trace line with the tab and overlay state,
    /// written when a panel opens or closes and when the window is created.
    pub(super) fn log_visual_state(&self, reason: &str, cx: &App) {
        if !log::log_enabled!(log::Level::Trace) {
            return;
        }
        let selected = self.state.selected();
        let index = selected
            .and_then(|id| self.state.index_of(id))
            .map_or(-1, |i| i as i64);
        let active_app = self
            .selected_panes()
            .and_then(|p| p.read(cx).focused_session(cx))
            .and_then(|s| s.read(cx).ai_app.clone())
            .unwrap_or_else(|| "nil".into());
        let path = selected
            .and_then(|id| self.tab_path(id, cx))
            .unwrap_or_default();
        let picker = self.picker.as_ref().map(|p| p.kind);
        log::trace!(
            "Overlay visual state ({reason}): tabs={} selectedIndex={index} selectedID={} \
             activeApp={active_app} path={path} overlays[search={} rename={} clipboard={} \
             bookmarks={} snippets={} timeline={}]",
            self.state.len(),
            selected.map_or_else(|| "nil".to_string(), |id| id.to_string()),
            self.search.is_some(),
            self.rename.is_some(),
            picker == Some(super::pickers::PickerKind::Clipboard),
            self.bookmarks_panel.is_some(),
            picker == Some(super::pickers::PickerKind::Snippets),
            self.timeline_panel.is_some(),
        );
    }
}
