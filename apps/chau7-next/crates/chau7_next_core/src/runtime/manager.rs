//! Port of `Runtime/RuntimeSessionManager.swift`: the registry of runtime
//! sessions, fed by Claude Code hook events.
//!
//! What the manager needs from the app (send text to a tab, read a tab's
//! output, find a tab by directory, check a tab still exists, post a
//! notification) goes through [`RuntimeHost`], so the logic runs and is
//! tested without a window. Never call the host while holding the
//! registry lock: the app side may run on another thread.

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard};

use chrono::{DateTime, Duration, Utc};

use super::agent_backend::{AgentBackend, SessionConfig};
use super::backends::ClaudeCodeBackend;
use super::exit_classifier::TurnExitReason;
use super::runtime_event::RuntimeEventType;
use super::session::RuntimeSession;
use super::session_state::{State, Trigger};
use super::transcript_reader::IncrementalTranscriptReader;
use crate::command_detection::event_parsing::EventType;
use crate::monitoring::claude_code::ClaudeCodeEvent;

/// How long stopped sessions stay queryable (`stoppedRetentionSeconds`).
pub const STOPPED_RETENTION_SECONDS: i64 = 600;
/// The cleanup period (`startCleanupTimer`).
pub const CLEANUP_INTERVAL_SECONDS: u64 = 30;
/// `turn_completed` above this many tokens posts `token_threshold`.
pub const TOKEN_THRESHOLD: i64 = 100_000;
/// `output_chunk` keeps this many characters.
pub const OUTPUT_CHUNK_CHARS: usize = 4096;
/// Lines of tab output captured when a turn completes.
pub const CAPTURE_LINES: usize = 50;
/// Tools that edit files (`file_edited` notification).
pub const EDIT_TOOLS: [&str; 4] = ["Write", "Edit", "NotebookEdit", "Bash"];

/// A notification the runtime posts (`emitNotification`: an `AIEvent` with
/// source `runtime`, producer `runtime_session_manager`, authoritative).
#[derive(Debug, Clone, PartialEq)]
pub struct RuntimeNotification {
    pub event_type: String,
    /// The backend name (`claude`, `codex`, `shell`).
    pub tool: String,
    pub message: String,
    pub directory: String,
    pub tab_id: String,
    /// The Claude session id when bound, else the runtime session id.
    pub session_id: String,
}

/// What the manager asks of the app.
pub trait RuntimeHost {
    /// Type text into the tab (`TerminalControlService.sendInput`).
    fn send_input(&mut self, tab_id: &str, input: &str);
    /// The last `lines` lines of the tab's terminal text.
    fn tab_output(&mut self, tab_id: &str, lines: usize) -> Option<String>;
    /// The first tab whose working directory is `cwd` (`resolveTabByCwd`).
    fn tab_for_cwd(&mut self, cwd: &str) -> Option<String>;
    /// Provider/session identity for the visible AI process, when available.
    fn live_ai_identity(&mut self, _tab_id: &str) -> Option<(String, Option<String>)> {
        None
    }
    /// Resolve a matching Claude session or an unbound Claude tab, never an unrelated provider.
    fn tab_for_claude_event(&mut self, cwd: &str, _session_id: Option<&str>) -> Option<String> {
        self.tab_for_cwd(cwd)
    }
    /// Whether the tab is still open.
    fn tab_exists(&mut self, tab_id: &str) -> bool;
    fn notify(&mut self, notification: RuntimeNotification);
}

#[derive(Default)]
struct Maps {
    sessions: HashMap<String, Arc<RuntimeSession>>,
    tab_to_session: HashMap<String, String>,
    cwd_to_sessions: HashMap<String, HashSet<String>>,
    claude_to_runtime: HashMap<String, String>,
    runtime_to_claude: HashMap<String, String>,
    recently_stopped: HashMap<String, (Arc<RuntimeSession>, DateTime<Utc>)>,
    transcript_readers: HashMap<String, IncrementalTranscriptReader>,
    failed_adoptions: HashMap<String, DateTime<Utc>>,
    orphan_tracking: HashMap<String, (DateTime<Utc>, u32, bool)>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OrphanLogDecision {
    Log,
    SuppressionMarker,
    Suppress,
}

/// The registry (`RuntimeSessionManager.shared`).
pub struct RuntimeSessionManager {
    maps: Mutex<Maps>,
    /// `~/.claude/projects`, for token usage; `None` disables it.
    claude_projects_dir: Option<PathBuf>,
}

fn normalize_claude_id(id: &str) -> Option<String> {
    let trimmed = id.trim();
    (!trimmed.is_empty()).then(|| trimmed.to_string())
}

/// `extractFilePath`: the message's first word when it starts with `/`.
pub fn extract_file_path(message: &str) -> Option<String> {
    if !message.starts_with('/') {
        return None;
    }
    message.split([' ', '\t']).next().map(str::to_string)
}

fn one(key: &str, value: impl Into<String>) -> HashMap<String, String> {
    HashMap::from([(key.to_string(), value.into())])
}

impl RuntimeSessionManager {
    pub fn new(claude_projects_dir: Option<PathBuf>) -> Self {
        Self {
            maps: Mutex::new(Maps::default()),
            claude_projects_dir,
        }
    }

    fn lock(&self) -> MutexGuard<'_, Maps> {
        self.maps.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn register(&self, session: &Arc<RuntimeSession>) {
        let mut maps = self.lock();
        maps.sessions.insert(session.id.clone(), session.clone());
        maps.tab_to_session
            .insert(session.tab_id.clone(), session.id.clone());
        maps.cwd_to_sessions
            .entry(session.config.directory.clone())
            .or_default()
            .insert(session.id.clone());
    }

    /// A new session in `starting` (the caller opens the tab).
    pub fn create_session(
        &self,
        tab_id: &str,
        backend: Box<dyn AgentBackend>,
        config: SessionConfig,
        auto_approve: bool,
    ) -> Arc<RuntimeSession> {
        let session = Arc::new(RuntimeSession::new(
            tab_id,
            backend,
            config,
            auto_approve,
            false,
        ));
        self.register(&session);
        session.record(
            None,
            RuntimeEventType::SESSION_STARTING.raw_value(),
            HashMap::new(),
        );
        log::info!(
            "RuntimeSessionManager: created session {} tab={tab_id} backend={}",
            session.id,
            session.backend.name()
        );
        session
    }

    /// Adopt an existing tab as a passive session, ready at once.
    pub fn adopt_session(
        &self,
        tab_id: &str,
        backend: Box<dyn AgentBackend>,
        cwd: &str,
    ) -> Arc<RuntimeSession> {
        let config = SessionConfig::new(cwd, backend.name());
        self.adopt_session_with_config(tab_id, backend, config)
    }

    pub fn adopt_session_with_config(
        &self,
        tab_id: &str,
        backend: Box<dyn AgentBackend>,
        config: SessionConfig,
    ) -> Arc<RuntimeSession> {
        if let Some(existing) = self.session_for_tab(tab_id) {
            return existing;
        }
        let auto_approve = config.auto_approve;
        let session = Arc::new(RuntimeSession::new(
            tab_id,
            backend,
            config,
            auto_approve,
            true,
        ));
        session.transition(Trigger::BackendReady);
        self.register(&session);
        session.record(
            None,
            RuntimeEventType::SESSION_READY.raw_value(),
            one("adopted", "true"),
        );
        log::info!(
            "RuntimeSessionManager: adopted session {} tab={tab_id}",
            session.id
        );
        session
    }

    /// An active or recently stopped session.
    pub fn session(&self, id: &str) -> Option<Arc<RuntimeSession>> {
        let maps = self.lock();
        maps.sessions
            .get(id)
            .or_else(|| maps.recently_stopped.get(id).map(|(s, _)| s))
            .cloned()
    }

    /// The active session in a tab.
    pub fn session_for_tab(&self, tab_id: &str) -> Option<Arc<RuntimeSession>> {
        let maps = self.lock();
        let id = maps.tab_to_session.get(tab_id)?;
        maps.sessions.get(id).cloned()
    }

    /// The session bound to a Claude Code session id.
    pub fn session_for_claude_session_id(&self, claude_id: &str) -> Option<Arc<RuntimeSession>> {
        let claude_id = normalize_claude_id(claude_id)?;
        let maps = self.lock();
        let id = maps.claude_to_runtime.get(&claude_id)?;
        maps.sessions
            .get(id)
            .or_else(|| maps.recently_stopped.get(id).map(|(s, _)| s))
            .cloned()
    }

    /// Active sessions (plus recently stopped ones), oldest first.
    pub fn all_sessions(&self, include_stopped: bool) -> Vec<Arc<RuntimeSession>> {
        let maps = self.lock();
        let mut out: Vec<_> = maps.sessions.values().cloned().collect();
        if include_stopped {
            out.extend(maps.recently_stopped.values().map(|(s, _)| s.clone()));
        }
        out.sort_by(|a, b| a.created_at.cmp(&b.created_at).then(a.id.cmp(&b.id)));
        out
    }

    pub fn child_sessions(&self, parent: &str, include_stopped: bool) -> Vec<Arc<RuntimeSession>> {
        self.all_sessions(include_stopped)
            .into_iter()
            .filter(|session| session.config.parent_session_id.as_deref() == Some(parent))
            .collect()
    }
    pub fn descendant_sessions(
        &self,
        parent: &str,
        include_stopped: bool,
    ) -> Vec<Arc<RuntimeSession>> {
        let all = self.all_sessions(include_stopped);
        let mut seen = HashSet::from([parent.to_string()]);
        let mut out = Vec::new();
        let mut frontier = vec![parent.to_string()];
        while let Some(parent) = frontier.pop() {
            for session in &all {
                if session.config.parent_session_id.as_deref() == Some(&parent)
                    && seen.insert(session.id.clone())
                {
                    frontier.push(session.id.clone());
                    out.push(session.clone());
                }
            }
        }
        out.sort_by(|a, b| a.created_at.cmp(&b.created_at).then(a.id.cmp(&b.id)));
        out
    }

    /// Whether a tab hosts an active runtime session.
    pub fn is_runtime_managed(&self, tab_id: &str) -> bool {
        self.lock().tab_to_session.contains_key(tab_id)
    }

    /// The tab ids hosting active sessions.
    pub fn managed_tabs(&self) -> HashSet<String> {
        self.lock().tab_to_session.keys().cloned().collect()
    }

    /// The backend was launched: `ready` plus `session_ready`.
    pub fn mark_ready(&self, session_id: &str) {
        let Some(session) = self.lock().sessions.get(session_id).cloned() else {
            return;
        };
        session.transition(Trigger::BackendReady);
        session.record(
            None,
            RuntimeEventType::SESSION_READY.raw_value(),
            HashMap::new(),
        );
    }

    /// Stop an active session: `session_stopped`, `stopped`, kept for
    /// queries. `false` when it is not active.
    pub fn stop_session(&self, id: &str) -> bool {
        let Some(session) = self.lock().sessions.get(id).cloned() else {
            return false;
        };
        session.record(
            None,
            RuntimeEventType::SESSION_STOPPED.raw_value(),
            HashMap::new(),
        );
        session.transition(Trigger::TabClosed);
        self.move_to_stopped(&session, Utc::now());
        true
    }

    fn move_to_stopped(&self, session: &Arc<RuntimeSession>, now: DateTime<Utc>) {
        let mut maps = self.lock();
        maps.transcript_readers.remove(&session.id);
        maps.sessions.remove(&session.id);
        maps.tab_to_session.remove(&session.tab_id);
        let dir = &session.config.directory;
        if let Some(ids) = maps.cwd_to_sessions.get_mut(dir) {
            ids.remove(&session.id);
            if ids.is_empty() {
                maps.cwd_to_sessions.remove(dir);
            }
        }
        if let Some(claude) = maps.runtime_to_claude.remove(&session.id) {
            maps.claude_to_runtime.remove(&claude);
        }
        maps.recently_stopped
            .insert(session.id.clone(), (session.clone(), now));
        drop(maps);
        log::info!("RuntimeSessionManager: session {} stopped", session.id);
    }

    /// The periodic check: drop stopped sessions older than 10 minutes and
    /// stop sessions whose tab is gone (`reason: tab_closed`).
    pub fn cleanup(&self, now: DateTime<Utc>, host: &mut dyn RuntimeHost) {
        let active: Vec<Arc<RuntimeSession>> = {
            let mut maps = self.lock();
            let limit = Duration::seconds(STOPPED_RETENTION_SECONDS);
            maps.recently_stopped
                .retain(|_, (_, stopped)| now - *stopped < limit);
            maps.sessions.values().cloned().collect()
        };
        for session in active {
            if session.is_terminal() || host.tab_exists(&session.tab_id) {
                continue;
            }
            session.record(
                None,
                RuntimeEventType::SESSION_STOPPED.raw_value(),
                one("reason", "tab_closed"),
            );
            session.transition(Trigger::TabClosed);
            self.move_to_stopped(&session, now);
        }
    }

    /// Terminal/history evidence can settle an interactive backend without
    /// a Claude hook, after actual activity has been observed for this turn.
    pub fn reconcile_settled_turn(
        &self,
        id: &str,
        source: &str,
        host: &mut dyn RuntimeHost,
    ) -> bool {
        let Some(session) = self.session(id) else {
            return false;
        };
        if session.state() != State::Busy
            || !session.has_observed_turn_activity()
            || session.current_turn_id().is_none()
        {
            return false;
        }
        let output = host.tab_output(&session.tab_id, CAPTURE_LINES);
        session.complete_turn(None, output.as_deref());
        session.record(
            session.last_completed_turn_id().as_deref(),
            "turn_reconciled",
            one("source", source),
        );
        true
    }

    /// Structured Codex lifecycle records, already bound to a visible tab/native thread.
    pub fn handle_codex_record(
        &self,
        tab: &str,
        native: &str,
        cwd: &str,
        record: &super::codex_feedback::Record,
        host: &mut dyn RuntimeHost,
    ) -> Option<Arc<RuntimeSession>> {
        use super::codex_feedback::Record;
        let mut session = self.session_for_tab(tab);
        if session
            .as_ref()
            .is_some_and(|s| s.backend.name() != "codex")
        {
            return None;
        }
        if session
            .as_ref()
            .and_then(|s| s.native_session_id())
            .is_some_and(|id| !id.eq_ignore_ascii_case(native))
            && let Some(previous) = session.take()
        {
            previous.transition(Trigger::TabClosed);
            self.move_to_stopped(&previous, Utc::now());
        }
        let session = session.or_else(|| {
            matches!(record, Record::Started(_) | Record::Prompt(_))
                .then(|| self.adopt_session(tab, Box::new(super::backends::CodexBackend), cwd))
        })?;
        session.bind_native_session_id(native);
        if session.state() == State::Starting {
            self.mark_ready(&session.id);
        }
        match record {
            Record::Started(prompt)
            | Record::Prompt(super::codex_feedback::Prompt {
                message: prompt, ..
            }) => {
                if session.can_accept_turn() {
                    session.start_turn(prompt);
                }
                session.mark_turn_activity();
                if let Record::Prompt(prompt) = record {
                    if session.state() != State::AwaitingApproval {
                        session.transition(Trigger::InputRequested);
                    }
                    let mut data = one("call_id", &prompt.call_id);
                    data.insert("message".into(), prompt.message.clone());
                    data.insert("options".into(), prompt.options.join(", "));
                    session.record(
                        session.current_turn_id().as_deref(),
                        "input_requested",
                        data,
                    );
                }
            }
            Record::Usage {
                input,
                output,
                cached,
                reasoning,
            } if session.current_turn_id().is_some() => {
                session.add_token_usage(crate::telemetry::token_metrics::TokenUsage::provider(
                    "codex",
                    Some(*input),
                    Some(*output),
                    Some(0),
                    Some(*cached),
                    Some(*reasoning),
                ));
            }
            Record::TurnCompleted(summary)
                if session.current_turn_id().is_some() && session.state() == State::Busy =>
            {
                session.mark_turn_activity();
                let output = host.tab_output(tab, CAPTURE_LINES);
                session.complete_turn(summary.as_deref(), output.as_deref());
            }
            _ => (),
        }
        Some(session)
    }
    pub fn resolve_codex_input(&self, tab: &str, has_other_pending: bool) {
        if !has_other_pending
            && let Some(session) = self.session_for_tab(tab)
            && session.backend.name() == "codex"
            && session.state() == State::WaitingInput
        {
            session.transition(Trigger::InputProvided);
        }
    }

    // ----- Claude Code hook events -------------------------------------------

    /// Drive sessions from a Claude Code hook event (`handleClaudeEvent`);
    /// unknown Claude sessions are adopted by matching their cwd to a tab.
    pub fn handle_claude_event(&self, event: &ClaudeCodeEvent, host: &mut dyn RuntimeHost) {
        let mut session = self.resolve_session(event);
        if session.is_none() && !event.cwd.is_empty() {
            session = self.try_adopt(event, host);
        }
        let Some(session) = session else {
            return;
        };
        if host
            .live_ai_identity(&session.tab_id)
            .is_some_and(|(provider, _)| !provider.eq_ignore_ascii_case("claude"))
        {
            session.transition(Trigger::TabClosed);
            self.move_to_stopped(&session, Utc::now());
            return;
        }
        let start_turn_if_idle = |s: &RuntimeSession| {
            if s.current_turn_id().is_none() && s.can_accept_turn() {
                s.start_turn(&event.message);
            }
        };
        let turn_active = |s: &RuntimeSession| {
            s.current_turn_id().is_some()
                || matches!(s.state(), State::Busy | State::AwaitingApproval)
        };
        match event.event_type {
            EventType::ToolStart => {
                start_turn_if_idle(&session);
                session.mark_turn_activity();
                let file = extract_file_path(&event.message);
                session.record_tool_use(&event.tool_name, file.as_deref());
                session.record(
                    session.current_turn_id().as_deref(),
                    RuntimeEventType::TOOL_USE.raw_value(),
                    one("tool", event.tool_name.clone()),
                );
                self.emit(&session, "tool_called", &event.tool_name, host);
                if EDIT_TOOLS.contains(&event.tool_name.as_str()) {
                    let message = file.unwrap_or_else(|| event.tool_name.clone());
                    self.emit(&session, "file_edited", &message, host);
                }
            }
            EventType::ToolComplete => {
                session.record(
                    session.current_turn_id().as_deref(),
                    RuntimeEventType::TOOL_RESULT.raw_value(),
                    one("tool", event.tool_name.clone()),
                );
            }
            EventType::PermissionRequest => {
                start_turn_if_idle(&session);
                if turn_active(&session) {
                    let owns_notifications = session.backend.name().eq_ignore_ascii_case("claude");
                    if let Some(reason) = session.config.policy.validate_tool(&event.tool_name) {
                        host.send_input(&session.tab_id, "n\n");
                        session.record_policy_block(&event.tool_name, &reason);
                        if !owns_notifications {
                            self.emit(&session, "policy_blocked", &reason, host);
                        }
                    } else if session.auto_approve {
                        // Layer 2: answer what the CLI flag (layer 1) let through.
                        host.send_input(&session.tab_id, "y\n");
                        log::info!(
                            "Auto-approved permission for session {}: {} - {}",
                            session.id,
                            event.tool_name,
                            event.message
                        );
                        if !owns_notifications {
                            self.emit(&session, "permission_auto_approved", &event.message, host);
                        }
                    } else {
                        session.request_approval(&event.tool_name, &event.message);
                        if !owns_notifications {
                            self.emit(&session, "permission", &event.message, host);
                        }
                    }
                }
            }
            EventType::ResponseComplete => {
                if turn_active(&session) {
                    self.read_transcript_tokens(&session, event);
                    let output = host.tab_output(&session.tab_id, CAPTURE_LINES);
                    let turn = session.current_turn_id();
                    let result = session.complete_turn(Some(&event.message), output.as_deref());
                    if let Some(output) = output.filter(|o| !o.is_empty()) {
                        let chunk: String = output.chars().take(OUTPUT_CHUNK_CHARS).collect();
                        session.record(
                            turn.as_deref(),
                            RuntimeEventType::OUTPUT_CHUNK.raw_value(),
                            one("output", chunk),
                        );
                    }
                    // Claude posts its own "waiting for input" (Notification hook).
                    if !session.backend.name().eq_ignore_ascii_case("claude") {
                        let message = if event.message.is_empty() {
                            format!("{} is waiting for your input.", session.backend.name())
                        } else {
                            event.message.clone()
                        };
                        self.emit(&session, "waiting_input", &message, host);
                    }
                    let total = result.stats.total_tokens();
                    if total > TOKEN_THRESHOLD {
                        let message = format!("Turn used {total} tokens");
                        self.emit(&session, "token_threshold", &message, host);
                    }
                    if result.exit_reason != TurnExitReason::Success {
                        let kind = if result.exit_reason == TurnExitReason::ContextLimit {
                            "context_limit"
                        } else {
                            "failed"
                        };
                        let message = format!("Exit: {}", result.exit_reason.raw_value());
                        self.emit(&session, kind, &message, host);
                    }
                }
            }
            EventType::SessionEnd => {
                session.transition(Trigger::TabClosed);
                self.move_to_stopped(&session, Utc::now());
            }
            EventType::UserPrompt => {
                start_turn_if_idle(&session);
                session.mark_turn_activity();
                session.record(
                    session.current_turn_id().as_deref(),
                    RuntimeEventType::AGENT_RESPONDING.raw_value(),
                    one("message", event.message.clone()),
                );
            }
            EventType::Notification => {
                session.record(
                    session.current_turn_id().as_deref(),
                    RuntimeEventType::NOTIFICATION.raw_value(),
                    one("message", event.message.clone()),
                );
            }
            EventType::Unknown => {
                log::debug!(
                    "RuntimeSessionManager: unhandled event type={} session={}",
                    event.event_type.as_str(),
                    session.id
                );
            }
        }
    }

    fn emit(
        &self,
        session: &RuntimeSession,
        event_type: &str,
        message: &str,
        host: &mut dyn RuntimeHost,
    ) {
        let external = self.lock().runtime_to_claude.get(&session.id).cloned();
        host.notify(RuntimeNotification {
            event_type: event_type.to_string(),
            tool: session.backend.name().to_string(),
            message: message.to_string(),
            directory: session.config.directory.clone(),
            tab_id: session.tab_id.clone(),
            session_id: external.unwrap_or_else(|| session.id.clone()),
        });
    }

    /// `resolveSession(for:)`: the bound session, else a Claude session in
    /// the event's directory (preferring one with an active turn, then the
    /// most recent turn), which gets bound to the Claude session id.
    fn resolve_session(&self, event: &ClaudeCodeEvent) -> Option<Arc<RuntimeSession>> {
        let claude_id = normalize_claude_id(&event.session_id);
        let (candidates, bindings) = {
            let maps = self.lock();
            if let Some(id) = &claude_id
                && let Some(runtime) = maps.claude_to_runtime.get(id)
                && let Some(session) = maps.sessions.get(runtime)
            {
                return Some(session.clone());
            }
            let candidates: Vec<Arc<RuntimeSession>> = maps
                .cwd_to_sessions
                .get(&event.cwd)
                .map(|ids| {
                    ids.iter()
                        .filter_map(|id| maps.sessions.get(id).cloned())
                        .collect()
                })
                .unwrap_or_default();
            (candidates, maps.runtime_to_claude.clone())
        };
        let claude: Vec<_> = candidates
            .into_iter()
            .filter(|s| s.backend.name() == "claude")
            .collect();
        if claude.is_empty() {
            return None;
        }
        let eligible: Vec<_> = claude
            .iter()
            .filter(|s| match (&claude_id, bindings.get(&s.id)) {
                (None, _) | (_, None) => true,
                (Some(id), Some(bound)) => bound == id,
            })
            .cloned()
            .collect();
        // A different native session in the same directory cannot steal a bound runtime.
        let chosen = choose_candidate(eligible)?;
        if let Some(id) = claude_id {
            self.associate(&id, &chosen.id);
        }
        Some(chosen)
    }

    fn associate(&self, claude_id: &str, runtime_id: &str) {
        let mut maps = self.lock();
        if let Some(previous) = maps.runtime_to_claude.get(runtime_id).cloned()
            && previous != claude_id
        {
            maps.claude_to_runtime.remove(&previous);
        }
        maps.claude_to_runtime
            .insert(claude_id.to_string(), runtime_id.to_string());
        maps.runtime_to_claude
            .insert(runtime_id.to_string(), claude_id.to_string());
    }

    fn try_adopt(
        &self,
        event: &ClaudeCodeEvent,
        host: &mut dyn RuntimeHost,
    ) -> Option<Arc<RuntimeSession>> {
        let id = normalize_claude_id(&event.session_id);
        let key = id.clone().unwrap_or_else(|| format!("cwd:{}", event.cwd));
        let now = Utc::now();
        if self.should_skip_adoption(&key, now) {
            return None;
        }
        let Some(tab) = host.tab_for_claude_event(&event.cwd, id.as_deref()) else {
            self.record_adoption_failure(&key, now);
            match self.orphan_log_decision(&key, now) {
                OrphanLogDecision::Log => log::debug!("No live Claude tab for runtime adoption"),
                OrphanLogDecision::SuppressionMarker => {
                    log::debug!("Suppressing repeated orphan runtime adoption diagnostics")
                }
                OrphanLogDecision::Suppress => (),
            }
            return None;
        };
        let session = self.adopt_session(&tab, Box::new(ClaudeCodeBackend), &event.cwd);
        if session.backend.name() != "claude" {
            self.record_adoption_failure(&key, now);
            return None;
        }
        if let Some(id) = id {
            self.associate(&id, &session.id);
        }
        log::info!(
            "RuntimeSessionManager: auto-adopted session {} for cwd={}",
            session.id,
            event.cwd
        );
        Some(session)
    }

    /// Failed lookup retries after 3 seconds; a later new tab is never permanently excluded.
    pub fn should_skip_adoption(&self, key: &str, now: DateTime<Utc>) -> bool {
        self.lock()
            .failed_adoptions
            .get(key)
            .is_some_and(|last| now.signed_duration_since(*last) < Duration::seconds(3))
    }
    pub fn record_adoption_failure(&self, key: &str, now: DateTime<Utc>) {
        let mut maps = self.lock();
        if maps.failed_adoptions.len() >= 4096
            && !maps.failed_adoptions.contains_key(key)
            && let Some(oldest) = maps
                .failed_adoptions
                .iter()
                .min_by_key(|(_, time)| **time)
                .map(|(key, _)| key.clone())
        {
            maps.failed_adoptions.remove(&oldest);
            maps.orphan_tracking.remove(&oldest);
        }
        maps.failed_adoptions.insert(key.into(), now);
    }
    pub fn orphan_log_decision(&self, key: &str, now: DateTime<Utc>) -> OrphanLogDecision {
        let mut maps = self.lock();
        let entry = maps
            .orphan_tracking
            .entry(key.into())
            .or_insert((now, 0, false));
        entry.1 = entry.1.saturating_add(1);
        if entry.1 < 6 || now.signed_duration_since(entry.0) < Duration::seconds(60) {
            return OrphanLogDecision::Log;
        }
        if entry.2 {
            return OrphanLogDecision::Suppress;
        }
        entry.2 = true;
        OrphanLogDecision::SuppressionMarker
    }
    pub fn reset_adoption_cache(&self) {
        let mut maps = self.lock();
        maps.failed_adoptions.clear();
        maps.orphan_tracking.clear();
    }

    fn read_transcript_tokens(&self, session: &RuntimeSession, event: &ClaudeCodeEvent) {
        let Some(projects) = &self.claude_projects_dir else {
            return;
        };
        let mut reader = self.lock().transcript_readers.remove(&session.id);
        if reader.is_none() {
            let claude_id = Some(event.session_id.as_str()).filter(|s| !s.is_empty());
            reader =
                IncrementalTranscriptReader::new(projects, &session.config.directory, claude_id);
        }
        let Some(mut reader) = reader else {
            return;
        };
        let tokens = reader.read_new_tokens();
        if !tokens.is_empty() {
            session.add_tokens(
                tokens.input,
                tokens.output,
                tokens.cache_creation,
                tokens.cache_read,
            );
        }
        let mut maps = self.lock();
        if maps.sessions.contains_key(&session.id) {
            maps.transcript_readers.insert(session.id.clone(), reader);
        }
    }
}

/// `chooseClaudeCandidate`: among sessions with an active turn (or all),
/// the one with the latest turn (or creation) date.
fn choose_candidate(candidates: Vec<Arc<RuntimeSession>>) -> Option<Arc<RuntimeSession>> {
    let active: Vec<_> = candidates
        .iter()
        .filter(|s| {
            s.current_turn_id().is_some()
                || matches!(s.state(), State::Busy | State::AwaitingApproval)
        })
        .cloned()
        .collect();
    let pool = if active.is_empty() {
        candidates
    } else {
        active
    };
    pool.into_iter().max_by(|a, b| {
        let da = a.last_turn_submitted_at().unwrap_or(a.created_at);
        let db = b.last_turn_submitted_at().unwrap_or(b.created_at);
        da.cmp(&db).then(a.created_at.cmp(&b.created_at))
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::runtime::backends::GenericShellBackend;

    #[test]
    fn adoption_cache_retries_and_chronic_logging_only_suppresses_diagnostics() {
        let manager = RuntimeSessionManager::new(None);
        let now = Utc::now();
        manager.record_adoption_failure("native", now);
        assert!(manager.should_skip_adoption("native", now + Duration::milliseconds(2999)));
        assert!(!manager.should_skip_adoption("native", now + Duration::seconds(3)));
        for _ in 0..5 {
            assert_eq!(
                manager.orphan_log_decision("native", now),
                OrphanLogDecision::Log
            );
        }
        assert_eq!(
            manager.orphan_log_decision("native", now + Duration::seconds(60)),
            OrphanLogDecision::SuppressionMarker
        );
        assert_eq!(
            manager.orphan_log_decision("native", now + Duration::seconds(61)),
            OrphanLogDecision::Suppress
        );
        manager.reset_adoption_cache();
        assert!(!manager.should_skip_adoption("native", now));
        assert_eq!(
            manager.orphan_log_decision("native", now),
            OrphanLogDecision::Log
        );
    }
    #[test]
    fn duplicate_adoption_preserves_existing_backend_and_foreign_ids_do_not_rebind() {
        let manager = RuntimeSessionManager::new(None);
        let mut host = FakeHost::default();
        let shell = manager.adopt_session("shell", Box::new(GenericShellBackend), "/x");
        let duplicate = manager.adopt_session("shell", Box::new(ClaudeCodeBackend), "/x");
        assert_eq!(duplicate.id, shell.id);
        assert_eq!(duplicate.backend.name(), "shell");
        let claude = manager.adopt_session("claude", Box::new(ClaudeCodeBackend), "/c");
        manager.handle_claude_event(
            &event(EventType::UserPrompt, "native-a", "", "first", "/c"),
            &mut host,
        );
        manager.handle_claude_event(
            &event(EventType::UserPrompt, "native-b", "", "foreign", "/c"),
            &mut host,
        );
        assert_eq!(
            manager
                .session_for_claude_session_id("native-a")
                .unwrap()
                .id,
            claude.id
        );
        assert!(manager.session_for_claude_session_id("native-b").is_none());
    }
    #[test]
    fn codex_structured_feedback_drives_turn_without_fabricated_usage_or_resolution_verdict() {
        use super::super::codex_feedback::{Prompt, Record};
        let manager = RuntimeSessionManager::new(None);
        let mut host = FakeHost::default();
        let session = manager
            .handle_codex_record(
                "codex",
                "thread",
                "/c",
                &Record::Started("task".into()),
                &mut host,
            )
            .unwrap();
        assert_eq!(session.state(), State::Busy);
        assert_eq!(session.native_session_id().as_deref(), Some("thread"));
        let prompt = Prompt {
            call_id: "call".into(),
            message: "Choose".into(),
            options: vec!["A".into()],
        };
        manager.handle_codex_record("codex", "thread", "/c", &Record::Prompt(prompt), &mut host);
        assert_eq!(session.state(), State::WaitingInput);
        manager.resolve_codex_input("codex", true);
        assert_eq!(session.state(), State::WaitingInput);
        manager.resolve_codex_input("codex", false);
        assert_eq!(session.state(), State::Busy);
        manager.handle_codex_record(
            "codex",
            "thread",
            "/c",
            &Record::Usage {
                input: 10,
                output: 4,
                cached: 2,
                reasoning: 1,
            },
            &mut host,
        );
        session.request_approval("Codex", "Approval");
        assert!(session.reconcile_approval_resolution("backend"));
        assert!(
            !of_type(&session, "approval_resolved")[0]
                .data
                .contains_key("approved")
        );
        manager.handle_codex_record(
            "codex",
            "thread",
            "/c",
            &Record::TurnCompleted(Some("{}".into())),
            &mut host,
        );
        assert_eq!(session.state(), State::Ready);
        assert_eq!(session.cumulative_token_usage().input_tokens, 8);
        assert_eq!(session.cumulative_token_usage().output_tokens, 3);
        assert_eq!(session.cumulative_token_usage().reasoning_output_tokens, 1);
        assert_eq!(session.cumulative_token_usage().cache_read_input_tokens, 2);
        assert!(session.has_token_usage_evidence());
        assert_eq!(
            session.latest_turn_result().unwrap().value,
            Some(serde_json::json!({}))
        );
    }

    #[test]
    fn children_and_descendants_keep_parent_attribution_after_stop() {
        let manager = RuntimeSessionManager::new(None);
        let parent = manager.adopt_session("p", Box::new(GenericShellBackend), "/p");
        let mut config = SessionConfig::new("/p", "shell");
        config.parent_session_id = Some(parent.id.clone());
        config.delegation_depth = 1;
        let child = manager.create_session("c", Box::new(GenericShellBackend), config, false);
        let mut config = SessionConfig::new("/p", "shell");
        config.parent_session_id = Some(child.id.clone());
        config.delegation_depth = 2;
        let grandchild = manager.create_session("g", Box::new(GenericShellBackend), config, false);
        assert_eq!(manager.child_sessions(&parent.id, false).len(), 1);
        assert_eq!(manager.descendant_sessions(&parent.id, false).len(), 2);
        manager.stop_session(&grandchild.id);
        assert_eq!(manager.descendant_sessions(&parent.id, true).len(), 2);
        assert_eq!(manager.descendant_sessions(&parent.id, false).len(), 1);
    }
    #[derive(Default)]
    struct FakeHost {
        inputs: Vec<(String, String)>,
        output: Option<String>,
        tabs: HashMap<String, String>,
        notifications: Vec<RuntimeNotification>,
    }

    impl RuntimeHost for FakeHost {
        fn send_input(&mut self, tab_id: &str, input: &str) {
            self.inputs.push((tab_id.into(), input.into()));
        }
        fn tab_output(&mut self, _: &str, _: usize) -> Option<String> {
            self.output.clone()
        }
        fn tab_for_cwd(&mut self, cwd: &str) -> Option<String> {
            self.tabs
                .iter()
                .find(|(_, dir)| *dir == cwd)
                .map(|(t, _)| t.clone())
        }
        fn tab_exists(&mut self, tab_id: &str) -> bool {
            self.tabs.contains_key(tab_id)
        }
        fn notify(&mut self, n: RuntimeNotification) {
            self.notifications.push(n);
        }
    }

    fn event(
        kind: EventType,
        session: &str,
        tool: &str,
        message: &str,
        cwd: &str,
    ) -> ClaudeCodeEvent {
        ClaudeCodeEvent {
            event_type: kind,
            hook: String::new(),
            session_id: session.into(),
            transcript_path: String::new(),
            tool_name: tool.into(),
            title: None,
            message: message.into(),
            notification_type: None,
            cwd: cwd.into(),
            timestamp: 0.0,
        }
    }

    fn claude(manager: &RuntimeSessionManager, tab: &str, cwd: &str) -> Arc<RuntimeSession> {
        manager.create_session(
            tab,
            Box::new(ClaudeCodeBackend),
            SessionConfig::new(cwd, "claude"),
            false,
        )
    }

    fn of_type(
        session: &RuntimeSession,
        kind: &str,
    ) -> Vec<crate::runtime::runtime_event::RuntimeEvent> {
        session
            .journal
            .events(0, 1000)
            .events
            .into_iter()
            .filter(|e| e.event_type == kind)
            .collect()
    }

    // Ported from RuntimeSessionManagerTests.swift.

    #[test]
    fn claude_session_binding_survives_second_session_in_same_directory() {
        let m = RuntimeSessionManager::new(None);
        let mut host = FakeHost::default();
        let first = claude(&m, "T1", "/w");
        m.mark_ready(&first.id);
        assert!(first.start_turn("first prompt").is_some());
        m.handle_claude_event(
            &event(EventType::ToolStart, "c1", "Read", "/tmp/one", "/w"),
            &mut host,
        );
        let second = claude(&m, "T2", "/w");
        m.mark_ready(&second.id);
        assert!(second.start_turn("second prompt").is_some());
        m.handle_claude_event(
            &event(EventType::ToolStart, "c1", "Edit", "/tmp/two", "/w"),
            &mut host,
        );
        assert_eq!(of_type(&first, "tool_use").len(), 2);
        assert_eq!(of_type(&second, "tool_use").len(), 0);
    }

    #[test]
    fn stopping_session_clears_claude_session_binding() {
        let m = RuntimeSessionManager::new(None);
        let mut host = FakeHost::default();
        let first = claude(&m, "T1", "/w");
        m.mark_ready(&first.id);
        first.start_turn("first");
        m.handle_claude_event(
            &event(EventType::ToolStart, "c2", "Read", "/a", "/w"),
            &mut host,
        );
        assert!(m.stop_session(&first.id));
        assert!(!m.stop_session(&first.id));
        assert_eq!(first.state(), State::Stopped);
        let second = claude(&m, "T2", "/w");
        m.mark_ready(&second.id);
        second.start_turn("second");
        m.handle_claude_event(
            &event(EventType::ToolStart, "c2", "Edit", "/b", "/w"),
            &mut host,
        );
        assert_eq!(of_type(&first, "tool_use").len(), 1);
        assert_eq!(of_type(&second, "tool_use").len(), 1);
        // The stopped session stays queryable.
        assert_eq!(m.session(&first.id).unwrap().id, first.id);
        assert_eq!(m.all_sessions(false).len(), 1);
        assert_eq!(m.all_sessions(true).len(), 2);
    }

    #[test]
    fn notification_events_bind_claude_session_and_journal_notification() {
        let m = RuntimeSessionManager::new(None);
        let mut host = FakeHost::default();
        let session = claude(&m, "T", "/n");
        m.handle_claude_event(
            &event(EventType::Notification, "cn", "", "Heads up", "/n"),
            &mut host,
        );
        assert_eq!(
            m.session_for_claude_session_id("cn").unwrap().id,
            session.id
        );
        let notes = of_type(&session, "notification");
        assert_eq!(notes.len(), 1);
        assert_eq!(notes[0].data["message"], "Heads up");
    }

    #[test]
    fn user_prompt_starts_turn_for_adopted_claude_session() {
        // Swift creates a `starting` session here, which cannot take a
        // turn; an adopted (ready) session is what the test name means.
        let m = RuntimeSessionManager::new(None);
        let mut host = FakeHost::default();
        let session = m.adopt_session("T", Box::new(ClaudeCodeBackend), "/p");
        m.handle_claude_event(
            &event(EventType::UserPrompt, "ct", "", "Please continue", "/p"),
            &mut host,
        );
        assert_eq!(
            m.session_for_claude_session_id("ct").unwrap().id,
            session.id
        );
        assert_eq!(session.state(), State::Busy);
        assert!(session.current_turn_id().is_some());
        assert_eq!(
            of_type(&session, "agent_responding")[0].data["message"],
            "Please continue"
        );
    }

    #[test]
    fn unknown_claude_sessions_are_adopted_by_directory() {
        let m = RuntimeSessionManager::new(None);
        let mut host = FakeHost::default();
        // No tab in that directory: nothing.
        m.handle_claude_event(
            &event(EventType::UserPrompt, "x", "", "hi", "/nowhere"),
            &mut host,
        );
        assert!(m.all_sessions(true).is_empty());
        host.tabs.insert("TAB".into(), "/proj".into());
        m.handle_claude_event(
            &event(EventType::UserPrompt, "c9", "", "hi", "/proj"),
            &mut host,
        );
        let adopted = m.session_for_tab("TAB").unwrap();
        assert!(adopted.adopted);
        assert_eq!(adopted.backend.name(), "claude");
        assert_eq!(adopted.state(), State::Busy);
        // Current Swift associates the native ID on the adopting event.
        assert_eq!(
            m.session_for_claude_session_id("c9").unwrap().id,
            adopted.id
        );
        m.handle_claude_event(
            &event(EventType::Notification, "c9", "", "n", "/proj"),
            &mut host,
        );
        assert_eq!(
            m.session_for_claude_session_id("c9").unwrap().id,
            adopted.id
        );
        assert_eq!(m.all_sessions(false).len(), 1);
        assert!(m.is_runtime_managed("TAB"));
    }

    #[test]
    fn full_turn_with_tools_output_and_notifications() {
        let m = RuntimeSessionManager::new(None);
        let mut host = FakeHost {
            output: Some("did it\nerror: oops".into()),
            ..Default::default()
        };
        let s = m.adopt_session("T", Box::new(ClaudeCodeBackend), "/f");
        m.handle_claude_event(
            &event(EventType::ToolStart, "c", "Edit", "/f/a.rs more", "/f"),
            &mut host,
        );
        m.handle_claude_event(
            &event(EventType::ToolComplete, "c", "Edit", "", "/f"),
            &mut host,
        );
        m.handle_claude_event(
            &event(EventType::ResponseComplete, "c", "", "All done", "/f"),
            &mut host,
        );
        assert_eq!(s.state(), State::Ready);
        let done = &of_type(&s, "turn_completed")[0];
        assert_eq!(done.data["exit_reason"], "error");
        assert_eq!(done.data["tools_used"], "Edit");
        assert_eq!(done.data["files_touched"], "1");
        assert_eq!(done.data["summary"], "All done");
        assert_eq!(of_type(&s, "tool_result").len(), 1);
        assert_eq!(
            of_type(&s, "output_chunk")[0].data["output"],
            "did it\nerror: oops"
        );
        let kinds: Vec<_> = host
            .notifications
            .iter()
            .map(|n| n.event_type.as_str())
            .collect();
        // Claude owns waiting_input; the turn failed.
        assert_eq!(kinds, ["tool_called", "file_edited", "failed"]);
        assert_eq!(host.notifications[1].message, "/f/a.rs");
        assert_eq!(host.notifications[0].session_id, "c");
        assert_eq!(host.notifications[0].tool, "claude");
    }

    #[test]
    fn permission_requests_pend_or_auto_approve() {
        let m = RuntimeSessionManager::new(None);
        let mut host = FakeHost::default();
        let manual = m.adopt_session("T1", Box::new(ClaudeCodeBackend), "/a");
        m.handle_claude_event(
            &event(EventType::PermissionRequest, "p1", "Bash", "rm x", "/a"),
            &mut host,
        );
        assert_eq!(manual.state(), State::AwaitingApproval);
        let approval = manual.pending_approval().unwrap();
        assert_eq!(approval.tool, "Bash");
        assert_eq!(
            of_type(&manual, "approval_needed")[0].data["approval_id"],
            approval.id
        );
        assert!(host.inputs.is_empty());

        // Auto approve: "y\n" typed, no pending approval, and no runtime
        // notification (Claude posts its own).
        let mut cfg = SessionConfig::new("/c", "claude");
        cfg.auto_approve = true;
        let claude_auto = m.create_session("T3", Box::new(ClaudeCodeBackend), cfg, true);
        m.mark_ready(&claude_auto.id);
        m.handle_claude_event(
            &event(EventType::PermissionRequest, "p3", "Bash", "ls", "/c"),
            &mut host,
        );
        assert_eq!(host.inputs, [("T3".to_string(), "y\n".to_string())]);
        assert!(claude_auto.pending_approval().is_none());
        assert_eq!(claude_auto.state(), State::Busy);
        assert!(host.notifications.is_empty());
    }

    #[test]
    fn session_end_and_cleanup_stop_sessions() {
        let m = RuntimeSessionManager::new(None);
        let mut host = FakeHost::default();
        host.tabs.insert("LIVE".into(), "/l".into());
        let live = m.adopt_session("LIVE", Box::new(GenericShellBackend), "/l");
        let gone = m.adopt_session("GONE", Box::new(GenericShellBackend), "/g");
        let ended = claude(&m, "E", "/e");
        m.mark_ready(&ended.id);
        m.handle_claude_event(&event(EventType::SessionEnd, "e", "", "", "/e"), &mut host);
        assert_eq!(ended.state(), State::Stopped);
        let now = Utc::now();
        m.cleanup(now, &mut host);
        assert_eq!(gone.state(), State::Stopped);
        assert_eq!(
            of_type(&gone, "session_stopped")[0].data["reason"],
            "tab_closed"
        );
        assert_eq!(live.state(), State::Ready);
        assert!(m.session(&gone.id).is_some());
        // Ten minutes later the stopped sessions are dropped.
        m.cleanup(
            now + Duration::seconds(STOPPED_RETENTION_SECONDS + 1),
            &mut host,
        );
        assert!(m.session(&gone.id).is_none());
        assert!(m.session(&ended.id).is_none());
        assert!(m.session(&live.id).is_some());
    }

    #[test]
    fn claude_events_never_drive_other_backends() {
        let m = RuntimeSessionManager::new(None);
        let mut host = FakeHost::default();
        // A shell session in a directory where Claude events land is not a
        // Claude candidate, so events adopt the tab instead.
        let s = m.adopt_session("S", Box::new(GenericShellBackend), "/s");
        m.handle_claude_event(
            &event(EventType::UserPrompt, "z", "", "hi", "/s"),
            &mut host,
        );
        assert_eq!(s.turn_count(), 0);
        assert!(m.session_for_claude_session_id("z").is_none());
    }

    #[test]
    fn file_paths_come_from_the_message() {
        assert_eq!(
            extract_file_path("/a/b.rs extra").as_deref(),
            Some("/a/b.rs")
        );
        assert_eq!(extract_file_path("Write"), None);
        assert_eq!(extract_file_path(""), None);
    }
}
