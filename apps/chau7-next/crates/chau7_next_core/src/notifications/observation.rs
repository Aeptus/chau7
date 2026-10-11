//! Typed, provider-scoped session observations. All clocks are injected.
use super::{
    canonical::{self, NotificationSemanticKind as Kind},
    repo_muting::normalized_root,
};
use crate::ai::{
    event::{AiEvent, AiEventReliability, AiEventSource},
    tool_registry::resume_provider_key_for,
};
use chrono::{DateTime, Utc};
use std::collections::BTreeSet;

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum State {
    Unknown,
    Running,
    Idle,
    WaitingForInput,
    AttentionRequired,
    PermissionRequired,
    Finished,
    Failed,
}
impl State {
    pub fn terminal(self) -> bool {
        matches!(self, Self::Finished | Self::Failed)
    }
    pub fn interactive(self) -> bool {
        self.specificity() > 0
    }
    pub fn specificity(self) -> u8 {
        match self {
            Self::PermissionRequired => 3,
            Self::AttentionRequired => 2,
            Self::WaitingForInput => 1,
            _ => 0,
        }
    }
    pub fn name(self) -> &'static str {
        match self {
            Self::Unknown => "unknown",
            Self::Running => "running",
            Self::Idle => "idle",
            Self::WaitingForInput => "waitingForInput",
            Self::AttentionRequired => "attentionRequired",
            Self::PermissionRequired => "permissionRequired",
            Self::Finished => "finished",
            Self::Failed => "failed",
        }
    }
}
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SourceClass {
    Runtime,
    ProviderHook,
    TerminalStructured,
    ShellLifecycle,
    ProviderFallback,
    HistoryFallback,
    TerminalTextHeuristic,
    App,
    Generic,
    Unknown,
}
impl SourceClass {
    fn precedence(self) -> u16 {
        match self {
            Self::Runtime => 600,
            Self::ProviderHook => 500,
            Self::TerminalStructured => 350,
            Self::ShellLifecycle => 250,
            Self::ProviderFallback => 190,
            Self::HistoryFallback => 160,
            Self::TerminalTextHeuristic => 80,
            Self::App => 70,
            Self::Generic => 60,
            Self::Unknown => 0,
        }
    }
}
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord)]
pub struct Alias {
    pub scope: u8,
    pub provider: String,
    pub value: String,
}
impl Alias {
    pub fn scoped_key(&self) -> String {
        format!(
            "{}:{}",
            ["session", "tab", "dir", "event"][usize::from(self.scope)],
            self.value
        )
    }
    pub fn key(&self) -> String {
        format!("{}|{}", self.provider, self.scoped_key())
    }
}
pub fn provider(event: &AiEvent) -> String {
    match event.source.raw_value() {
        AiEventSource::CLAUDE_CODE => "claude".into(),
        AiEventSource::CODEX => "codex".into(),
        source => {
            let value = resume_provider_key_for(&event.tool)
                .unwrap_or(source)
                .trim()
                .to_lowercase();
            if value.is_empty() {
                "unknown".into()
            } else {
                value
            }
        }
    }
}
pub fn aliases(event: &AiEvent) -> BTreeSet<Alias> {
    let provider = provider(event);
    let mut values = BTreeSet::new();
    if let Some(value) = event
        .session_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        values.insert(Alias {
            scope: 0,
            provider: provider.clone(),
            value: value.to_lowercase(),
        });
    }
    if let Some(value) = event.tab_id {
        values.insert(Alias {
            scope: 1,
            provider: provider.clone(),
            value: value.to_string(),
        });
    }
    if let Some(value) = event
        .directory
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        values.insert(Alias {
            scope: 2,
            provider: provider.clone(),
            value: normalized_root(value)
                .map(|path| path.to_string_lossy().to_lowercase())
                .unwrap_or_else(|| value.to_lowercase()),
        });
    }
    if values.is_empty() {
        values.insert(Alias {
            scope: 3,
            provider,
            value: event.id.to_string(),
        });
    }
    values
}
pub fn source_class(event: &AiEvent) -> SourceClass {
    use SourceClass as S;
    match event.source.raw_value() {
        AiEventSource::RUNTIME => S::Runtime,
        AiEventSource::SHELL => S::ShellLifecycle,
        AiEventSource::HISTORY_MONITOR | AiEventSource::EVENTS_LOG => S::HistoryFallback,
        AiEventSource::TERMINAL_SESSION => {
            if event.reliability == AiEventReliability::Heuristic {
                S::TerminalTextHeuristic
            } else {
                S::TerminalStructured
            }
        }
        AiEventSource::APP => S::App,
        AiEventSource::CLAUDE_CODE | AiEventSource::CODEX => match event.reliability {
            AiEventReliability::Heuristic => S::TerminalTextHeuristic,
            AiEventReliability::Fallback => S::ProviderFallback,
            AiEventReliability::Authoritative => {
                if event
                    .producer
                    .as_deref()
                    .is_some_and(|p| p.trim().eq_ignore_ascii_case("terminal_osc9"))
                {
                    S::TerminalStructured
                } else {
                    S::ProviderHook
                }
            }
        },
        AiEventSource::CURSOR
        | AiEventSource::WINDSURF
        | AiEventSource::COPILOT
        | AiEventSource::AIDER
        | AiEventSource::CLINE
        | AiEventSource::CONTINUE_AI => {
            if event.reliability == AiEventReliability::Fallback {
                S::ProviderFallback
            } else {
                S::Generic
            }
        }
        _ => S::Unknown,
    }
}
#[derive(Debug, Clone)]
pub struct Observation {
    pub state: State,
    pub class: SourceClass,
    pub aliases: BTreeSet<Alias>,
    pub reliability: AiEventReliability,
    pub timestamp: DateTime<Utc>,
    pub event_key: String,
}
impl Observation {
    fn new(event: &AiEvent, state: State, now: DateTime<Utc>) -> Self {
        Self {
            state,
            class: source_class(event),
            aliases: aliases(event),
            reliability: event.reliability,
            timestamp: now,
            event_key: format!("{}|event:{}", provider(event), event.id),
        }
    }
    pub fn lifecycle(event: &AiEvent, now: DateTime<Utc>) -> Option<Self> {
        match canonical::normalize(event.raw_type.as_deref().unwrap_or(&event.event_type)).as_str()
        {
            "session_start" | "sessionstart" | "user_prompt" | "userprompt" | "tool_start"
            | "toolstart" | "process_started" | "processstarted" | "command_started"
            | "commandstarted" => Some(Self::new(event, State::Running, now)),
            _ => None,
        }
    }
    pub fn notification(event: &AiEvent, kind: Kind, now: DateTime<Utc>) -> Option<Self> {
        let state = match kind {
            Kind::TaskFinished => State::Finished,
            Kind::TaskFailed => State::Failed,
            Kind::PermissionRequired => State::PermissionRequired,
            Kind::WaitingForInput => State::WaitingForInput,
            Kind::AttentionRequired => State::AttentionRequired,
            Kind::Idle => State::Idle,
            _ => return None,
        };
        Some(Self::new(event, state, now))
    }
    pub fn strength(&self) -> u16 {
        self.class.precedence()
            + match self.reliability {
                AiEventReliability::Authoritative => 40,
                AiEventReliability::Fallback => 20,
                AiEventReliability::Heuristic => 0,
            }
    }
    pub fn primary_key(&self) -> String {
        self.aliases
            .first()
            .map(Alias::key)
            .unwrap_or_else(|| self.event_key.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn identities_are_provider_scoped_and_ordered_without_empty_values() {
        let mut e = AiEvent::new(
            AiEventSource::claude_code(),
            "permission_request",
            "Claude",
            "",
            "ignored",
        );
        e.session_id = Some(" SESSION ".into());
        e.tab_id = Some(uuid::Uuid::nil());
        e.directory = Some(" /repo/./child ".into());
        let keys: Vec<_> = aliases(&e).iter().map(Alias::key).collect();
        assert_eq!(keys[0], "claude|session:session");
        assert!(keys[1].starts_with("claude|tab:"));
        assert!(keys[2].starts_with("claude|dir:"));
        e.source = AiEventSource::codex();
        assert!(
            aliases(&e)
                .first()
                .unwrap()
                .key()
                .starts_with("codex|session:")
        );
    }
    #[test]
    fn class_strength_and_injected_processing_clock_preserve_stateless_tools() {
        let mut e = AiEvent::new(
            AiEventSource::claude_code(),
            "tool_failed",
            "Claude",
            "",
            "old raw timestamp",
        );
        let now = DateTime::from_timestamp(1_800_000_000, 0).unwrap();
        assert!(Observation::notification(&e, Kind::ToolFailed, now).is_none());
        let hook = Observation::notification(&e, Kind::TaskFailed, now).unwrap();
        assert_eq!(hook.timestamp, now);
        assert_eq!(hook.strength(), 540);
        e.producer = Some("terminal_osc9".into());
        assert_eq!(
            Observation::notification(&e, Kind::TaskFailed, now)
                .unwrap()
                .strength(),
            390
        );
        e.reliability = AiEventReliability::Heuristic;
        assert_eq!(
            Observation::notification(&e, Kind::TaskFailed, now)
                .unwrap()
                .strength(),
            80
        );
    }
}
