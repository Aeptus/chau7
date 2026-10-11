//! Port of `NotificationTriggerCatalog.swift`.
//!
//! The trigger catalog (non-AI triggers per source plus the AI source x type
//! matrix), display flags, the AI source group, trigger conditions and the
//! persisted trigger state with its 3-tier enable resolution.
//!
//! Trigger ids (`claude_code.finished`), group ids (`ai_coding.finished`) and
//! the JSON keys of [`NotificationTriggerState`] / [`TriggerCondition`] are
//! persisted in settings and must not change. The non-AI table was generated
//! mechanically from the Swift source.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::ops::BitOr;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};

use super::{AiEvent, AiEventSource};

/// Swift `NotificationTriggerCatalog.wildcardType`.
pub const WILDCARD_TYPE: &str = "*";

/// Swift `NotificationTriggerDisplay` option set (raw value is an `Int` bitmask).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub struct NotificationTriggerDisplay(pub i64);

impl NotificationTriggerDisplay {
    pub const SETTINGS: NotificationTriggerDisplay = NotificationTriggerDisplay(1 << 0);
    pub const ACTIVITY: NotificationTriggerDisplay = NotificationTriggerDisplay(1 << 1);
    pub const DEBUG: NotificationTriggerDisplay = NotificationTriggerDisplay(1 << 2);

    pub const fn new(raw_value: i64) -> Self {
        NotificationTriggerDisplay(raw_value)
    }

    pub const fn raw_value(self) -> i64 {
        self.0
    }

    /// True when every bit of `other` is set (Swift `OptionSet.contains`).
    pub const fn contains(self, other: NotificationTriggerDisplay) -> bool {
        self.0 & other.0 == other.0
    }
}

impl BitOr for NotificationTriggerDisplay {
    type Output = NotificationTriggerDisplay;
    fn bitor(self, rhs: Self) -> Self {
        NotificationTriggerDisplay(self.0 | rhs.0)
    }
}

const SETTINGS_AND_ACTIVITY: NotificationTriggerDisplay = NotificationTriggerDisplay(
    NotificationTriggerDisplay::SETTINGS.0 | NotificationTriggerDisplay::ACTIVITY.0,
);

/// Swift `NotificationTriggerSourceInfo`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotificationTriggerSourceInfo {
    pub id: AiEventSource,
    pub label_key: &'static str,
    pub label_fallback: &'static str,
    pub sort_order: i64,
}

/// Swift `NotificationTrigger`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotificationTrigger {
    pub id: String,
    pub source: AiEventSource,
    pub trigger_type: String,
    pub label_key: String,
    pub label_fallback: String,
    pub description_key: String,
    pub description_fallback: String,
    pub default_enabled: bool,
    pub display_contexts: NotificationTriggerDisplay,
}

impl NotificationTrigger {
    /// Normalizes `trigger_type` and derives the id, like the Swift init.
    #[allow(clippy::too_many_arguments)]
    pub fn new(
        source: impl Into<AiEventSource>,
        trigger_type: &str,
        label_key: &str,
        label_fallback: &str,
        description_key: &str,
        description_fallback: &str,
        default_enabled: bool,
        display_contexts: NotificationTriggerDisplay,
    ) -> Self {
        let source = source.into();
        let normalized = normalize_type(trigger_type);
        NotificationTrigger {
            id: trigger_id(&source, &normalized),
            source,
            trigger_type: normalized,
            label_key: label_key.to_string(),
            label_fallback: label_fallback.to_string(),
            description_key: description_key.to_string(),
            description_fallback: description_fallback.to_string(),
            default_enabled,
            display_contexts,
        }
    }

    pub fn is_wildcard(&self) -> bool {
        self.trigger_type == WILDCARD_TYPE
    }
}

/// Conditions that must be met for a trigger to fire. JSON keys:
/// `onlyWhenUnfocused`, `onlyWhenTabInactive`, `respectDND`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct TriggerCondition {
    /// Only fire if Chau7 is not the frontmost application.
    #[serde(rename = "onlyWhenUnfocused")]
    pub only_when_unfocused: bool,
    /// Only fire if the triggering tab is not the currently selected tab.
    #[serde(rename = "onlyWhenTabInactive")]
    pub only_when_tab_inactive: bool,
    /// Suppress this trigger when Focus/DND is active.
    #[serde(rename = "respectDND")]
    pub respect_dnd: bool,
}

impl Default for TriggerCondition {
    fn default() -> Self {
        TriggerCondition {
            only_when_unfocused: false,
            only_when_tab_inactive: true,
            respect_dnd: true,
        }
    }
}

/// Swift `NotificationTriggerGroup`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotificationTriggerGroup {
    pub id: String,
    pub label_key: String,
    pub label_fallback: String,
    pub sources: Vec<AiEventSource>,
    pub trigger_types: Vec<String>,
}

impl NotificationTriggerGroup {
    pub fn group_trigger_id(&self, trigger_type: &str) -> String {
        format!("{}.{}", self.id, trigger_type)
    }

    pub fn contains(&self, source: &AiEventSource) -> bool {
        self.sources.contains(source)
    }
}

/// Swift `GroupTriggerInfo`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GroupTriggerInfo {
    pub id: String,
    pub trigger_type: String,
    pub label_fallback: String,
    pub description_fallback: String,
    pub default_enabled: bool,
}

/// Persisted trigger enablement. JSON keys: `overrides` (required) and
/// `groupOverrides` (optional on read for backward compatibility).
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct NotificationTriggerState {
    pub overrides: BTreeMap<String, bool>,
    #[serde(rename = "groupOverrides", default)]
    pub group_overrides: BTreeMap<String, bool>,
}

impl NotificationTriggerState {
    pub fn new(overrides: BTreeMap<String, bool>, group_overrides: BTreeMap<String, bool>) -> Self {
        NotificationTriggerState {
            overrides,
            group_overrides,
        }
    }

    /// 3-tier resolution: per-trigger override, then group override, then the
    /// catalog default.
    pub fn is_enabled(&self, trigger: &NotificationTrigger) -> bool {
        if let Some(&per_trigger) = self.overrides.get(&trigger.id) {
            return per_trigger;
        }
        if let Some(group) = group_for(&trigger.source) {
            let group_id = group.group_trigger_id(&trigger.trigger_type);
            if let Some(&group_value) = self.group_overrides.get(&group_id) {
                return group_value;
            }
        }
        trigger.default_enabled
    }

    pub fn has_per_trigger_override(&self, trigger: &NotificationTrigger) -> bool {
        self.overrides.contains_key(&trigger.id)
    }

    pub fn is_group_enabled(
        &self,
        group_id: &str,
        trigger_type: &str,
        default_enabled: bool,
    ) -> bool {
        let key = format!("{group_id}.{trigger_type}");
        self.group_overrides
            .get(&key)
            .copied()
            .unwrap_or(default_enabled)
    }

    pub fn set_enabled(&mut self, enabled: bool, trigger: &NotificationTrigger) {
        self.overrides.insert(trigger.id.clone(), enabled);
    }

    pub fn set_group_enabled(&mut self, enabled: bool, group_id: &str, trigger_type: &str) {
        self.group_overrides
            .insert(format!("{group_id}.{trigger_type}"), enabled);
    }

    pub fn remove_group_override(&mut self, group_id: &str, trigger_type: &str) {
        self.group_overrides
            .remove(&format!("{group_id}.{trigger_type}"));
    }

    pub fn remove_override(&mut self, trigger: &NotificationTrigger) {
        self.overrides.remove(&trigger.id);
    }

    /// Drops overrides for unknown triggers and unknown group trigger ids,
    /// using the built-in catalog.
    pub fn normalize(&mut self) {
        self.normalize_using(all());
    }

    /// [`normalize`](Self::normalize) against an explicit catalog.
    pub fn normalize_using(&mut self, catalog: &[NotificationTrigger]) {
        let known: HashSet<&str> = catalog.iter().map(|t| t.id.as_str()).collect();
        self.overrides.retain(|k, _| known.contains(k.as_str()));
        let known_groups = all_group_trigger_ids();
        self.group_overrides.retain(|k, _| known_groups.contains(k));
    }
}

// MARK: - Catalog

/// Source metadata, already in ascending `sort_order`.
pub fn sources() -> &'static [NotificationTriggerSourceInfo] {
    static SOURCES: OnceLock<Vec<NotificationTriggerSourceInfo>> = OnceLock::new();
    SOURCES.get_or_init(|| {
        let rows: [(&'static str, &'static str, &'static str, i64); 16] = [
            // Core sources
            (
                AiEventSource::EVENTS_LOG,
                "notifications.source.eventsLog",
                "AI Events Log",
                0,
            ),
            (
                AiEventSource::TERMINAL_SESSION,
                "notifications.source.terminalSession",
                "Terminal Session",
                1,
            ),
            (
                AiEventSource::HISTORY_MONITOR,
                "notifications.source.historyMonitor",
                "History Monitor",
                2,
            ),
            // Shell source
            (
                AiEventSource::SHELL,
                "notifications.source.shell",
                "Shell",
                10,
            ),
            // AI coding apps (sorted together)
            (
                AiEventSource::CLAUDE_CODE,
                "notifications.source.claudeCode",
                "Claude Code",
                20,
            ),
            (
                AiEventSource::CODEX,
                "notifications.source.codex",
                "Codex",
                21,
            ),
            (
                AiEventSource::CURSOR,
                "notifications.source.cursor",
                "Cursor",
                22,
            ),
            (
                AiEventSource::WINDSURF,
                "notifications.source.windsurf",
                "Windsurf",
                23,
            ),
            (
                AiEventSource::COPILOT,
                "notifications.source.copilot",
                "GitHub Copilot",
                24,
            ),
            (
                AiEventSource::AIDER,
                "notifications.source.aider",
                "Aider",
                25,
            ),
            (
                AiEventSource::CLINE,
                "notifications.source.cline",
                "Cline",
                26,
            ),
            (
                AiEventSource::CONTINUE_AI,
                "notifications.source.continueAI",
                "Continue",
                27,
            ),
            (
                AiEventSource::RUNTIME,
                "notifications.source.runtime",
                "Runtime Agent",
                28,
            ),
            // App source
            (AiEventSource::APP, "notifications.source.app", "App", 100),
            // Catch-all sources (last)
            (
                AiEventSource::API_PROXY,
                "notifications.source.apiProxy",
                "API Proxy",
                200,
            ),
            (
                AiEventSource::UNKNOWN,
                "notifications.source.unknown",
                "Unknown",
                201,
            ),
        ];
        rows.into_iter()
            .map(
                |(id, label_key, label_fallback, sort_order)| NotificationTriggerSourceInfo {
                    id: AiEventSource::new(id),
                    label_key,
                    label_fallback,
                    sort_order,
                },
            )
            .collect()
    })
}

/// One row of the AI trigger matrix.
struct AiTriggerType {
    trigger_type: &'static str,
    camel_key: &'static str,
    label_suffix: &'static str,
    desc_suffix: &'static str,
    default_enabled: bool,
}

const fn ai_type(
    trigger_type: &'static str,
    camel_key: &'static str,
    label_suffix: &'static str,
    desc_suffix: &'static str,
    default_enabled: bool,
) -> AiTriggerType {
    AiTriggerType {
        trigger_type,
        camel_key,
        label_suffix,
        desc_suffix,
        default_enabled,
    }
}

/// Trigger types shared across all AI coding tools.
const AI_TRIGGER_TYPES: [AiTriggerType; 14] = [
    ai_type(
        "finished",
        "finished",
        "Response complete",
        "finished responding.",
        true,
    ),
    ai_type(
        "failed",
        "failed",
        "Task failed",
        "failed or exited with an error.",
        true,
    ),
    ai_type(
        "permission",
        "permission",
        "Permission request",
        "needs permission to continue.",
        true,
    ),
    ai_type(
        "waiting_input",
        "waitingInput",
        "Waiting for input",
        "is waiting for your input.",
        true,
    ),
    ai_type(
        "attention_required",
        "attentionRequired",
        "Needs attention",
        "needs your attention.",
        true,
    ),
    ai_type(
        "authentication_succeeded",
        "authenticationSucceeded",
        "Authentication complete",
        "completed authentication.",
        false,
    ),
    ai_type(
        "idle",
        "idle",
        "Session idle",
        "session appears idle.",
        false,
    ),
    ai_type(
        "token_threshold",
        "tokenThreshold",
        "Token threshold",
        "Token usage exceeded threshold.",
        false,
    ),
    ai_type(
        "cost_threshold",
        "costThreshold",
        "Cost threshold",
        "Session cost exceeded threshold.",
        false,
    ),
    ai_type(
        "tool_called",
        "toolCalled",
        "Tool called",
        "called a tool.",
        false,
    ),
    ai_type(
        "file_edited",
        "fileEdited",
        "File edited",
        "edited a file.",
        false,
    ),
    ai_type(
        "error",
        "error",
        "Error occurred",
        "encountered an error.",
        false,
    ),
    ai_type(
        "context_limit",
        "contextLimit",
        "Context limit",
        "approaching context window limit.",
        false,
    ),
    ai_type(
        WILDCARD_TYPE,
        "other",
        "Other events",
        "event types.",
        false,
    ),
];

/// AI sources that share the same trigger structure: (source, display name,
/// camelCase key for localization).
const AI_SOURCES: [(&str, &str, &str); 9] = [
    (AiEventSource::CLAUDE_CODE, "Claude Code", "claudeCode"),
    (AiEventSource::CODEX, "Codex", "codex"),
    (AiEventSource::CURSOR, "Cursor", "cursor"),
    (AiEventSource::WINDSURF, "Windsurf", "windsurf"),
    (AiEventSource::COPILOT, "GitHub Copilot", "copilot"),
    (AiEventSource::AIDER, "Aider", "aider"),
    (AiEventSource::CLINE, "Cline", "cline"),
    (AiEventSource::CONTINUE_AI, "Continue", "continueAI"),
    (AiEventSource::RUNTIME, "Runtime Agent", "runtime"),
];

/// All AI triggers generated from the source x type matrix.
fn ai_triggers() -> Vec<NotificationTrigger> {
    let mut out = Vec::new();
    for (source, name, camel) in AI_SOURCES.iter() {
        for tt in AI_TRIGGER_TYPES.iter() {
            let is_wildcard = tt.trigger_type == WILDCARD_TYPE;
            let label_fallback = if is_wildcard {
                format!("Other {name} events")
            } else {
                tt.label_suffix.to_string()
            };
            let description_fallback = if is_wildcard {
                format!("Any other {name} event types.")
            } else {
                format!("{name} {}", tt.desc_suffix)
            };
            out.push(NotificationTrigger::new(
                AiEventSource::new(*source),
                tt.trigger_type,
                &format!("notifications.trigger.{camel}.{}.label", tt.camel_key),
                &label_fallback,
                &format!("notifications.trigger.{camel}.{}.description", tt.camel_key),
                &description_fallback,
                tt.default_enabled,
                SETTINGS_AND_ACTIVITY,
            ));
        }
    }
    out
}

// MARK: - Non-AI Triggers (unique types and descriptions)

fn events_log_triggers() -> Vec<NotificationTrigger> {
    vec![
        NotificationTrigger::new(
            AiEventSource::EVENTS_LOG,
            "finished",
            "notifications.trigger.eventsLog.finished.label",
            "Task finished",
            "notifications.trigger.eventsLog.finished.description",
            "An AI event reports a completed task.",
            true,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::EVENTS_LOG,
            "failed",
            "notifications.trigger.eventsLog.failed.label",
            "Task failed",
            "notifications.trigger.eventsLog.failed.description",
            "An AI event reports a failure or error.",
            true,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::EVENTS_LOG,
            "needs_validation",
            "notifications.trigger.eventsLog.needsValidation.label",
            "Needs validation",
            "notifications.trigger.eventsLog.needsValidation.description",
            "An AI event requests review or confirmation.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::EVENTS_LOG,
            "permission",
            "notifications.trigger.eventsLog.permission.label",
            "Permission request",
            "notifications.trigger.eventsLog.permission.description",
            "An AI event requests permission to proceed.",
            true,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::EVENTS_LOG,
            "tool_complete",
            "notifications.trigger.eventsLog.toolComplete.label",
            "Tool complete",
            "notifications.trigger.eventsLog.toolComplete.description",
            "An AI event reports a tool finished executing.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::EVENTS_LOG,
            "session_end",
            "notifications.trigger.eventsLog.sessionEnd.label",
            "Session ended",
            "notifications.trigger.eventsLog.sessionEnd.description",
            "An AI event reports a session ended.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::EVENTS_LOG,
            "idle",
            "notifications.trigger.eventsLog.idle.label",
            "Command idle",
            "notifications.trigger.eventsLog.idle.description",
            "An AI event reports inactivity or waiting for input.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::EVENTS_LOG,
            "notification",
            "notifications.trigger.eventsLog.notification.label",
            "Custom notification",
            "notifications.trigger.eventsLog.notification.description",
            "An AI event requests a custom notification.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::EVENTS_LOG,
            "*",
            "notifications.trigger.eventsLog.other.label",
            "Other events",
            "notifications.trigger.eventsLog.other.description",
            "Any other AI event types not listed above.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
    ]
}

fn terminal_session_triggers() -> Vec<NotificationTrigger> {
    vec![
        NotificationTrigger::new(
            AiEventSource::TERMINAL_SESSION,
            "finished",
            "notifications.trigger.terminalSession.finished.label",
            "AI tool finished",
            "notifications.trigger.terminalSession.finished.description",
            "An AI tool finished in the terminal.",
            true,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::TERMINAL_SESSION,
            "permission",
            "notifications.trigger.terminalSession.permission.label",
            "AI tool needs permission",
            "notifications.trigger.terminalSession.permission.description",
            "An AI tool in the terminal needs permission to continue.",
            true,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::TERMINAL_SESSION,
            "idle",
            "notifications.trigger.terminalSession.idle.label",
            "Command idle",
            "notifications.trigger.terminalSession.idle.description",
            "Terminal command produced no output for the idle timeout.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::TERMINAL_SESSION,
            "failed",
            "notifications.trigger.terminalSession.failed.label",
            "Shell exited",
            "notifications.trigger.terminalSession.failed.description",
            "Terminal shell process exited.",
            true,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::TERMINAL_SESSION,
            "info",
            "notifications.trigger.terminalSession.info.label",
            "AI tool started",
            "notifications.trigger.terminalSession.info.description",
            "An AI tool started in the terminal.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
    ]
}

fn history_monitor_triggers() -> Vec<NotificationTrigger> {
    vec![
        NotificationTrigger::new(
            AiEventSource::HISTORY_MONITOR,
            "finished",
            "notifications.trigger.historyMonitor.finished.label",
            "Session completed (history)",
            "notifications.trigger.historyMonitor.finished.description",
            "AI session completed as detected by history file monitoring.",
            true,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::HISTORY_MONITOR,
            "idle",
            "notifications.trigger.historyMonitor.idle.label",
            "History idle",
            "notifications.trigger.historyMonitor.idle.description",
            "No new history entries for the idle timeout.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
    ]
}

fn shell_triggers() -> Vec<NotificationTrigger> {
    vec![
        NotificationTrigger::new(
            AiEventSource::SHELL,
            "command_finished",
            "notifications.trigger.shell.commandFinished.label",
            "Command finished",
            "notifications.trigger.shell.commandFinished.description",
            "A shell command completed execution.",
            true,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::SHELL,
            "command_failed",
            "notifications.trigger.shell.commandFailed.label",
            "Command failed",
            "notifications.trigger.shell.commandFailed.description",
            "A shell command exited with non-zero status.",
            true,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::SHELL,
            "exit_code_match",
            "notifications.trigger.shell.exitCodeMatch.label",
            "Exit code match",
            "notifications.trigger.shell.exitCodeMatch.description",
            "Command exited with a specific exit code.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::SHELL,
            "pattern_match",
            "notifications.trigger.shell.patternMatch.label",
            "Output pattern match",
            "notifications.trigger.shell.patternMatch.description",
            "Command output matched a configured pattern.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::SHELL,
            "long_running",
            "notifications.trigger.shell.longRunning.label",
            "Long-running command",
            "notifications.trigger.shell.longRunning.description",
            "Command has been running longer than threshold.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::SHELL,
            "process_started",
            "notifications.trigger.shell.processStarted.label",
            "Process started",
            "notifications.trigger.shell.processStarted.description",
            "A new process was started in the shell.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::SHELL,
            "process_ended",
            "notifications.trigger.shell.processEnded.label",
            "Process ended",
            "notifications.trigger.shell.processEnded.description",
            "A shell process has terminated.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::SHELL,
            "directory_changed",
            "notifications.trigger.shell.directoryChanged.label",
            "Directory changed",
            "notifications.trigger.shell.directoryChanged.description",
            "Working directory was changed (cd).",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::SHELL,
            "git_branch_changed",
            "notifications.trigger.shell.gitBranchChanged.label",
            "Git branch changed",
            "notifications.trigger.shell.gitBranchChanged.description",
            "Git branch was switched or changed.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::SHELL,
            "*",
            "notifications.trigger.shell.other.label",
            "Other shell events",
            "notifications.trigger.shell.other.description",
            "Any other shell event types.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
    ]
}

fn app_triggers() -> Vec<NotificationTrigger> {
    vec![
        NotificationTrigger::new(
            AiEventSource::APP,
            "launch",
            "notifications.trigger.app.launch.label",
            "App launched",
            "notifications.trigger.app.launch.description",
            "The app was launched.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::APP,
            "update_available",
            "notifications.trigger.app.updateAvailable.label",
            "Update available",
            "notifications.trigger.app.updateAvailable.description",
            "A new version is available.",
            true,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::APP,
            "file_conflict",
            "notifications.trigger.app.fileConflict.label",
            "File conflict detected",
            "notifications.trigger.app.fileConflict.description",
            "Multiple tabs modified the same file, risking merge conflicts.",
            true,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::APP,
            "memory_threshold",
            "notifications.trigger.app.memoryThreshold.label",
            "Memory threshold",
            "notifications.trigger.app.memoryThreshold.description",
            "Memory usage exceeded threshold.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::APP,
            "tab_opened",
            "notifications.trigger.app.tabOpened.label",
            "Tab opened",
            "notifications.trigger.app.tabOpened.description",
            "A new tab was opened.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::APP,
            "tab_closed",
            "notifications.trigger.app.tabClosed.label",
            "Tab closed",
            "notifications.trigger.app.tabClosed.description",
            "A tab was closed.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::APP,
            "window_focused",
            "notifications.trigger.app.windowFocused.label",
            "Window focused",
            "notifications.trigger.app.windowFocused.description",
            "App window gained focus.",
            false,
            NotificationTriggerDisplay::ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::APP,
            "window_unfocused",
            "notifications.trigger.app.windowUnfocused.label",
            "Window unfocused",
            "notifications.trigger.app.windowUnfocused.description",
            "App window lost focus.",
            false,
            NotificationTriggerDisplay::ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::APP,
            "file_modified",
            "notifications.trigger.app.fileModified.label",
            "File modified",
            "notifications.trigger.app.fileModified.description",
            "A watched file was modified.",
            false,
            NotificationTriggerDisplay::ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::APP,
            "docker_event",
            "notifications.trigger.app.dockerEvent.label",
            "Docker event",
            "notifications.trigger.app.dockerEvent.description",
            "A Docker container event occurred.",
            false,
            NotificationTriggerDisplay::ACTIVITY,
        ),
        NotificationTrigger::new(
            AiEventSource::APP,
            "*",
            "notifications.trigger.app.other.label",
            "Other app events",
            "notifications.trigger.app.other.description",
            "Any other app event types.",
            false,
            SETTINGS_AND_ACTIVITY,
        ),
    ]
}

fn api_proxy_triggers() -> Vec<NotificationTrigger> {
    vec![NotificationTrigger::new(
        AiEventSource::API_PROXY,
        "*",
        "notifications.trigger.apiProxy.other.label",
        "API Proxy events",
        "notifications.trigger.apiProxy.other.description",
        "Any event from the API proxy.",
        false,
        SETTINGS_AND_ACTIVITY,
    )]
}

fn unknown_source_triggers() -> Vec<NotificationTrigger> {
    vec![NotificationTrigger::new(
        AiEventSource::UNKNOWN,
        "*",
        "notifications.trigger.unknown.other.label",
        "Unknown source events",
        "notifications.trigger.unknown.other.description",
        "Events from unrecognized sources.",
        false,
        SETTINGS_AND_ACTIVITY,
    )]
}

// MARK: - Combined Catalog

struct Catalog {
    all: Vec<NotificationTrigger>,
    /// trigger id -> position in `all`
    index: HashMap<String, usize>,
    /// source -> position of its wildcard trigger (first wins)
    wildcard_index: HashMap<AiEventSource, usize>,
}

fn catalog() -> &'static Catalog {
    static CATALOG: OnceLock<Catalog> = OnceLock::new();
    CATALOG.get_or_init(|| {
        let mut all = Vec::new();
        all.extend(events_log_triggers());
        all.extend(terminal_session_triggers());
        all.extend(history_monitor_triggers());
        all.extend(shell_triggers());
        all.extend(ai_triggers());
        all.extend(app_triggers());
        all.extend(api_proxy_triggers());
        all.extend(unknown_source_triggers());

        let mut index = HashMap::new();
        for (i, t) in all.iter().enumerate() {
            index.insert(t.id.clone(), i);
        }
        let mut wildcard_index = HashMap::new();
        for (i, t) in all.iter().enumerate() {
            if t.is_wildcard() {
                wildcard_index.entry(t.source.clone()).or_insert(i);
            }
        }
        Catalog {
            all,
            index,
            wildcard_index,
        }
    })
}

/// Every trigger in the Swift catalog order.
pub fn all() -> &'static [NotificationTrigger] {
    &catalog().all
}

/// Lower-cased, trimmed trigger type.
pub fn normalize_type(trigger_type: &str) -> String {
    trigger_type.trim().to_lowercase()
}

/// `"<source raw value>.<normalized type>"`.
pub fn trigger_id(source: &AiEventSource, trigger_type: &str) -> String {
    format!("{}.{}", source.raw_value(), normalize_type(trigger_type))
}

/// Trigger for an event (`trigger(for:)`).
pub fn trigger_for_event(event: &AiEvent) -> Option<&'static NotificationTrigger> {
    trigger(&event.source, &event.event_type)
}

/// Exact match first, then the source's wildcard trigger.
pub fn trigger(source: &AiEventSource, trigger_type: &str) -> Option<&'static NotificationTrigger> {
    let c = catalog();
    let id = trigger_id(source, &normalize_type(trigger_type));
    c.index
        .get(&id)
        .or_else(|| c.wildcard_index.get(source))
        .map(|&i| &c.all[i])
}

pub fn triggers_for(source: &AiEventSource) -> Vec<&'static NotificationTrigger> {
    all().iter().filter(|t| &t.source == source).collect()
}

pub fn displayable_triggers(
    context: NotificationTriggerDisplay,
) -> Vec<&'static NotificationTrigger> {
    all()
        .iter()
        .filter(|t| t.display_contexts.contains(context))
        .collect()
}

// MARK: - Source Group Support

/// The "All AI Sources" group.
pub fn ai_coding_group() -> &'static NotificationTriggerGroup {
    &groups()[0]
}

pub fn groups() -> &'static [NotificationTriggerGroup] {
    static GROUPS: OnceLock<Vec<NotificationTriggerGroup>> = OnceLock::new();
    GROUPS.get_or_init(|| {
        vec![NotificationTriggerGroup {
            id: "ai_coding".to_string(),
            label_key: "notifications.group.aiCoding".to_string(),
            label_fallback: "All AI Sources".to_string(),
            sources: AI_SOURCES
                .iter()
                .map(|(s, _, _)| AiEventSource::new(*s))
                .collect(),
            trigger_types: AI_TRIGGER_TYPES
                .iter()
                .map(|t| t.trigger_type.to_string())
                .collect(),
        }]
    })
}

/// The group a source belongs to, if any.
pub fn group_for(source: &AiEventSource) -> Option<&'static NotificationTriggerGroup> {
    groups().iter().find(|g| g.contains(source))
}

/// All valid group trigger ids (used by `normalize`).
pub fn all_group_trigger_ids() -> &'static HashSet<String> {
    static IDS: OnceLock<HashSet<String>> = OnceLock::new();
    IDS.get_or_init(|| {
        let mut ids = HashSet::new();
        for group in groups() {
            for t in &group.trigger_types {
                ids.insert(group.group_trigger_id(t));
            }
        }
        ids
    })
}

/// Group trigger info for the settings UI.
pub fn group_trigger_infos(group: &NotificationTriggerGroup) -> Vec<GroupTriggerInfo> {
    group
        .trigger_types
        .iter()
        .filter_map(|t| {
            let rep = AI_TRIGGER_TYPES.iter().find(|r| r.trigger_type == t)?;
            Some(GroupTriggerInfo {
                id: group.group_trigger_id(t),
                trigger_type: t.clone(),
                label_fallback: rep.label_suffix.to_string(),
                description_fallback: format!("All AI sources: {}", rep.desc_suffix),
                default_enabled: rep.default_enabled,
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn find(id: &str) -> &'static NotificationTrigger {
        all().iter().find(|t| t.id == id).unwrap()
    }

    fn map<const N: usize>(entries: [(&str, bool); N]) -> BTreeMap<String, bool> {
        entries.iter().map(|(k, v)| (k.to_string(), *v)).collect()
    }

    fn ev(source: AiEventSource, event_type: &str) -> AiEvent {
        AiEvent::new(source, event_type, "", "", "t")
    }

    // Catalog Integrity

    #[test]
    fn test_catalog_has_unique_ids() {
        let ids: Vec<_> = all().iter().map(|t| t.id.as_str()).collect();
        assert_eq!(ids.iter().collect::<HashSet<_>>().len(), ids.len());
    }

    #[test]
    fn test_catalog_is_non_empty() {
        assert!(!all().is_empty());
    }

    #[test]
    fn test_catalog_size_matches_swift() {
        // 39 hand-written triggers + 9 AI sources x 14 types.
        assert_eq!(all().len(), 39 + 9 * 14);
    }

    #[test]
    fn test_all_triggers_have_labels() {
        for t in all() {
            assert!(!t.label_fallback.is_empty(), "{}", t.id);
            assert!(!t.label_key.is_empty(), "{}", t.id);
        }
    }

    #[test]
    fn test_all_triggers_have_descriptions() {
        for t in all() {
            assert!(!t.description_fallback.is_empty(), "{}", t.id);
            assert!(!t.description_key.is_empty(), "{}", t.id);
        }
    }

    // triggerId Format

    #[test]
    fn test_trigger_id_format() {
        assert_eq!(
            trigger_id(&AiEventSource::new(AiEventSource::CLAUDE_CODE), "finished"),
            "claude_code.finished"
        );
    }

    #[test]
    fn test_trigger_id_normalizes_type() {
        assert_eq!(
            trigger_id(
                &AiEventSource::new(AiEventSource::CLAUDE_CODE),
                "  FINISHED  "
            ),
            "claude_code.finished"
        );
    }

    // trigger(for:) via event

    #[test]
    fn test_trigger_lookup_matches_exact() {
        let t = trigger_for_event(&ev(
            AiEventSource::new(AiEventSource::TERMINAL_SESSION),
            "idle",
        ));
        assert_eq!(t.map(|t| t.id.as_str()), Some("terminal_session.idle"));
    }

    #[test]
    fn test_trigger_lookup_uses_wildcard_for_events_log() {
        let t = trigger_for_event(&ev(
            AiEventSource::new(AiEventSource::EVENTS_LOG),
            "custom_type",
        ))
        .unwrap();
        assert_eq!(t.trigger_type, WILDCARD_TYPE);
    }

    // trigger(source:type:) Direct Lookup

    #[test]
    fn test_trigger_direct_lookup_exact() {
        let t = trigger(&AiEventSource::new(AiEventSource::CLAUDE_CODE), "finished").unwrap();
        assert_eq!(t.source, AiEventSource::new(AiEventSource::CLAUDE_CODE));
        assert_eq!(t.trigger_type, "finished");
    }

    #[test]
    fn test_trigger_direct_lookup_waiting_input() {
        let t = trigger(&AiEventSource::new(AiEventSource::CODEX), "waiting_input").unwrap();
        assert_eq!(t.source, AiEventSource::new(AiEventSource::CODEX));
        assert_eq!(t.trigger_type, "waiting_input");
        assert!(t.default_enabled);
    }

    #[test]
    fn test_trigger_direct_lookup_case_insensitive() {
        let t = trigger(&AiEventSource::new(AiEventSource::CLAUDE_CODE), "FINISHED").unwrap();
        assert_eq!(t.trigger_type, "finished");
    }

    #[test]
    fn test_trigger_direct_lookup_trims_whitespace() {
        let t = trigger(
            &AiEventSource::new(AiEventSource::CLAUDE_CODE),
            "  finished  ",
        )
        .unwrap();
        assert_eq!(t.trigger_type, "finished");
    }

    #[test]
    fn test_trigger_direct_lookup_falls_back_to_wildcard() {
        let t = trigger(
            &AiEventSource::new(AiEventSource::CLAUDE_CODE),
            "unknown_type",
        )
        .unwrap();
        assert!(t.is_wildcard());
    }

    #[test]
    fn test_trigger_direct_lookup_no_wildcard_for_unknown_source() {
        assert!(
            trigger(
                &AiEventSource::new(AiEventSource::HISTORY_MONITOR),
                "nonexistent"
            )
            .is_none()
        );
    }

    // triggers(for:) Source Filtering

    #[test]
    fn test_triggers_for_source() {
        let shell = triggers_for(&AiEventSource::new(AiEventSource::SHELL));
        assert!(!shell.is_empty());
        for t in shell {
            assert_eq!(t.source, AiEventSource::new(AiEventSource::SHELL));
        }
    }

    #[test]
    fn test_triggers_for_source_history_monitor() {
        let triggers = triggers_for(&AiEventSource::new(AiEventSource::HISTORY_MONITOR));
        assert_eq!(triggers.len(), 2);
        let types: HashSet<_> = triggers.iter().map(|t| t.trigger_type.as_str()).collect();
        assert!(types.contains("finished"));
        assert!(types.contains("idle"));
    }

    #[test]
    fn test_triggers_for_source_events_log() {
        let triggers = triggers_for(&AiEventSource::new(AiEventSource::EVENTS_LOG));
        let types: Vec<_> = triggers.iter().map(|t| t.trigger_type.as_str()).collect();
        for expected in ["finished", "failed", "needs_validation", "*"] {
            assert!(types.contains(&expected), "{expected}");
        }
    }

    // displayableTriggers(in:)

    #[test]
    fn test_displayable_triggers_in_settings() {
        let triggers = displayable_triggers(NotificationTriggerDisplay::SETTINGS);
        assert!(!triggers.is_empty());
        for t in triggers {
            assert!(
                t.display_contexts
                    .contains(NotificationTriggerDisplay::SETTINGS)
            );
        }
    }

    #[test]
    fn test_displayable_triggers_in_activity() {
        let triggers = displayable_triggers(NotificationTriggerDisplay::ACTIVITY);
        assert!(!triggers.is_empty());
        for t in triggers {
            assert!(
                t.display_contexts
                    .contains(NotificationTriggerDisplay::ACTIVITY)
            );
        }
    }

    #[test]
    fn test_displayable_triggers_in_debug() {
        assert_eq!(
            displayable_triggers(NotificationTriggerDisplay::DEBUG).len(),
            0
        );
    }

    #[test]
    fn test_activity_only_trigger_not_in_settings() {
        let settings = displayable_triggers(NotificationTriggerDisplay::SETTINGS);
        assert!(!settings.iter().any(|t| t.id == "app.docker_event"));
        let activity = displayable_triggers(NotificationTriggerDisplay::ACTIVITY);
        assert!(activity.iter().any(|t| t.id == "app.docker_event"));
    }

    // NotificationTrigger Properties

    #[test]
    fn test_wildcard_trigger_is_wildcard() {
        let w = all()
            .iter()
            .find(|t| {
                t.source == AiEventSource::new(AiEventSource::EVENTS_LOG) && t.trigger_type == "*"
            })
            .unwrap();
        assert!(w.is_wildcard());
    }

    #[test]
    fn test_non_wildcard_trigger_is_not_wildcard() {
        let t = all()
            .iter()
            .find(|t| {
                t.source == AiEventSource::new(AiEventSource::EVENTS_LOG)
                    && t.trigger_type == "finished"
            })
            .unwrap();
        assert!(!t.is_wildcard());
    }

    #[test]
    fn test_trigger_equality() {
        assert_eq!(find("events_log.finished"), find("events_log.finished"));
    }

    // NotificationTriggerState

    #[test]
    fn test_trigger_state_defaults_use_catalog_values() {
        let t = find("events_log.finished");
        assert_eq!(
            NotificationTriggerState::default().is_enabled(t),
            t.default_enabled
        );
    }

    #[test]
    fn test_trigger_state_override_wins() {
        let t = find("events_log.failed");
        let mut state = NotificationTriggerState::default();
        state.set_enabled(!t.default_enabled, t);
        assert_eq!(state.is_enabled(t), !t.default_enabled);
    }

    #[test]
    fn test_trigger_state_disabled_override() {
        let t = all().iter().find(|t| t.default_enabled).unwrap();
        let mut state = NotificationTriggerState::default();
        state.set_enabled(false, t);
        assert!(!state.is_enabled(t));
    }

    #[test]
    fn test_trigger_state_enabled_override() {
        let t = all().iter().find(|t| !t.default_enabled).unwrap();
        let mut state = NotificationTriggerState::default();
        state.set_enabled(true, t);
        assert!(state.is_enabled(t));
    }

    #[test]
    fn test_normalize_drops_unknown_overrides() {
        let mut state =
            NotificationTriggerState::new(map([("unknown.trigger", false)]), BTreeMap::new());
        state.normalize();
        assert!(state.overrides.is_empty());
    }

    #[test]
    fn test_normalize_keeps_known_overrides() {
        let known = all()[0].id.clone();
        let mut state = NotificationTriggerState::new(
            map([(known.as_str(), false), ("bogus.id", true)]),
            BTreeMap::new(),
        );
        state.normalize();
        assert_eq!(state.overrides.len(), 1);
        assert!(state.overrides.contains_key(&known));
    }

    #[test]
    fn test_state_codable_round_trip() {
        let original = NotificationTriggerState::new(
            map([
                ("events_log.finished", false),
                ("claude_code.permission", true),
            ]),
            BTreeMap::new(),
        );
        let json = serde_json::to_string(&original).unwrap();
        let decoded: NotificationTriggerState = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, original);
    }

    // NotificationTriggerDisplay OptionSet

    #[test]
    fn test_display_option_set_settings() {
        let d = NotificationTriggerDisplay::SETTINGS;
        assert!(d.contains(NotificationTriggerDisplay::SETTINGS));
        assert!(!d.contains(NotificationTriggerDisplay::ACTIVITY));
    }

    #[test]
    fn test_display_option_set_combined() {
        let d = NotificationTriggerDisplay::SETTINGS | NotificationTriggerDisplay::ACTIVITY;
        assert!(d.contains(NotificationTriggerDisplay::SETTINGS));
        assert!(d.contains(NotificationTriggerDisplay::ACTIVITY));
        assert!(!d.contains(NotificationTriggerDisplay::DEBUG));
        assert_eq!(d.raw_value(), 3);
    }

    #[test]
    fn test_display_option_set_empty() {
        let d = NotificationTriggerDisplay::default();
        assert!(!d.contains(NotificationTriggerDisplay::SETTINGS));
        assert!(!d.contains(NotificationTriggerDisplay::ACTIVITY));
        assert!(!d.contains(NotificationTriggerDisplay::DEBUG));
    }

    // NotificationTriggerSourceInfo

    #[test]
    fn test_sources_cover_expected_sources() {
        let ids: Vec<_> = sources().iter().map(|s| s.id.clone()).collect();
        for expected in [
            AiEventSource::new(AiEventSource::EVENTS_LOG),
            AiEventSource::new(AiEventSource::TERMINAL_SESSION),
            AiEventSource::new(AiEventSource::CLAUDE_CODE),
            AiEventSource::new(AiEventSource::SHELL),
            AiEventSource::new(AiEventSource::APP),
        ] {
            assert!(ids.contains(&expected));
        }
    }

    #[test]
    fn test_sources_sorted_by_sort_order() {
        let orders: Vec<_> = sources().iter().map(|s| s.sort_order).collect();
        let mut sorted = orders.clone();
        sorted.sort();
        assert_eq!(orders, sorted);
    }

    #[test]
    fn test_sources_have_labels() {
        for s in sources() {
            assert!(!s.label_fallback.is_empty());
            assert!(!s.label_key.is_empty());
        }
    }

    #[test]
    fn test_sources_identifiable() {
        let s = &sources()[0];
        assert_eq!(s.id, s.id);
    }

    // Group Catalog Tests

    #[test]
    fn test_ai_coding_group_contains_all_sources() {
        let group = ai_coding_group();
        let expected = [
            AiEventSource::new(AiEventSource::CLAUDE_CODE),
            AiEventSource::new(AiEventSource::CODEX),
            AiEventSource::new(AiEventSource::CURSOR),
            AiEventSource::new(AiEventSource::WINDSURF),
            AiEventSource::new(AiEventSource::COPILOT),
            AiEventSource::new(AiEventSource::AIDER),
            AiEventSource::new(AiEventSource::CLINE),
            AiEventSource::new(AiEventSource::CONTINUE_AI),
            AiEventSource::new(AiEventSource::RUNTIME),
        ];
        assert_eq!(group.sources.len(), expected.len());
        for s in &expected {
            assert!(group.contains(s), "{}", s.raw_value());
        }
    }

    #[test]
    fn test_group_trigger_id_format() {
        let group = ai_coding_group();
        assert_eq!(group.group_trigger_id("finished"), "ai_coding.finished");
        assert_eq!(group.group_trigger_id("permission"), "ai_coding.permission");
    }

    #[test]
    fn test_group_for_ai_source() {
        assert_eq!(
            group_for(&AiEventSource::new(AiEventSource::CLAUDE_CODE)).map(|g| g.id.as_str()),
            Some("ai_coding")
        );
    }

    #[test]
    fn test_group_for_non_ai_source_is_nil() {
        assert!(group_for(&AiEventSource::new(AiEventSource::EVENTS_LOG)).is_none());
        assert!(group_for(&AiEventSource::new(AiEventSource::SHELL)).is_none());
        assert!(group_for(&AiEventSource::new(AiEventSource::APP)).is_none());
    }

    #[test]
    fn test_group_trigger_infos_count() {
        let group = ai_coding_group();
        let infos = group_trigger_infos(group);
        assert_eq!(infos.len(), group.trigger_types.len());
        for info in infos {
            assert!(info.id.starts_with("ai_coding."));
            assert!(!info.label_fallback.is_empty());
        }
    }

    #[test]
    fn test_all_group_trigger_ids() {
        let ids = all_group_trigger_ids();
        assert_eq!(ids.len(), ai_coding_group().trigger_types.len());
        assert!(ids.contains("ai_coding.finished"));
        assert!(ids.contains("ai_coding.permission"));
    }

    // 3-Tier Resolution Tests

    #[test]
    fn test_per_trigger_override_wins_over_group() {
        let t = trigger(&AiEventSource::new(AiEventSource::CLAUDE_CODE), "finished").unwrap();
        let mut state = NotificationTriggerState::new(
            map([(t.id.as_str(), false)]),
            map([("ai_coding.finished", true)]),
        );
        assert!(!state.is_enabled(t));
        state = NotificationTriggerState::new(
            map([(t.id.as_str(), true)]),
            map([("ai_coding.finished", false)]),
        );
        assert!(state.is_enabled(t));
    }

    #[test]
    fn test_group_override_wins_over_default() {
        let t = trigger(&AiEventSource::new(AiEventSource::CLAUDE_CODE), "finished").unwrap();
        let state =
            NotificationTriggerState::new(BTreeMap::new(), map([("ai_coding.finished", false)]));
        assert!(!state.is_enabled(t));
    }

    #[test]
    fn test_default_used_when_no_overrides() {
        let finished =
            trigger(&AiEventSource::new(AiEventSource::CLAUDE_CODE), "finished").unwrap();
        let failed = trigger(&AiEventSource::new(AiEventSource::CLAUDE_CODE), "failed").unwrap();
        let idle = trigger(&AiEventSource::new(AiEventSource::CLAUDE_CODE), "idle").unwrap();
        let state = NotificationTriggerState::default();
        assert!(state.is_enabled(finished));
        assert!(state.is_enabled(failed));
        assert!(!state.is_enabled(idle));
    }

    #[test]
    fn test_per_trigger_false_overrides_group_true() {
        let cursor = trigger(&AiEventSource::new(AiEventSource::CURSOR), "finished").unwrap();
        let claude = trigger(&AiEventSource::new(AiEventSource::CLAUDE_CODE), "finished").unwrap();
        let state = NotificationTriggerState::new(
            map([(cursor.id.as_str(), false)]),
            map([("ai_coding.finished", true)]),
        );
        assert!(!state.is_enabled(cursor));
        assert!(state.is_enabled(claude));
    }

    // Group Override Helpers

    #[test]
    fn test_has_per_trigger_override() {
        let t = trigger(&AiEventSource::new(AiEventSource::CLAUDE_CODE), "finished").unwrap();
        let mut state = NotificationTriggerState::default();
        assert!(!state.has_per_trigger_override(t));
        state.set_enabled(false, t);
        assert!(state.has_per_trigger_override(t));
    }

    #[test]
    fn test_is_group_enabled() {
        let mut state = NotificationTriggerState::default();
        assert!(state.is_group_enabled("ai_coding", "finished", true));
        assert!(!state.is_group_enabled("ai_coding", "idle", false));
        state.set_group_enabled(false, "ai_coding", "finished");
        assert!(!state.is_group_enabled("ai_coding", "finished", true));
    }

    #[test]
    fn test_remove_group_override() {
        let mut state = NotificationTriggerState::default();
        state.set_group_enabled(false, "ai_coding", "finished");
        assert!(!state.is_group_enabled("ai_coding", "finished", true));
        state.remove_group_override("ai_coding", "finished");
        assert!(state.is_group_enabled("ai_coding", "finished", true));
    }

    #[test]
    fn test_remove_override() {
        let t = trigger(&AiEventSource::new(AiEventSource::CLAUDE_CODE), "finished").unwrap();
        let mut state = NotificationTriggerState::default();
        state.set_enabled(false, t);
        assert!(state.has_per_trigger_override(t));
        state.remove_override(t);
        assert!(!state.has_per_trigger_override(t));
    }

    // Codable Backward Compat

    #[test]
    fn test_codable_round_trip_with_group_overrides() {
        let original = NotificationTriggerState::new(
            map([("claude_code.finished", false)]),
            map([("ai_coding.finished", true), ("ai_coding.idle", false)]),
        );
        let json = serde_json::to_string(&original).unwrap();
        assert!(json.contains("\"groupOverrides\""));
        let decoded: NotificationTriggerState = serde_json::from_str(&json).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn test_codable_backward_compat_no_group_overrides() {
        let json = r#"{"overrides":{"claude_code.finished":false}}"#;
        let decoded: NotificationTriggerState = serde_json::from_str(json).unwrap();
        assert_eq!(decoded.overrides, map([("claude_code.finished", false)]));
        assert!(decoded.group_overrides.is_empty());
    }

    #[test]
    fn test_state_requires_overrides_key() {
        // Swift decodes `overrides` with `decode`, so a missing key is an error.
        assert!(
            serde_json::from_str::<NotificationTriggerState>(r#"{"groupOverrides":{}}"#).is_err()
        );
    }

    // Normalize

    #[test]
    fn test_normalize_drops_orphaned_group_overrides() {
        let mut state = NotificationTriggerState::new(
            BTreeMap::new(),
            map([
                ("ai_coding.finished", true),
                ("bogus_group.finished", false),
            ]),
        );
        state.normalize();
        assert_eq!(state.group_overrides.len(), 1);
        assert!(state.group_overrides.contains_key("ai_coding.finished"));
        assert!(!state.group_overrides.contains_key("bogus_group.finished"));
    }

    #[test]
    fn test_normalize_keeps_valid_group_overrides() {
        let mut state = NotificationTriggerState::new(
            BTreeMap::new(),
            map([
                ("ai_coding.finished", true),
                ("ai_coding.permission", false),
            ]),
        );
        state.normalize();
        assert_eq!(state.group_overrides.len(), 2);
    }

    // Non-Group Triggers Unaffected by Group Overrides

    #[test]
    fn test_non_group_trigger_ignores_group_overrides() {
        let t = trigger(
            &AiEventSource::new(AiEventSource::SHELL),
            "command_finished",
        )
        .unwrap();
        let state = NotificationTriggerState::new(
            BTreeMap::new(),
            map([("ai_coding.command_finished", false)]),
        );
        assert_eq!(state.is_enabled(t), t.default_enabled);
    }

    // History Monitor Trigger Coverage

    #[test]
    fn test_history_monitor_finished_trigger_exists() {
        assert!(
            trigger(
                &AiEventSource::new(AiEventSource::HISTORY_MONITOR),
                "finished"
            )
            .is_some()
        );
    }

    #[test]
    fn test_history_monitor_finished_is_enabled_by_default() {
        assert!(
            trigger(
                &AiEventSource::new(AiEventSource::HISTORY_MONITOR),
                "finished"
            )
            .unwrap()
            .default_enabled
        );
    }

    #[test]
    fn test_ai_failed_trigger_is_enabled_by_default() {
        assert!(
            trigger(&AiEventSource::new(AiEventSource::RUNTIME), "failed")
                .unwrap()
                .default_enabled
        );
    }

    #[test]
    fn test_events_log_noise_triggers_are_disabled_by_default() {
        assert!(
            !trigger(
                &AiEventSource::new(AiEventSource::EVENTS_LOG),
                "needs_validation"
            )
            .unwrap()
            .default_enabled
        );
        assert!(
            !trigger(
                &AiEventSource::new(AiEventSource::EVENTS_LOG),
                "notification"
            )
            .unwrap()
            .default_enabled
        );
        assert!(
            !trigger(&AiEventSource::new(AiEventSource::EVENTS_LOG), "*")
                .unwrap()
                .default_enabled
        );
    }

    // Branches not covered by the Swift tests

    #[test]
    fn test_ai_matrix_strings_match_swift() {
        let t = find("claude_code.finished");
        assert_eq!(
            t.label_key,
            "notifications.trigger.claudeCode.finished.label"
        );
        assert_eq!(t.label_fallback, "Response complete");
        assert_eq!(t.description_fallback, "Claude Code finished responding.");
        let w = find("continue_ai.*");
        assert_eq!(w.label_key, "notifications.trigger.continueAI.other.label");
        assert_eq!(w.label_fallback, "Other Continue events");
        assert_eq!(w.description_fallback, "Any other Continue event types.");
        let infos = group_trigger_infos(ai_coding_group());
        assert_eq!(
            infos[0].description_fallback,
            "All AI sources: finished responding."
        );
        assert!(infos[0].default_enabled);
    }

    #[test]
    fn test_trigger_condition_defaults_and_json_keys() {
        let c = TriggerCondition::default();
        assert!(!c.only_when_unfocused);
        assert!(c.only_when_tab_inactive);
        assert!(c.respect_dnd);
        let json = serde_json::to_string(&c).unwrap();
        assert_eq!(
            json,
            r#"{"onlyWhenUnfocused":false,"onlyWhenTabInactive":true,"respectDND":true}"#
        );
        let back: TriggerCondition = serde_json::from_str(&json).unwrap();
        assert_eq!(back, c);
    }
}
