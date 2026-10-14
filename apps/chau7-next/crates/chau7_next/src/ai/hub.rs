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

use std::collections::{HashMap, VecDeque};
use std::path::PathBuf;
use std::time::{Duration, Instant};

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
use uuid::Uuid;

use super::events_out::{self, tab_uuid};
use crate::history::monitor::{self as history_monitor, HistoryNotice};
use crate::monitoring_status::MonitoringStatus;
use crate::settings::Settings;
use crate::tab_bar::TabId;
use crate::workspace::AppData;

const MAX_PENDING_CLAUDE_STARTS: usize = 64;
const MAX_CLAUDE_START_RETRIES: u8 = 20;
const CLAUDE_START_RETRY_TTL: Duration = Duration::from_secs(5);

/// State shared by the monitors.
#[derive(Default)]
pub struct AiHub {
    pub claude: ClaudeSessionTracker,
    codex_candidates: Vec<Candidate>,
    claude_fallbacks: HashMap<String, Task<()>>,
    pending_claude_starts: VecDeque<PendingClaudeStart>,
    seen_claude_starts: VecDeque<ClaudeStartKey>,
    conflicts: ConflictDetector<TabId>,
    finished_blocks: HashMap<TabId, Vec<FinishedBlock>>,
    /// "Restart Monitor" was clicked: rebuild the event log tailers.
    restart_requested: bool,
}

impl Global for AiHub {}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ClaudeStartKey {
    tab_identifier: Uuid,
    session_id: String,
}

struct PendingClaudeStart {
    key: ClaudeStartKey,
    cwd: String,
    timestamp: f64,
    started_at: Instant,
    attempts: u8,
}

impl PendingClaudeStart {
    fn retryable_at(&self, now: Instant) -> bool {
        self.attempts < MAX_CLAUDE_START_RETRIES
            && now.saturating_duration_since(self.started_at) < CLAUDE_START_RETRY_TTL
    }

    fn identity_event(&self) -> ClaudeCodeEvent {
        ClaudeCodeEvent {
            // SessionStart is not part of the event-parsing enum yet. Unknown
            // is safe here because identity adoption only treats UserPrompt
            // as permission to replace a prior session identity.
            event_type: EventType::Unknown,
            raw_type: "session_start".into(),
            tool_use_id: String::new(),
            tool_input_json: None,
            hook: "SessionStart".into(),
            session_id: self.key.session_id.clone(),
            transcript_path: String::new(),
            tool_name: String::new(),
            title: None,
            message: String::new(),
            notification_type: None,
            cwd: self.cwd.clone(),
            timestamp: self.timestamp,
        }
    }
}

impl AiHub {
    fn remember_claude_start(&mut self, key: ClaudeStartKey) -> bool {
        if self.seen_claude_starts.contains(&key) {
            return false;
        }
        if self.seen_claude_starts.len() == MAX_PENDING_CLAUDE_STARTS {
            self.seen_claude_starts.pop_front();
        }
        self.seen_claude_starts.push_back(key);
        true
    }
}

/// Event log monitor settings ("Monitor AI Events" and the log path in
/// Settings > Notifications).
#[derive(Debug, Clone, PartialEq)]
struct Flags {
    /// The shared AI events log to follow; `None` when monitoring is off.
    events: Option<PathBuf>,
}

/// The tailers, moved to a background thread for each poll.
#[derive(Default)]
struct MonitorIo {
    flags: Option<Flags>,
    claude: Vec<FileTailer>,
    events: Vec<FileTailer>,
    codex: CodexSessionResolver,
    codex_history: Vec<(String, f64)>,
    codex_candidates: Vec<Candidate>,
    codex_resolved_at: Option<Instant>,
}

/// What one poll read.
#[derive(Default)]
struct Batch {
    claude: Vec<ResolvedClaude>,
    events: Vec<String>,
    notices: Vec<HistoryNotice>,
    codex_candidates: Vec<Candidate>,
}

struct ResolvedClaude {
    event: ClaudeCodeEvent,
    transcript_owned: bool,
    next_tab_identifier: Option<Uuid>,
}
impl ResolvedClaude {
    fn from_line(line: &str, home: &std::path::Path, next_owned: bool) -> Option<Self> {
        let next_tab_identifier = if next_owned {
            serde_json::from_str::<serde_json::Value>(line)
                .ok()
                .and_then(|value| {
                    value
                        .get("tabID")
                        .and_then(serde_json::Value::as_str)
                        .and_then(|tab| Uuid::parse_str(tab).ok())
                })
        } else {
            None
        };
        let mut event = parse_event_line(line, now_secs())?;
        let transcript = (!event.transcript_path.trim().is_empty())
            .then(|| std::path::Path::new(event.transcript_path.trim()));
        let metadata = chau7_next_core::monitoring::claude_resolver::metadata(
            home,
            &event.session_id,
            transcript,
        );
        if event.cwd.trim().is_empty()
            && let Some(project) = metadata.and_then(|candidate| candidate.project_directory)
        {
            event.cwd = project;
        }
        let transcript_owned =
            chau7_next_core::monitoring::claude_resolver::has_restorable_transcript(
                home,
                &event.session_id,
                &event.cwd,
                transcript,
            );
        Some(Self {
            event,
            transcript_owned,
            next_tab_identifier,
        })
    }
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
        if self.claude.is_empty() || restart {
            self.claude = vec![
                started(root.claude_hook_events_file()),
                started(root.next_claude_hook_events_file()),
            ];
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

    fn poll(
        &mut self,
        tick: u64,
        home: &std::path::Path,
        history: Vec<(String, f64)>,
        mut notices: Vec<HistoryNotice>,
    ) -> Batch {
        // Resolve history metadata only on this existing background worker.
        // Missing rollouts can appear after their history record, so retry at
        // most every two seconds; positive entries use the bounded resolver.
        if self.codex_history != history
            || self
                .codex_resolved_at
                .is_none_or(|at| at.elapsed() >= Duration::from_secs(2))
        {
            self.codex_candidates = history
                .iter()
                .filter_map(|(id, timestamp)| {
                    let mut candidate = self.codex.metadata(home, id, Some(*timestamp))?;
                    candidate.touched_at = *timestamp;
                    Some(candidate)
                })
                .collect();
            self.codex_history = history;
            self.codex_resolved_at = Some(Instant::now());
        }
        for notice in &mut notices {
            if notice
                .directory
                .as_ref()
                .is_none_or(|directory| directory.trim().is_empty())
                && provider_key(&notice.tool) == "codex"
            {
                notice.directory = self
                    .codex
                    .metadata(home, &notice.session_id, Some(notice.timestamp))
                    .map(|candidate| candidate.cwd);
            }
        }
        let mut batch = Batch {
            notices,
            codex_candidates: self.codex_candidates.clone(),
            ..Batch::default()
        };
        for (index, claude) in self.claude.iter_mut().enumerate() {
            let next_owned = index == 1;
            for line in claude.poll() {
                if let Some(event) = ResolvedClaude::from_line(&line, home, next_owned) {
                    batch.claude.push(event);
                } else {
                    log::debug!("Ignoring malformed Claude hook record");
                }
            }
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
        let mut io = MonitorIo::default();
        let mut tick: u64 = 0;
        loop {
            let (current, restart, history, notices) = cx.update(|cx| {
                let f = flags(&root, cx);
                MonitoringStatus::update_if_changed(cx, |s| {
                    s.events = f.events.is_some();
                });
                let restart = std::mem::take(&mut cx.global_mut::<AiHub>().restart_requested);
                let history = history_monitor::history_entries("codex", cx)
                    .into_iter()
                    .rev()
                    .take(64)
                    .map(|entry| (entry.session_id, entry.timestamp))
                    .collect();
                (f, restart, history, history_monitor::take_notices(cx))
            });
            let root2 = root.clone();
            let (back, batch) = cx
                .background_executor()
                .spawn(async move {
                    io.configure(&root2, current, restart);
                    let batch = io.poll(tick, root2.home(), history, notices);
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
    retry_pending_claude_starts(cx);
    let now = now_secs();
    cx.global_mut::<AiHub>().codex_candidates = batch.codex_candidates;
    for record in batch.claude {
        handle_claude_event(
            record.event,
            record.transcript_owned,
            record.next_tab_identifier,
            cx,
        );
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
    for notice in batch.notices {
        publish_history_notice(notice, cx);
    }
}

fn provider_key(tool: &str) -> String {
    resume_provider_key_for(tool)
        .map(str::to_string)
        .unwrap_or_else(|| tool.to_lowercase())
}

// ----- Claude Code hooks -----------------------------------------------------

fn handle_claude_event(
    event: ClaudeCodeEvent,
    transcript_owned: bool,
    next_tab_identifier: Option<Uuid>,
    cx: &mut App,
) {
    log::trace!(
        "Claude event: type={} session={} tool={}",
        event.event_type.as_str(),
        event.short_session_id(),
        event.tool_name
    );
    cancel_claude_fallback(&event.session_id, cx);
    cx.global_mut::<AiHub>().claude.handle_event(&event);
    let retry_target = next_tab_identifier.filter(|_| {
        transcript_owned
            && event.raw_type == "session_start"
            && event.hook == "SessionStart"
            && chau7_next_core::ai::resume::is_valid_session_id(&event.session_id)
    });
    let seen_start = retry_target.map(|tab_identifier| {
        cx.global_mut::<AiHub>()
            .remember_claude_start(ClaudeStartKey {
                tab_identifier,
                session_id: event.session_id.trim().to_string(),
            })
    });
    let owned_tab = if let Some(tab_identifier) = retry_target {
        if claude_start_target_is_unique(&event, transcript_owned, tab_identifier, cx) {
            crate::terminal::session::adopt_claude_hook_identity(&event, transcript_owned, cx)
        } else {
            None
        }
    } else {
        crate::terminal::session::adopt_claude_hook_identity(&event, transcript_owned, cx)
    };
    if seen_start == Some(true)
        && owned_tab.is_none()
        && let Some(tab_identifier) = retry_target
    {
        let key = ClaudeStartKey {
            tab_identifier,
            session_id: event.session_id.trim().to_string(),
        };
        let hub = cx.global_mut::<AiHub>();
        if hub.pending_claude_starts.len() < MAX_PENDING_CLAUDE_STARTS
            && !hub
                .pending_claude_starts
                .iter()
                .any(|pending| pending.key == key)
        {
            hub.pending_claude_starts.push_back(PendingClaudeStart {
                key,
                cwd: event.cwd.clone(),
                timestamp: event.timestamp,
                started_at: Instant::now(),
                attempts: 0,
            });
        }
    }
    // The agent runtime first, so a runtime session binds this Claude
    // session before the event is routed (RUN-013, RUN-023).
    let known_runtime_tab =
        crate::runtime::notification_tab_for_claude_session(&event.session_id, cx);
    if owned_tab.is_some() || known_runtime_tab.is_some() {
        crate::runtime::handle_claude_event(&event, cx);
    }
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
    ai.tab_id = owned_tab
        .or_else(|| crate::runtime::notification_tab_for_claude_session(&event.session_id, cx));
    crate::remote::ingest_claude_event(&event, ai.tab_id.and_then(events_out::tab_from_uuid), cx);
    ai.producer = Some("claude_code_monitor".into());
    ai.reliability = AiEventReliability::Authoritative;
    events_out::publish(ai, true, cx);
    if event.event_type == EventType::ResponseComplete {
        log::info!("Claude Code response complete: {}", event.project_name());
        schedule_claude_fallback(event, cx);
    }
}

/// The standard adopter scans every pane. Before calling it for a deferred
/// Next SessionStart, prove its unique-owner selection would be this explicit
/// shell tab; otherwise a same-directory Claude pane could claim the event.
fn claude_start_target_is_unique(
    event: &ClaudeCodeEvent,
    transcript_owned: bool,
    target_tab_identifier: Uuid,
    cx: &mut App,
) -> bool {
    let Some(home) = cx
        .try_global::<AppData>()
        .map(|data| data.root.home().to_path_buf())
    else {
        return false;
    };
    let replace = event.event_type == EventType::UserPrompt;
    let mut exact_count = 0;
    let mut exact_is_target = false;
    let mut eligible_count = 0;
    let mut eligible_is_target = false;
    for window in crate::mcp::windows::windows(cx) {
        let workspace = window.workspace.read(cx);
        for uuid in workspace.mcp_tab_uuids() {
            let Some(tab) = workspace.mcp_find(uuid) else {
                continue;
            };
            let Some(panes) = workspace.mcp_panes(tab) else {
                continue;
            };
            for (_, entity) in panes.read(cx).pane_sessions(cx) {
                let session = entity.read(cx);
                let shell = session.shell();
                if !session.is_ai_running()
                    || session.exited.is_some()
                    || !shell.can_adopt_observed_ai_identity(
                        "claude",
                        &event.session_id,
                        event.timestamp,
                        replace,
                    )
                {
                    continue;
                }
                let cwd = shell.current_directory();
                let related = chau7_next_core::monitoring::claude_resolver::related_directory(
                    &home, &event.cwd, cwd,
                );
                if !related {
                    continue;
                }
                let is_target =
                    Uuid::parse_str(&session.tab_identifier).ok() == Some(target_tab_identifier);
                if shell.ai_session_id() == Some(event.session_id.trim()) {
                    exact_count += 1;
                    exact_is_target |= is_target;
                } else if transcript_owned {
                    eligible_count += 1;
                    eligible_is_target |= is_target;
                }
            }
        }
    }
    (exact_count == 1 && exact_is_target)
        || (exact_count == 0 && eligible_count == 1 && eligible_is_target)
}

fn retry_pending_claude_starts(cx: &mut App) {
    let pending = {
        let hub = cx.global_mut::<AiHub>();
        std::mem::take(&mut hub.pending_claude_starts)
    };
    let now = Instant::now();
    let mut remaining = VecDeque::new();
    for mut candidate in pending {
        if !candidate.retryable_at(now) {
            continue;
        }
        candidate.attempts += 1;
        let event = candidate.identity_event();
        let adopted = claude_start_target_is_unique(&event, true, candidate.key.tab_identifier, cx)
            && crate::terminal::session::adopt_claude_hook_identity(&event, true, cx).is_some();
        if !adopted && candidate.retryable_at(now) {
            remaining.push_back(candidate);
        }
    }
    cx.global_mut::<AiHub>().pending_claude_starts = remaining;
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
    let hub = cx.global::<AiHub>();
    let claude_cwd = hub.claude.sessions.get(session).map(|s| s.cwd.clone());
    let codex_cwd = (provider_key(tool) == "codex")
        .then(|| {
            hub.codex_candidates
                .iter()
                .find(|candidate| candidate.session_id == session)
        })
        .flatten()
        .map(|candidate| candidate.cwd.clone());
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
        chrono::DateTime::from_timestamp_millis((notice.timestamp * 1000.0) as i64)
            .map(iso8601::format_iso8601)
            .unwrap_or_else(iso8601::now_iso8601),
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
    // Already resolved by MonitorIo; this capture/query path never opens
    // provider files or clones and discards the resolver's cache.
    let candidates: Vec<Candidate> = hub
        .codex_candidates
        .iter()
        .filter(|candidate| !claimed.contains(&candidate.session_id))
        .cloned()
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

    #[test]
    fn claude_start_seen_keys_dedupe_by_tab_and_remain_bounded() {
        let mut hub = AiHub::default();
        let first = ClaudeStartKey {
            tab_identifier: Uuid::from_u128(1),
            session_id: "session-1".into(),
        };
        assert!(hub.remember_claude_start(first.clone()));
        assert!(!hub.remember_claude_start(first.clone()));
        assert!(hub.remember_claude_start(ClaudeStartKey {
            tab_identifier: Uuid::from_u128(2),
            session_id: "session-1".into(),
        }));

        let mut newest = first.clone();
        for tab in 3..=(MAX_PENDING_CLAUDE_STARTS as u128 + 2) {
            newest = ClaudeStartKey {
                tab_identifier: Uuid::from_u128(tab),
                session_id: format!("session-{tab}"),
            };
            assert!(hub.remember_claude_start(newest.clone()));
        }
        assert_eq!(hub.seen_claude_starts.len(), MAX_PENDING_CLAUDE_STARTS);
        assert!(!hub.remember_claude_start(newest));
        // The bounded FIFO forgets the oldest key rather than growing without limit.
        assert!(hub.remember_claude_start(first));
        assert_eq!(hub.seen_claude_starts.len(), MAX_PENDING_CLAUDE_STARTS);
    }

    #[test]
    fn pending_claude_start_retry_stops_at_ttl_or_attempt_limit() {
        let started_at = Instant::now();
        let mut pending = PendingClaudeStart {
            key: ClaudeStartKey {
                tab_identifier: Uuid::from_u128(1),
                session_id: "session-1".into(),
            },
            cwd: "/owned-repo".into(),
            timestamp: 1.0,
            started_at,
            attempts: 0,
        };
        assert!(pending.retryable_at(started_at));
        assert!(
            pending.retryable_at(started_at + CLAUDE_START_RETRY_TTL - Duration::from_millis(1))
        );
        assert!(!pending.retryable_at(started_at + CLAUDE_START_RETRY_TTL));

        pending.attempts = MAX_CLAUDE_START_RETRIES - 1;
        assert!(pending.retryable_at(started_at));
        pending.attempts = MAX_CLAUDE_START_RETRIES;
        assert!(!pending.retryable_at(started_at));
    }

    #[test]
    fn hook_resolution_runs_readonly_against_isolated_stores_and_rejects_foreign_root() {
        let home =
            std::env::temp_dir().join(format!("chau7-next-hook-resolver-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(home.join(".claude/projects")).unwrap();
        let transcript = home.join("s1.jsonl");
        std::fs::write(&transcript, b"{}\n").unwrap();
        std::fs::write(
            home.join(".claude/history.jsonl"),
            serde_json::json!({"sessionId":"s1","project":"/owned-repo","timestamp":1}).to_string(),
        )
        .unwrap();
        let line = serde_json::json!({"type":"user_prompt","sessionId":"s1","cwd":"", "transcriptPath":transcript,"timestamp":1}).to_string();
        let resolved = ResolvedClaude::from_line(&line, &home, false).unwrap();
        assert_eq!(resolved.event.cwd, "/owned-repo");
        assert!(resolved.transcript_owned);
        let foreign = serde_json::json!({"type":"permission_request","sessionId":"s1","cwd":"/other-repo", "transcriptPath":transcript,"timestamp":2}).to_string();
        assert!(
            !ResolvedClaude::from_line(&foreign, &home, false)
                .unwrap()
                .transcript_owned
        );
        assert!(ResolvedClaude::from_line("invalid-json", &home, false).is_none());
        std::fs::remove_dir_all(home).unwrap();
    }
    #[test]
    fn codex_background_cache_retries_missing_rollout_and_enriches_notice() {
        let home =
            std::env::temp_dir().join(format!("chau7-next-codex-hub-{}", uuid::Uuid::new_v4()));
        let day = home.join(".codex/sessions/2026/01/01");
        std::fs::create_dir_all(&day).unwrap();
        let history = vec![("s1".to_string(), 123.0)];
        let mut io = MonitorIo::default();
        assert!(
            io.poll(1, &home, history.clone(), vec![])
                .codex_candidates
                .is_empty()
        );
        std::fs::write(
            day.join("rollout-s1.jsonl"),
            serde_json::json!({"type":"session_meta","payload":{"id":"s1","cwd":"/owned-repo"}})
                .to_string(),
        )
        .unwrap();
        // An unchanged history does not rescan every UI refresh.
        assert!(
            io.poll(1, &home, history.clone(), vec![])
                .codex_candidates
                .is_empty()
        );
        io.codex_resolved_at = Instant::now().checked_sub(Duration::from_secs(3));
        let notice = HistoryNotice {
            kind: "finished",
            tool: "Codex".into(),
            session_id: "s1".into(),
            message: "finished".into(),
            directory: None,
            timestamp: 123.0,
        };
        let batch = io.poll(1, &home, history.clone(), vec![notice]);
        assert_eq!(batch.codex_candidates[0].cwd, "/owned-repo");
        assert_eq!(batch.codex_candidates[0].touched_at, 123.0);
        assert_eq!(batch.notices[0].directory.as_deref(), Some("/owned-repo"));
        let event =
            history_notice_event(batch.notices[0].clone(), batch.notices[0].directory.clone());
        assert_eq!(iso8601::parse_iso8601(&event.ts).unwrap().timestamp(), 123);
        std::fs::remove_dir_all(&home).unwrap();
        // Queries consume an immutable measured snapshot even after files vanish.
        assert_eq!(
            io.poll(1, &home, history, vec![]).codex_candidates[0].session_id,
            "s1"
        );
    }
}
