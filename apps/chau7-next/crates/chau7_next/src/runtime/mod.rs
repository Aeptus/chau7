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

pub mod codex_feedback;
pub mod control;

use std::sync::OnceLock;
use std::time::Duration;

use chau7_next_core::ai::event::{AiEvent, AiEventReliability, AiEventSource};
use chau7_next_core::mcp::output::format_buffer_output;
use chau7_next_core::monitoring::claude_code::ClaudeCodeEvent;
use chau7_next_core::runtime::manager::{
    CLEANUP_INTERVAL_SECONDS, RuntimeHost, RuntimeNotification, RuntimeSessionManager,
};
use gpui::{App, AppContext};
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
    let timer = crate::observability::register_timer(
        cx,
        "runtime.cleanup",
        "Runtime session cleanup",
        "runtime",
        CLEANUP_INTERVAL_SECONDS * 1000,
    );
    cx.spawn(async move |cx| {
        let _timer = timer;
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
    start_readiness_monitor(cx);
    codex_feedback::start(cx);
}

fn start_readiness_monitor(cx: &mut App) {
    let timer = crate::observability::register_timer(
        cx,
        "runtime.readiness",
        "Runtime launch and turn readiness",
        "runtime",
        500,
    );
    cx.spawn(async move |cx| {
        let _timer = timer;
        loop {
            cx.background_executor()
                .timer(Duration::from_millis(500))
                .await;
            let snapshots = cx.update(|cx| {
                let mut callback = chau7_next_core::work_profiler::timer_callback(
                    "runtime.readiness",
                    "capture",
                    chau7_next_core::work_profiler::Queue::Main,
                );
                let snapshots = manager()
                    .all_sessions(false)
                    .into_iter()
                    .filter(|session| {
                        matches!(
                            session.state(),
                            chau7_next_core::runtime::session_state::State::Starting
                                | chau7_next_core::runtime::session_state::State::Busy
                                | chau7_next_core::runtime::session_state::State::Ready
                        )
                    })
                    .filter_map(|session| {
                        launch_snapshot(&session, cx)
                            .map(|(snapshot, pid)| (session, snapshot, pid))
                    })
                    .collect::<Vec<_>>();
                callback.items(snapshots.len());
                callback.idle(snapshots.is_empty());
                snapshots
            });
            if snapshots.is_empty() {
                continue;
            }
            let snapshots = cx
                .background_spawn(async move {
                    let mut callback = chau7_next_core::work_profiler::timer_callback(
                        "runtime.readiness",
                        "process_probe",
                        chau7_next_core::work_profiler::Queue::Background,
                    );
                    callback.items(snapshots.len());
                    snapshots
                        .into_iter()
                        .map(|(session, mut snapshot, pid)| {
                            if session.state()
                                == chau7_next_core::runtime::session_state::State::Starting
                                && snapshot.ai_provider.is_none()
                                && snapshot.active_run_provider.is_none()
                            {
                                snapshot.process_names =
                                    crate::platform::process::process_tree(pid)
                                        .into_iter()
                                        .filter_map(crate::platform::process::process_name)
                                        .collect();
                            }
                            (session, snapshot)
                        })
                        .collect::<Vec<_>>()
                })
                .await;
            cx.update(|cx| {
                let mut callback = chau7_next_core::work_profiler::timer_callback(
                    "runtime.readiness",
                    "apply",
                    chau7_next_core::work_profiler::Queue::Main,
                );
                callback.items(snapshots.len());
                use chau7_next_core::runtime::{launch_readiness, session_state::State};
                for (session, snapshot) in snapshots {
                    session.observe_terminal_status(&snapshot.effective_status);
                    if session.state() == State::Starting
                        && (session.backend.name() == "shell"
                            && !snapshot.shell_loading
                            && snapshot.is_at_prompt
                            || launch_readiness::is_ready(
                                &snapshot,
                                session.backend.name(),
                                session.config.purpose.as_deref(),
                            ))
                    {
                        manager().mark_ready(&session.id);
                    } else if session.state() == State::Busy {
                        let fresh = snapshot
                            .status_observed_at
                            .zip(session.last_turn_submitted_at())
                            .is_none_or(|(observed, submitted)| {
                                observed.timestamp_millis() >= submitted.timestamp_millis()
                            });
                        if fresh && launch_readiness::is_settled(&snapshot, session.backend.name())
                        {
                            manager().reconcile_settled_turn(
                                &session.id,
                                "terminal_settled:monitor",
                                &mut AppHost { cx },
                            );
                        }
                    }
                }
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

    fn live_ai_identity(&mut self, tab_id: &str) -> Option<(String, Option<String>)> {
        let tab = find_tab(tab_id, self.cx)?;
        let terminal = tab
            .window
            .workspace
            .read(self.cx)
            .mcp_session(tab.tab, self.cx)?;
        let shell = terminal.read(self.cx).shell();
        Some((
            shell.effective_provider()?,
            shell.ai_session_id().map(str::to_string),
        ))
    }

    fn tab_for_claude_event(&mut self, cwd: &str, native_id: Option<&str>) -> Option<String> {
        let mut unbound = Vec::new();
        let mut matched = Vec::new();
        for window in windows(self.cx) {
            let ws = window.workspace.read(self.cx);
            for uuid in ws.mcp_tab_uuids() {
                let Some(id) = ws.mcp_find(uuid) else {
                    continue;
                };
                let Some(terminal) = ws.mcp_session(id, self.cx) else {
                    continue;
                };
                let terminal = terminal.read(self.cx);
                let shell = terminal.shell();
                if !shell
                    .effective_provider()
                    .is_some_and(|p| p.eq_ignore_ascii_case("claude"))
                {
                    continue;
                }
                if native_id
                    .zip(shell.ai_session_id())
                    .is_some_and(|(incoming, current)| incoming.eq_ignore_ascii_case(current))
                {
                    matched.push(uuid_string(uuid));
                } else if shell.ai_session_id().is_none()
                    && terminal
                        .cwd
                        .as_ref()
                        .is_some_and(|p| p.to_string_lossy() == cwd)
                {
                    unbound.push(uuid_string(uuid));
                }
            }
        }
        if matched.len() == 1 {
            matched.pop()
        } else if matched.is_empty() && unbound.len() == 1 {
            unbound.pop()
        } else {
            None
        }
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

/// Cheap main-thread snapshot; process enumeration belongs on a worker.
pub fn launch_snapshot(
    session: &chau7_next_core::runtime::session::RuntimeSession,
    cx: &mut App,
) -> Option<(
    chau7_next_core::runtime::launch_readiness::LaunchSnapshot,
    u32,
)> {
    use chau7_next_core::history_monitor::{
        latest_session_status, resolve_effective_prompt_state, resolve_effective_status,
    };
    use chau7_next_core::shell_session::display_name_from_provider;
    let tab = find_tab(&session.tab_id, cx)?;
    let terminal = tab.window.workspace.read(cx).mcp_session(tab.tab, cx)?;
    let terminal = terminal.read(cx);
    let shell = terminal.shell();
    let provider = shell.effective_provider();
    let statuses = crate::history::monitor::session_statuses(cx);
    let matched = provider.as_ref().and_then(|provider| {
        let tool = display_name_from_provider(Some(provider)).unwrap_or_else(|| provider.clone());
        latest_session_status(&statuses, &tool, shell.ai_session_id()?)
            .map(|status| (status.state, status.last_seen))
    });
    let effective_status = matched.map_or(terminal.status(), |(state, _)| {
        resolve_effective_status(state, terminal.status())
    });
    let is_at_prompt = matched.map_or(terminal.is_at_prompt(), |(state, _)| {
        resolve_effective_prompt_state(state, terminal.is_at_prompt())
    });
    let active_run_provider = crate::telemetry::recorder(cx).and_then(|recorder| {
        recorder
            .active_run_for_tab(&terminal.tab_identifier)
            .map(|run| run.provider)
    });
    Some((
        chau7_next_core::runtime::launch_readiness::LaunchSnapshot {
            shell_loading: terminal.is_loading(),
            is_at_prompt,
            effective_status: effective_status.as_str().into(),
            raw_status: terminal.status().as_str().into(),
            active_app: terminal.ai_app.clone(),
            raw_active_app: terminal.ai_app.clone(),
            ai_provider: provider,
            active_run_provider,
            process_names: Vec::new(),
            status_observed_at: matched.and_then(|(_, seen)| {
                chrono::DateTime::from_timestamp_millis((seen * 1000.0) as i64)
            }),
        },
        terminal.shell_pid() as u32,
    ))
}
