//! App-wide AI monitors (`AppModel` bootstrap): the AI event logs, Claude
//! Code hook events and cross-tab file conflicts. Claude and Codex history
//! idle detection and the PTY log lines of the log view are followed by
//! `crate::history::monitor`; their "idle" and "finished" notices are
//! published here, with the session's directory resolved.
//!
//! Every file here is followed read-only with `FileTailer`: Chau7 Next
//! never creates, truncates or rotates the files hooks and the Swift app
//! write (`~/.ai-events.log`, `~/.chau7/claude-events.jsonl`, the Claude
//! and Codex histories). Its own AI events log (`DataRoot::ai_events_log`)
//! is followed too, for the timeline.
//!
//! One loop polls the files on a background thread every 250 ms (Claude
//! hooks) or 500 ms (event logs) and applies what it read on the main
//! thread, then runs the Claude idle check and publishes the history
//! monitor's notices.

use std::collections::HashMap;
use std::path::PathBuf;
use std::time::Duration;

use chau7_next_core::ai::detection_state::now_secs;
use chau7_next_core::ai::event::{AiEvent, AiEventReliability, AiEventSource, parse_line};
use chau7_next_core::ai::tool_registry::{event_source_raw_value_for, resume_provider_key_for};
use chau7_next_core::command_detection::event_parsing::EventType;
use chau7_next_core::data_root::DataRoot;
use chau7_next_core::history_events::resolve_directory;
use chau7_next_core::iso8601;
use chau7_next_core::monitoring::claude_code::{
    ClaudeCodeEvent, ClaudeSessionTracker, WAITING_INPUT_FALLBACK_DELAY, parse_event_line,
    waiting_input_message,
};
use chau7_next_core::monitoring::codex_sessions::{
    Candidate, CodexSessionResolver, best_matching_session_id,
};
use chau7_next_core::monitoring::conflicts::{ConflictDetector, FinishedBlock, conflict_message};
use chau7_next_core::monitoring::tailer::FileTailer;
use gpui::{App, Global, Task};

use super::events_out::{self, tab_uuid};
use crate::history::monitor::{self as history_monitor, HistoryNotice};
use crate::monitoring_status::MonitoringStatus;
use crate::settings::Settings;
use crate::tab_bar::TabId;
use crate::workspace::AppData;

/// State shared by the monitors.
#[derive(Default)]
pub struct AiHub {
    pub claude: ClaudeSessionTracker,
    pub codex: CodexSessionResolver,
    claude_fallbacks: HashMap<String, Task<()>>,
    conflicts: ConflictDetector<TabId>,
    finished_blocks: HashMap<TabId, Vec<FinishedBlock>>,
    /// "Restart Monitor" was clicked: rebuild the event log tailers.
    restart_requested: bool,
}

impl Global for AiHub {}

/// Event log monitor settings ("Monitor AI Events" and the log path in
/// Settings > Notifications).
#[derive(Debug, Clone, PartialEq)]
struct Flags {
    /// The shared AI events log to follow; `None` when monitoring is off.
    events: Option<PathBuf>,
}

/// The tailers, moved to a background thread for each poll.
struct MonitorIo {
    flags: Option<Flags>,
    claude: Option<FileTailer>,
    events: Vec<FileTailer>,
}

/// What one poll read.
#[derive(Default)]
struct Batch {
    claude: Vec<String>,
    events: Vec<String>,
}

impl MonitorIo {
    /// Rebuilds the tailers when the settings change (`applyMonitoringState`)
    /// or on "Restart Monitor" (`restartTailer`).
    fn configure(&mut self, root: &DataRoot, flags: Flags, restart: bool) {
        if self.flags.as_ref() == Some(&flags) && !restart {
            return;
        }
        self.flags = Some(flags.clone());
        let started = |path| {
            let mut tailer = FileTailer::new(path);
            tailer.start(0);
            tailer
        };
        // The Claude Code hook monitor always runs (`startClaudeCodeMonitor`).
        if self.claude.is_none() {
            self.claude = Some(started(root.claude_hook_events_file()));
        }
        self.events = match &flags.events {
            Some(shared) => vec![started(shared.clone()), started(root.ai_events_log())],
            None => Vec::new(),
        };
        log::info!(
            "AI event monitor: {}{}",
            match &flags.events {
                Some(path) => format!("on, {}", path.display()),
                None => "off".into(),
            },
            if restart { " (restarted)" } else { "" }
        );
    }

    fn poll(&mut self, tick: u64) -> Batch {
        let mut batch = Batch::default();
        if let Some(claude) = self.claude.as_mut() {
            batch.claude = claude.poll();
        }
        if tick.is_multiple_of(2) {
            for tailer in &mut self.events {
                batch.events.extend(tailer.poll());
            }
        }
        batch
    }
}

fn flags(root: &DataRoot, cx: &App) -> Flags {
    let n = &Settings::get(cx).notifications;
    // `CHAU7_EVENTS_LOG` (legacy `AI_EVENTS_LOG`) beats the setting.
    let path = crate::logging::env_override(
        chau7_next_core::env_vars::EVENTS_LOG,
        Some(chau7_next_core::env_vars::LEGACY_EVENTS_LOG),
    )
    .unwrap_or_else(|| n.ai_events_log_path.clone());
    Flags {
        events: n
            .monitor_ai_events
            .then(|| history_monitor::expand_home(&path, root.home())),
    }
}

/// "Restart Monitor" (Settings > Notifications): the event log tailers are
/// rebuilt on the next poll. Registered with
/// `notifications::set_restart_monitor_hook`.
pub fn restart_event_monitor(cx: &mut App) {
    if let Some(hub) = cx.try_global::<AiHub>()
        && !hub.restart_requested
    {
        cx.global_mut::<AiHub>().restart_requested = true;
    }
}

/// Starts the monitors (`AppModel.bootstrap`).
pub fn init(cx: &mut App) {
    cx.set_global(AiHub::default());
    let root = cx.global::<AppData>().root.clone();
    cx.spawn(async move |cx| {
        let mut io = MonitorIo {
            flags: None,
            claude: None,
            events: Vec::new(),
        };
        let mut tick: u64 = 0;
        loop {
            let (current, restart) = cx.update(|cx| {
                let f = flags(&root, cx);
                MonitoringStatus::update_if_changed(cx, |s| {
                    s.events = f.events.is_some();
                });
                let restart = std::mem::take(&mut cx.global_mut::<AiHub>().restart_requested);
                (f, restart)
            });
            let root2 = root.clone();
            let (back, batch) = cx
                .background_executor()
                .spawn(async move {
                    io.configure(&root2, current, restart);
                    let batch = io.poll(tick);
                    (io, batch)
                })
                .await;
            io = back;
            cx.update(|cx| apply(batch, cx));
            tick = tick.wrapping_add(1);
            cx.background_executor()
                .timer(Duration::from_millis(250))
                .await;
        }
    })
    .detach();
}

fn apply(batch: Batch, cx: &mut App) {
    let now = now_secs();
    for line in batch.claude {
        match parse_event_line(&line, now) {
            Some(event) => handle_claude_event(event, cx),
            None => log::warn!(
                "Claude event parse failed: {}",
                line.chars().take(120).collect::<String>()
            ),
        }
    }
    for line in batch.events {
        match parse_line(&line) {
            Ok(event) => {
                // Our own start/finish lines only feed the timeline.
                let notify = event.source.raw_value() != AiEventSource::TERMINAL_SESSION;
                events_out::publish(event, notify, cx);
            }
            Err(err) => log::warn!(
                "AI event parse failed ({err}): {}",
                line.chars().take(120).collect::<String>()
            ),
        }
    }
    // Idle checks (`checkIdleSessions`, `checkIdle`).
    let idle = cx.global_mut::<AiHub>().claude.check_idle(now);
    for session in idle {
        log::info!(
            "Claude Code session idle: {} ({})",
            session.project_name,
            session.id.chars().take(8).collect::<String>()
        );
        cancel_claude_fallback(&session.id, cx);
        let mut event = AiEvent::new(
            AiEventSource::claude_code(),
            "idle",
            "Claude",
            format!("Waiting for input in {}", session.project_name),
            iso8601::now_iso8601(),
        );
        event.directory = Some(session.cwd.clone()).filter(|d| !d.is_empty());
        event.session_id = Some(session.id.clone());
        event.producer = Some("claude_code_idle".into());
        event.reliability = AiEventReliability::Authoritative;
        events_out::publish(event, true, cx);
    }
    // History idle monitor notices (`HistoryIdleMonitor` callbacks).
    for notice in history_monitor::take_notices(cx) {
        publish_history_notice(notice, cx);
    }
}

fn provider_key(tool: &str) -> String {
    resume_provider_key_for(tool)
        .map(str::to_string)
        .unwrap_or_else(|| tool.to_lowercase())
}

// ----- Claude Code hooks -----------------------------------------------------

fn handle_claude_event(event: ClaudeCodeEvent, cx: &mut App) {
    log::trace!(
        "Claude event: type={} session={} tool={}",
        event.event_type.as_str(),
        event.short_session_id(),
        event.tool_name
    );
    cancel_claude_fallback(&event.session_id, cx);
    cx.global_mut::<AiHub>().claude.handle_event(&event);
    // The agent runtime first, so a runtime session binds this Claude
    // session before the event is routed (RUN-013, RUN-023).
    crate::runtime::handle_claude_event(&event, cx);
    let mut ai = AiEvent::new(
        AiEventSource::claude_code(),
        event.event_type.as_str(),
        "Claude",
        event.message.clone(),
        iso8601::format_iso8601(
            chrono::DateTime::from_timestamp_millis((event.timestamp * 1000.0) as i64)
                .unwrap_or_else(chrono::Utc::now),
        ),
    );
    ai.raw_type = Some(event.event_type.as_str().to_string());
    ai.title = event.title.clone();
    ai.notification_type = event.notification_type.clone();
    ai.directory = Some(event.cwd.clone()).filter(|d| !d.is_empty());
    ai.session_id = Some(event.session_id.clone()).filter(|s| !s.is_empty());
    ai.tab_id = crate::runtime::notification_tab_for_claude_session(&event.session_id, cx);
    crate::remote::ingest_claude_event(&event, ai.tab_id.and_then(events_out::tab_from_uuid), cx);
    ai.producer = Some("claude_code_monitor".into());
    ai.reliability = AiEventReliability::Authoritative;
    events_out::publish(ai, true, cx);
    if event.event_type == EventType::ResponseComplete {
        log::info!("Claude Code response complete: {}", event.project_name());
        schedule_claude_fallback(event, cx);
    }
}

/// `scheduleClaudeWaitingInputFallback`: "waiting for input" 0.75 s after a
/// response completes, unless another event of the session arrives first.
fn schedule_claude_fallback(event: ClaudeCodeEvent, cx: &mut App) {
    let session = event.session_id.trim().to_string();
    if session.is_empty() {
        return;
    }
    let key = session.clone();
    let task = cx.spawn(async move |cx| {
        cx.background_executor()
            .timer(Duration::from_secs_f64(WAITING_INPUT_FALLBACK_DELAY))
            .await;
        cx.update(|cx| {
            cx.global_mut::<AiHub>().claude_fallbacks.remove(&session);
            let mut ai = AiEvent::new(
                AiEventSource::claude_code(),
                "waiting_input",
                "Claude",
                waiting_input_message(&event),
                iso8601::now_iso8601(),
            );
            ai.title = event.title.clone();
            ai.notification_type = Some("idle_prompt".into());
            ai.directory = Some(event.cwd.clone()).filter(|d| !d.is_empty());
            ai.session_id = Some(session.clone());
            ai.tab_id = crate::runtime::notification_tab_for_claude_session(&session, cx);
            ai.producer = Some("claude_response_complete_fallback".into());
            ai.reliability = AiEventReliability::Fallback;
            events_out::publish(ai, true, cx);
        });
    });
    cx.global_mut::<AiHub>().claude_fallbacks.insert(key, task);
}

fn cancel_claude_fallback(session: &str, cx: &mut App) {
    let session = session.trim();
    if !session.is_empty() {
        cx.global_mut::<AiHub>().claude_fallbacks.remove(session);
    }
}

// ----- history idle ----------------------------------------------------------

fn event_source(tool: &str) -> AiEventSource {
    event_source_raw_value_for(&tool.to_lowercase())
        .map(AiEventSource::new)
        .unwrap_or_else(AiEventSource::history_monitor)
}

fn history_directory(tool: &str, session: &str, cx: &mut App) -> Option<String> {
    let root = cx.global::<AppData>().root.clone();
    let hub = cx.global_mut::<AiHub>();
    let claude_cwd = hub.claude.sessions.get(session).map(|s| s.cwd.clone());
    let codex_cwd = (provider_key(tool) == "codex")
        .then(|| hub.codex.metadata(root.home(), session, None))
        .flatten()
        .map(|c| c.cwd);
    resolve_directory(
        tool,
        Some(session),
        |_| claude_cwd.clone().filter(|c| !c.is_empty()),
        |_| codex_cwd.clone(),
    )
}

/// An "idle" or "finished" notice of the history monitor as an AI event
/// (`handleIdleEvent`, `handleSessionFinished`).
fn publish_history_notice(notice: HistoryNotice, cx: &mut App) {
    let directory = notice
        .directory
        .clone()
        .or_else(|| history_directory(&notice.tool, &notice.session_id, cx));
    let event = history_notice_event(notice, directory);
    events_out::publish(event, true, cx);
}

/// The AI event of a history notice (pure part of [`publish_history_notice`]).
fn history_notice_event(notice: HistoryNotice, directory: Option<String>) -> AiEvent {
    let mut ai = AiEvent::new(
        event_source(&notice.tool),
        notice.kind,
        notice.tool.clone(),
        notice.message,
        iso8601::now_iso8601(),
    );
    ai.directory = directory;
    ai.session_id = Some(notice.session_id).filter(|s| !s.is_empty());
    ai.producer = Some("history_idle_monitor".into());
    ai.reliability = AiEventReliability::Fallback;
    ai
}

// ----- queries used by tabs and restore ---------------------------------------

/// Claude sessions seen by the hook monitor for a directory, best first:
/// (session id, last activity).
pub fn claude_session_candidates(directory: &str, cx: &App) -> Vec<(String, f64)> {
    cx.try_global::<AiHub>()
        .map(|hub| hub.claude.session_candidates(directory))
        .unwrap_or_default()
}

/// The Codex session of `directory` among the last 64 sessions seen in
/// Codex's history (`resolveResumeMetadata` fallback), skipping `claimed`.
pub fn codex_observed_session(
    directory: &str,
    reference: Option<f64>,
    claimed: &std::collections::HashSet<String>,
    cx: &App,
) -> Option<String> {
    let hub = cx.try_global::<AiHub>()?;
    let root = cx.global::<AppData>().root.clone();
    let entries = history_monitor::history_entries("codex", cx);
    let mut resolver = hub.codex.clone();
    let candidates: Vec<Candidate> = entries
        .iter()
        .rev()
        .take(64)
        .filter_map(|entry| {
            let meta = resolver.metadata(root.home(), &entry.session_id, Some(entry.timestamp))?;
            Some(Candidate {
                session_id: meta.session_id,
                cwd: meta.cwd,
                touched_at: entry.timestamp,
            })
        })
        .filter(|c| !claimed.contains(&c.session_id))
        .collect();
    best_matching_session_id(directory, reference, &candidates)
}

// ----- file conflicts --------------------------------------------------------

/// A command of `tab` finished and changed `files`: check every tab for
/// files changed by two of them (`ConflictDetector.checkForConflicts`).
/// `live` holds every open tab; closed tabs are forgotten.
pub fn record_changed_files(
    tab: TabId,
    files: Vec<String>,
    live: &std::collections::HashSet<TabId>,
    cx: &mut App,
) {
    let now = now_secs();
    let new = {
        let hub = cx.global_mut::<AiHub>();
        hub.finished_blocks.retain(|t, _| live.contains(t));
        let closed: Vec<TabId> = hub
            .conflicts
            .active()
            .iter()
            .flat_map(|c| c.tabs.iter().copied())
            .filter(|t| !live.contains(t))
            .collect();
        for t in closed {
            hub.conflicts.remove_tab(&t);
        }
        let blocks = hub.finished_blocks.entry(tab).or_default();
        blocks.push(FinishedBlock {
            end_time: now,
            changed_files: files,
        });
        let window = hub.conflicts.lookback_window;
        blocks.retain(|b| b.end_time > now - window);
        let all: Vec<(TabId, Vec<FinishedBlock>)> = hub
            .finished_blocks
            .iter()
            .map(|(t, b)| (*t, b.clone()))
            .collect();
        hub.conflicts.check(&all, now)
    };
    for conflict in new {
        let message = conflict_message(&conflict);
        for tab in &conflict.tabs {
            let mut event = AiEvent::new(
                AiEventSource::app(),
                "file_conflict",
                "Chau7",
                message.clone(),
                iso8601::now_iso8601(),
            );
            event.tab_id = Some(tab_uuid(*tab));
            events_out::publish(event, true, cx);
        }
    }
}

/// Files in conflict involving `tab`, sorted.
pub fn conflicts_for_tab(tab: TabId, cx: &App) -> Vec<String> {
    cx.try_global::<AiHub>()
        .map(|hub| {
            hub.conflicts
                .for_tab(&tab)
                .into_iter()
                .map(|c| c.file_path.clone())
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn provider_keys_and_sources() {
        assert_eq!(provider_key("Claude"), "claude");
        assert_eq!(provider_key("Codex"), "codex");
        assert_eq!(provider_key("Mystery"), "mystery");
        assert_eq!(event_source("Claude").raw_value(), "claude_code");
        assert_eq!(event_source("Unknown Tool").raw_value(), "history_monitor");
    }
}
