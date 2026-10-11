//! Agent runtime (`apps/chau7-macos/Sources/Chau7/Runtime/`): AI agents
//! started in tabs and driven turn by turn through the `runtime_*` MCP
//! tools. The logic (backends, sessions, registry, journal) is
//! `chau7_next_core::runtime`; this module plugs it into the app:
//!
//! - [`manager`]: the one registry, shared by the MCP client threads and the
//!   main thread (Claude Code hook events, the 30 s cleanup).
//! - [`AppHost`]: what the registry asks of the app, on the main thread
//!   (type into a tab, read its output, find a tab by directory, post a
//!   notification).
//! - [`control`]: the MCP tools (`RuntimeControlService`).
//! - Hooks for other modules: [`handle_claude_event`] (the AI hub feeds
//!   every Claude Code hook event here first) and
//!   [`notification_tab_for_claude_session`] (Claude notifications of a
//!   runtime session go to its tab, RUN-023).

pub mod control;

use std::sync::OnceLock;
use std::time::Duration;

use chau7_next_core::ai::event::{AiEvent, AiEventReliability, AiEventSource};
use chau7_next_core::mcp::output::format_buffer_output;
use chau7_next_core::monitoring::claude_code::ClaudeCodeEvent;
use chau7_next_core::runtime::manager::{
    CLEANUP_INTERVAL_SECONDS, RuntimeHost, RuntimeNotification, RuntimeSessionManager,
};
use gpui::App;
use uuid::Uuid;

use crate::ai::events_out;
use crate::mcp::windows::{find_tab, windows};
use crate::pane::PaneTree;
use crate::workspace::AppData;
use crate::workspace::mcp::uuid_string;

static MANAGER: OnceLock<RuntimeSessionManager> = OnceLock::new();

/// The session registry (`RuntimeSessionManager.shared`). Before [`init`]
/// (tests), it reads no Claude transcripts.
pub fn manager() -> &'static RuntimeSessionManager {
    MANAGER.get_or_init(|| RuntimeSessionManager::new(None))
}

/// Create the registry and start the 30 s cleanup (`startCleanupTimer`).
pub fn init(cx: &mut App) {
    let projects = cx.global::<AppData>().root.claude_projects_dir();
    let _ = MANAGER.set(RuntimeSessionManager::new(Some(projects)));
    cx.spawn(async move |cx| {
        loop {
            cx.background_executor()
                .timer(Duration::from_secs(CLEANUP_INTERVAL_SECONDS))
                .await;
            cx.update(|cx| {
                manager().cleanup(chrono::Utc::now(), &mut AppHost { cx });
                sync_runtime_owned_tabs(cx);
            });
        }
    })
    .detach();
}

/// A Claude Code hook event, before it goes to notifications
/// (`AppModel.handleClaudeCodeMonitorEvent` feeds the runtime first).
pub fn handle_claude_event(event: &ClaudeCodeEvent, cx: &mut App) {
    let before = manager().managed_tabs();
    manager().handle_claude_event(event, &mut AppHost { cx });
    if manager().managed_tabs() != before {
        sync_runtime_owned_tabs(cx);
    }
}

/// The notification `tab_id` of the runtime session bound to a Claude
/// session (`sessionForClaudeSessionID(..)?.tabID`), so the Claude event
/// lands on the runtime's tab.
pub fn notification_tab_for_claude_session(claude_session: &str, cx: &mut App) -> Option<Uuid> {
    let session = manager().session_for_claude_session_id(claude_session)?;
    let tab = find_tab(&session.tab_id, cx)?;
    Some(events_out::tab_uuid(tab.tab))
}

/// Tell every terminal whether its tab hosts a runtime session, for the
/// terminal-prompt "waiting for input" fallback (RUN-023).
pub fn sync_runtime_owned_tabs(cx: &mut App) {
    let managed = manager().managed_tabs();
    for window in windows(cx) {
        let ws = window.workspace.read(cx);
        let tabs: Vec<_> = ws
            .mcp_tab_uuids()
            .into_iter()
            .filter_map(|uuid| {
                let id = ws.mcp_find(uuid)?;
                Some((managed.contains(&uuid_string(uuid)), ws.mcp_panes(id)?))
            })
            .collect();
        for (owned, panes) in tabs {
            let sessions = panes.read(cx).pane_sessions(cx);
            for (_, session) in sessions {
                if session.read(cx).shell().runtime_owns_tab != owned {
                    session.update(cx, |s, _| s.set_runtime_owned(owned));
                }
            }
        }
    }
}

/// The app as the registry sees it, on the main thread.
pub struct AppHost<'a> {
    pub cx: &'a mut App,
}

impl RuntimeHost for AppHost<'_> {
    fn send_input(&mut self, tab_id: &str, input: &str) {
        let Some(tab) = find_tab(tab_id, self.cx) else {
            return;
        };
        if let Some(panes) = tab.window.workspace.read(self.cx).mcp_panes(tab.tab) {
            PaneTree::send_input(&panes, input.as_bytes(), self.cx);
        }
    }

    fn tab_output(&mut self, tab_id: &str, lines: usize) -> Option<String> {
        let tab = find_tab(tab_id, self.cx)?;
        let session = tab
            .window
            .workspace
            .read(self.cx)
            .mcp_session(tab.tab, self.cx)?;
        let text = session.read(self.cx).buffer_text();
        Some(format_buffer_output(&text, lines).0)
    }

    fn tab_for_cwd(&mut self, cwd: &str) -> Option<String> {
        for window in windows(self.cx) {
            let ws = window.workspace.read(self.cx);
            for uuid in ws.mcp_tab_uuids() {
                let Some(id) = ws.mcp_find(uuid) else {
                    continue;
                };
                let tab_cwd = ws
                    .mcp_session(id, self.cx)
                    .and_then(|s| s.read(self.cx).cwd.clone())
                    .map(|p| p.to_string_lossy().into_owned())
                    .unwrap_or_default();
                if tab_cwd == cwd {
                    return Some(uuid_string(uuid));
                }
            }
        }
        None
    }

    fn tab_exists(&mut self, tab_id: &str) -> bool {
        find_tab(tab_id, self.cx).is_some()
    }

    fn notify(&mut self, n: RuntimeNotification) {
        let mut event = AiEvent::new(
            AiEventSource::new(AiEventSource::RUNTIME),
            n.event_type,
            n.tool,
            n.message,
            chau7_next_core::iso8601::now_iso8601(),
        );
        event.directory = Some(n.directory);
        event.tab_id = find_tab(&n.tab_id, self.cx).map(|t| events_out::tab_uuid(t.tab));
        event.session_id = Some(n.session_id);
        event.producer = Some("runtime_session_manager".into());
        event.reliability = AiEventReliability::Authoritative;
        events_out::publish(event, true, self.cx);
    }
}
