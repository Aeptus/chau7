//! The command center behind the menu bar item (StatusBar module): the model
//! of the popover, free of any window or platform item so it can be tested.
//!
//! Ports `StatusBar/StatusBarController.swift` (`CommandCenterSessionSummary`,
//! `CommandCenterBadgeCounts`, `CommandCenterViewModel`, the status icon
//! rules, `flashAlert`) and the content of `StatusBarPanelView`
//! (hero zone, live sessions, activity feed, quick commands, footer).
//!
//! The app builds a [`PanelModel`] once a second from the live tabs, the
//! notification history, the recent AI events, the pinned snippets and the
//! monitoring switch; the popover only draws it, and [`menu_entries`] gives
//! the same content as a plain menu for hosts without a popover.

use chrono::{DateTime, Local, Utc};
use uuid::Uuid;

use crate::ai::event::{AiEvent, AiEventSource};
use crate::iso8601;
use crate::notifications::canonical::{self, NotificationSemanticKind};
use crate::notifications::history::HistoryEntry;
use crate::notifications::triggers;
use crate::shell_session::CommandStatus;

/// Width of the popover (`contentSize`), in points.
pub const POPOVER_WIDTH: f32 = 380.0;
/// Height of the popover (`contentSize`), in points.
pub const POPOVER_HEIGHT: f32 = 520.0;
/// The Live Sessions box shows at most this many sessions.
pub const MAX_LIVE_SESSIONS: usize = 5;
/// The Activity box shows at most this many entries.
pub const MAX_TIMELINE_ENTRIES: usize = 8;
/// Quick Commands shows this many pinned snippets.
pub const MAX_QUICK_COMMANDS: usize = 5;
/// The panel and the badge refresh this often.
pub const REFRESH_SECS: u64 = 1;

/// SF Symbol of the item when monitoring is off.
pub const ICON_OFF: &str = "bell";
/// SF Symbol of the item when monitoring is on, and while an alert flashes.
pub const ICON_ON: &str = "bell.badge.fill";
/// Tooltip and VoiceOver name of the item.
pub const ITEM_NAME: &str = crate::data_root::APP_NAME;

// ----- sessions ---------------------------------------------------------------

/// What an AI session in the list is doing (`CommandCenterSessionSummary.State`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SessionState {
    Running,
    WaitingInput,
    ApprovalRequired,
    Stuck,
}

impl SessionState {
    /// `CommandCenterSessionSummary.state(for:)`: idle and exited sessions are
    /// not listed.
    pub fn from_status(status: CommandStatus) -> Option<Self> {
        match status {
            CommandStatus::Running => Some(Self::Running),
            CommandStatus::WaitingForInput => Some(Self::WaitingInput),
            CommandStatus::ApprovalRequired => Some(Self::ApprovalRequired),
            CommandStatus::Stuck => Some(Self::Stuck),
            CommandStatus::Idle | CommandStatus::Done | CommandStatus::Exited => None,
        }
    }

    /// `LiveSessionCard.stateDescription`.
    pub fn description(self) -> &'static str {
        match self {
            Self::Running => "Working",
            Self::WaitingInput => "Waiting for input",
            Self::ApprovalRequired => "Approval required",
            Self::Stuck => "No recent output",
        }
    }

    /// `LiveSessionCard.stateIcon` (SF Symbol).
    pub fn icon(self) -> &'static str {
        match self {
            Self::Running => "gearshape.2",
            Self::WaitingInput => "bubble.left.and.exclamationmark.bubble.right",
            Self::ApprovalRequired => "hand.raised",
            Self::Stuck => "exclamationmark.triangle",
        }
    }

    /// Color of the status dot (`LiveSessionCard.statusColor`).
    pub fn dot_tone(self) -> Tone {
        match self {
            Self::Running => Tone::Orange,
            Self::WaitingInput => Tone::Blue,
            Self::ApprovalRequired => Tone::Red,
            Self::Stuck => Tone::Yellow,
        }
    }

    /// Color of the state text (`LiveSessionCard.stateColor`).
    pub fn text_tone(self) -> Tone {
        match self {
            Self::Running => Tone::Secondary,
            Self::WaitingInput => Tone::Blue,
            Self::ApprovalRequired => Tone::Red,
            Self::Stuck => Tone::Yellow,
        }
    }

    /// The dot of a working session has a ring (`isAnimated`).
    pub fn has_ring(self) -> bool {
        self == Self::Running
    }
}

/// A semantic color; the popover maps it to the theme.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tone {
    Blue,
    Orange,
    Yellow,
    Red,
    Green,
    Gray,
    Cyan,
    Purple,
    Secondary,
}

/// One terminal session of a tab, as the window reports it.
#[derive(Debug, Clone, PartialEq)]
pub struct SessionCandidate {
    pub tab_id: u64,
    pub pane_id: u64,
    /// `aiDisplayAppName`.
    pub ai_display_app_name: Option<String>,
    /// `effectiveAIProvider`.
    pub effective_ai_provider: Option<String>,
    /// `effectiveAISessionId`.
    pub effective_ai_session_id: Option<String>,
    pub status: CommandStatus,
    /// The tab's custom title.
    pub tab_custom_title: Option<String>,
    /// The title the tab bar shows (`displayTitle`).
    pub tab_display_title: String,
    pub current_directory: String,
    /// Last output of the session, seconds on the app clock.
    pub last_output: f64,
    /// Creation of the tab, seconds on the app clock.
    pub tab_created: f64,
}

/// An AI session worth a line in the panel (`CommandCenterSessionSummary`).
#[derive(Debug, Clone, PartialEq)]
pub struct SessionSummary {
    /// `<tab id>:<pane id>`.
    pub id: String,
    pub tab_id: u64,
    pub pane_id: u64,
    pub title: String,
    pub app_name: String,
    pub directory: Option<String>,
    /// Seconds on the app clock.
    pub last_activity: f64,
    pub state: SessionState,
}

impl SessionSummary {
    /// Last folder of the directory (`directoryName`).
    pub fn directory_name(&self) -> Option<String> {
        let dir = self.directory.as_deref()?.trim();
        if dir.is_empty() {
            return None;
        }
        let standardized = dir.trim_end_matches('/');
        if standardized.is_empty() {
            return Some("/".to_string());
        }
        let name = standardized.rsplit('/').next().unwrap_or(standardized);
        Some(if name.is_empty() {
            standardized.to_string()
        } else {
            name.to_string()
        })
    }

    /// The folder, unless it only repeats the title (`contextLabel`).
    pub fn context_label(&self) -> Option<String> {
        let name = self.directory_name()?;
        if name.to_lowercase() == self.title.to_lowercase() {
            None
        } else {
            Some(name)
        }
    }

    /// Only a session waiting for input needs attention.
    pub fn needs_attention(&self) -> bool {
        matches!(
            self.state,
            SessionState::WaitingInput | SessionState::ApprovalRequired
        )
    }

    /// The app name is shown unless it equals the title (`showAppName`).
    pub fn show_app_name(&self) -> bool {
        self.app_name.to_lowercase() != self.title.to_lowercase()
    }
}

/// Foundation's `capitalized`: first letter of each word upper case, the rest
/// lower case.
pub fn capitalized(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut start = true;
    for c in text.chars() {
        if c.is_alphanumeric() {
            if start {
                out.extend(c.to_uppercase());
            } else {
                out.extend(c.to_lowercase());
            }
            start = false;
        } else {
            out.push(c);
            start = true;
        }
    }
    out
}

/// `CommandCenterSessionSummary.displayName(for:)`.
pub fn display_name(candidate: &SessionCandidate) -> String {
    if let Some(name) = candidate
        .ai_display_app_name
        .as_deref()
        .map(str::trim)
        .filter(|n| !n.is_empty())
    {
        return name.to_string();
    }
    if let Some(provider) = candidate
        .effective_ai_provider
        .as_deref()
        .map(str::trim)
        .filter(|p| !p.is_empty())
    {
        return capitalized(provider);
    }
    "AI Session".to_string()
}

fn is_ai_session(candidate: &SessionCandidate) -> bool {
    candidate.ai_display_app_name.is_some()
        || candidate.effective_ai_provider.is_some()
        || candidate.effective_ai_session_id.is_some()
}

/// Title of the line: custom tab title, else the tab title unless it is
/// generic, else the folder, else the app (`collectLiveSessions`).
fn session_title(candidate: &SessionCandidate, app_name: &str) -> String {
    if let Some(custom) = candidate
        .tab_custom_title
        .as_deref()
        .map(str::trim)
        .filter(|t| !t.is_empty())
    {
        return custom.to_string();
    }
    let display = candidate.tab_display_title.trim();
    let generic = |other: &str| display.to_lowercase() == other.to_lowercase();
    if !display.is_empty() && !generic("Shell") && !generic("Editor") && !generic(app_name) {
        return display.to_string();
    }
    let directory = candidate
        .current_directory
        .trim_end_matches('/')
        .rsplit('/')
        .next()
        .unwrap_or("");
    if directory.is_empty() {
        app_name.to_string()
    } else {
        directory.to_string()
    }
}

/// `CommandCenterSessionSummary.collectLiveSessions`: sessions with an AI
/// tool that are running, waiting or stuck, most recent activity first.
pub fn collect_live_sessions(candidates: &[SessionCandidate]) -> Vec<SessionSummary> {
    let mut sessions: Vec<SessionSummary> = candidates
        .iter()
        .filter(|c| is_ai_session(c))
        .filter_map(|c| {
            let state = SessionState::from_status(c.status)?;
            let app_name = display_name(c);
            let title = session_title(c, &app_name);
            let directory = c.current_directory.trim();
            Some(SessionSummary {
                id: format!("{}:{}", c.tab_id, c.pane_id),
                tab_id: c.tab_id,
                pane_id: c.pane_id,
                title,
                app_name,
                directory: (!directory.is_empty()).then(|| directory.to_string()),
                last_activity: c.last_output.max(c.tab_created),
                state,
            })
        })
        .collect();
    sessions.sort_by(|a, b| {
        b.last_activity
            .partial_cmp(&a.last_activity)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    sessions
}

/// "now", "1 minute ago", "3 hours ago"... (`LiveSessionCard.timeAgo`).
pub fn time_ago(seconds: i64) -> String {
    if seconds < 60 {
        return "now".to_string();
    }
    let plural = |n: i64, unit: &str| {
        if n == 1 {
            format!("1 {unit} ago")
        } else {
            format!("{n} {unit}s ago")
        }
    };
    if seconds < 3600 {
        return plural(seconds / 60, "minute");
    }
    if seconds < 86400 {
        return plural(seconds / 3600, "hour");
    }
    plural(seconds / 86400, "day")
}

/// `CommandCenterViewModel.sessionCount`.
pub fn session_count(count: usize) -> String {
    if count == 1 {
        "1 session".to_string()
    } else {
        format!("{count} sessions")
    }
}

/// `CommandCenterViewModel.attentionSummary`.
pub fn attention_summary(count: usize) -> String {
    if count == 1 {
        "1 session needs attention".to_string()
    } else {
        format!("{count} sessions need attention")
    }
}

// ----- placement ----------------------------------------------------------------

/// Gap between the menu bar item and the popover, in points.
pub const POPOVER_GAP: f64 = 4.0;
/// Distance kept between the popover and the edge of the screen.
pub const POPOVER_MARGIN: f64 = 8.0;
/// Height of the menu bar, used when the item's frame is not known.
pub const MENU_BAR_HEIGHT: f64 = 24.0;

/// A rectangle: x, y, width, height.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// Top left corner of the popover in window coordinates (origin at the top
/// left of the main screen, y down), under the menu bar item.
///
/// `item` is the clicked status button's frame in AppKit screen coordinates
/// (bottom-left origin of the main screen, y up); `main_height` is the main
/// screen height; `screen_x` is the horizontal extent of the screen the item
/// is on. The popover is centered under the item and kept on the screen; with
/// no frame it sits at the right end of the menu bar.
pub fn popover_origin(item: Option<Rect>, main_height: f64, screen_x: (f64, f64)) -> (f64, f64) {
    let width = POPOVER_WIDTH as f64;
    let min_x = screen_x.0 + POPOVER_MARGIN;
    let max_x = (screen_x.1 - width - POPOVER_MARGIN).max(min_x);
    match item {
        Some(item) => {
            let x = item.x + item.width / 2.0 - width / 2.0;
            let top = main_height - item.y + POPOVER_GAP;
            (x.clamp(min_x, max_x), top)
        }
        None => (max_x, MENU_BAR_HEIGHT + POPOVER_GAP),
    }
}

// ----- icon and badge ---------------------------------------------------------

/// `CommandCenterBadgeCounts`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct BadgeCounts {
    pub live: usize,
    pub attention: usize,
}

/// What the menu bar item shows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StatusIcon {
    pub symbol: &'static str,
    /// Text next to the icon: the number of sessions waiting for input.
    pub title: String,
}

/// `updateBadgeAndIcon`: an outline bell when monitoring is off; a filled
/// badge bell when it is on, with the number of sessions waiting for input
/// next to it when there are any. An alert flash shows the filled bell.
pub fn status_icon(monitoring: bool, counts: BadgeCounts, alert: Option<bool>) -> StatusIcon {
    let mut icon = if !monitoring {
        StatusIcon {
            symbol: ICON_OFF,
            title: String::new(),
        }
    } else if counts.attention > 0 {
        StatusIcon {
            symbol: ICON_ON,
            title: counts.attention.to_string(),
        }
    } else {
        StatusIcon {
            symbol: ICON_ON,
            title: String::new(),
        }
    };
    if alert == Some(true) {
        icon.symbol = ICON_ON;
    } else if alert == Some(false) {
        icon.symbol = ICON_OFF;
    }
    icon
}

/// The icon during a "Menu bar alert" action (`flashAlert`): the alert bell
/// for `duration_secs`; when `animate`, it alternates with the normal icon
/// every 0.5 s, at most 10 times, then stays on the last one until the end.
/// `Some(true)` shows the alert bell, `Some(false)` the normal icon, `None`
/// means the flash is over.
pub fn flash_phase(duration_secs: u64, animate: bool, elapsed_ms: u64) -> Option<bool> {
    if elapsed_ms >= duration_secs * 1000 {
        return None;
    }
    if !animate {
        return Some(true);
    }
    let pulses = (duration_secs * 2).min(10);
    if pulses == 0 {
        return None;
    }
    let index = (elapsed_ms / 500).min(pulses - 1);
    Some(index.is_multiple_of(2))
}

// ----- activity feed ----------------------------------------------------------

/// One line of the Activity box (`UnifiedTimelineEntry`).
#[derive(Debug, Clone, PartialEq)]
pub struct TimelineEntry {
    pub id: Uuid,
    /// SF Symbol.
    pub icon: &'static str,
    pub tone: Tone,
    pub title: String,
    pub detail: String,
    pub timestamp: DateTime<Utc>,
    /// Dimmed in the list.
    pub is_rate_limited: bool,
}

/// `HH:mm:ss` in local time, as the rows show it.
pub fn timeline_time(timestamp: DateTime<Utc>) -> String {
    timestamp
        .with_timezone(&Local)
        .format("%H:%M:%S")
        .to_string()
}

fn event_kind(event: &AiEvent) -> NotificationSemanticKind {
    canonical::kind_with_canonical_type(
        Some(event.raw_type.as_deref().unwrap_or(&event.event_type)),
        event.notification_type.as_deref(),
        Some(&event.event_type),
    )
}

fn kind_from_raw(raw: &str) -> Option<NotificationSemanticKind> {
    NotificationSemanticKind::ALL
        .into_iter()
        .find(|k| k.raw_value() == raw)
}

fn event_icon(event: &AiEvent) -> &'static str {
    match event_kind(event) {
        NotificationSemanticKind::TaskFinished => return "text.bubble",
        NotificationSemanticKind::TaskFailed => return "exclamationmark.circle",
        NotificationSemanticKind::ToolFailed => return "wrench.and.screwdriver",
        NotificationSemanticKind::PermissionRequired => return "exclamationmark.triangle",
        NotificationSemanticKind::WaitingForInput => return "keyboard",
        NotificationSemanticKind::AttentionRequired => return "bell",
        NotificationSemanticKind::AuthenticationSucceeded => return "checkmark.shield",
        NotificationSemanticKind::Idle => return "moon",
        NotificationSemanticKind::Informational | NotificationSemanticKind::Unknown => {}
    }
    if crate::notifications::vocabulary::entry(&event.event_type).is_some() {
        return "bell";
    }
    match event.source.raw_value() {
        AiEventSource::TERMINAL_SESSION => "terminal.fill",
        AiEventSource::SHELL => "terminal",
        AiEventSource::HISTORY_MONITOR | AiEventSource::EVENTS_LOG => "clock.arrow.circlepath",
        AiEventSource::APP => "app.badge",
        AiEventSource::API_PROXY => "arrow.up.arrow.down",
        _ => "circle",
    }
}

fn event_tone(event: &AiEvent) -> Tone {
    match event_kind(event) {
        NotificationSemanticKind::TaskFinished => return Tone::Blue,
        NotificationSemanticKind::TaskFailed => return Tone::Red,
        NotificationSemanticKind::ToolFailed => return Tone::Orange,
        NotificationSemanticKind::PermissionRequired => return Tone::Yellow,
        NotificationSemanticKind::WaitingForInput | NotificationSemanticKind::AttentionRequired => {
            return Tone::Orange;
        }
        NotificationSemanticKind::AuthenticationSucceeded => return Tone::Green,
        NotificationSemanticKind::Idle => return Tone::Gray,
        NotificationSemanticKind::Informational | NotificationSemanticKind::Unknown => {}
    }
    Tone::Secondary
}

/// Readable name of a tool from the AI events (`friendlyToolName`).
pub fn friendly_tool_name(tool: &str) -> String {
    match tool.to_lowercase().as_str() {
        "write" => "file write".into(),
        "read" => "file read".into(),
        "edit" => "file edit".into(),
        "bash" => "shell command".into(),
        "glob" => "file search".into(),
        "grep" => "content search".into(),
        "webfetch" => "web fetch".into(),
        "websearch" => "web search".into(),
        "notebookedit" => "notebook edit".into(),
        "todowrite" => "task update".into(),
        "listtool" => "file listing".into(),
        "cli" => "CLI".into(),
        _ => tool.to_string(),
    }
}

/// Readable name of an event source (`friendlySourceName`).
pub fn friendly_source_name(source: &AiEventSource) -> String {
    match source.raw_value() {
        AiEventSource::CLAUDE_CODE => "Claude Code".into(),
        AiEventSource::CODEX => "Codex".into(),
        AiEventSource::CURSOR => "Cursor".into(),
        AiEventSource::WINDSURF => "Windsurf".into(),
        AiEventSource::COPILOT => "Copilot".into(),
        AiEventSource::AIDER => "Aider".into(),
        AiEventSource::CLINE => "Cline".into(),
        AiEventSource::CONTINUE_AI => "Continue".into(),
        AiEventSource::API_PROXY => "API Proxy".into(),
        AiEventSource::TERMINAL_SESSION => "Terminal".into(),
        AiEventSource::SHELL => "Shell".into(),
        AiEventSource::EVENTS_LOG => "Events".into(),
        AiEventSource::HISTORY_MONITOR => "History".into(),
        AiEventSource::APP => "Chau7".into(),
        other => other.to_string(),
    }
}

/// The same canonical notification vocabulary as the current Swift timeline.
fn event_title(event: &AiEvent) -> String {
    let source = source_display_name(event);
    if crate::notifications::vocabulary::entry(&event.event_type).is_none()
        && let Some(trigger) = triggers::trigger(&event.source, &event.event_type)
        && !trigger.is_wildcard()
    {
        return format!(
            "{source}: {}",
            crate::l10n::l(&trigger.label_key, &trigger.label_fallback)
        );
    }
    event.notification_title_with(Some(&source), None)
}

fn source_display_name(event: &AiEvent) -> String {
    let registered = crate::ai::tool_registry::AI_TOOLS
        .iter()
        .find(|tool| tool.event_source_raw_value == Some(event.source.raw_value()))
        .or_else(|| {
            let source = AiEventSource::for_provider(Some(&event.tool))?;
            crate::ai::tool_registry::AI_TOOLS
                .iter()
                .find(|tool| tool.event_source_raw_value == Some(source.raw_value()))
        });
    if let Some(tool) = registered {
        return match tool.event_source_raw_value {
            Some(AiEventSource::CLAUDE_CODE) => "Claude Code".into(),
            Some(AiEventSource::COPILOT) => "GitHub Copilot".into(),
            _ => tool.display_name.into(),
        };
    }
    let tool = event.tool.trim();
    if event.source.raw_value() == AiEventSource::UNKNOWN && !tool.is_empty() {
        return tool.into();
    }
    if let Some(source) = triggers::sources()
        .iter()
        .find(|source| source.id == event.source)
    {
        return crate::l10n::l(source.label_key, source.label_fallback);
    }
    if !tool.is_empty() {
        return tool.into();
    }
    capitalized(&event.source.raw_value().replace('_', " "))
}

/// `humanReadableType`: the title of a notification history row.
pub fn human_readable_type(kind: &str, semantic_kind: Option<&str>) -> String {
    if let Some(semantic) = semantic_kind.and_then(kind_from_raw) {
        match semantic {
            NotificationSemanticKind::TaskFinished => return "Finished responding".into(),
            NotificationSemanticKind::TaskFailed => return "Error occurred".into(),
            NotificationSemanticKind::ToolFailed => return "Tool failed".into(),
            NotificationSemanticKind::PermissionRequired => return "Needs permission".into(),
            NotificationSemanticKind::WaitingForInput => return "Waiting for input".into(),
            NotificationSemanticKind::AttentionRequired => return "Needs attention".into(),
            NotificationSemanticKind::AuthenticationSucceeded => return "Authenticated".into(),
            NotificationSemanticKind::Idle => return "Session idle".into(),
            NotificationSemanticKind::Informational => return "Information".into(),
            NotificationSemanticKind::Unknown => {}
        }
    }
    match kind {
        "finished" => "Finished responding".into(),
        "permission" => "Needs permission".into(),
        "waiting_input" => "Waiting for input".into(),
        "attention_required" => "Needs attention".into(),
        "idle" => "Session idle".into(),
        "tool_called" | "tool_start" => "Tool running".into(),
        "tool_complete" => "Tool done".into(),
        "session_end" => "Session ended".into(),
        "user_prompt" => "Prompt sent".into(),
        "error" | "failed" => "Error occurred".into(),
        "file_edited" => "File edited".into(),
        "command_finished" => "Command finished".into(),
        "api_call" => "API call".into(),
        "context_limit" => "Context limit reached".into(),
        "token_threshold" | "cost_threshold" => "Usage threshold".into(),
        other => capitalized(&other.replace('_', " ")),
    }
}

/// `extractFileName`: the last path component of a message when it looks like
/// a file ("/a/b/config.json" gives "config.json").
fn extract_file_name(message: &str) -> Option<String> {
    if !message.contains('/') {
        return None;
    }
    let last = message.rsplit('/').next()?;
    (!last.is_empty() && last.contains('.')).then(|| last.to_string())
}

fn compact_detail(message: &str) -> String {
    if let Some(file) = extract_file_name(message) {
        return file;
    }
    if message.chars().count() > 60 {
        return format!("{}...", message.chars().take(57).collect::<String>());
    }
    message.into()
}

fn event_detail(event: &AiEvent) -> String {
    let message = event.message.trim();
    if !message.is_empty() {
        return compact_detail(message);
    }
    for (path, key, fallback) in [
        (event.repo_path.as_deref(), "aiEvent.subtitle.repo", "Repo"),
        (
            event.directory.as_deref(),
            "aiEvent.subtitle.directory",
            "Dir",
        ),
    ] {
        if let Some(path) = path
            && let Some(name) = path.trim().trim_end_matches('/').rsplit('/').next()
            && !name.is_empty()
        {
            return format!("{}: {name}", crate::l10n::l(key, fallback));
        }
    }
    let body = event.notification_body();
    let body = body.trim();
    if !body.is_empty() && canonical::normalize(body) != canonical::normalize(&event.event_type) {
        return compact_detail(body);
    }
    source_display_name(event)
}

fn history_event(entry: &HistoryEntry) -> AiEvent {
    let mut event = AiEvent::new(
        AiEventSource::new(entry.source.clone()),
        &entry.event_type,
        &entry.tool,
        &entry.message,
        entry.timestamp.to_rfc3339(),
    );
    event.id = entry.id;
    event.raw_type = entry.raw_type.clone();
    event.notification_type = entry.notification_type.clone();
    event.tab_id = entry
        .resolved_tab_id
        .as_deref()
        .and_then(|id| Uuid::parse_str(id).ok());
    event.producer = entry.producer.clone();
    event
}

/// `unifiedTimeline`: the last notification history entries merged with the
/// last tool-agnostic events, duplicate UUIDs suppressed in favor of history,
/// newest first, at most 8. Distinct nearby events are preserved.
///
/// `history` is `NotificationHistory.recent(8)`; `recent_events` is the
/// accepted events, newest last.
pub fn unified_timeline(
    history: &[HistoryEntry],
    recent_events: &[AiEvent],
    now: DateTime<Utc>,
) -> Vec<TimelineEntry> {
    let start = recent_events.len().saturating_sub(MAX_TIMELINE_ENTRIES);
    let raw_events = &recent_events[start..];

    let mut entries: Vec<TimelineEntry> = history
        .iter()
        .map(|entry| {
            let event = history_event(entry);
            TimelineEntry {
                id: entry.id,
                icon: if entry.was_rate_limited {
                    "bell.slash"
                } else {
                    "bell.fill"
                },
                tone: if entry.was_rate_limited {
                    Tone::Gray
                } else {
                    Tone::Orange
                },
                title: event_title(&event),
                detail: event_detail(&event),
                timestamp: entry.timestamp,
                is_rate_limited: entry.was_rate_limited,
            }
        })
        .collect();

    let history_ids: std::collections::HashSet<_> = history.iter().map(|e| e.id).collect();
    for event in raw_events {
        let ts = iso8601::parse_iso8601(&event.ts).unwrap_or(now);
        let duplicate = history_ids.contains(&event.id);
        if duplicate {
            continue;
        }
        entries.push(TimelineEntry {
            id: event.id,
            icon: event_icon(event),
            tone: event_tone(event),
            title: event_title(event),
            detail: event_detail(event),
            timestamp: ts,
            is_rate_limited: false,
        });
    }

    entries.sort_by_key(|e| std::cmp::Reverse(e.timestamp));
    entries.truncate(MAX_TIMELINE_ENTRIES);
    entries
}

// ----- the panel --------------------------------------------------------------

/// Current Swift hero precedence and presentation.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HeroKind {
    ApprovalRequired,
    WaitingForInput,
    MonitoringPaused,
    Running,
    Quiet,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Hero {
    pub kind: HeroKind,
    pub title: String,
    pub detail: String,
}

/// Approval requests take priority over waiting sessions in the menu badge.
pub fn badge_counts(sessions: &[SessionSummary]) -> BadgeCounts {
    let approvals = sessions
        .iter()
        .filter(|s| s.state == SessionState::ApprovalRequired)
        .count();
    let waiting = sessions
        .iter()
        .filter(|s| s.state == SessionState::WaitingInput)
        .count();
    BadgeCounts {
        live: sessions.len(),
        attention: if approvals > 0 { approvals } else { waiting },
    }
}

/// Current Swift menu icon tooltip and accessibility status.
pub fn menu_status_description(sessions: &[SessionSummary], lang: crate::l10n::Lang) -> String {
    let approvals = sessions
        .iter()
        .filter(|s| s.state == SessionState::ApprovalRequired)
        .count();
    let waiting = sessions
        .iter()
        .filter(|s| s.state == SessionState::WaitingInput)
        .count();
    let (count, base, singular, plural) = if approvals > 0 {
        (
            approvals,
            "statusBar.icon.approval",
            "1 approval required",
            "%d approvals required",
        )
    } else if waiting > 0 {
        (
            waiting,
            "statusBar.icon.waitingInput",
            "1 session waiting for input",
            "%d sessions waiting for input",
        )
    } else if !sessions.is_empty() {
        (
            sessions.len(),
            "statusBar.icon.liveSession",
            "1 live session",
            "%d live sessions",
        )
    } else {
        return crate::l10n::localized_format(
            lang,
            "statusBar.icon.noLiveSessions",
            "monitoring active, no live sessions",
            &[],
        );
    };
    crate::l10n::localized_format(
        lang,
        &format!("{base}.{}", if count == 1 { "singular" } else { "plural" }),
        if count == 1 { singular } else { plural },
        &[crate::l10n::Arg::Int(count as i64)],
    )
}

pub fn prioritized_action_sessions(sessions: &[SessionSummary]) -> Vec<SessionSummary> {
    let mut sessions = sessions.to_vec();
    let priority = |state| match state {
        SessionState::ApprovalRequired => 0,
        SessionState::WaitingInput => 1,
        SessionState::Running => 2,
        SessionState::Stuck => 3,
    };
    sessions.sort_by(|a, b| {
        priority(a.state)
            .cmp(&priority(b.state))
            .then_with(|| b.last_activity.total_cmp(&a.last_activity))
    });
    sessions.truncate(MAX_LIVE_SESSIONS);
    sessions
}

fn hero_status(sessions: &[SessionSummary], monitoring: bool, lang: crate::l10n::Lang) -> Hero {
    let count = |state| sessions.iter().filter(|s| s.state == state).count();
    let approvals = count(SessionState::ApprovalRequired);
    let waiting = count(SessionState::WaitingInput);
    let running = count(SessionState::Running);
    let text = |key, fallback| crate::l10n::localized_format(lang, key, fallback, &[]);
    let counted = |base: &str, count: usize, singular: &str, plural: &str| {
        crate::l10n::localized_format(
            lang,
            &format!("{base}.{}", if count == 1 { "singular" } else { "plural" }),
            if count == 1 { singular } else { plural },
            &[crate::l10n::Arg::Int(count as i64)],
        )
    };
    if approvals > 0 {
        Hero {
            kind: HeroKind::ApprovalRequired,
            title: text("statusBar.hero.approvalRequired", "Approval required"),
            detail: counted(
                "statusBar.hero.approvalRequired.detail",
                approvals,
                "1 session needs approval",
                "%d sessions need approval",
            ),
        }
    } else if waiting > 0 {
        Hero {
            kind: HeroKind::WaitingForInput,
            title: text("statusBar.hero.waitingForInput", "Waiting for input"),
            detail: counted(
                "statusBar.hero.waitingForInput.detail",
                waiting,
                "1 session is waiting",
                "%d sessions are waiting",
            ),
        }
    } else if !monitoring {
        Hero {
            kind: HeroKind::MonitoringPaused,
            title: text("statusBar.hero.monitoringPaused", "Monitoring paused"),
            detail: text(
                "statusBar.hero.monitoringPaused.detail",
                "New AI activity is not being watched",
            ),
        }
    } else if running > 0 {
        Hero {
            kind: HeroKind::Running,
            title: counted(
                "statusBar.hero.running",
                running,
                "1 session running",
                "%d sessions running",
            ),
            detail: text(
                "statusBar.hero.running.detail",
                "No action needed right now",
            ),
        }
    } else {
        Hero {
            kind: HeroKind::Quiet,
            title: text("statusBar.hero.quiet", "Quiet"),
            detail: text("statusBar.hero.quiet.detail", "No live AI sessions"),
        }
    }
}

/// A pinned snippet in Quick Commands.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickCommand {
    pub id: String,
    pub title: String,
    pub body: String,
}

/// Everything the popover shows.
#[derive(Debug, Clone, PartialEq)]
pub struct PanelModel {
    pub hero: Hero,
    pub live_sessions: Vec<SessionSummary>,
    pub action_sessions: Vec<SessionSummary>,
    pub timeline: Vec<TimelineEntry>,
    pub quick_commands: Vec<QuickCommand>,
    pub monitoring: bool,
    pub version: String,
    pub counts: BadgeCounts,
}

/// Inputs of [`build_panel`].
pub struct PanelInputs<'a> {
    pub sessions: Vec<SessionSummary>,
    pub history: &'a [HistoryEntry],
    pub recent_events: &'a [AiEvent],
    /// Pinned snippets in the order they are listed.
    pub pinned: Vec<QuickCommand>,
    pub monitoring: bool,
    pub version: &'a str,
    pub now: DateTime<Utc>,
}

/// `refreshSessions` plus the sections of `StatusBarPanelView`.
pub fn build_panel(inputs: PanelInputs<'_>) -> PanelModel {
    build_panel_localized(inputs, crate::l10n::Lang::En)
}

/// Native panel and fallback menu use Swift's counted labels in the UI language.
pub fn build_panel_localized(inputs: PanelInputs<'_>, lang: crate::l10n::Lang) -> PanelModel {
    let counts = badge_counts(&inputs.sessions);
    let hero = hero_status(&inputs.sessions, inputs.monitoring, lang);
    let action_sessions = prioritized_action_sessions(&inputs.sessions);
    PanelModel {
        hero,
        action_sessions,
        live_sessions: inputs
            .sessions
            .into_iter()
            .take(MAX_LIVE_SESSIONS)
            .collect(),
        timeline: unified_timeline(inputs.history, inputs.recent_events, inputs.now),
        quick_commands: inputs.pinned.into_iter().take(MAX_QUICK_COMMANDS).collect(),
        monitoring: inputs.monitoring,
        version: inputs.version.to_string(),
        counts,
    }
}

/// What a click on a panel control does.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PanelCommand {
    /// Show the window and select the tab of a session ("Go", a session card).
    FocusSession {
        tab_id: u64,
    },
    /// Insert a pinned snippet in the selected tab, or copy it with no tab.
    RunSnippet(String),
    /// The Monitoring switch.
    SetMonitoring(bool),
    OpenSettings,
    OpenMonitoringSettings,
    OpenSnippetSettings,
    /// "Quit" after the confirmation.
    Quit,
}

/// One line of a flat menu with the same content as the panel, for hosts
/// that cannot show the popover.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MenuLine {
    /// A line that does nothing when chosen.
    Info(String),
    Command {
        title: String,
        command: PanelCommand,
        checked: bool,
    },
    Separator,
}

/// The panel as a menu: the hero, the live sessions, the quick commands, the
/// monitoring switch, All Settings and Quit.
pub fn menu_entries(panel: &PanelModel) -> Vec<MenuLine> {
    let mut lines = Vec::new();
    lines.push(MenuLine::Info(format!(
        "{} - {}",
        panel.hero.title, panel.hero.detail
    )));
    if !panel.action_sessions.is_empty() {
        lines.push(MenuLine::Separator);
        lines.push(MenuLine::Info("Action list".into()));
        for session in &panel.action_sessions {
            lines.push(MenuLine::Command {
                title: format!("{} - {}", session.title, session.state.description()),
                command: PanelCommand::FocusSession {
                    tab_id: session.tab_id,
                },
                checked: false,
            });
        }
    }
    if !panel.quick_commands.is_empty() {
        lines.push(MenuLine::Separator);
        lines.push(MenuLine::Info("Quick Commands".into()));
        for command in &panel.quick_commands {
            lines.push(MenuLine::Command {
                title: command.title.clone(),
                command: PanelCommand::RunSnippet(command.id.clone()),
                checked: false,
            });
        }
    }
    lines.push(MenuLine::Separator);
    lines.push(MenuLine::Command {
        title: "Monitoring".into(),
        command: PanelCommand::SetMonitoring(!panel.monitoring),
        checked: panel.monitoring,
    });
    lines.push(MenuLine::Command {
        title: "All Settings".into(),
        command: PanelCommand::OpenSettings,
        checked: false,
    });
    lines.push(MenuLine::Separator);
    lines.push(MenuLine::Info(format!("v{}", panel.version)));
    lines.push(MenuLine::Command {
        title: format!("Quit {}", crate::data_root::APP_NAME),
        command: PanelCommand::Quit,
        checked: false,
    });
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    fn candidate(tab: u64, status: CommandStatus, last_output: f64) -> SessionCandidate {
        SessionCandidate {
            tab_id: tab,
            pane_id: 1,
            ai_display_app_name: Some("Codex".into()),
            effective_ai_provider: Some("codex".into()),
            effective_ai_session_id: None,
            status,
            tab_custom_title: None,
            tab_display_title: "Codex".into(),
            current_directory: format!("/tmp/project{tab}"),
            last_output,
            tab_created: 0.0,
        }
    }

    fn summary(id: &str, state: SessionState, last: f64) -> SessionSummary {
        SessionSummary {
            id: id.into(),
            tab_id: 1,
            pane_id: 2,
            title: format!("Project {id}"),
            app_name: "Codex".into(),
            directory: Some(format!("/tmp/{id}")),
            last_activity: last,
            state,
        }
    }

    fn inputs(sessions: Vec<SessionSummary>) -> PanelInputs<'static> {
        PanelInputs {
            sessions,
            history: &[],
            recent_events: &[],
            pinned: Vec::new(),
            monitoring: true,
            version: "1.2.3",
            now: Utc::now(),
        }
    }

    #[test]
    fn hero_counts_all_sessions_before_card_truncation_in_every_language() {
        for lang in crate::l10n::Lang::ALL {
            for count in [1, 2, 3, 11] {
                for state in [
                    SessionState::Running,
                    SessionState::WaitingInput,
                    SessionState::ApprovalRequired,
                ] {
                    let sessions = (0..count)
                        .map(|n| summary(&format!("s-{n}"), state, 1.0))
                        .collect();
                    let panel = build_panel_localized(inputs(sessions), lang);
                    assert_eq!(panel.counts.live, count);
                    assert_eq!(panel.action_sessions.len(), count.min(MAX_LIVE_SESSIONS));
                    assert!(!panel.hero.title.is_empty());
                    assert!(!panel.hero.detail.is_empty());
                    assert_eq!(
                        panel.counts.attention,
                        if state == SessionState::Running {
                            0
                        } else {
                            count
                        }
                    );
                }
            }
        }
    }

    #[test]
    fn timeline_uses_adapter_semantics_and_preserves_raw_completion_provenance() {
        let mut e = AiEvent::new(
            AiEventSource::codex(),
            "waiting_input",
            "Codex",
            "Should I continue?",
            "2026-10-11T00:00:00Z",
        );
        e.raw_type = Some("agent-turn-complete".into());
        assert_eq!(event_kind(&e), NotificationSemanticKind::WaitingForInput);
        assert_eq!(event_icon(&e), "keyboard");
        assert_eq!(event_title(&e), "Codex: Waiting for input");
        assert_eq!(e.raw_type.as_deref(), Some("agent-turn-complete"));
        e.event_type = "tool_failed".into();
        e.raw_type = Some("tool-failed".into());
        assert_eq!(event_icon(&e), "wrench.and.screwdriver");
        assert_eq!(event_tone(&e), Tone::Orange);
        assert_eq!(event_title(&e), "Codex: Tool failed");
        assert_eq!(
            human_readable_type("tool_failed", Some("tool_failed")),
            "Tool failed"
        );
    }

    #[test]
    fn live_sessions_are_newest_first_and_capped_at_five() {
        let sessions = vec![
            summary("6", SessionState::Running, 95.0),
            summary("5", SessionState::WaitingInput, 90.0),
            summary("4", SessionState::Stuck, 80.0),
            summary("3", SessionState::Running, 70.0),
            summary("2", SessionState::Running, 60.0),
            summary("1", SessionState::Running, 50.0),
        ];
        let panel = build_panel(inputs(sessions));
        let ids: Vec<_> = panel.live_sessions.iter().map(|s| s.id.as_str()).collect();
        assert_eq!(ids, ["6", "5", "4", "3", "2"]);
        assert_eq!(panel.counts.live, 6);
    }

    #[test]
    fn hero_prioritizes_approval_then_waiting_then_pause_then_running_then_quiet() {
        let states = [
            SessionState::ApprovalRequired,
            SessionState::WaitingInput,
            SessionState::Running,
            SessionState::Stuck,
        ];
        let panel = |states: &[SessionState], monitoring| {
            let mut input = inputs(
                states
                    .iter()
                    .enumerate()
                    .map(|(i, state)| summary(&i.to_string(), *state, i as f64))
                    .collect(),
            );
            input.monitoring = monitoring;
            build_panel(input)
        };
        let approval = panel(&states, false);
        assert_eq!(approval.hero.kind, HeroKind::ApprovalRequired);
        assert_eq!(approval.hero.detail, "1 session needs approval");
        assert_eq!(approval.counts.attention, 1);
        assert_eq!(
            panel(&states[1..], false).hero.kind,
            HeroKind::WaitingForInput
        );
        assert_eq!(
            panel(&states[2..], false).hero.kind,
            HeroKind::MonitoringPaused
        );
        assert_eq!(panel(&states[2..], true).hero.kind, HeroKind::Running);
        assert_eq!(panel(&states[3..], true).hero.kind, HeroKind::Quiet);
        assert_eq!(panel(&[], true).hero.title, "Quiet");
    }

    #[test]
    fn icon_status_describes_primary_attention_kind() {
        let sessions = vec![
            summary("approval", SessionState::ApprovalRequired, 0.0),
            summary("waiting", SessionState::WaitingInput, 1.0),
            summary("running", SessionState::Running, 2.0),
        ];
        let lang = crate::l10n::Lang::En;
        assert_eq!(
            menu_status_description(&sessions, lang),
            "1 approval required"
        );
        assert_eq!(
            menu_status_description(&sessions[1..], lang),
            "1 session waiting for input"
        );
        assert_eq!(
            menu_status_description(&sessions[2..], lang),
            "1 live session"
        );
        assert_eq!(
            menu_status_description(&[], lang),
            "monitoring active, no live sessions"
        );
    }

    #[test]
    fn action_list_prioritizes_approval_waiting_running_stuck_then_activity() {
        let panel = build_panel(inputs(vec![
            summary("stuck", SessionState::Stuck, 999.0),
            summary("run-old", SessionState::Running, 100.0),
            summary("wait-old", SessionState::WaitingInput, 1.0),
            summary("approval", SessionState::ApprovalRequired, 0.0),
            summary("wait-new", SessionState::WaitingInput, 2.0),
            summary("run-new", SessionState::Running, 101.0),
        ]));
        let ids: Vec<_> = panel
            .action_sessions
            .iter()
            .map(|s| s.id.as_str())
            .collect();
        assert_eq!(
            ids,
            ["approval", "wait-new", "wait-old", "run-new", "run-old"]
        );
        assert_eq!(panel.counts.live, 6);
        assert_eq!(panel.counts.attention, 1);
    }

    #[test]
    fn quick_commands_are_the_first_five_pinned() {
        let mut input = inputs(Vec::new());
        input.pinned = (0..8)
            .map(|i| QuickCommand {
                id: format!("s{i}"),
                title: format!("Snippet {i}"),
                body: format!("echo {i}"),
            })
            .collect();
        let panel = build_panel(input);
        let ids: Vec<_> = panel.quick_commands.iter().map(|q| q.id.as_str()).collect();
        assert_eq!(ids, ["s0", "s1", "s2", "s3", "s4"]);
    }

    #[test]
    fn collect_skips_idle_exited_and_non_ai_sessions() {
        let mut shell = candidate(4, CommandStatus::Running, 1.0);
        shell.ai_display_app_name = None;
        shell.effective_ai_provider = None;
        let sessions = collect_live_sessions(&[
            candidate(1, CommandStatus::Running, 10.0),
            candidate(2, CommandStatus::Idle, 20.0),
            candidate(3, CommandStatus::Exited, 30.0),
            shell,
            candidate(5, CommandStatus::WaitingForInput, 50.0),
            candidate(6, CommandStatus::Stuck, 5.0),
        ]);
        let ids: Vec<_> = sessions.iter().map(|s| s.tab_id).collect();
        assert_eq!(ids, [5, 1, 6]);
        assert_eq!(sessions[0].id, "5:1");
        assert_eq!(sessions[0].state, SessionState::WaitingInput);
    }

    #[test]
    fn last_activity_is_never_before_the_tab_was_created() {
        let mut c = candidate(1, CommandStatus::Running, 3.0);
        c.tab_created = 40.0;
        assert_eq!(collect_live_sessions(&[c])[0].last_activity, 40.0);
    }

    #[test]
    fn title_prefers_custom_then_tab_title_then_folder() {
        let mut c = candidate(1, CommandStatus::Running, 1.0);
        c.tab_custom_title = Some("  My tab ".into());
        assert_eq!(collect_live_sessions(&[c.clone()])[0].title, "My tab");

        c.tab_custom_title = None;
        c.tab_display_title = "api server".into();
        assert_eq!(collect_live_sessions(&[c.clone()])[0].title, "api server");

        // The tab is named after the tool: the folder is used.
        c.tab_display_title = "codex".into();
        assert_eq!(collect_live_sessions(&[c.clone()])[0].title, "project1");

        c.tab_display_title = "Shell".into();
        c.current_directory = String::new();
        let s = &collect_live_sessions(&[c])[0];
        assert_eq!(s.title, "Codex");
        assert_eq!(s.directory, None);
    }

    #[test]
    fn display_name_falls_back_to_provider_then_generic() {
        let mut c = candidate(1, CommandStatus::Running, 1.0);
        c.ai_display_app_name = Some("  ".into());
        c.effective_ai_provider = Some("claude_code".into());
        assert_eq!(display_name(&c), "Claude_Code");
        c.effective_ai_provider = None;
        assert_eq!(display_name(&c), "AI Session");
    }

    #[test]
    fn directory_name_and_context_label() {
        let mut s = summary("a", SessionState::Running, 1.0);
        s.directory = Some(" /Users/me/work/api/ ".into());
        assert_eq!(s.directory_name().as_deref(), Some("api"));
        s.title = "Api".into();
        assert_eq!(s.context_label(), None);
        s.title = "Deploy".into();
        assert_eq!(s.context_label().as_deref(), Some("api"));
        s.directory = Some("  ".into());
        assert_eq!(s.directory_name(), None);
        s.directory = Some("/".into());
        assert_eq!(s.directory_name().as_deref(), Some("/"));
    }

    #[test]
    fn state_descriptions() {
        assert_eq!(SessionState::Running.description(), "Working");
        assert_eq!(
            SessionState::WaitingInput.description(),
            "Waiting for input"
        );
        assert_eq!(SessionState::Stuck.description(), "No recent output");
        assert_eq!(SessionState::from_status(CommandStatus::Idle), None);
        assert_eq!(SessionState::from_status(CommandStatus::Exited), None);
    }

    #[test]
    fn counts_in_words() {
        assert_eq!(session_count(1), "1 session");
        assert_eq!(session_count(4), "4 sessions");
        assert_eq!(attention_summary(1), "1 session needs attention");
        assert_eq!(attention_summary(2), "2 sessions need attention");
    }

    #[test]
    fn time_ago_units() {
        assert_eq!(time_ago(0), "now");
        assert_eq!(time_ago(59), "now");
        assert_eq!(time_ago(60), "1 minute ago");
        assert_eq!(time_ago(5 * 60 + 3), "5 minutes ago");
        assert_eq!(time_ago(3600), "1 hour ago");
        assert_eq!(time_ago(3 * 3600), "3 hours ago");
        assert_eq!(time_ago(86400), "1 day ago");
        assert_eq!(time_ago(3 * 86400), "3 days ago");
    }

    #[test]
    fn icon_states() {
        let none = BadgeCounts::default();
        let waiting = BadgeCounts {
            live: 3,
            attention: 2,
        };
        let off = status_icon(false, waiting, None);
        assert_eq!((off.symbol, off.title.as_str()), ("bell", ""));
        let clear = status_icon(true, none, None);
        assert_eq!(
            (clear.symbol, clear.title.as_str()),
            ("bell.badge.fill", "")
        );
        let busy = status_icon(true, waiting, None);
        assert_eq!((busy.symbol, busy.title.as_str()), ("bell.badge.fill", "2"));
    }

    #[test]
    fn alert_flash_uses_the_alert_bell() {
        assert_eq!(
            status_icon(false, BadgeCounts::default(), Some(true)).symbol,
            ICON_ON
        );
        assert_eq!(
            status_icon(true, BadgeCounts::default(), Some(false)).symbol,
            ICON_OFF
        );
    }

    #[test]
    fn flash_without_animation_is_steady_until_the_end() {
        assert_eq!(flash_phase(3, false, 0), Some(true));
        assert_eq!(flash_phase(3, false, 2999), Some(true));
        assert_eq!(flash_phase(3, false, 3000), None);
    }

    #[test]
    fn flash_pulses_every_half_second_at_most_ten_times() {
        assert_eq!(flash_phase(2, true, 0), Some(true));
        assert_eq!(flash_phase(2, true, 499), Some(true));
        assert_eq!(flash_phase(2, true, 500), Some(false));
        assert_eq!(flash_phase(2, true, 1000), Some(true));
        // Four pulses in 2 s: the last (index 3) is the normal icon, kept to the end.
        assert_eq!(flash_phase(2, true, 1999), Some(false));
        assert_eq!(flash_phase(2, true, 2000), None);
        // 30 s: still ten pulses, the tenth is the normal icon.
        assert_eq!(flash_phase(30, true, 4500), Some(false));
        assert_eq!(flash_phase(30, true, 20_000), Some(false));
        assert_eq!(flash_phase(0, true, 0), None);
    }

    fn event(kind: &str, tool: &str, message: &str, ts: DateTime<Utc>) -> AiEvent {
        AiEvent::new(
            AiEventSource::new(AiEventSource::CLAUDE_CODE),
            kind,
            tool,
            message,
            iso8601::format_iso8601(ts),
        )
    }

    fn history_entry(kind: &str, ts: DateTime<Utc>, limited: bool) -> HistoryEntry {
        let mut history = crate::notifications::history::NotificationHistory::default();
        let e = event(kind, "Claude Code", "done", ts);
        history.begin(&e, None, None, None);
        let mut entry = history.recent(1).remove(0);
        entry.timestamp = ts;
        entry.was_rate_limited = limited;
        entry
    }

    #[test]
    fn timeline_titles_icons_and_details() {
        let now = Utc::now();
        let events = vec![
            event("tool_start", "Write", "/src/main.rs", now),
            event(
                "permission",
                "Bash",
                "",
                now - chrono::Duration::seconds(10),
            ),
            event(
                "session_end",
                "",
                "bye",
                now - chrono::Duration::seconds(20),
            ),
        ];
        let timeline = unified_timeline(&[], &events, now);
        assert_eq!(timeline.len(), 3);
        assert_eq!(timeline[0].title, "Claude Code: Update");
        assert_eq!(timeline[0].detail, "main.rs");
        assert_eq!(timeline[0].icon, "circle");
        assert_eq!(timeline[1].title, "Claude Code: Permission needed");
        assert_eq!(timeline[1].icon, "exclamationmark.triangle");
        assert_eq!(timeline[1].tone, Tone::Yellow);
        assert_eq!(timeline[1].detail, "Needs your permission to continue.");
        assert_eq!(timeline[2].title, "Claude Code: Update");
        assert_eq!(timeline[2].tone, Tone::Secondary);
    }

    #[test]
    fn timeline_deduplicates_uuid_and_preserves_distinct_nearby_events() {
        let now = Utc::now();
        let history = vec![history_entry("finished", now, false)];
        let mut same = event(
            "finished",
            "Claude Code",
            "done",
            now + chrono::Duration::seconds(30),
        );
        same.id = history[0].id;
        let other = event("finished", "Claude Code", "done", now);
        let other_id = other.id;
        let timeline = unified_timeline(&history, &[same, other], now);
        assert_eq!(timeline.len(), 2);
        assert!(timeline.iter().any(|row| row.id == other_id));
        assert_eq!(
            timeline
                .iter()
                .filter(|row| row.id == history[0].id)
                .count(),
            1
        );
        assert_eq!(
            timeline
                .iter()
                .find(|row| row.id == history[0].id)
                .unwrap()
                .icon,
            "bell.fill"
        );
    }

    #[test]
    fn timeline_compacts_unicode_and_prefers_repo_subtitle() {
        let now = Utc::now();
        let mut event = event("waiting_input", "", "", now);
        event.repo_path = Some("/owned/repo/".into());
        event.directory = Some("/owned/directory".into());
        assert_eq!(event_detail(&event), "Repo: repo");
        event.message = "界".repeat(61);
        assert_eq!(event_detail(&event), format!("{}...", "界".repeat(57)));
        event.source = AiEventSource::new(AiEventSource::COPILOT);
        assert_eq!(source_display_name(&event), "GitHub Copilot");
    }

    #[test]
    fn rate_limited_entries_are_gray_and_dimmed() {
        let now = Utc::now();
        let timeline = unified_timeline(&[history_entry("finished", now, true)], &[], now);
        assert_eq!(timeline[0].icon, "bell.slash");
        assert_eq!(timeline[0].tone, Tone::Gray);
        assert!(timeline[0].is_rate_limited);
    }

    #[test]
    fn timeline_keeps_the_newest_eight() {
        let now = Utc::now();
        let events: Vec<_> = (0..12)
            .map(|i| {
                event(
                    "user_prompt",
                    "",
                    "",
                    now - chrono::Duration::seconds(i * 10),
                )
            })
            .collect();
        let timeline = unified_timeline(&[], &events, now);
        assert_eq!(timeline.len(), 8);
        assert!(
            timeline
                .windows(2)
                .all(|w| w[0].timestamp >= w[1].timestamp)
        );
    }

    #[test]
    fn human_readable_type_uses_semantic_kind_first() {
        assert_eq!(
            human_readable_type("whatever", Some("permission_required")),
            "Needs permission"
        );
        assert_eq!(
            human_readable_type("waiting_input", None),
            "Waiting for input"
        );
        assert_eq!(human_readable_type("some_new_type", None), "Some New Type");
        assert_eq!(
            human_readable_type("x", Some("informational")),
            "Information"
        );
    }

    #[test]
    fn clean_detail_shortens_messages() {
        assert_eq!(compact_detail("/a/b/config.json"), "config.json");
        assert_eq!(compact_detail("short"), "short");
        let long = "x".repeat(80);
        let cleaned = compact_detail(&long);
        assert_eq!(cleaned.chars().count(), 60);
        assert!(cleaned.ends_with("..."));
        assert_eq!(compact_detail(""), "");
    }

    #[test]
    fn menu_has_the_panel_content() {
        let mut input = inputs(vec![
            summary("w", SessionState::WaitingInput, 9.0),
            summary("r", SessionState::Running, 8.0),
        ]);
        input.pinned = vec![QuickCommand {
            id: "p".into(),
            title: "Deploy".into(),
            body: "make deploy".into(),
        }];
        let lines = menu_entries(&build_panel(input));
        assert_eq!(
            lines[0],
            MenuLine::Info("Waiting for input - 1 session is waiting".into())
        );
        assert!(lines.contains(&MenuLine::Command {
            title: "Project r - Working".into(),
            command: PanelCommand::FocusSession { tab_id: 1 },
            checked: false
        }));
        assert!(lines.contains(&MenuLine::Command {
            title: "Deploy".into(),
            command: PanelCommand::RunSnippet("p".into()),
            checked: false
        }));
        assert!(lines.contains(&MenuLine::Command {
            title: "Monitoring".into(),
            command: PanelCommand::SetMonitoring(false),
            checked: true
        }));
        assert_eq!(
            lines.last(),
            Some(&MenuLine::Command {
                title: format!("Quit {}", crate::data_root::APP_NAME),
                command: PanelCommand::Quit,
                checked: false
            })
        );
        assert!(lines.contains(&MenuLine::Info("v1.2.3".into())));
    }

    #[test]
    fn menu_when_all_clear() {
        let lines = menu_entries(&build_panel(inputs(Vec::new())));
        assert_eq!(
            lines[0],
            MenuLine::Info("Quiet - No live AI sessions".into())
        );
        assert!(!lines.contains(&MenuLine::Info("Action list".into())));
    }

    #[test]
    fn popover_is_centered_under_the_item() {
        // A 30 pt wide item whose window bottom is 24 pt below the top of a
        // 900 pt screen (AppKit y = 876).
        let item = Rect {
            x: 1000.0,
            y: 876.0,
            width: 30.0,
            height: 24.0,
        };
        let (x, y) = popover_origin(Some(item), 900.0, (0.0, 1440.0));
        assert_eq!(x, 1015.0 - f64::from(POPOVER_WIDTH) / 2.0);
        assert_eq!(y, 24.0 + POPOVER_GAP);
    }

    #[test]
    fn popover_stays_on_the_screen() {
        let right = Rect {
            x: 1420.0,
            y: 876.0,
            width: 20.0,
            height: 24.0,
        };
        let (x, _) = popover_origin(Some(right), 900.0, (0.0, 1440.0));
        assert_eq!(x, 1440.0 - f64::from(POPOVER_WIDTH) - POPOVER_MARGIN);
        let left = Rect { x: 2.0, ..right };
        let (x, _) = popover_origin(Some(left), 900.0, (0.0, 1440.0));
        assert_eq!(x, POPOVER_MARGIN);
    }

    #[test]
    fn popover_without_a_frame_is_at_the_right_of_the_menu_bar() {
        let (x, y) = popover_origin(None, 900.0, (0.0, 1440.0));
        assert_eq!(x, 1440.0 - f64::from(POPOVER_WIDTH) - POPOVER_MARGIN);
        assert_eq!(y, MENU_BAR_HEIGHT + POPOVER_GAP);
    }

    #[test]
    fn capitalized_matches_foundation() {
        assert_eq!(capitalized("claude"), "Claude");
        assert_eq!(capitalized("OPEN AI"), "Open Ai");
        assert_eq!(capitalized(""), "");
    }
}
