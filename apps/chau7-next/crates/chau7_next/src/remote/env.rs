//! [`HostEnv`] over the app's windows, tabs and terminal sessions.
//!
//! Every terminal window takes part (Swift serves the tabs of its one
//! overlay model). The "selected tab" is the selected tab of the window used
//! last: the active window, else the window remote control last selected in.

use std::collections::HashMap;
use std::time::Instant;

use chau7_next_core::telemetry::remote_client_event::RemoteClientTelemetryEvent;
use chrono::{DateTime, Utc};
use gpui::{AnyWindowHandle, App, Entity};

use super::host::{HostEnv, LastCommandInfo, PaneInfo, TabInfo, TabKey};
use super::snapshot;
use crate::pane::PaneTree;
use crate::terminal::session::TerminalSession;
use crate::workspace::{AppData, Workspace};

/// Lines of a pane given to the prompt detector (it reads the last 80).
const PROMPT_LINES: i32 = 80;

struct CachedTab {
    window: AnyWindowHandle,
    workspace: Entity<Workspace>,
    panes: Entity<PaneTree>,
    /// (pane id, session) in visual order.
    sessions: Vec<(u64, Entity<TerminalSession>)>,
    main: usize,
}

pub struct GpuiEnv<'a> {
    pub cx: &'a mut App,
    /// The window remote control follows when no window is active.
    pub focus_window: &'a mut Option<AnyWindowHandle>,
    pub resolved: Vec<(String, bool)>,
    pub telemetry: Vec<RemoteClientTelemetryEvent>,
    cache: Option<(Vec<TabInfo>, HashMap<TabKey, CachedTab>)>,
    now: DateTime<Utc>,
}

impl<'a> GpuiEnv<'a> {
    pub fn new(cx: &'a mut App, focus_window: &'a mut Option<AnyWindowHandle>) -> Self {
        Self {
            cx,
            focus_window,
            resolved: Vec::new(),
            telemetry: Vec::new(),
            cache: None,
            now: Utc::now(),
        }
    }

    fn date_of(&self, instant: Instant) -> DateTime<Utc> {
        let ago = instant.elapsed();
        self.now - chrono::Duration::from_std(ago).unwrap_or_default()
    }

    fn pane_info(&self, pane_id: u64, session: &TerminalSession) -> PaneInfo {
        let shell = session.shell();
        PaneInfo {
            pane_id,
            session_id: session.id,
            ai_app: session.ai_app.clone().filter(|a| !a.is_empty()),
            ai_provider: shell.effective_provider(),
            ai_session_id: shell.ai_session_id().map(str::to_string),
            status: session.status(),
            at_prompt: session.is_at_prompt(),
            cwd: session
                .cwd
                .as_ref()
                .map(|p| p.to_string_lossy().into_owned()),
            git_branch: session.git_branch.clone(),
            last_output_at: Some(self.date_of(session.last_activity)),
        }
    }

    fn build(&mut self) -> &(Vec<TabInfo>, HashMap<TabKey, CachedTab>) {
        if self.cache.is_none() {
            let mut infos = Vec::new();
            let mut cached = HashMap::new();
            for (window, workspace) in AppData::live(self.cx) {
                let sources = workspace.read(self.cx).remote_tabs(self.cx);
                for source in sources {
                    let tree = source.panes.read(self.cx);
                    let sessions = tree.pane_sessions(self.cx);
                    if sessions.is_empty() {
                        continue;
                    }
                    let focused = tree.focused_pane_id();
                    let main = sessions
                        .iter()
                        .position(|(id, _)| Some(*id) == focused)
                        .unwrap_or(0);
                    let panes: Vec<PaneInfo> = sessions
                        .iter()
                        .map(|(id, s)| self.pane_info(*id, s.read(self.cx)))
                        .collect();
                    let last_command =
                        sessions[main]
                            .1
                            .read(self.cx)
                            .blocks()
                            .blocks()
                            .last()
                            .map(|b| LastCommandInfo {
                                command: b.command.clone(),
                                start_time: b.start_time,
                                end_time: b.end_time,
                                exit_code: b.exit_code,
                            });
                    infos.push(TabInfo {
                        key: source.id,
                        title: source.title,
                        custom_title: source.custom_title,
                        is_mcp_controlled: source.mcp_controlled,
                        main_pane: main,
                        panes,
                        last_command,
                    });
                    cached.insert(
                        source.id,
                        CachedTab {
                            window,
                            workspace: workspace.clone(),
                            panes: source.panes.clone(),
                            sessions,
                            main,
                        },
                    );
                }
            }
            self.cache = Some((infos, cached));
        }
        self.cache.as_ref().expect("built above")
    }

    fn tab(&mut self, key: TabKey) -> Option<&CachedTab> {
        self.build().1.get(&key)
    }

    fn main_session(&mut self, key: TabKey) -> Option<Entity<TerminalSession>> {
        let tab = self.tab(key)?;
        tab.sessions.get(tab.main).map(|(_, s)| s.clone())
    }

    /// The window remote control follows.
    fn focus_workspace(&mut self) -> Option<Entity<Workspace>> {
        let live = AppData::live(self.cx);
        if let Some(active) = self.cx.active_window()
            && live.iter().any(|(h, _)| *h == active)
        {
            *self.focus_window = Some(active);
        }
        let chosen = self
            .focus_window
            .and_then(|f| live.iter().find(|(h, _)| *h == f).cloned())
            .or_else(|| live.first().cloned())?;
        *self.focus_window = Some(chosen.0);
        Some(chosen.1)
    }
}

impl HostEnv for GpuiEnv<'_> {
    fn tabs(&mut self) -> Vec<TabInfo> {
        self.build().0.clone()
    }

    fn selected(&mut self) -> Option<TabKey> {
        let workspace = self.focus_workspace()?;
        workspace.read(self.cx).selected_tab_id()
    }

    fn select(&mut self, key: TabKey) -> bool {
        let Some((window, workspace)) = self.tab(key).map(|t| (t.window, t.workspace.clone()))
        else {
            return false;
        };
        let done = window
            .update(self.cx, |_, window, cx| {
                workspace.update(cx, |ws, cx| ws.select_tab(key, window, cx));
            })
            .is_ok();
        if done {
            *self.focus_window = Some(window);
        }
        done
    }

    fn text_snapshot(&mut self, key: TabKey) -> Option<Vec<u8>> {
        let session = self.main_session(key)?;
        Some(session.read(self.cx).buffer_text().into_bytes())
    }

    fn grid_snapshot(&mut self, key: TabKey) -> Option<Vec<u8>> {
        let session = self.main_session(key)?;
        let session = session.read(self.cx);
        snapshot::encode_grid(&session.grid, session.cursor)
    }

    fn pane_text(&mut self, key: TabKey, pane_id: u64) -> Option<String> {
        let session = self
            .tab(key)?
            .sessions
            .iter()
            .find(|(id, _)| *id == pane_id)
            .map(|(_, s)| s.clone())?;
        let session = session.read(self.cx);
        let rows = i32::from(session.grid.rows);
        let lines: Vec<String> = (rows - PROMPT_LINES..rows)
            .filter_map(|line| session.line_text(line))
            .collect();
        Some(lines.join("\n"))
    }

    fn write_input(&mut self, key: TabKey, text: &str) -> bool {
        let Some(panes) = self.tab(key).map(|t| t.panes.clone()) else {
            return false;
        };
        PaneTree::send_input(&panes, text.as_bytes(), self.cx);
        // The tabs read before the input are stale now.
        self.cache = None;
        true
    }

    fn clear_persistent_style(&mut self, key: TabKey) {
        if let Some(workspace) = self.tab(key).map(|t| t.workspace.clone()) {
            workspace.update(self.cx, |ws, cx| {
                ws.clear_persistent_style(key, cx);
            });
        }
    }

    fn resolve_approval(&mut self, request_id: &str, approved: bool) {
        self.resolved.push((request_id.to_string(), approved));
    }

    fn store_telemetry(&mut self, event: RemoteClientTelemetryEvent) {
        self.telemetry.push(event);
    }

    fn now(&self) -> DateTime<Utc> {
        self.now
    }
}
