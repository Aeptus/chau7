//! Ports of `Chau7Core/Notifications/CanonicalNotificationModel.swift` and
//! `CanonicalNotificationMapping.swift`.
//!
//! Provider adapters translate raw tool events into one of the
//! [`NotificationSemanticKind`]s before the shared notification layer decides
//! anything. [`kind`] maps raw event types and provider notification subtypes
//! (Claude `permission_prompt`, `idle_prompt`, ...) to a kind.

use std::collections::BTreeMap;

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::ai::event::AiEventReliability;

/// Canonical semantic categories for user-facing AI notification events
/// (`NotificationSemanticKind`). Raw values are persisted in the history.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum NotificationSemanticKind {
    #[serde(rename = "task_finished")]
    TaskFinished,
    #[serde(rename = "task_failed")]
    TaskFailed,
    #[serde(rename = "permission_required")]
    PermissionRequired,
    #[serde(rename = "waiting_for_input")]
    WaitingForInput,
    #[serde(rename = "attention_required")]
    AttentionRequired,
    #[serde(rename = "authentication_succeeded")]
    AuthenticationSucceeded,
    #[serde(rename = "idle")]
    Idle,
    #[serde(rename = "informational")]
    Informational,
    #[serde(rename = "unknown")]
    Unknown,
}

impl NotificationSemanticKind {
    pub const ALL: [Self; 9] = [
        Self::TaskFinished,
        Self::TaskFailed,
        Self::PermissionRequired,
        Self::WaitingForInput,
        Self::AttentionRequired,
        Self::AuthenticationSucceeded,
        Self::Idle,
        Self::Informational,
        Self::Unknown,
    ];

    pub fn raw_value(self) -> &'static str {
        match self {
            Self::TaskFinished => "task_finished",
            Self::TaskFailed => "task_failed",
            Self::PermissionRequired => "permission_required",
            Self::WaitingForInput => "waiting_for_input",
            Self::AttentionRequired => "attention_required",
            Self::AuthenticationSucceeded => "authentication_succeeded",
            Self::Idle => "idle",
            Self::Informational => "informational",
            Self::Unknown => "unknown",
        }
    }

    /// Kinds that are surfaced as active user attention events.
    pub fn is_attention_seeking(self) -> bool {
        matches!(
            self,
            Self::TaskFinished
                | Self::TaskFailed
                | Self::PermissionRequired
                | Self::WaitingForInput
                | Self::AttentionRequired
        )
    }
}

/// Provider-side event payload in a transport-friendly shape
/// (`NotificationProviderEvent`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NotificationProviderEvent {
    pub id: Uuid,
    pub provider_id: String,
    pub provider_name: String,
    pub raw_type: Option<String>,
    pub title: Option<String>,
    pub message: String,
    pub notification_type: Option<String>,
    pub session_id: Option<String>,
    pub tab_id: Option<Uuid>,
    pub directory: Option<String>,
    pub timestamp: DateTime<Utc>,
    pub metadata: BTreeMap<String, String>,
}

impl NotificationProviderEvent {
    /// An event with a fresh id, the current time and no optional fields.
    pub fn new(
        provider_id: impl Into<String>,
        provider_name: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            provider_id: provider_id.into(),
            provider_name: provider_name.into(),
            raw_type: None,
            title: None,
            message: message.into(),
            notification_type: None,
            session_id: None,
            tab_id: None,
            directory: None,
            timestamp: Utc::now(),
            metadata: BTreeMap::new(),
        }
    }

    /// `canonicalEvent(kind:reliability:)`.
    pub fn canonical_event(
        &self,
        kind: NotificationSemanticKind,
        reliability: AiEventReliability,
    ) -> CanonicalNotificationEvent {
        CanonicalNotificationEvent {
            id: self.id,
            kind,
            provider_id: self.provider_id.clone(),
            provider_name: self.provider_name.clone(),
            raw_type: self.raw_type.clone(),
            title: self.title.clone(),
            message: self.message.clone(),
            notification_type: self.notification_type.clone(),
            session_id: self.session_id.clone(),
            tab_id: self.tab_id,
            directory: self.directory.clone(),
            timestamp: self.timestamp,
            reliability,
            metadata: self.metadata.clone(),
        }
    }
}

/// Canonical semantic notification event emitted by a provider adapter
/// (`CanonicalNotificationEvent`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CanonicalNotificationEvent {
    pub id: Uuid,
    pub kind: NotificationSemanticKind,
    pub provider_id: String,
    pub provider_name: String,
    pub raw_type: Option<String>,
    pub title: Option<String>,
    pub message: String,
    pub notification_type: Option<String>,
    pub session_id: Option<String>,
    pub tab_id: Option<Uuid>,
    pub directory: Option<String>,
    pub timestamp: DateTime<Utc>,
    pub reliability: AiEventReliability,
    pub metadata: BTreeMap<String, String>,
}

impl CanonicalNotificationEvent {
    /// A heuristic event with a fresh id, the current time and no optional
    /// fields.
    pub fn new(
        kind: NotificationSemanticKind,
        provider_id: impl Into<String>,
        provider_name: impl Into<String>,
        message: impl Into<String>,
    ) -> Self {
        NotificationProviderEvent::new(provider_id, provider_name, message)
            .canonical_event(kind, AiEventReliability::Heuristic)
    }

    pub fn is_attention_seeking(&self) -> bool {
        self.kind.is_attention_seeking()
    }
}

/// Result of translating a provider event (`NotificationProviderAdapterResult`).
#[derive(Debug, Clone, PartialEq, Eq)]
#[allow(clippy::large_enum_variant)]
pub enum NotificationProviderAdapterResult {
    Emit(CanonicalNotificationEvent),
    Drop { reason: String },
    DeferToFallback { reason: String },
}

impl NotificationProviderAdapterResult {
    pub fn canonical_event(&self) -> Option<&CanonicalNotificationEvent> {
        match self {
            Self::Emit(event) => Some(event),
            _ => None,
        }
    }

    pub fn reason(&self) -> Option<&str> {
        match self {
            Self::Emit(_) => None,
            Self::Drop { reason } | Self::DeferToFallback { reason } => Some(reason),
        }
    }
}

/// Adapter contract for provider-specific notification parsing
/// (`NotificationProviderAdapter`).
pub trait NotificationProviderAdapter {
    fn provider_id(&self) -> &str;
    fn adapt(&self, event: &NotificationProviderEvent) -> NotificationProviderAdapterResult;
}

// MARK: - Mapping (`NotificationSemanticMapping`)

/// The kind for a raw type and an optional notification subtype; the subtype
/// wins when it maps to something.
pub fn kind(raw_type: Option<&str>, notification_type: Option<&str>) -> NotificationSemanticKind {
    if let Some(mapped) = notification_type.and_then(kind_for_notification_type) {
        return mapped;
    }
    if let Some(mapped) = raw_type.and_then(kind_for_raw_type) {
        return mapped;
    }
    NotificationSemanticKind::Unknown
}

/// `kind(forNotificationType:)`.
pub fn kind_for_notification_type(value: &str) -> Option<NotificationSemanticKind> {
    use NotificationSemanticKind as K;
    Some(match normalize(value).as_str() {
        "permission_prompt" | "permissionrequest" | "permission" => K::PermissionRequired,
        "idle_prompt" | "idleprompt" | "waiting_input" | "waitinginput" | "input_required"
        | "inputrequired" => K::WaitingForInput,
        "auth_success"
        | "authsuccess"
        | "authentication_succeeded"
        | "authenticationsucceeded"
        | "login_success"
        | "loginsuccess" => K::AuthenticationSucceeded,
        "elicitation_dialog" | "elicitationdialog" | "attention_required" | "attentionrequired"
        | "needs_attention" | "needsattention" => K::AttentionRequired,
        _ => return None,
    })
}

/// `kind(forRawType:)`.
pub fn kind_for_raw_type(value: &str) -> Option<NotificationSemanticKind> {
    use NotificationSemanticKind as K;
    Some(match normalize(value).as_str() {
        "finished"
        | "response_complete"
        | "responsecomplete"
        | "task_finished"
        | "taskfinished"
        | "agent_turn_complete"
        | "agentturncomplete" => K::TaskFinished,
        "failed" | "error" | "context_limit" | "contextlimit" | "exit_failed" | "exitfailed" => {
            K::TaskFailed
        }
        "permission" | "permission_request" | "permissionrequest" => K::PermissionRequired,
        "waiting_input" | "waitinginput" | "idle_prompt" | "idleprompt" => K::WaitingForInput,
        "attention_required" | "attentionrequired" | "notification" => K::AttentionRequired,
        "auth_success" | "authsuccess" => K::AuthenticationSucceeded,
        "idle" => K::Idle,
        "informational" | "info" => K::Informational,
        _ => return None,
    })
}

/// Trim, lower-case, `-` to space, then whitespace runs to `_`.
pub fn normalize(value: &str) -> String {
    value
        .trim()
        .to_lowercase()
        .replace('-', " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join("_")
}

#[cfg(test)]
mod tests {
    use super::*;
    use NotificationSemanticKind as K;

    // CanonicalNotificationMappingTests

    #[test]
    fn notification_type_mappings() {
        assert_eq!(kind(None, Some("permission_prompt")), K::PermissionRequired);
        assert_eq!(kind(None, Some("idle_prompt")), K::WaitingForInput);
        assert_eq!(kind(None, Some("auth_success")), K::AuthenticationSucceeded);
        assert_eq!(kind(None, Some("elicitation_dialog")), K::AttentionRequired);
    }

    #[test]
    fn raw_type_mappings() {
        assert_eq!(kind(Some("response_complete"), None), K::TaskFinished);
        assert_eq!(kind(Some("failed"), None), K::TaskFailed);
        assert_eq!(
            kind(Some("permission_request"), None),
            K::PermissionRequired
        );
        assert_eq!(kind(Some("waiting_input"), None), K::WaitingForInput);
        assert_eq!(kind(Some("notification"), None), K::AttentionRequired);
        assert_eq!(kind(Some("idle"), None), K::Idle);
        assert_eq!(kind(Some("info"), None), K::Informational);
        assert_eq!(kind(Some("nope"), Some("nope")), K::Unknown);
    }

    #[test]
    fn notification_type_takes_precedence_over_raw_type() {
        assert_eq!(
            kind(Some("finished"), Some("permission_prompt")),
            K::PermissionRequired
        );
    }

    #[test]
    fn normalize_values() {
        assert_eq!(normalize(" Permission Prompt "), "permission_prompt");
        assert_eq!(normalize("idle-prompt"), "idle_prompt");
        assert_eq!(normalize("auth success"), "auth_success");
    }

    // CanonicalNotificationModelTests

    #[test]
    fn semantic_kinds_are_stable() {
        assert_eq!(K::TaskFinished.raw_value(), "task_finished");
        assert_eq!(K::TaskFailed.raw_value(), "task_failed");
        assert_eq!(K::PermissionRequired.raw_value(), "permission_required");
        assert_eq!(K::WaitingForInput.raw_value(), "waiting_for_input");
        for k in K::ALL {
            assert_eq!(
                serde_json::to_string(&k).unwrap(),
                format!("\"{}\"", k.raw_value())
            );
        }
    }

    #[test]
    fn attention_seeking_kinds() {
        assert!(K::TaskFinished.is_attention_seeking());
        assert!(K::TaskFailed.is_attention_seeking());
        assert!(K::PermissionRequired.is_attention_seeking());
        assert!(K::WaitingForInput.is_attention_seeking());
        assert!(!K::AuthenticationSucceeded.is_attention_seeking());
        assert!(!K::Informational.is_attention_seeking());
    }

    #[test]
    fn provider_event_builds_canonical_event() {
        let tab_id = Uuid::new_v4();
        let mut event = NotificationProviderEvent::new(
            "claude_code",
            "Claude Code",
            "Claude is waiting for your input",
        );
        event.id = Uuid::parse_str("11111111-1111-1111-1111-111111111111").unwrap();
        event.raw_type = Some("notification".into());
        event.title = Some("Claude needs your input".into());
        event.notification_type = Some("permission_prompt".into());
        event.session_id = Some("session-123".into());
        event.tab_id = Some(tab_id);
        event.directory = Some("/tmp/mockup".into());
        event.timestamp = DateTime::from_timestamp(1_700_000_000, 0).unwrap();
        event.metadata.insert("hook".into(), "Notification".into());

        let canonical =
            event.canonical_event(K::PermissionRequired, AiEventReliability::Authoritative);
        assert_eq!(canonical.id, event.id);
        assert_eq!(canonical.kind, K::PermissionRequired);
        assert_eq!(canonical.provider_id, "claude_code");
        assert_eq!(canonical.provider_name, "Claude Code");
        assert_eq!(canonical.raw_type.as_deref(), Some("notification"));
        assert_eq!(canonical.title.as_deref(), Some("Claude needs your input"));
        assert_eq!(canonical.message, "Claude is waiting for your input");
        assert_eq!(
            canonical.notification_type.as_deref(),
            Some("permission_prompt")
        );
        assert_eq!(canonical.session_id.as_deref(), Some("session-123"));
        assert_eq!(canonical.tab_id, Some(tab_id));
        assert_eq!(canonical.directory.as_deref(), Some("/tmp/mockup"));
        assert_eq!(canonical.timestamp, event.timestamp);
        assert_eq!(canonical.reliability, AiEventReliability::Authoritative);
        assert_eq!(
            canonical.metadata.get("hook").map(String::as_str),
            Some("Notification")
        );
        assert!(canonical.is_attention_seeking());
    }

    #[test]
    fn adapter_result_accessors() {
        let event = CanonicalNotificationEvent::new(K::TaskFinished, "codex", "Codex", "Done");
        let emitted = NotificationProviderAdapterResult::Emit(event.clone());
        assert_eq!(emitted.canonical_event(), Some(&event));
        assert_eq!(emitted.reason(), None);

        let dropped = NotificationProviderAdapterResult::Drop {
            reason: "disabled".into(),
        };
        assert_eq!(dropped.canonical_event(), None);
        assert_eq!(dropped.reason(), Some("disabled"));

        let deferred = NotificationProviderAdapterResult::DeferToFallback {
            reason: "missing identity".into(),
        };
        assert_eq!(deferred.canonical_event(), None);
        assert_eq!(deferred.reason(), Some("missing identity"));
    }
}
