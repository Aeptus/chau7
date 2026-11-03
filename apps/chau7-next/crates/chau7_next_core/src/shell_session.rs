//! What a terminal session knows about its shell: command status, the
//! command being run, the current directory, the AI tool in use and the
//! command blocks.
//!
//! Ports the session logic of
//! `apps/chau7-macos/Sources/Chau7/Terminal/Session/TerminalSessionModel.swift`
//! and `TerminalSessionModel+ShellIntegration.swift`, without UI or timers:
//! the caller feeds typed input ([`ShellSession::handle_input`]), PTY output
//! ([`ShellSession::handle_output`]), shell integration marks (OSC 133,
//! [`ShellSession::handle_mark`]) and a once-a-second [`ShellSession::tick`],
//! then drains [`ShellSession::take_events`].
//!
//! - Typed lines are captured (escape sequences stripped, split on Enter).
//!   Lines typed with echo off are reported as sensitive and never stored.
//! - Without OSC 133, Enter marks the command running; the tick turns it
//!   "stuck" after 30 s without output, completes it after the fallback delay
//!   without a prompt, and returns to idle after 3 s of quiet.
//! - With OSC 133 (A prompt, B command start, C executed, D finished), the
//!   marks drive the status and the command blocks.
//! - The AI tool is detected from the typed command (PATH aware, priority)
//!   and from the output (sliding-buffer state machine), and cleared when the
//!   prompt returns or on `exit`/`logout`/`quit`.
//! - The directory follows OSC 7 and typed `cd` lines; paths that do not
//!   exist locally are rejected.

use crate::ai::detection_state::AiDetectionState;
use crate::ai::resume;
use crate::command_block::CommandBlockList;
use crate::command_detection::{
    self, AI_TOOLS, OUTPUT_DETECTION_PATTERNS, normalize_token, tokenize,
};
use crate::escape_sanitizer;
use crate::sensitive_input;
use crate::shell_osc7::{self, Osc7Scanner};
use crate::terminal_prompt_notification::{
    TerminalPromptNotificationContext, should_emit_waiting_input,
};

/// Command status shown in the tab hover card and status bar (`CommandStatus`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum CommandStatus {
    #[default]
    Idle,
    /// An AI turn completed while its CLI remains open.
    Done,
    Running,
    /// An AI tool asks for input or permission.
    WaitingForInput,
    /// An explicit approval is outstanding.
    ApprovalRequired,
    /// Running for a long time without output.
    Stuck,
    Exited,
}

impl CommandStatus {
    /// Swift raw value.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Idle => "idle",
            Self::Done => "done",
            Self::Running => "running",
            Self::WaitingForInput => "waitingForInput",
            Self::ApprovalRequired => "approvalRequired",
            Self::Stuck => "stuck",
            Self::Exited => "exited",
        }
    }

    /// Label for the UI.
    pub fn label(self) -> &'static str {
        match self {
            Self::Idle => "Idle",
            Self::Done => "Done",
            Self::Running => "Running",
            Self::WaitingForInput => "Waiting for input",
            Self::ApprovalRequired => "Approval required",
            Self::Stuck => "Stuck",
            Self::Exited => "Exited",
        }
    }
}

/// OSC 133 marks (`ShellIntegrationEvent` of `chau7_terminal`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShellMark {
    /// A: the prompt is drawn.
    PromptStart,
    /// B: the command starts (prompt end).
    CommandStart,
    /// C: the command is executed.
    CommandExecuted,
    /// D: the command finished with this exit code.
    CommandFinished(i32),
}

/// What changed, for the UI and the event pipeline.
#[derive(Debug, Clone, PartialEq)]
pub enum ShellSessionEvent {
    StatusChanged(CommandStatus),
    /// A command started. `command` is the typed line when known.
    /// `from_shell_integration`: OSC 133 C (take a git snapshot now).
    CommandStarted {
        command: Option<String>,
        directory: String,
        from_shell_integration: bool,
        /// The block created by OSC 133, if one was created.
        block_id: Option<uuid::Uuid>,
    },
    /// A command finished. `exit_code` is known only with OSC 133 D.
    CommandFinished {
        command: Option<String>,
        exit_code: Option<i32>,
        duration: f64,
        from_shell_integration: bool,
        /// The command block finished by OSC 133, if one was created.
        /// Heuristic completion has no command block.
        block_id: Option<uuid::Uuid>,
    },
    /// The detected AI tool changed (display name).
    ActiveAppChanged(Option<String>),
    DirectoryChanged(String),
    /// A typed line to add to the command history; `sensitive` lines (echo
    /// off) must not be stored.
    HistoryLine {
        command: String,
        sensitive: bool,
    },
    /// The user answered: clear a permission border.
    PermissionResolved,
    /// An AI tool handed back the prompt after a real round trip
    /// (`emitWaitingInputFallbackIfNeeded`).
    WaitingInputFallback {
        tool: String,
        provider: String,
    },
}

/// Timing settings (`idleSeconds`, `stuckSeconds`, `fallbackCompletionSeconds`).
#[derive(Debug, Clone, PartialEq)]
pub struct ShellSessionConfig {
    pub idle_seconds: f64,
    pub stuck_seconds: f64,
    pub fallback_completion_seconds: f64,
    /// Custom AI detection rules: (substring, display name).
    pub custom_rules: Vec<(String, String)>,
}

impl Default for ShellSessionConfig {
    fn default() -> Self {
        Self::from_env(|_| None)
    }
}

impl ShellSessionConfig {
    /// Reads `CHAU7_IDLE_SECONDS` and `CHAU7_COMMAND_FALLBACK_SECONDS` (the
    /// `CHAU7_NEXT_` names first, since Chau7 Next drops inherited `CHAU7_`
    /// variables when started from a Chau7 tab, then the legacy
    /// `SMART_OVERLAY_` names).
    pub fn from_env(get: impl Fn(&str) -> Option<String>) -> Self {
        use crate::env_vars;
        let read = |name: &str, legacy: &str| {
            get(&name.replacen("CHAU7_", "CHAU7_NEXT_", 1))
                .filter(|v| !v.is_empty())
                .or_else(|| get(name).filter(|v| !v.is_empty()))
                .or_else(|| get(legacy).filter(|v| !v.is_empty()))
                .and_then(|v| v.trim().parse::<f64>().ok())
                .filter(|v| *v > 0.0)
        };
        let idle = read(env_vars::IDLE_SECONDS, env_vars::LEGACY_IDLE_SECONDS).unwrap_or(3.0);
        let stuck = 30.0;
        let fallback = read(
            env_vars::COMMAND_FALLBACK_SECONDS,
            env_vars::LEGACY_COMMAND_FALLBACK_SECONDS,
        )
        .unwrap_or_else(|| 30f64.max((idle * 3.0).max(stuck * 2.0)));
        Self {
            idle_seconds: idle,
            stuck_seconds: stuck,
            fallback_completion_seconds: fallback,
            custom_rules: Vec::new(),
        }
    }
}

/// File system and environment the session asks about.
pub trait ShellContext {
    /// Whether `path` is an existing directory.
    fn is_dir(&self, path: &str) -> bool;
    /// The shell's `PATH` (for PATH-aware AI detection).
    fn search_path(&self) -> Option<String>;
    /// The user's home folder (`cd` with no argument, `~`).
    fn home(&self) -> String;
}

/// AI waiting-for-input patterns (`maybeDetectAIWaitingForInput`).
pub const APPROVAL_PATTERNS: &[&str] = &[
    "needs your approval",
    "needs your permission",
    "approval required",
    "approve this command",
    "allow once",
    "always allow",
];
pub const WAITING_PATTERNS: &[&str] = &[
    "yes/no",
    "[y/n]",
    "(y/n)",
    "allow?",
    "approve?",
    "continue?",
    "proceed?",
    "permission required",
    "question requested",
    "input requested",
    "needs your input",
    "ready for your input",
    "enter your",
    "type your",
    "waiting for your input",
    "❯ 1.",
    "❯ 1)",
];

#[derive(Debug, Clone)]
pub struct ShellSession {
    config: ShellSessionConfig,
    status: CommandStatus,
    is_at_prompt: bool,
    is_shell_loading: bool,
    /// A line was typed before the shell drew its first prompt (an MCP or
    /// runtime launch queued into a new tab). The shell has not read it yet,
    /// so the startup's own finish and first prompt are not its completion.
    typed_while_loading: bool,
    has_shell_integration: bool,
    saw_osc7: bool,
    has_pending_command: bool,
    pending_command_line: Option<String>,
    prompt_seen_for_pending_command: bool,
    command_finished_notified: bool,
    command_pending_detection: bool,
    command_started_at: f64,
    last_input_at: f64,
    last_output_at: f64,
    input_buffer: String,
    ai: AiDetectionState,
    active_app: Option<String>,
    last_detected_app: Option<String>,
    live_agent_name: Option<String>,
    last_ai_provider: Option<String>,
    last_ai_session_id: Option<String>,
    suppress_waiting_fallback: bool,
    fallback_armed: bool,
    fallback_saw_output: bool,
    /// Set while a resume command waits to be typed at the prompt.
    pub prefill_pending: bool,
    /// The tab hosts an agent runtime session (the runtime reports
    /// waiting for input itself, `RuntimeSessionManager.sessionForTab`).
    pub runtime_owns_tab: bool,
    pending_feedback_approval: bool,
    pending_feedback_input: bool,
    last_feedback_at: Option<f64>,
    agent_turn_started_at: Option<f64>,
    pub provider_has_authoritative_notifications: bool,
    current_directory: String,
    osc7: Osc7Scanner,
    blocks: CommandBlockList,
    pending_block_id: Option<uuid::Uuid>,
    events: Vec<ShellSessionEvent>,
    /// CTO input prefix added to each typed line before it is recorded
    /// (`applyCTOPrefixIfNeeded`); the shell still runs the typed text.
    input_prefix: Option<String>,
}

impl ShellSession {
    pub fn new(config: ShellSessionConfig, directory: &str, now: f64) -> Self {
        Self {
            config,
            status: CommandStatus::Idle,
            is_at_prompt: false,
            is_shell_loading: true,
            typed_while_loading: false,
            has_shell_integration: false,
            saw_osc7: false,
            has_pending_command: false,
            pending_command_line: None,
            prompt_seen_for_pending_command: false,
            command_finished_notified: false,
            command_pending_detection: false,
            command_started_at: now,
            last_input_at: now,
            last_output_at: now,
            input_buffer: String::new(),
            ai: AiDetectionState::new(),
            active_app: None,
            last_detected_app: None,
            live_agent_name: None,
            last_ai_provider: None,
            last_ai_session_id: None,
            suppress_waiting_fallback: false,
            fallback_armed: false,
            fallback_saw_output: false,
            prefill_pending: false,
            runtime_owns_tab: false,
            pending_feedback_approval: false,
            pending_feedback_input: false,
            last_feedback_at: None,
            agent_turn_started_at: None,
            provider_has_authoritative_notifications: false,
            current_directory: directory.to_string(),
            osc7: Osc7Scanner::new(),
            blocks: CommandBlockList::new(),
            pending_block_id: None,
            events: Vec::new(),
            input_prefix: None,
        }
    }

    pub fn set_config(&mut self, config: ShellSessionConfig) {
        self.config = config;
    }

    /// The CTO input prefix for this session (`None` for no prefix).
    pub fn set_input_prefix(&mut self, prefix: Option<String>) {
        self.input_prefix = prefix;
    }

    pub fn status(&self) -> CommandStatus {
        self.status
    }

    /// Activity status describes a command or AI turn, not process lifetime.
    /// A completed agent turn or an unintegrated shell can still own live
    /// processes. The caller supplies descendants from the shared background
    /// process snapshot; this decision must never scan processes on the UI.
    pub fn requires_process_close_warning(&self, has_child_processes: bool) -> bool {
        self.status != CommandStatus::Exited
            && (has_child_processes
                || self.is_ai_running()
                || matches!(
                    self.status,
                    CommandStatus::Running
                        | CommandStatus::WaitingForInput
                        | CommandStatus::ApprovalRequired
                        | CommandStatus::Stuck
                ))
    }

    pub fn is_at_prompt(&self) -> bool {
        self.is_at_prompt
    }

    /// True until the first prompt (`isShellLoading`).
    pub fn is_shell_loading(&self) -> bool {
        self.is_shell_loading
    }

    /// The shell sent OSC 133 marks at least once.
    pub fn has_shell_integration(&self) -> bool {
        self.has_shell_integration
    }

    /// The shell reported its directory with OSC 7 at least once.
    pub fn saw_osc7(&self) -> bool {
        self.saw_osc7
    }

    pub fn active_app(&self) -> Option<&str> {
        self.active_app.as_deref()
    }

    /// Whether the AI tool is live (not only restored from a saved tab).
    pub fn is_ai_running(&self) -> bool {
        self.live_agent_name.is_some() || (self.active_app.is_some() && !self.ai.is_restored())
    }

    /// Process-tree ground truth. A disappearance keeps persisted resume metadata.
    pub fn update_live_agent(&mut self, app: Option<&str>) -> bool {
        let app = app
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(str::to_string);
        let provider = app.as_deref().and_then(resume::normalize_provider_name);
        let metadata_matches = app.is_none()
            || (self.last_detected_app == app
                && provider
                    .as_deref()
                    .is_none_or(|p| self.last_ai_provider.as_deref() == Some(p)));
        if self.live_agent_name == app && metadata_matches {
            return false;
        }
        self.live_agent_name = app.clone();
        if let Some(app) = app {
            if let Some(provider) = provider {
                if self
                    .last_ai_provider
                    .as_deref()
                    .is_some_and(|old| old != provider)
                {
                    self.reset_feedback_for_identity(Some(&provider), None);
                    self.last_ai_session_id = None;
                }
                self.last_ai_provider = Some(provider);
            }
            self.last_detected_app = Some(app);
        }
        true
    }

    pub fn live_agent_name(&self) -> Option<&str> {
        self.live_agent_name.as_deref()
    }
    /// Current Swift canonical provider display; custom detections retain their name.
    pub fn ai_display_app_name(&self) -> Option<String> {
        display_name_from_provider(self.last_ai_provider.as_deref())
            .or_else(|| self.last_detected_app.clone())
            .or_else(|| self.active_app.clone())
    }

    pub fn last_detected_app(&self) -> Option<&str> {
        self.last_detected_app.as_deref()
    }

    pub fn ai_provider(&self) -> Option<&str> {
        self.last_ai_provider.as_deref()
    }

    /// Cached unsubmitted fragment used by the input admission fence.
    pub fn pending_input_text(&self) -> &str {
        &self.input_buffer
    }

    /// Unsubmitted user fragment, separate from completed command history.
    pub fn has_pending_input(&self) -> bool {
        !self.input_buffer.is_empty()
    }

    pub fn ai_session_id(&self) -> Option<&str> {
        self.last_ai_session_id.as_deref()
    }

    pub fn current_directory(&self) -> &str {
        &self.current_directory
    }

    /// The command being run (typed line, secrets redacted).
    pub fn pending_command(&self) -> Option<&str> {
        self.pending_command_line.as_deref()
    }

    /// Actual observed input/output timestamps for restore persistence.
    pub fn last_input_at(&self) -> f64 {
        self.last_input_at
    }
    pub fn last_output_at(&self) -> f64 {
        self.last_output_at
    }

    pub fn command_started_at(&self) -> f64 {
        self.command_started_at
    }

    pub fn blocks(&self) -> &CommandBlockList {
        &self.blocks
    }

    pub fn blocks_mut(&mut self) -> &mut CommandBlockList {
        &mut self.blocks
    }

    pub fn take_events(&mut self) -> Vec<ShellSessionEvent> {
        std::mem::take(&mut self.events)
    }

    fn set_status(&mut self, status: CommandStatus) {
        if self.status != status {
            self.status = status;
            self.events.push(ShellSessionEvent::StatusChanged(status));
        }
    }

    fn set_active_app(&mut self, app: Option<String>) {
        if self.active_app != app {
            self.active_app = app.clone();
            self.events.push(ShellSessionEvent::ActiveAppChanged(app));
        }
    }

    // MARK: input

    /// Bytes typed or pasted by the user (`handleInput`).
    pub fn handle_input(
        &mut self,
        text: &str,
        echo_disabled: bool,
        ctx: &dyn ShellContext,
        now: f64,
    ) {
        self.last_input_at = now;
        let sanitized = sanitize_input_for_buffer(text);
        if sanitized.is_empty() {
            return;
        }
        apply_line_editing(&mut self.input_buffer, &sanitized);
        if sanitized.contains(['\n', '\r']) {
            self.process_input_buffer(echo_disabled, ctx, now);
            self.mark_running(now);
        }
    }

    fn process_input_buffer(&mut self, echo_disabled: bool, ctx: &dyn ShellContext, now: f64) {
        let normalized = self.input_buffer.replace('\r', "\n");
        let mut parts: Vec<&str> = normalized.split('\n').collect();
        if parts.len() <= 1 {
            return;
        }
        let rest = parts.pop().unwrap_or_default().to_string();
        let lines: Vec<String> = parts.iter().map(|s| s.to_string()).collect();
        for line in lines {
            self.handle_input_line(&line, echo_disabled, ctx, now);
        }
        self.input_buffer = rest;
    }

    fn mark_running(&mut self, now: f64) {
        if self.has_shell_integration {
            return;
        }
        if self.status != CommandStatus::Running && self.status != CommandStatus::Stuck {
            self.set_status(CommandStatus::Running);
            self.command_started_at = now;
        }
    }

    /// One typed line (`handleInputLine`).
    pub fn handle_input_line(
        &mut self,
        line: &str,
        echo_disabled: bool,
        ctx: &dyn ShellContext,
        now: f64,
    ) {
        let sanitized = escape_sanitizer::sanitize(line);
        let sanitized = match &self.input_prefix {
            Some(prefix) => crate::cto_wrappers::apply_input_prefix(&sanitized, prefix),
            None => sanitized,
        };
        let trimmed = sanitized.trim();
        if trimmed.is_empty() {
            self.pending_command_line = None;
            self.prompt_seen_for_pending_command = false;
            self.command_finished_notified = false;
            self.command_pending_detection = false;
            return;
        }
        let trimmed = trimmed.to_string();
        if self.is_shell_loading {
            self.typed_while_loading = true;
        }
        let resume_metadata = resume::extract_metadata(&trimmed);
        if resume_metadata.is_none() {
            self.suppress_waiting_fallback = false;
        }
        self.events.push(ShellSessionEvent::HistoryLine {
            command: trimmed.clone(),
            sensitive: echo_disabled,
        });
        if echo_disabled {
            return;
        }
        let persisted = sensitive_input::sanitized_command_for_persistence(&trimmed, false);
        self.pending_command_line = persisted.clone();
        if !self.has_shell_integration {
            self.has_pending_command = true;
            self.prompt_seen_for_pending_command = false;
            self.command_finished_notified = false;
            self.is_at_prompt = false;
            self.events.push(ShellSessionEvent::CommandStarted {
                command: persisted,
                directory: self.current_directory.clone(),
                from_shell_integration: false,
                block_id: None,
            });
            self.events.push(ShellSessionEvent::PermissionResolved);
        }
        self.track_resume_metadata(&trimmed);
        self.update_active_app_from_command(&trimmed, ctx, now);
        self.command_pending_detection = false;
        // Waiting-input fallback: armed by a real (non-resume) AI command.
        let search_path = ctx.search_path();
        let detected = command_detection::detect_launchable_app(
            &trimmed,
            &self.current_directory,
            search_path.as_deref(),
        );
        if self.active_app.is_some() || detected.is_some() {
            self.fallback_armed = resume_metadata.is_none();
            self.fallback_saw_output = false;
        } else {
            self.clear_waiting_fallback_tracking();
        }
        if let Some(target) = cd_target(&trimmed) {
            let mut target = if target.is_empty() {
                ctx.home()
            } else {
                target
            };
            if let Some(rest) = target.strip_prefix('~') {
                target = format!("{}{}", ctx.home(), rest);
            }
            let resolved = if target.starts_with('/') {
                target
            } else {
                format!("{}/{}", self.current_directory, target)
            };
            self.update_directory(&resolved, ctx);
        }
    }

    fn update_active_app_from_command(&mut self, line: &str, ctx: &dyn ShellContext, now: f64) {
        let search_path = ctx.search_path();
        if let Some(app) = command_detection::detect_launchable_app(
            line,
            &self.current_directory,
            search_path.as_deref(),
        ) {
            self.ai.handle_command(Some(&app), now);
            self.last_detected_app = Some(app.clone());
            self.set_active_app(Some(app));
            return;
        }
        let lowered = line.to_lowercase();
        let custom = self.config.custom_rules.clone();
        for (pattern, name) in custom {
            let pattern = pattern.trim().to_lowercase();
            if pattern.is_empty() || !lowered.contains(&pattern) {
                continue;
            }
            let name = name.trim();
            let display = if name.is_empty() { "Custom AI" } else { name }.to_string();
            self.ai.handle_command(Some(&display), now);
            self.last_detected_app = Some(display.clone());
            self.set_active_app(Some(display));
            return;
        }
        if self.active_app.is_some() && is_exit_command(line) {
            self.ai.handle_exit();
            self.set_active_app(None);
        }
    }

    /// `trackAIResumeMetadata`.
    pub fn track_resume_metadata(&mut self, line: &str) {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return;
        }
        if let Some(meta) = resume::extract_metadata(trimmed) {
            self.reset_feedback_for_identity(Some(&meta.provider), Some(&meta.session_id));
            self.last_ai_provider = Some(meta.provider);
            self.last_ai_session_id = Some(meta.session_id);
            return;
        }
        if let Some(provider) = resume::detect_provider(trimmed) {
            // A fresh launch drops the old native identity and its pending feedback.
            self.reset_feedback_for_identity(Some(&provider), None);
            self.last_ai_provider = Some(provider);
            self.last_ai_session_id = None;
        }
    }

    /// A history/hook identity is considered only after transcript ownership was
    /// checked off-thread. Recheck command generation/provider on the main thread.
    pub fn can_adopt_observed_ai_identity(
        &self,
        provider: &str,
        session_id: &str,
        observed_at: f64,
        replace_different: bool,
    ) -> bool {
        let provider = resume::normalize_provider_name(provider);
        let session_id = session_id.trim();
        self.status != CommandStatus::Exited
            && observed_at.is_finite()
            && observed_at >= self.last_input_at
            && resume::is_valid_session_id(session_id)
            && provider.is_some()
            && self.effective_provider() == provider
            && (replace_different
                || self
                    .ai_session_id()
                    .is_none_or(|current| current == session_id))
    }

    pub fn adopt_observed_ai_identity(
        &mut self,
        provider: &str,
        session_id: &str,
        observed_at: f64,
        replace_different: bool,
    ) -> bool {
        if !self.can_adopt_observed_ai_identity(
            provider,
            session_id,
            observed_at,
            replace_different,
        ) {
            return false;
        }
        let session_id = session_id.trim();
        let normalized = resume::normalize_provider_name(provider);
        if self.last_ai_provider == normalized && self.ai_session_id() == Some(session_id) {
            return false;
        }
        self.reset_feedback_for_identity(normalized.as_deref(), Some(session_id));
        self.last_ai_provider = normalized;
        self.last_ai_session_id = Some(session_id.to_owned());
        true
    }

    /// An identity reported by an agent hook that ran inside this tab (its
    /// event carries this tab's ID). Unlike a history or transcript match,
    /// it names the agent this tab is running, so it replaces a stale or
    /// different provider and session instead of requiring them to match;
    /// otherwise one wrong provider would make the tab unresumable for good.
    /// Reports older than the current command's launch are ignored.
    pub fn adopt_tab_reported_ai_identity(
        &mut self,
        provider: &str,
        session_id: &str,
        observed_at: f64,
    ) -> bool {
        self.adopt_tab_reported_ai_identity_from_process(
            provider,
            session_id,
            observed_at,
            None,
            None,
        )
    }

    /// New Codex hooks identify their reporting process. A tab environment can
    /// be inherited by a nested CLI, so only the primary process may change the
    /// foreground thread. Legacy hooks may fill an unbound ID, never replace
    /// an already live conversation. Explicit shell launches still clear it.
    pub fn adopt_tab_reported_ai_identity_from_process(
        &mut self,
        provider: &str,
        session_id: &str,
        observed_at: f64,
        reporter_pid: Option<u32>,
        primary_pid: Option<u32>,
    ) -> bool {
        let Some(provider) = resume::normalize_provider_name(provider) else {
            return false;
        };
        if provider == "codex" {
            match reporter_pid {
                Some(pid) if pid == 0 || primary_pid != Some(pid) => return false,
                None if self.is_ai_running()
                    && self
                        .ai_session_id()
                        .is_some_and(|old| old != session_id.trim()) =>
                {
                    return false;
                }
                _ => {}
            }
        }
        let session_id = session_id.trim();
        if self.status == CommandStatus::Exited
            || !resume::is_valid_session_id(session_id)
            || !observed_at.is_finite()
            || observed_at < self.command_started_at
            || (self.last_ai_provider.as_deref() == Some(provider.as_str())
                && self.ai_session_id() == Some(session_id))
        {
            return false;
        }
        self.reset_feedback_for_identity(Some(&provider), Some(session_id));
        self.last_ai_provider = Some(provider);
        self.last_ai_session_id = Some(session_id.to_owned());
        true
    }

    /// Restores AI metadata of a saved tab (`restoreAIMetadata`).
    pub fn restore_ai_metadata(&mut self, provider: Option<&str>, session_id: Option<&str>) {
        let normalized = resume::normalize_provider_name(provider.unwrap_or_default());
        let session_id = session_id
            .map(str::trim)
            .filter(|s| resume::is_valid_session_id(s));
        self.reset_feedback_for_identity(normalized.as_deref(), session_id);
        let display = display_name_from_provider(normalized.as_deref());
        if let Some(name) = &display {
            self.ai.handle_restore(name);
        }
        self.active_app = display.clone();
        self.last_detected_app = display.clone();
        self.last_ai_provider = normalized;
        self.suppress_waiting_fallback = display.is_some();
        self.fallback_armed = false;
        self.fallback_saw_output = false;
        self.last_ai_session_id = session_id.map(str::to_string);
    }

    fn reset_feedback_for_identity(&mut self, provider: Option<&str>, session_id: Option<&str>) {
        if self.last_ai_provider.as_deref() != provider
            || self.last_ai_session_id.as_deref() != session_id
        {
            self.pending_feedback_approval = false;
            self.pending_feedback_input = false;
            self.provider_has_authoritative_notifications = false;
            self.last_feedback_at = None;
            self.agent_turn_started_at = None;
        }
    }

    // MARK: output

    /// PTY output (`handleOutput`).
    pub fn handle_output(&mut self, data: &[u8], ctx: &dyn ShellContext, now: f64) {
        if data.is_empty() {
            return;
        }
        self.last_output_at = now;
        if self.fallback_armed && (self.active_app.is_some() || self.last_detected_app.is_some()) {
            self.fallback_saw_output = true;
        }
        for path in self.osc7.feed(data) {
            self.saw_osc7 = true;
            self.update_directory(&path, ctx);
        }
        let saw_prompt = shell_osc7::contains_osc7(data);
        if saw_prompt {
            self.clear_active_app_after_prompt(now);
            self.handle_prompt_detected(now);
        }
        if !saw_prompt && !self.command_pending_detection {
            self.detect_app_from_output(data, now);
        }
        self.detect_waiting_for_input(data);
    }

    fn detect_app_from_output(&mut self, data: &[u8], now: f64) {
        let Some(haystack) = self.ai.prepare_haystack(data, now) else {
            return;
        };
        let custom: Vec<(String, String)> = self
            .config
            .custom_rules
            .iter()
            .filter(|(p, _)| !p.trim().is_empty())
            .map(|(p, n)| {
                let n = n.trim();
                (
                    p.trim().to_lowercase(),
                    if n.is_empty() { "Custom AI" } else { n }.to_string(),
                )
            })
            .collect();
        let matched = OUTPUT_DETECTION_PATTERNS
            .iter()
            .map(|(p, n)| (p.to_lowercase(), n.to_string()))
            .chain(custom)
            .find(|(pattern, _)| haystack.contains(pattern.as_str()))
            .map(|(_, name)| name);
        let authoritative = self
            .active_app
            .clone()
            .or_else(|| self.last_detected_app.clone())
            .or_else(|| display_name_from_provider(self.last_ai_provider.as_deref()));
        if self
            .ai
            .handle_output_match(matched.as_deref(), authoritative.as_deref(), now)
            && let Some(app) = self.ai.current_app().map(str::to_string)
        {
            self.last_detected_app = Some(app.clone());
            self.set_active_app(Some(app));
        }
    }

    fn detect_waiting_for_input(&mut self, data: &[u8]) {
        if self.active_app.is_none()
            || !matches!(self.status, CommandStatus::Running | CommandStatus::Stuck)
        {
            return;
        }
        // A chunk can end mid-character or carry a stray invalid byte; decode
        // lossily so the prompt text around it is still checked.
        let text = String::from_utf8_lossy(data);
        let text = escape_sanitizer::sanitize(&text);
        let trailing = text
            .trim_end()
            .chars()
            .rev()
            .take(280)
            .collect::<String>()
            .chars()
            .rev()
            .collect::<String>()
            .to_lowercase();
        if APPROVAL_PATTERNS
            .iter()
            .any(|pattern| trailing.contains(pattern))
        {
            self.set_status(CommandStatus::ApprovalRequired);
        } else if WAITING_PATTERNS
            .iter()
            .any(|pattern| trailing.contains(pattern))
        {
            self.set_status(CommandStatus::WaitingForInput);
        }
    }

    /// Start of the current observed provider turn, never inferred from PTY silence.
    pub fn agent_turn_started_at(&self) -> Option<f64> {
        self.agent_turn_started_at
    }

    /// Apply authoritative feedback only to the current provider/native session and command generation.
    pub fn apply_agent_feedback(
        &mut self,
        kind: &str,
        provider: &str,
        session_id: Option<&str>,
        observed_at: f64,
    ) -> bool {
        if self.status == CommandStatus::Exited
            || !observed_at.is_finite()
            || observed_at < self.last_input_at
            || self.last_feedback_at.is_some_and(|at| observed_at < at)
        {
            return false;
        }
        let provider = resume::normalize_provider_name(provider);
        if provider.is_none() || self.effective_provider() != provider {
            return false;
        }
        if let (Some(current), Some(incoming)) = (self.ai_session_id(), session_id)
            && current != incoming
        {
            return false;
        }
        match kind {
            "turn_started" | "user_prompt" => {
                self.pending_feedback_approval = false;
                self.pending_feedback_input = false;
                self.agent_turn_started_at = Some(observed_at);
            }
            // Background tools can finish after the main turn. Only a new
            // turn start can reopen an authoritatively completed turn.
            "tool_start" | "tool_complete" | "tool_failed" => {
                if self.status == CommandStatus::Done && self.last_feedback_at.is_some() {
                    return false;
                }
                // PreToolUse can precede approval; completion proves the tool ran.
                if kind != "tool_start" {
                    self.pending_feedback_approval = false;
                }
            }
            "approval_requested" | "permission" => self.pending_feedback_approval = true,
            "user_input_requested" | "waiting_input" => self.pending_feedback_input = true,
            "approval_resolved" | "permission_resolved" => self.pending_feedback_approval = false,
            "user_input_resolved" => self.pending_feedback_input = false,
            "turn_completed" | "finished" => {
                self.pending_feedback_approval = false;
                self.pending_feedback_input = false;
                self.provider_has_authoritative_notifications = true;
                self.last_feedback_at = Some(observed_at);
                self.set_status(CommandStatus::Done);
                return true;
            }
            _ => return false,
        }
        self.provider_has_authoritative_notifications = true;
        self.last_feedback_at = Some(observed_at);
        self.set_status(if self.pending_feedback_approval {
            CommandStatus::ApprovalRequired
        } else if self.pending_feedback_input {
            CommandStatus::WaitingForInput
        } else {
            CommandStatus::Running
        });
        true
    }

    fn completed_status(&self) -> CommandStatus {
        if self.active_app.is_some()
            || self.effective_provider().is_some()
            || self.last_detected_app.is_some()
        {
            CommandStatus::Done
        } else {
            CommandStatus::Idle
        }
    }

    fn clear_active_app_after_prompt(&mut self, now: f64) {
        if self.ai.handle_prompt_return(now) {
            self.set_active_app(self.ai.current_app().map(str::to_string));
        }
    }

    /// The prompt came back (`handlePromptDetected`).
    fn handle_prompt_detected(&mut self, now: f64) {
        if self.is_shell_loading && self.typed_while_loading {
            // The first prompt of a new shell, which reads the queued line next.
            self.is_shell_loading = false;
            self.typed_while_loading = false;
            self.is_at_prompt = false;
            return;
        }
        let previous = self.status;
        self.is_shell_loading = false;
        self.is_at_prompt = true;
        if matches!(
            self.status,
            CommandStatus::Running
                | CommandStatus::Stuck
                | CommandStatus::WaitingForInput
                | CommandStatus::ApprovalRequired
        ) {
            self.set_status(self.completed_status());
        }
        self.emit_waiting_fallback_if_needed(previous);
        self.clear_waiting_fallback_tracking();
        if !self.has_pending_command || self.pending_command_line.is_none() {
            return;
        }
        self.prompt_seen_for_pending_command = true;
        if !self.command_finished_notified {
            self.command_finished_notified = true;
            self.events.push(ShellSessionEvent::CommandFinished {
                command: self.pending_command_line.clone(),
                exit_code: None,
                duration: (now - self.command_started_at).max(0.0),
                from_shell_integration: false,
                block_id: None,
            });
        }
    }

    fn emit_waiting_fallback_if_needed(&mut self, previous: CommandStatus) {
        if self.ai.is_restored() && self.suppress_waiting_fallback {
            return;
        }
        let provider = self.effective_provider();
        let context = TerminalPromptNotificationContext {
            previous_status: previous.as_str().to_string(),
            has_owner_tab: true,
            runtime_owns_tab: self.runtime_owns_tab,
            provider_id: provider.clone(),
            provider_is_restored: self.ai.is_restored(),
            provider_has_authoritative_notifications: self.provider_has_authoritative_notifications,
            has_pending_prefill_input: self.prefill_pending,
            suppress_until_next_user_command: self.suppress_waiting_fallback,
            has_recent_system_resume_prefill: false,
            command_looks_like_resume: self
                .pending_command_line
                .as_deref()
                .and_then(resume::extract_metadata)
                .is_some(),
            observed_ai_round_trip: self.fallback_armed && self.fallback_saw_output,
            session_id: self.last_ai_session_id.clone(),
        };
        if !should_emit_waiting_input(&context) {
            return;
        }
        let Some(provider) = provider else {
            return;
        };
        let tool = self
            .active_app
            .clone()
            .or_else(|| self.last_detected_app.clone())
            .or_else(|| display_name_from_provider(Some(&provider)))
            .unwrap_or_else(|| provider.clone());
        self.events
            .push(ShellSessionEvent::WaitingInputFallback { tool, provider });
    }

    /// Provider of the AI tool in use (or last used).
    pub fn effective_provider(&self) -> Option<String> {
        self.last_ai_provider.clone().or_else(|| {
            self.active_app
                .as_deref()
                .or(self.last_detected_app.as_deref())
                .and_then(resume::normalize_provider_name)
        })
    }

    fn clear_waiting_fallback_tracking(&mut self) {
        self.fallback_armed = false;
        self.fallback_saw_output = false;
    }

    // MARK: shell integration

    /// An OSC 133 mark. `line` is the absolute buffer line of the cursor
    /// (for command blocks).
    pub fn handle_mark(&mut self, mark: ShellMark, line: i64, now: f64) {
        self.has_shell_integration = true;
        match mark {
            ShellMark::PromptStart => self.handle_prompt_detected(now),
            ShellMark::CommandStart => {
                self.is_at_prompt = false;
                self.set_status(CommandStatus::Running);
                self.pending_block_id = None;
                self.has_pending_command = true;
                self.command_started_at = now;
                self.command_finished_notified = false;
                self.prompt_seen_for_pending_command = false;
                self.events.push(ShellSessionEvent::PermissionResolved);
            }
            ShellMark::CommandExecuted => {
                let command = self.pending_command_line.clone();
                let block_id = self.blocks.command_started_with_id(
                    command.as_deref().unwrap_or_default(),
                    line,
                    Some(self.current_directory.clone()),
                );
                self.pending_block_id = Some(block_id);
                self.events.push(ShellSessionEvent::CommandStarted {
                    command: command.clone(),
                    directory: self.current_directory.clone(),
                    from_shell_integration: true,
                    block_id: Some(block_id),
                });
            }
            ShellMark::CommandFinished(code) => {
                // The startup's own exit status, before the queued line ran.
                if self.command_finished_notified
                    || (self.is_shell_loading && self.typed_while_loading)
                {
                    return;
                }
                self.command_finished_notified = true;
                self.has_pending_command = false;
                self.prompt_seen_for_pending_command = true;
                self.events.push(ShellSessionEvent::CommandFinished {
                    command: self.pending_command_line.clone(),
                    exit_code: Some(code),
                    duration: (now - self.command_started_at).max(0.0),
                    from_shell_integration: true,
                    block_id: self.pending_block_id.take(),
                });
                self.blocks.command_finished(line, code as i64);
            }
        }
    }

    // MARK: timers

    /// Once a second (`markIdleIfNeeded`): stuck, fallback completion, idle.
    pub fn tick(&mut self, now: f64) {
        if !matches!(self.status, CommandStatus::Running | CommandStatus::Stuck) {
            return;
        }
        // A provider can spend minutes thinking or running a tool silently.
        // Its ordered lifecycle owns completion while the CLI is still live.
        if self.last_feedback_at.is_some() && self.is_ai_running() {
            return;
        }
        if !self.has_pending_command {
            return;
        }
        let latest = self.last_input_at.max(self.last_output_at);
        let idle_for = now - latest;
        let running_for = now - self.command_started_at;
        if !self.has_shell_integration {
            if self.status == CommandStatus::Running
                && running_for >= self.config.stuck_seconds
                && now - self.last_output_at >= self.config.stuck_seconds
            {
                self.set_status(CommandStatus::Stuck);
                return;
            }
            if !self.prompt_seen_for_pending_command {
                if idle_for >= self.config.fallback_completion_seconds {
                    self.prompt_seen_for_pending_command = true;
                    if !self.command_finished_notified {
                        self.command_finished_notified = true;
                        self.events.push(ShellSessionEvent::CommandFinished {
                            command: self.pending_command_line.clone(),
                            exit_code: None,
                            duration: running_for.max(0.0),
                            from_shell_integration: false,
                            block_id: None,
                        });
                    }
                } else {
                    return;
                }
            }
        }
        if idle_for < self.config.idle_seconds {
            return;
        }
        self.set_status(self.completed_status());
        self.has_pending_command = false;
        self.prompt_seen_for_pending_command = false;
        self.pending_command_line = None;
    }

    /// The shell exited.
    pub fn mark_exited(&mut self) {
        self.set_status(CommandStatus::Exited);
    }

    // MARK: directory

    /// New directory from OSC 7, a `cd` line or the process table
    /// (`updateCurrentDirectory`). Returns true when it changed.
    pub fn update_directory(&mut self, path: &str, ctx: &dyn ShellContext) -> bool {
        let normalized = standardize_path(path);
        if normalized == self.current_directory {
            return false;
        }
        if !ctx.is_dir(&normalized) {
            log::debug!("rejected non-existent directory: {normalized}");
            return false;
        }
        self.current_directory = normalized.clone();
        self.events
            .push(ShellSessionEvent::DirectoryChanged(normalized));
        true
    }
}

/// Display name for a provider key (`displayName(fromProvider:)`).
pub fn display_name_from_provider(provider: Option<&str>) -> Option<String> {
    let normalized = resume::normalize_provider_name(provider?)?;
    if let Some(tool) = AI_TOOLS
        .iter()
        .find(|t| t.resume_provider_key == Some(normalized.as_str()))
    {
        return Some(tool.display_name.to_string());
    }
    let mut chars = normalized.chars();
    Some(match chars.next() {
        Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
        None => String::new(),
    })
}

/// `exit`, `logout` or `quit`, alone or followed by a space, `;`, `&` or `|`.
pub fn is_exit_command(line: &str) -> bool {
    let lowered = line.trim().to_lowercase();
    if lowered.is_empty() {
        return false;
    }
    ["exit", "logout", "quit"].iter().any(|command| {
        if lowered == *command {
            return true;
        }
        lowered
            .strip_prefix(command)
            .and_then(|rest| rest.chars().next())
            .is_some_and(|c| c.is_whitespace() || matches!(c, ';' | '&' | '|'))
    })
}

/// The directory of a `cd` line: `Some("")` for a bare `cd`, `None` for
/// other commands and `cd -` (`cdTarget`).
pub fn cd_target(line: &str) -> Option<String> {
    let tokens = tokenize(line);
    let index = command_detection::command_token_index(&tokens)?;
    if normalize_token(&tokens[index]) != "cd" {
        return None;
    }
    match tokens.get(index + 1) {
        None => Some(String::new()),
        Some(arg) if arg == "-" => None,
        Some(arg) => Some(arg.clone()),
    }
}

/// `URL(fileURLWithPath:).standardized.path`: `.` and `..` resolved,
/// repeated and trailing slashes removed (symlinks are kept).
pub fn standardize_path(path: &str) -> String {
    let mut parts: Vec<&str> = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                parts.pop();
            }
            other => parts.push(other),
        }
    }
    format!("/{}", parts.join("/"))
}

/// Strips CSI, OSC and DCS sequences and other `ESC x` pairs from typed
/// input (`sanitizeInputForBuffer`).
pub fn sanitize_input_for_buffer(text: &str) -> String {
    if !text.contains('\u{1b}') {
        return text.to_string();
    }
    let data = text.as_bytes();
    let mut out = Vec::with_capacity(data.len());
    let mut i = 0;
    while i < data.len() {
        let byte = data[i];
        if byte != 0x1b {
            out.push(byte);
            i += 1;
            continue;
        }
        i += 1;
        if i >= data.len() {
            break;
        }
        match data[i] {
            b'[' => {
                i += 1;
                while i < data.len() {
                    let c = data[i];
                    i += 1;
                    if (0x40..=0x7e).contains(&c) {
                        break;
                    }
                }
            }
            b']' | b'P' => {
                i += 1;
                while i < data.len() {
                    if data[i] == 0x07 {
                        i += 1;
                        break;
                    }
                    if data[i] == 0x1b && i + 1 < data.len() && data[i + 1] == b'\\' {
                        i += 2;
                        break;
                    }
                    i += 1;
                }
            }
            _ => i += 1,
        }
    }
    String::from_utf8(out).unwrap_or_else(|_| text.to_string())
}

/// Appends typed text to the line buffer, applying backspace (DEL and BS)
/// and Ctrl-U (kill line) so the captured line matches what was run.
pub(crate) fn apply_line_editing(buffer: &mut String, text: &str) {
    for ch in text.chars() {
        match ch {
            '\u{7f}' | '\u{8}' => {
                buffer.pop();
            }
            '\u{15}' => {
                let keep = buffer.rfind(['\n', '\r']).map(|i| i + 1).unwrap_or(0);
                buffer.truncate(keep);
            }
            '\u{3}' => {
                // Ctrl-C abandons the line.
                let keep = buffer.rfind(['\n', '\r']).map(|i| i + 1).unwrap_or(0);
                buffer.truncate(keep);
            }
            other => buffer.push(other),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Ctx;
    impl ShellContext for Ctx {
        fn is_dir(&self, path: &str) -> bool {
            matches!(path, "/" | "/tmp" | "/home/me" | "/home/me/src" | "/srv")
        }
        fn search_path(&self) -> Option<String> {
            Some(String::new())
        }
        fn home(&self) -> String {
            "/home/me".into()
        }
    }

    struct ToolCtx(std::path::PathBuf);
    impl ToolCtx {
        fn claude() -> Self {
            let root = std::env::temp_dir()
                .join(format!("chau7-next-shell-tool-{}", uuid::Uuid::new_v4()));
            std::fs::create_dir_all(&root).unwrap();
            let executable = root.join(if cfg!(windows) {
                "claude.exe"
            } else {
                "claude"
            });
            std::fs::write(&executable, b"fixture-only; never executed").unwrap();
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                std::fs::set_permissions(executable, std::fs::Permissions::from_mode(0o755))
                    .unwrap();
            }
            Self(root)
        }
    }
    impl ShellContext for ToolCtx {
        fn is_dir(&self, path: &str) -> bool {
            Ctx.is_dir(path)
        }
        fn search_path(&self) -> Option<String> {
            Some(self.0.to_string_lossy().into_owned())
        }
        fn home(&self) -> String {
            Ctx.home()
        }
    }
    impl Drop for ToolCtx {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    fn session() -> ShellSession {
        ShellSession::new(ShellSessionConfig::default(), "/home/me", 0.0)
    }

    #[test]
    fn pending_input_guard_tracks_fragments_editing_and_submission() {
        let mut s = session();
        assert!(!s.has_pending_input());
        s.handle_input("draft", false, &Ctx, 0.0);
        assert!(s.has_pending_input());
        s.handle_input("\u{15}", false, &Ctx, 0.1);
        assert!(!s.has_pending_input());
        s.handle_input("complete\rnext", false, &Ctx, 0.2);
        assert!(s.has_pending_input());
        s.handle_input("\u{3}", false, &Ctx, 0.3);
        assert!(!s.has_pending_input());
        s.handle_input("submitted\r", false, &Ctx, 0.4);
        assert!(!s.has_pending_input());
    }

    #[test]
    fn tab_reported_identity_replaces_a_stale_provider_for_any_agent() {
        let mut s = session();
        // A tab once saved as Codex without a session now runs Claude: the
        // provider gate of observed identities refuses Claude's session...
        s.restore_ai_metadata(Some("codex"), None);
        assert!(!s.can_adopt_observed_ai_identity("claude", "claude-session", 10.0, false));
        // ...but the tab's own hook names it, for any provider.
        assert!(s.adopt_tab_reported_ai_identity("claude", "claude-session", 10.0));
        assert_eq!(s.effective_provider().as_deref(), Some("claude"));
        assert_eq!(s.ai_session_id(), Some("claude-session"));
        assert!(!s.adopt_tab_reported_ai_identity("claude", "claude-session", 11.0));
        assert!(s.adopt_tab_reported_ai_identity("codex", "codex-thread", 12.0));
        assert_eq!(s.effective_provider().as_deref(), Some("codex"));
        assert_eq!(s.ai_session_id(), Some("codex-thread"));
        assert!(s.adopt_tab_reported_ai_identity("opencode", "opencode-session", 13.0));
        assert_eq!(s.effective_provider().as_deref(), Some("opencode"));
    }

    #[test]
    fn tab_reported_codex_hook_cannot_replace_a_live_parent_thread() {
        let mut s = session();
        s.track_resume_metadata("codex resume parent-thread");
        s.update_live_agent(Some("Codex"));
        assert!(s.is_ai_running());
        // A nested CLI can inherit this tab's environment. Its authoritative
        // hook is not proof that the foreground conversation changed.
        assert!(!s.adopt_tab_reported_ai_identity("codex", "child-thread", 10.0));
        assert_eq!(s.ai_session_id(), Some("parent-thread"));
    }

    #[test]
    fn primary_codex_can_change_threads_but_nested_and_unknown_processes_cannot() {
        let mut s = session();
        s.track_resume_metadata("codex resume parent-thread");
        s.update_live_agent(Some("Codex"));
        assert!(!s.adopt_tab_reported_ai_identity_from_process(
            "codex",
            "child-thread",
            10.0,
            Some(42),
            Some(7),
        ));
        assert!(!s.adopt_tab_reported_ai_identity_from_process(
            "codex",
            "child-thread",
            10.0,
            Some(42),
            None,
        ));
        assert_eq!(s.ai_session_id(), Some("parent-thread"));
        // /new inside the same foreground TUI is a legitimate identity change.
        assert!(s.adopt_tab_reported_ai_identity_from_process(
            "codex",
            "new-thread",
            11.0,
            Some(7),
            Some(7),
        ));
        assert_eq!(s.ai_session_id(), Some("new-thread"));
        // A fresh shell launch may bind a legacy hook after clearing its ID.
        s.track_resume_metadata("codex");
        assert_eq!(s.ai_session_id(), None);
        assert!(s.adopt_tab_reported_ai_identity("codex", "fresh-thread", 12.0));
    }

    #[test]
    fn nested_codex_cannot_bind_an_unidentified_parent() {
        let mut s = session();
        s.update_live_agent(Some("Codex"));
        assert!(!s.adopt_tab_reported_ai_identity_from_process(
            "codex",
            "child-thread",
            10.0,
            Some(42),
            Some(7),
        ));
        assert!(s.adopt_tab_reported_ai_identity_from_process(
            "codex",
            "parent-thread",
            10.0,
            Some(7),
            Some(7),
        ));
    }

    #[test]
    fn tab_reported_identity_ignores_invalid_old_and_exited_reports() {
        let mut s = session();
        s.restore_ai_metadata(Some("codex"), Some("codex-thread"));
        assert!(!s.adopt_tab_reported_ai_identity("not-an-agent", "id", 10.0));
        assert!(!s.adopt_tab_reported_ai_identity("claude", "bad id/with spaces", 10.0));
        assert!(!s.adopt_tab_reported_ai_identity("claude", "claude-session", f64::NAN));
        s.command_started_at = 50.0;
        // A late report from an agent that ran before the current command.
        assert!(!s.adopt_tab_reported_ai_identity("claude", "claude-session", 40.0));
        s.status = CommandStatus::Exited;
        assert!(!s.adopt_tab_reported_ai_identity("claude", "claude-session", 60.0));
        assert_eq!(s.ai_session_id(), Some("codex-thread"));
    }

    #[test]
    fn live_process_identity_repairs_restore_and_preserves_same_provider_resume() {
        let mut s = session();
        s.restore_ai_metadata(Some("claude"), Some("native-session"));
        assert!(!s.is_ai_running());
        assert!(s.update_live_agent(Some("Claude")));
        assert!(s.is_ai_running());
        assert_eq!(s.ai_session_id(), Some("native-session"));
        assert!(!s.update_live_agent(Some("Claude")));
        // A competing stale source cannot permanently override live ground truth.
        s.last_ai_provider = Some("codex".into());
        assert!(s.update_live_agent(Some("Claude")));
        assert_eq!(s.effective_provider().as_deref(), Some("claude"));
        s.last_ai_session_id = Some("native-session".into());
        assert!(s.update_live_agent(None));
        assert!(!s.is_ai_running());
        assert_eq!(s.ai_session_id(), Some("native-session"));
        assert_eq!(s.ai_display_app_name().as_deref(), Some("Claude"));
        assert!(s.update_live_agent(Some("Codex")));
        assert_eq!(s.effective_provider().as_deref(), Some("codex"));
        assert_eq!(s.ai_display_app_name().as_deref(), Some("Codex"));
        assert_eq!(s.ai_session_id(), None);
    }

    #[test]
    fn process_absence_preserves_current_swift_non_restored_shell_fallback() {
        let ctx = ToolCtx::claude();
        let mut s = session();
        s.handle_input("claude\r", false, &ctx, 0.0);
        assert!(s.is_ai_running());
        assert!(!s.update_live_agent(None));
        // No native match is not proof of absence (SSH/remote or missed argv).
        assert!(s.is_ai_running());
        assert_eq!(s.effective_provider().as_deref(), Some("claude"));
        let mut restored = session();
        restored.restore_ai_metadata(Some("claude"), Some("native-session"));
        assert!(!restored.update_live_agent(None));
        assert!(!restored.is_ai_running());
    }

    #[test]
    fn observed_identity_adoption_is_provider_time_and_native_session_fenced() {
        let ctx = ToolCtx::claude();
        let mut s = session();
        s.handle_input("claude\r", false, &ctx, 10.0);
        assert!(!s.adopt_observed_ai_identity("codex", "s1", 11.0, true));
        assert!(!s.adopt_observed_ai_identity("claude", "bad;id", 11.0, true));
        assert!(!s.adopt_observed_ai_identity("claude", "s1", 9.0, true));
        assert!(s.adopt_observed_ai_identity("claude", "s1", 11.0, false));
        assert_eq!(s.ai_session_id(), Some("s1"));
        assert!(!s.adopt_observed_ai_identity("claude", "s1", 12.0, false));
        assert!(!s.adopt_observed_ai_identity("claude", "s2", 12.0, false));
        assert!(s.adopt_observed_ai_identity("claude", "s2", 12.0, true));
        assert_eq!(s.ai_session_id(), Some("s2"));
        assert!(!s.adopt_observed_ai_identity("claude", "s3", f64::NAN, true));
        s.mark_exited();
        assert!(!s.adopt_observed_ai_identity("claude", "s3", 20.0, true));
    }

    #[test]
    fn config_defaults_and_env() {
        let c = ShellSessionConfig::default();
        assert_eq!(c.idle_seconds, 3.0);
        assert_eq!(c.fallback_completion_seconds, 60.0);
        let c = ShellSessionConfig::from_env(|k| match k {
            "CHAU7_IDLE_SECONDS" => Some("40".into()),
            _ => None,
        });
        assert_eq!(c.fallback_completion_seconds, 120.0);
        let c = ShellSessionConfig::from_env(|k| match k {
            "CHAU7_NEXT_COMMAND_FALLBACK_SECONDS" => Some("5".into()),
            _ => None,
        });
        assert_eq!(c.fallback_completion_seconds, 5.0);
    }

    #[test]
    fn cto_prefix_is_added_to_the_recorded_line_only() {
        let mut s = session();
        s.set_input_prefix(Some("/think".into()));
        s.handle_input("ls -la\r", false, &Ctx, 1.0);
        assert_eq!(s.pending_command(), Some("/think ls -la"));
        assert!(s.take_events().contains(&ShellSessionEvent::HistoryLine {
            command: "/think ls -la".into(),
            sensitive: false
        }));
        s.set_input_prefix(None);
        s.handle_input("pwd\r", false, &Ctx, 2.0);
        assert_eq!(s.pending_command(), Some("pwd"));
    }

    #[test]
    fn typed_line_without_osc133_runs_then_idles() {
        let mut s = session();
        s.handle_input("ls -la", false, &Ctx, 1.0);
        assert_eq!(s.status(), CommandStatus::Idle);
        s.handle_input("\r", false, &Ctx, 1.0);
        assert_eq!(s.status(), CommandStatus::Running);
        assert_eq!(s.pending_command(), Some("ls -la"));
        let events = s.take_events();
        assert!(events.contains(&ShellSessionEvent::HistoryLine {
            command: "ls -la".into(),
            sensitive: false
        }));
        assert!(events.iter().any(|e| matches!(
            e,
            ShellSessionEvent::CommandStarted {
                from_shell_integration: false,
                ..
            }
        )));
        // Quiet for less than the fallback: still running.
        s.tick(30.0);
        assert_eq!(s.status(), CommandStatus::Running);
        // Stuck first (30 s without output), then the fallback completion
        // and the idle delay make it idle.
        s.tick(62.0);
        assert_eq!(s.status(), CommandStatus::Stuck);
        s.tick(63.0);
        assert_eq!(s.status(), CommandStatus::Idle);
        assert!(s.take_events().iter().any(|e| matches!(
            e,
            ShellSessionEvent::CommandFinished {
                exit_code: None,
                ..
            }
        )));
    }

    #[test]
    fn stuck_after_30s_without_output() {
        let mut s = session();
        s.handle_input("sleep 100\r", false, &Ctx, 0.0);
        s.tick(31.0);
        assert_eq!(s.status(), CommandStatus::Stuck);
    }

    #[test]
    fn prompt_osc7_completes_heuristic_command() {
        let mut s = session();
        s.handle_output(b"\x1b]7;file://h/home/me\x07$ ", &Ctx, 0.0);
        s.handle_input("make\r", false, &Ctx, 0.0);
        s.take_events();
        s.handle_output(b"done\r\n\x1b]7;file://h/tmp\x07$ ", &Ctx, 2.0);
        assert_eq!(s.status(), CommandStatus::Idle);
        assert_eq!(s.current_directory(), "/tmp");
        let events = s.take_events();
        assert!(events.contains(&ShellSessionEvent::DirectoryChanged("/tmp".into())));
        assert!(
            events
                .iter()
                .any(|e| matches!(e, ShellSessionEvent::CommandFinished { .. }))
        );
        assert!(!s.is_shell_loading());
    }

    #[test]
    fn a_line_queued_during_shell_startup_is_not_finished_by_the_first_prompt() {
        let mut s = session();
        // A runtime launch typed into a new tab before its shell has started.
        s.handle_input("codex\r", false, &Ctx, 1.0);
        assert_eq!(s.status(), CommandStatus::Running);
        s.take_events();
        // zsh startup: its precmd reports the startup status, then a prompt.
        s.handle_mark(ShellMark::CommandFinished(0), 0, 1.2);
        s.handle_mark(ShellMark::PromptStart, 0, 1.2);
        assert_eq!(s.status(), CommandStatus::Running);
        assert!(!s.is_shell_loading());
        assert!(!s.is_at_prompt());
        assert!(
            !s.take_events()
                .iter()
                .any(|e| matches!(e, ShellSessionEvent::CommandFinished { .. }))
        );
        // The shell reads the queued line: its real lifecycle is reported.
        s.handle_mark(ShellMark::CommandStart, 1, 1.3);
        s.handle_mark(ShellMark::CommandExecuted, 1, 1.3);
        assert_eq!(s.status(), CommandStatus::Running);
        s.handle_mark(ShellMark::CommandFinished(0), 9, 30.0);
        s.handle_mark(ShellMark::PromptStart, 9, 30.0);
        assert!(s.is_at_prompt());
        let finished: Vec<_> = s
            .take_events()
            .into_iter()
            .filter(|e| matches!(e, ShellSessionEvent::CommandFinished { .. }))
            .collect();
        assert_eq!(finished.len(), 1);
    }

    #[test]
    fn a_line_queued_during_startup_survives_the_first_osc7_prompt() {
        let mut s = session();
        s.handle_input("codex\r", false, &Ctx, 0.0);
        s.take_events();
        s.handle_output(b"\x1b]7;file://h/home/me\x07$ ", &Ctx, 0.5);
        assert_eq!(s.status(), CommandStatus::Running);
        assert!(
            !s.take_events()
                .iter()
                .any(|e| matches!(e, ShellSessionEvent::CommandFinished { .. }))
        );
        s.handle_output(b"bye\r\n\x1b]7;file://h/home/me\x07$ ", &Ctx, 9.0);
        assert_ne!(s.status(), CommandStatus::Running);
        assert!(
            s.take_events()
                .iter()
                .any(|e| matches!(e, ShellSessionEvent::CommandFinished { .. }))
        );
    }

    #[test]
    fn a_shell_started_without_queued_input_finishes_startup_normally() {
        let mut s = session();
        s.handle_mark(ShellMark::CommandFinished(0), 0, 0.5);
        s.handle_mark(ShellMark::PromptStart, 0, 0.5);
        assert!(s.is_at_prompt());
        assert!(!s.is_shell_loading());
        assert_eq!(s.status(), CommandStatus::Idle);
    }

    #[test]
    fn osc133_drives_status_and_blocks() {
        let mut s = session();
        s.handle_mark(ShellMark::PromptStart, 0, 0.0);
        s.handle_input("cargo test\r", false, &Ctx, 1.0);
        // With OSC 133, typing does not mark running.
        assert_eq!(s.status(), CommandStatus::Idle);
        s.handle_mark(ShellMark::CommandStart, 1, 1.0);
        assert_eq!(s.status(), CommandStatus::Running);
        s.handle_mark(ShellMark::CommandExecuted, 1, 1.0);
        assert!(s.blocks().blocks()[0].is_running());
        assert_eq!(s.blocks().blocks()[0].command, "cargo test");
        let block_id = s.blocks().blocks()[0].id;
        s.handle_mark(ShellMark::CommandFinished(2), 9, 4.0);
        s.handle_mark(ShellMark::PromptStart, 9, 4.0);
        assert_eq!(s.status(), CommandStatus::Idle);
        let block = &s.blocks().blocks()[0];
        assert_eq!(block.exit_code, Some(2));
        assert_eq!(block.end_line, Some(9));
        let events = s.take_events();
        assert!(events.iter().any(|event| matches!(
            event,
            ShellSessionEvent::CommandStarted {
                from_shell_integration: true,
                block_id: Some(id),
                ..
            } if *id == block_id
        )));
        let finished: Vec<_> = events
            .into_iter()
            .filter(|e| matches!(e, ShellSessionEvent::CommandFinished { .. }))
            .collect();
        assert_eq!(finished.len(), 1);
        assert!(matches!(
            finished[0],
            ShellSessionEvent::CommandFinished {
                exit_code: Some(2),
                duration,
                block_id: Some(id),
                ..
            } if (duration - 3.0).abs() < 1e-9 && id == block_id
        ));
    }

    #[test]
    fn echo_off_lines_are_sensitive_and_not_tracked() {
        let mut s = session();
        s.handle_input("hunter2\r", true, &Ctx, 0.0);
        assert_eq!(s.pending_command(), None);
        assert!(s.take_events().contains(&ShellSessionEvent::HistoryLine {
            command: "hunter2".into(),
            sensitive: true
        }));
    }

    #[test]
    fn secrets_are_redacted_in_pending_command() {
        let mut s = session();
        s.handle_input("export API_KEY=abc\r", false, &Ctx, 0.0);
        assert!(!s.pending_command().unwrap().contains("abc"));
    }

    #[test]
    fn escape_sequences_and_backspaces_are_stripped() {
        let mut s = session();
        s.handle_input("lss\x7f -l\x1b[D\x1b[C\r", false, &Ctx, 0.0);
        assert_eq!(s.pending_command(), Some("ls -l"));
        assert_eq!(sanitize_input_for_buffer("a\x1b]0;t\x07b\x1bOc"), "abc");
    }

    #[test]
    fn cd_lines_update_directory() {
        let mut s = session();
        s.handle_input("cd src\r", false, &Ctx, 0.0);
        assert_eq!(s.current_directory(), "/home/me/src");
        s.handle_input("cd ..\r", false, &Ctx, 0.0);
        assert_eq!(s.current_directory(), "/home/me");
        s.handle_input("cd /nope\r", false, &Ctx, 0.0);
        assert_eq!(s.current_directory(), "/home/me");
        s.handle_input("cd /tmp\r", false, &Ctx, 0.0);
        s.handle_input("cd\r", false, &Ctx, 0.0);
        assert_eq!(s.current_directory(), "/home/me");
        s.handle_input("cd -\r", false, &Ctx, 0.0);
        assert_eq!(s.current_directory(), "/home/me");
        assert_eq!(cd_target("FOO=1 cd ~/x").as_deref(), Some("~/x"));
        assert_eq!(cd_target("ls"), None);
    }

    #[test]
    fn standardizes_paths() {
        assert_eq!(standardize_path("/a/./b/../c//"), "/a/c");
        assert_eq!(standardize_path("/.."), "/");
    }

    #[test]
    fn exit_commands() {
        assert!(is_exit_command("exit"));
        assert!(is_exit_command("logout"));
        assert!(is_exit_command("exit 1"));
        assert!(is_exit_command("quit;"));
        assert!(!is_exit_command("exiting"));
        assert!(!is_exit_command(""));
    }

    #[test]
    fn ai_detected_from_output_and_cleared_at_prompt() {
        let mut s = session();
        let pattern = OUTPUT_DETECTION_PATTERNS[0];
        s.handle_input("x\r", false, &Ctx, 0.0);
        s.handle_output(pattern.0.as_bytes(), &Ctx, 1.0);
        assert_eq!(s.active_app(), Some(pattern.1));
        assert!(s.is_ai_running());
        // Cooldown of 3 s: a prompt right away keeps it.
        s.handle_output(b"\x1b]7;file://h/home/me\x07", &Ctx, 2.0);
        assert_eq!(s.active_app(), Some(pattern.1));
        s.handle_output(b"\x1b]7;file://h/home/me\x07", &Ctx, 10.0);
        assert_eq!(s.active_app(), None);
    }

    #[test]
    fn waiting_for_input_while_ai_runs() {
        let mut s = session();
        let pattern = OUTPUT_DETECTION_PATTERNS[0];
        s.handle_input("x\r", false, &Ctx, 0.0);
        s.handle_output(pattern.0.as_bytes(), &Ctx, 1.0);
        s.handle_output(b"Proceed? [y/N]", &Ctx, 1.5);
        assert_eq!(s.status(), CommandStatus::WaitingForInput);
        // Answering marks it running again.
        s.handle_input("y\r", false, &Ctx, 2.0);
        assert_eq!(s.status(), CommandStatus::Running);
    }

    #[test]
    fn custom_rules_and_exit() {
        let config = ShellSessionConfig {
            custom_rules: vec![("mybot".into(), "".into())],
            ..Default::default()
        };
        let mut s = ShellSession::new(config, "/home/me", 0.0);
        s.handle_input("mybot --fast\r", false, &Ctx, 0.0);
        assert_eq!(s.active_app(), Some("Custom AI"));
        s.handle_input("exit\r", false, &Ctx, 1.0);
        assert_eq!(s.active_app(), None);
    }

    #[test]
    fn resume_metadata_kept_and_restored() {
        let mut s = session();
        s.track_resume_metadata("claude --resume abc123");
        assert_eq!(s.ai_provider(), Some("claude"));
        assert_eq!(s.ai_session_id(), Some("abc123"));
        let mut r = session();
        r.restore_ai_metadata(Some("codex"), Some("bad id!"));
        assert_eq!(r.ai_provider(), Some("codex"));
        assert_eq!(r.ai_session_id(), None);
        assert!(r.active_app().is_some());
        assert!(!r.is_ai_running());
        assert_eq!(display_name_from_provider(None), None);
    }

    #[test]
    fn process_close_warning_keeps_completed_live_agent_protected() {
        let mut s = session();
        s.restore_ai_metadata(Some("codex"), Some("thread-1"));
        s.update_live_agent(Some("Codex"));
        assert!(s.apply_agent_feedback("turn_completed", "codex", Some("thread-1"), 5.0));
        assert_eq!(s.status(), CommandStatus::Done);
        assert!(s.requires_process_close_warning(false));
        s.update_live_agent(None);
        assert!(!s.requires_process_close_warning(false));
    }

    #[test]
    fn process_close_warning_catches_children_without_shell_integration() {
        let s = session();
        assert_eq!(s.status(), CommandStatus::Idle);
        assert!(!s.has_shell_integration());
        assert!(s.requires_process_close_warning(true));
        assert!(!s.requires_process_close_warning(false));
    }

    #[test]
    fn process_close_warning_ignores_restored_metadata_and_exited_sessions() {
        let mut s = session();
        s.restore_ai_metadata(Some("codex"), Some("thread-1"));
        for status in [CommandStatus::Idle, CommandStatus::Done] {
            s.set_status(status);
            assert!(!s.requires_process_close_warning(false));
            assert!(s.requires_process_close_warning(true));
        }
        s.update_live_agent(Some("Codex"));
        s.set_status(CommandStatus::Exited);
        assert!(!s.requires_process_close_warning(true));
    }

    #[test]
    fn process_close_warning_preserves_busy_statuses() {
        let mut s = session();
        for status in [
            CommandStatus::Running,
            CommandStatus::WaitingForInput,
            CommandStatus::ApprovalRequired,
            CommandStatus::Stuck,
        ] {
            s.set_status(status);
            assert!(s.requires_process_close_warning(false));
        }
    }

    #[test]
    fn provider_lifecycle_survives_silence_and_rejects_reordered_completion() {
        for provider in ["codex", "claude"] {
            let mut s = session();
            s.handle_input(&format!("{provider}\r"), false, &Ctx, 1.0);
            s.restore_ai_metadata(Some(provider), Some("thread-1"));
            s.update_live_agent(Some(if provider == "codex" {
                "Codex"
            } else {
                "Claude"
            }));
            assert!(s.apply_agent_feedback("turn_started", provider, Some("thread-1"), 2.0));
            assert_eq!(s.agent_turn_started_at(), Some(2.0));
            s.tick(602.0);
            assert_eq!(s.status(), CommandStatus::Running);
            s.apply_agent_feedback("permission", provider, Some("thread-1"), 603.0);
            s.apply_agent_feedback("tool_start", provider, Some("thread-1"), 604.0);
            assert_eq!(s.status(), CommandStatus::ApprovalRequired);
            s.apply_agent_feedback("tool_complete", provider, Some("thread-1"), 605.0);
            assert_eq!(s.status(), CommandStatus::Running);
            s.apply_agent_feedback("turn_completed", provider, Some("thread-1"), 606.0);
            assert_eq!(s.status(), CommandStatus::Done);
            assert!(!s.apply_agent_feedback("tool_complete", provider, Some("thread-1"), 606.5));
            assert_eq!(s.status(), CommandStatus::Done);
            s.apply_agent_feedback("user_prompt", provider, Some("thread-1"), 607.0);
            assert_eq!(s.status(), CommandStatus::Running);
            assert_eq!(s.agent_turn_started_at(), Some(607.0));
            assert!(!s.apply_agent_feedback("turn_completed", provider, Some("thread-1"), 606.5));
            assert_eq!(s.status(), CommandStatus::Running);
            s.restore_ai_metadata(Some(provider), Some("thread-2"));
            assert_eq!(s.agent_turn_started_at(), None);
        }
    }

    #[test]
    fn explicit_approval_and_input_feedback_keep_independent_pending_state() {
        let mut s = session();
        s.restore_ai_metadata(Some("codex"), Some("thread-1"));
        assert!(s.apply_agent_feedback("approval_requested", "codex", Some("thread-1"), 1.0));
        assert_eq!(s.status(), CommandStatus::ApprovalRequired);
        s.apply_agent_feedback("user_input_requested", "codex", Some("thread-1"), 2.0);
        assert_eq!(s.status(), CommandStatus::ApprovalRequired);
        s.apply_agent_feedback("approval_resolved", "codex", Some("thread-1"), 3.0);
        assert_eq!(s.status(), CommandStatus::WaitingForInput);
        s.apply_agent_feedback("user_input_resolved", "codex", Some("thread-1"), 4.0);
        assert_eq!(s.status(), CommandStatus::Running);
        s.apply_agent_feedback("turn_completed", "codex", Some("thread-1"), 5.0);
        assert_eq!(s.status(), CommandStatus::Done);
        assert!(s.provider_has_authoritative_notifications);
        assert_eq!(CommandStatus::Done.as_str(), "done");
        assert_eq!(CommandStatus::ApprovalRequired.as_str(), "approvalRequired");
    }
    #[test]
    fn native_identity_changes_reset_pending_feedback_and_authoritative_fallback_guard() {
        let mut s = session();
        s.restore_ai_metadata(Some("codex"), Some("thread-1"));
        s.apply_agent_feedback("approval_requested", "codex", Some("thread-1"), 1.0);
        s.track_resume_metadata("codex resume thread-1");
        assert!(s.provider_has_authoritative_notifications);
        s.restore_ai_metadata(Some("codex"), Some("thread-2"));
        assert!(!s.provider_has_authoritative_notifications);
        assert!(!s.pending_feedback_approval);
        s.apply_agent_feedback("user_input_requested", "codex", Some("thread-2"), 2.0);
        s.track_resume_metadata("claude --resume another-thread");
        assert!(!s.provider_has_authoritative_notifications);
        assert!(!s.pending_feedback_input);
    }

    #[test]
    fn authoritative_feedback_rejects_stale_foreign_and_exited_session_events() {
        let mut s = session();
        s.restore_ai_metadata(Some("codex"), Some("thread-1"));
        s.last_input_at = 10.0;
        assert!(!s.apply_agent_feedback("approval_requested", "codex", Some("thread-1"), 9.0));
        assert!(!s.apply_agent_feedback("approval_requested", "claude", Some("thread-1"), 11.0));
        assert!(!s.apply_agent_feedback("approval_requested", "codex", Some("other"), 11.0));
        assert!(!s.apply_agent_feedback("unknown", "codex", Some("thread-1"), 11.0));
        assert!(!s.apply_agent_feedback("finished", "codex", Some("thread-1"), f64::NAN));
        assert!(!s.provider_has_authoritative_notifications);
        s.mark_exited();
        assert!(!s.apply_agent_feedback("user_input_requested", "codex", Some("thread-1"), 12.0));
        assert_eq!(s.status(), CommandStatus::Exited);
    }
    #[test]
    fn terminal_detection_distinguishes_explicit_approval_and_ignores_old_output() {
        let mut s = session();
        s.handle_input("mybot\r", false, &Ctx, 1.0);
        s.set_active_app(Some("Custom AI".into()));
        s.detect_waiting_for_input(b"This command needs your approval");
        assert_eq!(s.status(), CommandStatus::ApprovalRequired);
        s.set_status(CommandStatus::Running);
        s.detect_waiting_for_input(format!("Proceed? {}", "x".repeat(300)).as_bytes());
        assert_eq!(s.status(), CommandStatus::Running);
        s.detect_waiting_for_input(b"Input requested");
        assert_eq!(s.status(), CommandStatus::WaitingForInput);
    }

    #[test]
    fn terminal_detection_survives_invalid_utf8_in_chunk() {
        let mut s = session();
        s.handle_input("mybot\r", false, &Ctx, 1.0);
        s.set_active_app(Some("Custom AI".into()));
        // A split multi-byte character (first two bytes of a 3-byte one)
        // ahead of the prompt must not hide it.
        let mut chunk = b"\xe2\x94".to_vec();
        chunk.extend_from_slice(b" This command needs your approval");
        s.detect_waiting_for_input(&chunk);
        assert_eq!(s.status(), CommandStatus::ApprovalRequired);
    }

    #[test]
    fn exited_status() {
        let mut s = session();
        s.mark_exited();
        assert_eq!(s.status(), CommandStatus::Exited);
        assert_eq!(CommandStatus::WaitingForInput.as_str(), "waitingForInput");
    }
}

#[cfg(test)]
mod resume_typing_tests {
    use super::*;

    struct NoPath;
    impl ShellContext for NoPath {
        fn is_dir(&self, _: &str) -> bool {
            true
        }
        fn search_path(&self) -> Option<String> {
            None
        }
        fn home(&self) -> String {
            "/h".into()
        }
    }

    #[test]
    fn typed_resume_command_keeps_provider_and_session() {
        let mut s = ShellSession::new(ShellSessionConfig::default(), "/h", 0.0);
        for c in "claude --resume abc123".chars() {
            s.handle_input(&c.to_string(), false, &NoPath, 1.0);
        }
        s.handle_input("\r", false, &NoPath, 1.0);
        assert_eq!(s.ai_provider(), Some("claude"));
        assert_eq!(s.ai_session_id(), Some("abc123"));
    }
}
