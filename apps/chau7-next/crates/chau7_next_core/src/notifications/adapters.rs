//! Ports of `Chau7Core/Notifications/NotificationProviderAdapterRegistry.swift`
//! and `NotificationIngress.swift`.
//!
//! Every event entering the notification layer goes through [`adapt`]: the
//! source picks an adapter (Claude Code hooks, generic AI tools, fallback
//! monitors, terminal sessions, shell, app, API proxy, unknown), which either
//! drops the event with a reason or emits a canonical event plus the shared
//! [`AiEvent`] the pipeline works on. [`ingest`] is the public entry point.

use std::collections::BTreeMap;

use chrono::Utc;

use super::canonical::{
    self, CanonicalNotificationEvent, NotificationProviderAdapter,
    NotificationProviderAdapterResult, NotificationProviderEvent, NotificationSemanticKind,
};
use crate::ai::event::{AiEvent, AiEventReliability, AiEventSource};
use crate::iso8601::parse_iso8601;
use crate::monitoring::codex_feedback;

/// Registry decision (`NotificationProviderAdapterRegistry.Decision`).
#[derive(Debug, Clone, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum AdapterDecision {
    Emit {
        event: AiEvent,
        canonical: CanonicalNotificationEvent,
    },
    Drop {
        reason: String,
    },
}

impl AdapterDecision {
    pub fn event(&self) -> Option<&AiEvent> {
        match self {
            Self::Emit { event, .. } => Some(event),
            Self::Drop { .. } => None,
        }
    }

    pub fn canonical_event(&self) -> Option<&CanonicalNotificationEvent> {
        match self {
            Self::Emit { canonical, .. } => Some(canonical),
            Self::Drop { .. } => None,
        }
    }
}

fn drop(reason: String) -> AdapterDecision {
    AdapterDecision::Drop { reason }
}

/// Picks the adapter for the event's source
/// (`NotificationProviderAdapterRegistry.adapt`).
pub fn adapt(event: &AiEvent) -> AdapterDecision {
    match event.source.raw_value() {
        AiEventSource::CLAUDE_CODE => adapt_claude_code_event(event),
        AiEventSource::CODEX => adapt_codex_event(event),
        AiEventSource::RUNTIME
        | AiEventSource::CURSOR
        | AiEventSource::WINDSURF
        | AiEventSource::COPILOT
        | AiEventSource::AIDER
        | AiEventSource::CLINE
        | AiEventSource::CONTINUE_AI => adapt_generic_ai_event(event),
        AiEventSource::HISTORY_MONITOR | AiEventSource::EVENTS_LOG => {
            adapt_fallback_ai_event(event)
        }
        AiEventSource::TERMINAL_SESSION => adapt_terminal_session_event(event),
        AiEventSource::SHELL => adapt_shell_event(event),
        AiEventSource::APP => adapt_app_event(event),
        AiEventSource::API_PROXY => adapt_api_proxy_event(event),
        _ => adapt_unknown_event(event),
    }
}

fn adapt_claude_code_event(event: &AiEvent) -> AdapterDecision {
    let provider_event = provider_event(event);
    match (ClaudeCodeNotificationAdapter {
        reliability: event.reliability,
    })
    .adapt(&provider_event)
    {
        NotificationProviderAdapterResult::Emit(canonical) => AdapterDecision::Emit {
            event: as_ai_event(&canonical, event, None, None),
            canonical,
        },
        NotificationProviderAdapterResult::Drop { reason }
        | NotificationProviderAdapterResult::DeferToFallback { reason } => drop(reason),
    }
}

/// Native Codex events distinguish authoritative prompts from inferred proposals.
fn adapt_codex_event(event: &AiEvent) -> AdapterDecision {
    use AiEventReliability as R;
    use NotificationSemanticKind as K;
    let raw = normalized_raw_type(event);
    let (kind, reliability) = match raw.as_str() {
        "agent_turn_complete" | "agentturncomplete" => {
            if codex_feedback::assess(&event.message).is_some_and(|a| a.should_request_attention())
            {
                (K::WaitingForInput, R::Heuristic)
            } else {
                (K::TaskFinished, R::Authoritative)
            }
        }
        "approval_requested" | "approvalrequested" => (K::PermissionRequired, R::Authoritative),
        "user_input_requested" | "userinputrequested" => (K::WaitingForInput, R::Authoritative),
        _ => (
            canonical::kind(Some(&raw), event.notification_type.as_deref()),
            event.reliability,
        ),
    };
    if kind == K::Unknown {
        return drop(format!("Unsupported Codex raw event {raw}"));
    }
    let canonical = provider_event(event).canonical_event(kind, reliability);
    AdapterDecision::Emit {
        event: as_ai_event(&canonical, event, None, None),
        canonical,
    }
}

fn adapt_generic_ai_event(event: &AiEvent) -> AdapterDecision {
    let provider_event = provider_event(event);
    let kind = canonical::kind(
        provider_event.raw_type.as_deref(),
        provider_event.notification_type.as_deref(),
    );
    if kind == NotificationSemanticKind::Unknown {
        return drop(format!(
            "Unsupported generic AI raw event {}",
            provider_event
                .raw_type
                .as_deref()
                .unwrap_or(&event.event_type)
        ));
    }
    emit_canonicalized_event(
        event,
        kind,
        &event.event_type,
        provider_event.raw_type.clone(),
        event.reliability,
    )
}

fn normalized_raw_type(event: &AiEvent) -> String {
    canonical::normalize(event.raw_type.as_deref().unwrap_or(&event.event_type))
}

fn adapt_terminal_session_event(event: &AiEvent) -> AdapterDecision {
    let normalized_type = normalized_raw_type(event);
    let kind = canonical::kind(Some(&normalized_type), event.notification_type.as_deref());
    let raw_type = event
        .raw_type
        .clone()
        .unwrap_or_else(|| normalized_type.clone());

    if kind == NotificationSemanticKind::Unknown && normalized_type == "info" {
        return emit_canonicalized_event(
            event,
            NotificationSemanticKind::Informational,
            &event.event_type,
            Some(raw_type),
            AiEventReliability::Fallback,
        );
    }
    if kind == NotificationSemanticKind::Unknown {
        return drop(format!(
            "Unsupported terminal session raw event {normalized_type}"
        ));
    }
    if event.tab_id.is_none() && event.session_id.is_none() {
        return drop(format!(
            "Terminal session event {normalized_type} missing exact routing identity"
        ));
    }
    emit_canonicalized_event(
        event,
        kind,
        &event.event_type,
        Some(raw_type),
        AiEventReliability::Fallback,
    )
}

fn adapt_fallback_ai_event(event: &AiEvent) -> AdapterDecision {
    let normalized_type = normalized_raw_type(event);
    let kind = canonical::kind(Some(&normalized_type), event.notification_type.as_deref());
    if kind == NotificationSemanticKind::Unknown {
        return drop(format!(
            "Unsupported fallback AI raw event {normalized_type}"
        ));
    }
    if event.tab_id.is_none() && event.session_id.is_none() && event.directory.is_none() {
        return drop(format!(
            "Fallback AI event {normalized_type} missing routing identity"
        ));
    }
    let raw_type = event.raw_type.clone().unwrap_or(normalized_type);
    emit_canonicalized_event(
        event,
        kind,
        &event.event_type,
        Some(raw_type),
        AiEventReliability::Fallback,
    )
}

fn emit_with_table(
    event: &AiEvent,
    label: &str,
    table: impl Fn(&str) -> NotificationSemanticKind,
) -> AdapterDecision {
    let normalized_type = normalized_raw_type(event);
    let kind = table(&normalized_type);
    if kind == NotificationSemanticKind::Unknown {
        return drop(format!("Unsupported {label} raw event {normalized_type}"));
    }
    let raw_type = event.raw_type.clone().unwrap_or(normalized_type);
    emit_canonicalized_event(
        event,
        kind,
        &event.event_type,
        Some(raw_type),
        event.reliability,
    )
}

fn adapt_shell_event(event: &AiEvent) -> AdapterDecision {
    use NotificationSemanticKind as K;
    emit_with_table(event, "shell", |t| match t {
        "command_finished" | "script_succeeded" => K::TaskFinished,
        "command_failed" | "script_failed" => K::TaskFailed,
        "dev_server_started" | "exit_code_match" | "pattern_match" | "long_running"
        | "process_started" | "process_ended" | "directory_changed" | "git_branch_changed"
        | "other" => K::Informational,
        _ => K::Unknown,
    })
}

fn adapt_app_event(event: &AiEvent) -> AdapterDecision {
    use NotificationSemanticKind as K;
    emit_with_table(event, "app", |t| match t {
        "update_available" | "launch" | "tab_opened" | "tab_closed" | "window_focused"
        | "window_unfocused" | "file_modified" | "docker_event" | "other" => K::Informational,
        "file_conflict" | "memory_threshold" => K::AttentionRequired,
        _ => K::Unknown,
    })
}

fn adapt_api_proxy_event(event: &AiEvent) -> AdapterDecision {
    use NotificationSemanticKind as K;
    emit_with_table(event, "API proxy", |t| match t {
        "api_call" => K::Informational,
        "api_error" | "error" => K::TaskFailed,
        _ => K::Unknown,
    })
}

fn adapt_unknown_event(event: &AiEvent) -> AdapterDecision {
    let notification_type = event.notification_type.clone();
    emit_with_table(event, "unknown-source", move |t| {
        canonical::kind(Some(t), notification_type.as_deref())
    })
}

fn emit_canonicalized_event(
    event: &AiEvent,
    kind: NotificationSemanticKind,
    preserved_type: &str,
    raw_type: Option<String>,
    reliability: AiEventReliability,
) -> AdapterDecision {
    let canonical = provider_event(event).canonical_event(kind, reliability);
    AdapterDecision::Emit {
        event: as_ai_event(&canonical, event, Some(preserved_type), raw_type),
        canonical,
    }
}

/// `ClaudeCodeNotificationAdapter`.
struct ClaudeCodeNotificationAdapter {
    reliability: AiEventReliability,
}

impl NotificationProviderAdapter for ClaudeCodeNotificationAdapter {
    fn provider_id(&self) -> &str {
        AiEventSource::CLAUDE_CODE
    }

    fn adapt(&self, event: &NotificationProviderEvent) -> NotificationProviderAdapterResult {
        use NotificationProviderAdapterResult as R;
        let raw_type = canonical::normalize(event.raw_type.as_deref().unwrap_or(""));
        let authoritative =
            |kind| R::Emit(event.canonical_event(kind, AiEventReliability::Authoritative));
        match raw_type.as_str() {
            "notification" => {
                let inferred = event
                    .notification_type
                    .clone()
                    .or_else(|| infer_notification_type(event).map(str::to_string));
                let kind = canonical::kind(None, inferred.as_deref());
                if kind == NotificationSemanticKind::Unknown {
                    return R::Drop {
                        reason: "Unsupported Claude notification payload".into(),
                    };
                }
                authoritative(kind)
            }
            "permission_request" | "permissionrequest" => {
                authoritative(NotificationSemanticKind::PermissionRequired)
            }
            "response_failed" | "responsefailed" => authoritative(NotificationSemanticKind::TaskFailed),
            "tool_failed" | "toolfailed" => authoritative(NotificationSemanticKind::ToolFailed),
            "elicitation" => authoritative(NotificationSemanticKind::AttentionRequired),
            "idle" => {
                let kind = if canonical::is_input_prompt_like(event.title.as_deref(), &event.message, event.notification_type.as_deref()) {
                    NotificationSemanticKind::WaitingForInput
                } else { NotificationSemanticKind::Idle };
                R::Emit(event.canonical_event(kind, self.reliability))
            }
            "response_complete" | "responsecomplete" => R::Drop {
                reason: "Claude response_complete is state-only; Notification hook owns user-facing delivery".into(),
            },
            "user_prompt" | "userprompt" | "session_start" | "sessionstart" | "tool_start" | "toolstart" | "tool_complete"
            | "toolcomplete" | "session_end" | "sessionend" => R::Drop {
                reason: format!("Claude raw event {raw_type} is not user-facing"),
            },
            _ => {
                let kind = canonical::kind(Some(&raw_type), None);
                if kind == NotificationSemanticKind::Unknown {
                    return R::Drop {
                        reason: format!("Unsupported Claude raw event {raw_type}"),
                    };
                }
                R::Emit(event.canonical_event(kind, self.reliability))
            }
        }
    }
}

fn infer_notification_type(event: &NotificationProviderEvent) -> Option<&'static str> {
    let haystack = [event.title.as_deref(), Some(event.message.as_str())]
        .into_iter()
        .flatten()
        .map(|s| s.trim().to_lowercase())
        .collect::<Vec<_>>()
        .join(" ");
    if haystack.contains("waiting for your input") || haystack.contains("needs your input") {
        return Some("idle_prompt");
    }
    if haystack.contains("needs your approval") || haystack.contains("needs your permission") {
        return Some("permission_prompt");
    }
    if haystack.contains("needs your attention") {
        return Some("elicitation_dialog");
    }
    if haystack.contains("authenticated")
        || haystack.contains("signed in")
        || haystack.contains("login successful")
    {
        return Some("auth_success");
    }
    None
}

/// `NotificationProviderEvent(event:)`. A timestamp without fractional
/// seconds does not parse with the Swift formatter and becomes "now".
fn provider_event(event: &AiEvent) -> NotificationProviderEvent {
    let mut metadata = BTreeMap::new();
    if let Some(producer) = event.producer.as_ref().filter(|p| !p.is_empty()) {
        metadata.insert("producer".to_string(), producer.clone());
    }
    NotificationProviderEvent {
        id: event.id,
        provider_id: event.source.raw_value().to_string(),
        provider_name: event.tool.clone(),
        raw_type: Some(
            event
                .raw_type
                .clone()
                .unwrap_or_else(|| event.event_type.clone()),
        ),
        title: event.title.clone(),
        message: event.message.clone(),
        notification_type: event.notification_type.clone(),
        session_id: event.session_id.clone(),
        tab_id: event.tab_id,
        directory: event.directory.clone(),
        timestamp: parse_iso8601(&event.ts).unwrap_or_else(Utc::now),
        metadata,
    }
}

/// `CanonicalNotificationEvent.sharedTriggerType`.
fn shared_trigger_type(canonical: &CanonicalNotificationEvent) -> String {
    use NotificationSemanticKind as K;
    match canonical.kind {
        K::TaskFinished => "finished",
        K::TaskFailed => "failed",
        K::ToolFailed => "tool_failed",
        K::PermissionRequired => "permission",
        K::WaitingForInput => "waiting_input",
        K::AttentionRequired => "attention_required",
        K::AuthenticationSucceeded => "authentication_succeeded",
        K::Informational => "info",
        K::Idle => "idle",
        K::Unknown => {
            return canonical
                .raw_type
                .clone()
                .unwrap_or_else(|| "unknown".into());
        }
    }
    .to_string()
}

/// Preserve ingress identity, attribution and raw timestamp while enriching semantics.
fn as_ai_event(
    canonical: &CanonicalNotificationEvent,
    original: &AiEvent,
    shared_type_override: Option<&str>,
    raw_type_override: Option<String>,
) -> AiEvent {
    let mut event = original.clone();
    event.event_type = shared_type_override
        .map(str::to_string)
        .unwrap_or_else(|| shared_trigger_type(canonical));
    event.raw_type = raw_type_override.or_else(|| canonical.raw_type.clone());
    event.reliability = canonical.reliability;
    event
}

// MARK: - Ingress

/// An event the ingress accepted (`NotificationIngress.AcceptedEvent`).
#[derive(Debug, Clone, PartialEq)]
pub struct AcceptedEvent {
    pub shared_event: AiEvent,
    pub canonical_event: CanonicalNotificationEvent,
}

/// `NotificationIngress.Decision`.
#[derive(Debug, Clone, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum IngressDecision {
    Accept(AcceptedEvent),
    Drop { reason: String },
}

/// `NotificationIngress.ingest`: run the provider adapters on an event.
pub fn ingest(event: &AiEvent) -> IngressDecision {
    match adapt(event) {
        AdapterDecision::Drop { reason } => IngressDecision::Drop { reason },
        AdapterDecision::Emit { event, canonical } => IngressDecision::Accept(AcceptedEvent {
            shared_event: event,
            canonical_event: canonical,
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use NotificationSemanticKind as K;
    use uuid::Uuid;

    fn event(source: AiEventSource, event_type: &str, tool: &str) -> AiEvent {
        AiEvent::new(source, event_type, tool, "msg", "2026-04-01T00:00:00Z")
    }

    fn emit(decision: AdapterDecision) -> (AiEvent, CanonicalNotificationEvent) {
        match decision {
            AdapterDecision::Emit { event, canonical } => (event, canonical),
            AdapterDecision::Drop { reason } => panic!("expected emit, got drop: {reason}"),
        }
    }

    fn dropped(decision: AdapterDecision) -> String {
        match decision {
            AdapterDecision::Drop { reason } => reason,
            AdapterDecision::Emit { .. } => panic!("expected drop"),
        }
    }

    fn claude_notification(title: &str, message: &str, kind: &str) -> AiEvent {
        let mut e = event(AiEventSource::claude_code(), "notification", "Claude");
        e.raw_type = Some("notification".into());
        e.title = Some(title.into());
        e.message = message.into();
        e.notification_type = Some(kind.into());
        e.session_id = Some("claude-session-1".into());
        e.producer = Some("claude_code_monitor".into());
        e.reliability = AiEventReliability::Authoritative;
        e
    }

    #[test]
    fn codex_native_completion_routes_medium_and_high_actionability_with_heuristic_evidence() {
        for message in [
            "1. Alpha\n2. Beta\nTell me which option to apply.",
            "Should I apply it to the remaining workspaces?",
        ] {
            let mut e = event(AiEventSource::codex(), "agent-turn-complete", "Codex");
            e.message = message.into();
            e.raw_type = Some("Agent-Turn-Complete".into());
            e.repo_path = Some("/repo/project".into());
            e.directory = Some("/repo/project/subdir".into());
            e.tab_id = Some(Uuid::new_v4());
            e.session_id = Some("session-1".into());
            e.producer = Some("codex_notify".into());
            e.ts = "2026-10-11T00:00:00.123456+02:00".into();
            let (adapted, canonical) = emit(adapt(&e));
            assert_eq!(canonical.kind, K::WaitingForInput);
            assert_eq!(canonical.reliability, AiEventReliability::Heuristic);
            let mut expected = e.clone();
            expected.event_type = "waiting_input".into();
            expected.reliability = AiEventReliability::Heuristic;
            assert_eq!(adapted, expected);
        }
    }

    #[test]
    fn codex_low_confidence_or_completed_answer_remains_authoritative_finished() {
        for message in [
            "Done.",
            "Does that explanation make sense?",
            "1. Improve testing\n2. Improve docs",
        ] {
            let mut e = event(AiEventSource::codex(), "agentturncomplete", "Codex");
            e.message = message.into();
            let (adapted, canonical) = emit(adapt(&e));
            assert_eq!(canonical.kind, K::TaskFinished);
            assert_eq!(adapted.event_type, "finished");
            assert_eq!(adapted.raw_type.as_deref(), Some("agentturncomplete"));
            assert_eq!(adapted.reliability, AiEventReliability::Authoritative);
        }
    }

    #[test]
    fn codex_authoritative_prompt_aliases_fallback_and_unsupported_match_swift() {
        for (raw, kind, shared) in [
            ("approval-requested", K::PermissionRequired, "permission"),
            ("ApprovalRequested", K::PermissionRequired, "permission"),
            ("user-input-requested", K::WaitingForInput, "waiting_input"),
            ("UserInputRequested", K::WaitingForInput, "waiting_input"),
        ] {
            let e = event(AiEventSource::codex(), raw, "Codex");
            let (adapted, canonical) = emit(adapt(&e));
            assert_eq!(canonical.kind, kind);
            assert_eq!(adapted.event_type, shared);
            assert_eq!(adapted.raw_type.as_deref(), Some(raw));
            assert_eq!(adapted.reliability, AiEventReliability::Authoritative);
        }
        let mut e = event(AiEventSource::codex(), "idle", "Codex");
        e.reliability = AiEventReliability::Fallback;
        assert_eq!(emit(adapt(&e)).0.reliability, AiEventReliability::Fallback);
        e.event_type = "provider_internal_state".into();
        assert!(dropped(adapt(&e)).contains("Unsupported Codex raw event"));
    }

    #[test]
    fn enrichment_preserves_raw_attribution_for_claude_and_generic_events() {
        for source in [AiEventSource::claude_code(), AiEventSource::runtime()] {
            let mut e = event(source, "finished", "Agent");
            e.repo_path = Some("/repo/project".into());
            e.ts = "raw-invalid-timestamp".into();
            let (adapted, _) = emit(adapt(&e));
            assert_eq!(adapted.repo_path, e.repo_path);
            assert_eq!(adapted.ts, e.ts);
            assert_eq!(adapted.id, e.id);
        }
    }

    #[test]
    fn claude_tool_failure_has_own_default_off_trigger_and_never_becomes_task_failure() {
        for raw in ["tool_failed", "toolfailed", "tool-failed"] {
            let e = event(AiEventSource::claude_code(), raw, "Claude");
            let (adapted, canonical) = emit(adapt(&e));
            assert_eq!(canonical.kind, K::ToolFailed);
            assert!(!canonical.kind.is_attention_seeking());
            assert_eq!(adapted.event_type, "tool_failed");
            assert_eq!(adapted.reliability, AiEventReliability::Authoritative);
            let trigger = super::super::triggers::trigger_for_event(&adapted).unwrap();
            assert_eq!(trigger.id, "claude_code.tool_failed");
            assert!(!trigger.default_enabled);
        }
    }

    #[test]
    fn claude_failure_elicitation_and_state_only_aliases_match_current_swift() {
        for (raw, kind, shared) in [
            ("response_failed", K::TaskFailed, "failed"),
            ("responsefailed", K::TaskFailed, "failed"),
            ("elicitation", K::AttentionRequired, "attention_required"),
        ] {
            let e = event(AiEventSource::claude_code(), raw, "Claude");
            let (adapted, canonical) = emit(adapt(&e));
            assert_eq!(canonical.kind, kind);
            assert_eq!(adapted.event_type, shared);
            assert_eq!(adapted.raw_type.as_deref(), Some(raw));
            assert_eq!(adapted.reliability, AiEventReliability::Authoritative);
        }
        for raw in [
            "session_start",
            "sessionstart",
            "session-start",
            "response-complete",
            "user-prompt",
            "tool-start",
            "tool-complete",
            "session-end",
        ] {
            assert!(matches!(
                adapt(&event(AiEventSource::claude_code(), raw, "Claude")),
                AdapterDecision::Drop { .. }
            ));
        }
    }

    #[test]
    fn claude_idle_input_detection_and_default_mapping_preserve_reliability() {
        let mut e = event(AiEventSource::claude_code(), "idle", "Claude");
        e.reliability = AiEventReliability::Fallback;
        for message in [
            "Waiting for input",
            "Waiting for your input",
            "Needs your input",
            "Input requested",
            "Question requested",
            "Ready for your input",
        ] {
            e.message = message.into();
            let (adapted, canonical) = emit(adapt(&e));
            assert_eq!(canonical.kind, K::WaitingForInput);
            assert_eq!(adapted.reliability, AiEventReliability::Fallback);
        }
        e.message = "Agent is idle".into();
        assert_eq!(emit(adapt(&e)).1.kind, K::Idle);
        e.notification_type = Some("idle_prompt".into());
        assert_eq!(emit(adapt(&e)).1.kind, K::WaitingForInput);
        e.notification_type = None;
        e.event_type = "finished".into();
        assert_eq!(emit(adapt(&e)).0.reliability, AiEventReliability::Fallback);
    }

    // NotificationProviderAdapterRegistryTests

    #[test]
    fn claude_notification_event_maps_to_waiting_input() {
        let mut e = claude_notification(
            "Claude needs your input",
            "Claude is waiting for your input",
            "idle_prompt",
        );
        e.id = Uuid::parse_str("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA").unwrap();
        let (adapted, canonical) = emit(adapt(&e));
        assert_eq!(canonical.kind, K::WaitingForInput);
        assert_eq!(adapted.event_type, "waiting_input");
        assert_eq!(adapted.raw_type.as_deref(), Some("notification"));
        assert_eq!(adapted.notification_type.as_deref(), Some("idle_prompt"));
        assert_eq!(adapted.tool, "Claude");
        assert_eq!(adapted.id, e.id);
        assert_eq!(adapted.producer.as_deref(), Some("claude_code_monitor"));
    }

    #[test]
    fn claude_response_complete_is_dropped_as_state_only() {
        let mut e = event(AiEventSource::claude_code(), "response_complete", "Claude");
        e.raw_type = Some("response_complete".into());
        assert!(dropped(adapt(&e)).contains("state-only"));
    }

    #[test]
    fn claude_notification_event_maps_to_attention_required() {
        let e = claude_notification(
            "Claude needs your attention",
            "Claude Code needs your attention",
            "elicitation_dialog",
        );
        let (adapted, canonical) = emit(adapt(&e));
        assert_eq!(canonical.kind, K::AttentionRequired);
        assert_eq!(adapted.event_type, "attention_required");
        assert_eq!(
            adapted.notification_type.as_deref(),
            Some("elicitation_dialog")
        );
    }

    #[test]
    fn claude_notification_infers_type_from_text() {
        let mut e = claude_notification("", "Claude needs your permission to use Bash", "");
        e.notification_type = None;
        let (_, canonical) = emit(adapt(&e));
        assert_eq!(canonical.kind, K::PermissionRequired);
        e.message = "nothing to see".into();
        assert_eq!(
            dropped(adapt(&e)),
            "Unsupported Claude notification payload"
        );
        let mut tool = event(AiEventSource::claude_code(), "tool_start", "Claude");
        tool.raw_type = Some("tool_start".into());
        assert!(dropped(adapt(&tool)).contains("not user-facing"));
        let finished = event(AiEventSource::claude_code(), "finished", "Claude");
        let (adapted, canonical) = emit(adapt(&finished));
        assert_eq!(canonical.kind, K::TaskFinished);
        assert_eq!(adapted.event_type, "finished");
        assert_eq!(canonical.reliability, finished.reliability);
    }

    #[test]
    fn runtime_waiting_input_canonicalizes_without_changing_behavior() {
        let mut e = event(AiEventSource::runtime(), "waiting_input", "Codex");
        e.session_id = Some("session-1".into());
        e.producer = Some("runtime_session_manager".into());
        let (adapted, canonical) = emit(adapt(&e));
        assert_eq!(adapted.event_type, "waiting_input");
        assert_eq!(adapted.tool, "Codex");
        assert_eq!(canonical.kind, K::WaitingForInput);
    }

    #[test]
    fn unsupported_generic_ai_event_is_dropped() {
        let mut e = event(AiEventSource::runtime(), "provider_internal_state", "Codex");
        e.raw_type = Some("provider_internal_state".into());
        assert!(dropped(adapt(&e)).contains("Unsupported generic AI raw event"));
    }

    #[test]
    fn history_monitor_finished_canonicalizes_as_fallback() {
        let mut e = event(AiEventSource::history_monitor(), "finished", "Codex");
        e.session_id = Some("session-1".into());
        let (adapted, canonical) = emit(adapt(&e));
        assert_eq!(canonical.kind, K::TaskFinished);
        assert_eq!(adapted.event_type, "finished");
        assert_eq!(adapted.reliability, AiEventReliability::Fallback);
    }

    #[test]
    fn events_log_waiting_input_drops_without_identity() {
        let e = event(AiEventSource::events_log(), "waiting_input", "Codex");
        assert!(dropped(adapt(&e)).contains("missing routing identity"));
    }

    #[test]
    fn current_shell_script_and_dev_server_aliases_reach_canonical_admission() {
        for (raw, kind) in [
            ("script_succeeded", K::TaskFinished),
            ("script_failed", K::TaskFailed),
            ("dev_server_started", K::Informational),
        ] {
            let e = event(AiEventSource::shell(), raw, "Shell");
            let (adapted, canonical) = emit(adapt(&e));
            assert_eq!(canonical.kind, kind);
            assert_eq!(adapted.event_type, raw);
            assert_eq!(adapted.raw_type.as_deref(), Some(raw));
        }
    }

    #[test]
    fn shell_command_failed_preserves_trigger_type_and_canonicalizes() {
        let mut e = event(AiEventSource::shell(), "command_failed", "Shell");
        e.directory = Some("/tmp/test".into());
        let (adapted, canonical) = emit(adapt(&e));
        assert_eq!(adapted.event_type, "command_failed");
        assert_eq!(adapted.raw_type.as_deref(), Some("command_failed"));
        assert_eq!(canonical.kind, K::TaskFailed);
    }

    #[test]
    fn app_update_available_preserves_trigger_type_and_canonicalizes() {
        let e = event(AiEventSource::app(), "update_available", "Chau7");
        let (adapted, canonical) = emit(adapt(&e));
        assert_eq!(adapted.event_type, "update_available");
        assert_eq!(canonical.kind, K::Informational);
        let unknown = event(AiEventSource::app(), "scheduled", "App");
        assert_eq!(
            dropped(adapt(&unknown)),
            "Unsupported app raw event scheduled"
        );
    }

    #[test]
    fn api_proxy_error_canonicalizes_as_failure() {
        let mut e = event(AiEventSource::api_proxy(), "api_error", "OpenAI");
        e.reliability = AiEventReliability::Heuristic;
        let (adapted, canonical) = emit(adapt(&e));
        assert_eq!(adapted.event_type, "api_error");
        assert_eq!(canonical.kind, K::TaskFailed);
    }

    #[test]
    fn unknown_source_uses_generic_mapping() {
        let e = event(AiEventSource::new("custom"), "permission", "X");
        let (_, canonical) = emit(adapt(&e));
        assert_eq!(canonical.kind, K::PermissionRequired);
        let e = event(AiEventSource::new("custom"), "weird", "X");
        assert!(dropped(adapt(&e)).contains("unknown-source"));
    }

    #[test]
    fn timestamps_round_trip_through_swift_formatter() {
        let mut e = event(AiEventSource::runtime(), "finished", "Codex");
        e.ts = "2026-04-01T10:00:00.250Z".into();
        let (adapted, _) = emit(adapt(&e));
        assert_eq!(adapted.ts, "2026-04-01T10:00:00.250Z");
    }

    // NotificationIngressTests

    fn accepted(decision: IngressDecision) -> AcceptedEvent {
        match decision {
            IngressDecision::Accept(a) => a,
            IngressDecision::Drop { reason } => panic!("dropped: {reason}"),
        }
    }

    fn ingress_reason(decision: IngressDecision) -> String {
        match decision {
            IngressDecision::Drop { reason } => reason,
            IngressDecision::Accept(_) => panic!("accepted"),
        }
    }

    #[test]
    fn ingress_accepts_canonical_claude_notification() {
        let e = claude_notification(
            "Claude needs your input",
            "Claude is waiting for your input",
            "idle_prompt",
        );
        let a = accepted(ingest(&e));
        assert_eq!(a.shared_event.event_type, "waiting_input");
        assert_eq!(a.canonical_event.kind, K::WaitingForInput);
    }

    #[test]
    fn ingress_drops_unsupported_generic_ai_event() {
        let mut e = event(AiEventSource::runtime(), "provider_internal_state", "Codex");
        e.raw_type = Some("provider_internal_state".into());
        assert!(ingress_reason(ingest(&e)).contains("Unsupported generic AI raw event"));
    }

    #[test]
    fn ingress_drops_terminal_session_finished_without_exact_identity() {
        let e = event(AiEventSource::terminal_session(), "finished", "Claude");
        assert!(ingress_reason(ingest(&e)).contains("missing exact routing identity"));
    }

    #[test]
    fn ingress_accepts_terminal_session_finished_with_tab_identity() {
        let tab_id = Uuid::new_v4();
        let mut e = event(AiEventSource::terminal_session(), "finished", "Claude");
        e.tab_id = Some(tab_id);
        let a = accepted(ingest(&e));
        assert_eq!(a.shared_event.tab_id, Some(tab_id));
        assert_eq!(a.shared_event.event_type, "finished");
        assert_eq!(a.canonical_event.kind, K::TaskFinished);
        assert_eq!(a.shared_event.reliability, AiEventReliability::Fallback);
        let mut info = event(AiEventSource::terminal_session(), "info", "Claude");
        info.tab_id = Some(tab_id);
        assert_eq!(
            accepted(ingest(&info)).canonical_event.kind,
            K::Informational
        );
    }

    #[test]
    fn ingress_accepts_shell_command_failure_as_canonical_shared_event() {
        let mut e = event(AiEventSource::shell(), "command_failed", "Shell");
        e.directory = Some("/tmp/test".into());
        let a = accepted(ingest(&e));
        assert_eq!(a.shared_event.event_type, "command_failed");
        assert_eq!(a.canonical_event.kind, K::TaskFailed);
    }

    #[test]
    fn ingress_accepts_app_informational_event_as_canonical_shared_event() {
        let e = event(AiEventSource::app(), "update_available", "Chau7");
        let a = accepted(ingest(&e));
        assert_eq!(a.shared_event.event_type, "update_available");
        assert_eq!(a.canonical_event.kind, K::Informational);
    }
}
