//! Ports of `NotificationDeliverySemantics.swift`,
//! `NotificationEventPreparation.swift` and `NotificationStylePlanner.swift`.
//!
//! - Delivery semantics: authoritative events (hooks) for the core types must
//!   reach an exact tab; weaker fallback events for the same identity are
//!   suppressed for 180 s after an authoritative one.
//! - Preparation: drop events whose trigger is disabled, then resolve the
//!   event's tab.
//! - Style planner: the default tab style for an event type, and which style
//!   actions to run when only the tab should be styled.

use std::collections::{HashMap, HashSet, VecDeque};
use std::time::{Duration, Instant};

use uuid::Uuid;

use super::actions::{NotificationActionConfig, NotificationActionType};
use super::schedule::{notification_identity_key, standardize_path};
use super::triggers::{self, NotificationTriggerState};
use crate::ai::event::{AiEvent, AiEventReliability};
use crate::tab_target::TabTarget;

// MARK: - Delivery semantics

/// Types that must be routed exactly when they come from an authoritative
/// producer.
pub const AUTHORITATIVE_ROUTING_TYPES: [&str; 5] = [
    "finished",
    "failed",
    "permission",
    "waiting_input",
    "attention_required",
];

/// How long an authoritative delivery shadows fallback events (180 s).
pub const AUTHORITY_RETENTION: Duration = Duration::from_secs(180);

fn is_authoritative_routing_type(event: &AiEvent) -> bool {
    AUTHORITATIVE_ROUTING_TYPES.contains(&event.normalized_type().as_str())
}

/// An authoritative core event that has no tab yet.
pub fn requires_authoritative_routing(event: &AiEvent) -> bool {
    event.reliability == AiEventReliability::Authoritative
        && is_authoritative_routing_type(event)
        && event.tab_id.is_none()
}

/// Give up on routing: retries exhausted, or nothing to route by.
pub fn should_drop_after_routing_failure(
    event: &AiEvent,
    retry_attempts: usize,
    max_retry_attempts: usize,
) -> bool {
    requires_authoritative_routing(event)
        && (retry_attempts >= max_retry_attempts
            || (event.session_id.is_none() && event.directory.is_none()))
}

pub fn unresolved_routing_drop_reason(
    event: &AiEvent,
    retry_attempts: usize,
    max_retry_attempts: usize,
) -> String {
    let t = event.normalized_type();
    if event.session_id.is_none() && event.directory.is_none() {
        return format!("Authoritative {t} event missing exact routing identity");
    }
    format!(
        "Authoritative {t} event unresolved after {retry_attempts}/{max_retry_attempts} routing attempts"
    )
}

/// Keys identifying "this kind of event for this session, tab or directory".
pub fn authority_keys(event: &AiEvent) -> Vec<String> {
    if !is_authoritative_routing_type(event) {
        return Vec::new();
    }
    let tool = event.tool.trim().to_lowercase();
    let mut identities = Vec::new();
    if let Some(session) = event
        .session_id
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        identities.push(format!("session:{}", session.to_lowercase()));
    }
    if let Some(tab) = event.tab_id {
        identities.push(format!("tab:{}", tab.hyphenated()));
    }
    if let Some(dir) = event
        .directory
        .as_deref()
        .map(str::trim)
        .filter(|s| !s.is_empty())
    {
        identities.push(format!("dir:{}", standardize_path(dir).to_lowercase()));
    }
    if identities.is_empty() {
        identities.push(notification_identity_key(event));
    }
    let t = event.normalized_type();
    identities
        .into_iter()
        .map(|id| format!("{t}|{tool}|{id}"))
        .collect()
}

pub fn authority_key(event: &AiEvent) -> Option<String> {
    authority_keys(event).into_iter().next()
}

/// A non-authoritative event shadowed by a recent authoritative one.
pub fn should_suppress_as_fallback(
    event: &AiEvent,
    authoritative_events: &HashMap<String, Instant>,
    now: Instant,
    retention: Duration,
) -> bool {
    if event.reliability == AiEventReliability::Authoritative {
        return false;
    }
    authority_keys(event).iter().any(|key| {
        authoritative_events
            .get(key)
            .is_some_and(|seen| now.saturating_duration_since(*seen) <= retention)
    })
}

// MARK: - Preparation

/// An event ready for the pipeline (`NotificationEventPreparation.PreparedEvent`).
#[derive(Debug, Clone, PartialEq)]
pub struct PreparedEvent {
    pub event: AiEvent,
    /// `explicit_tab`, `resolved_via_tab_resolver` or `unresolved`.
    pub resolution_method: String,
}

#[derive(Debug, Clone, PartialEq)]
#[allow(clippy::large_enum_variant)]
pub enum Preparation {
    Drop { reason: String },
    Proceed(PreparedEvent),
}

/// Maps a routing target to the tab it belongs to.
pub type TabResolverFn<'a> = &'a mut dyn FnMut(&TabTarget) -> Option<Uuid>;

/// Whether this app instance hosts (or hosted) a tab.
pub type TabOwnerFn<'a> = &'a mut dyn FnMut(Uuid) -> bool;

/// Why an event naming another instance's tab is dropped.
pub const FOREIGN_TAB_REASON: &str = "Tab belongs to another Chau7 instance";

/// Tabs this instance has hosted. The AI event log and CLI hooks are shared
/// by every Chau7 instance on the Mac, so an explicit tab id may name a tab
/// of another running app; only ids seen here are owned. A tab closed
/// moments before its event stays owned, so its result still resolves.
#[derive(Debug, Default)]
pub struct KnownTabs {
    seen: HashSet<Uuid>,
    order: VecDeque<Uuid>,
}

impl KnownTabs {
    /// Ids remembered beyond the live tabs; the oldest are forgotten first.
    pub const CAPACITY: usize = 4096;

    /// Remember the tabs open right now.
    pub fn observe(&mut self, live: impl IntoIterator<Item = Uuid>) {
        for tab in live {
            if self.seen.insert(tab) {
                self.order.push_back(tab);
            }
        }
        while self.order.len() > Self::CAPACITY {
            if let Some(oldest) = self.order.pop_front() {
                self.seen.remove(&oldest);
            }
        }
    }

    pub fn owns(&self, tab: Uuid) -> bool {
        self.seen.contains(&tab)
    }
}

/// Drop disabled triggers first (without resolving a tab), then events
/// naming a tab this instance does not own, then fill in the tab id when the
/// event has none.
pub fn prepare(
    event: &AiEvent,
    trigger_state: &NotificationTriggerState,
    tab_resolver: Option<TabResolverFn>,
    owns_tab: Option<TabOwnerFn>,
) -> Preparation {
    if let Some(trigger) = triggers::trigger_for_event(event)
        && !trigger_state.is_enabled(trigger)
    {
        return Preparation::Drop {
            reason: format!("Trigger {} disabled", trigger.id),
        };
    }
    if let Some(tab) = event.tab_id {
        if let Some(owns) = owns_tab
            && !owns(tab)
        {
            return Preparation::Drop {
                reason: FOREIGN_TAB_REASON.into(),
            };
        }
        return Preparation::Proceed(PreparedEvent {
            event: event.clone(),
            resolution_method: "explicit_tab".into(),
        });
    }
    let Some(resolver) = tab_resolver else {
        return Preparation::Proceed(PreparedEvent {
            event: event.clone(),
            resolution_method: "unresolved".into(),
        });
    };
    let resolved = resolver(&event.tab_target());
    Preparation::Proceed(PreparedEvent {
        event: event.resolving_tab_id(resolved),
        resolution_method: if resolved.is_some() {
            "resolved_via_tab_resolver"
        } else {
            "unresolved"
        }
        .into(),
    })
}

/// Derive presentation semantics through the canonical adapter contract,
/// including source-specific shell/app types absent from raw AI vocabulary.
pub fn semantic_kind(event: &AiEvent) -> super::canonical::NotificationSemanticKind {
    use super::{adapters, canonical};
    let kind = canonical::kind_with_canonical_type(
        event.raw_type.as_deref(),
        event.notification_type.as_deref(),
        Some(&event.event_type),
    );
    if kind != canonical::NotificationSemanticKind::Unknown {
        return kind;
    }
    adapters::adapt(event)
        .canonical_event()
        .map(|canonical| canonical.kind)
        .unwrap_or(kind)
}

/// Current authoritative evidence clears a lingering interactive style when
/// it no longer describes an active prompt. Tool failures remain stateless
/// to the reconciler, but still prove the provider is actively working.
pub fn should_clear_persistent_attention_style(
    event: &AiEvent,
    kind: super::canonical::NotificationSemanticKind,
) -> bool {
    use super::canonical::{self, NotificationSemanticKind as K};
    if event.reliability != AiEventReliability::Authoritative {
        return false;
    }
    match kind {
        K::PermissionRequired | K::WaitingForInput | K::AttentionRequired => false,
        K::Idle => !canonical::is_input_prompt_like(
            event.title.as_deref(),
            &event.message,
            event.notification_type.as_deref(),
        ),
        _ => true,
    }
}

// MARK: - Style planner

/// Current vocabulary style with a semantic fallback for normalized aliases.
/// Defaults have no timer: acknowledgement clears non-persistent styles.
pub fn default_style_action(event: &AiEvent) -> Option<NotificationActionConfig> {
    use super::vocabulary;
    let direct = vocabulary::entry(&event.event_type).and_then(|e| e.style);
    let semantic = semantic_kind(event);
    let preset = direct.or_else(|| {
        vocabulary::semantic_trigger(semantic)
            .and_then(vocabulary::entry)
            .and_then(|e| e.style)
    })?;
    Some(
        NotificationActionConfig::new(NotificationActionType::StyleTab)
            .with_config([("style", preset)]),
    )
}

/// Style actions to run when the event's tab is the selected one: the
/// enabled style actions, else the default style unless a (disabled) style
/// action was configured.
pub fn style_only_actions(
    event: &AiEvent,
    resolved_actions: &[NotificationActionConfig],
) -> Vec<NotificationActionConfig> {
    let enabled: Vec<_> = resolved_actions
        .iter()
        .filter(|a| a.enabled && a.action_type == NotificationActionType::StyleTab)
        .cloned()
        .collect();
    if !enabled.is_empty() {
        return enabled;
    }
    if resolved_actions
        .iter()
        .any(|a| a.action_type == NotificationActionType::StyleTab)
    {
        return Vec::new();
    }
    default_style_action(event).into_iter().collect()
}

/// The default style to add to configured actions that have no style action.
pub fn supplemental_style_action(
    event: &AiEvent,
    resolved_actions: &[NotificationActionConfig],
) -> Option<NotificationActionConfig> {
    if resolved_actions
        .iter()
        .any(|a| a.action_type == NotificationActionType::StyleTab)
    {
        return None;
    }
    default_style_action(event)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::event::AiEventSource;

    fn ev(source: AiEventSource, t: &str, reliability: AiEventReliability) -> AiEvent {
        let mut e = AiEvent::new(source, t, "Claude", "done", "2026-04-01T00:00:00Z");
        e.reliability = reliability;
        e
    }

    // NotificationDeliverySemanticsTests

    #[test]
    fn requires_authoritative_routing_for_core_event_without_tab_id() {
        let mut e = ev(
            AiEventSource::runtime(),
            "finished",
            AiEventReliability::Authoritative,
        );
        e.session_id = Some("session-1".into());
        assert!(requires_authoritative_routing(&e));
        e.tab_id = Some(Uuid::new_v4());
        assert!(!requires_authoritative_routing(&e));
    }

    #[test]
    fn does_not_require_authoritative_routing_for_fallback_event() {
        let mut e = ev(
            AiEventSource::history_monitor(),
            "finished",
            AiEventReliability::Fallback,
        );
        e.session_id = Some("session-1".into());
        assert!(!requires_authoritative_routing(&e));
    }

    #[test]
    fn suppresses_fallback_when_recent_authoritative_event_exists() {
        let mut fallback = ev(
            AiEventSource::history_monitor(),
            "finished",
            AiEventReliability::Fallback,
        );
        fallback.session_id = Some("session-1".into());
        let mut authoritative = ev(
            AiEventSource::runtime(),
            "finished",
            AiEventReliability::Authoritative,
        );
        authoritative.session_id = Some("session-1".into());
        let key = authority_key(&authoritative).unwrap();
        let now = Instant::now();
        let seen = HashMap::from([(key, now)]);
        assert!(should_suppress_as_fallback(
            &fallback,
            &seen,
            now,
            AUTHORITY_RETENTION
        ));
        assert!(!should_suppress_as_fallback(
            &fallback,
            &seen,
            now + Duration::from_secs(181),
            AUTHORITY_RETENTION
        ));
        assert!(!should_suppress_as_fallback(
            &authoritative,
            &seen,
            now,
            AUTHORITY_RETENTION
        ));
    }

    #[test]
    fn drops_unresolved_authoritative_event_after_retry_exhaustion() {
        let mut e = ev(
            AiEventSource::claude_code(),
            "finished",
            AiEventReliability::Authoritative,
        );
        e.session_id = Some("session-1".into());
        assert!(should_drop_after_routing_failure(&e, 3, 3));
        assert!(!should_drop_after_routing_failure(&e, 1, 3));
        assert_eq!(
            unresolved_routing_drop_reason(&e, 3, 3),
            "Authoritative finished event unresolved after 3/3 routing attempts"
        );
    }

    #[test]
    fn drops_authoritative_event_missing_exact_identity() {
        let e = ev(
            AiEventSource::claude_code(),
            "permission",
            AiEventReliability::Authoritative,
        );
        assert!(should_drop_after_routing_failure(&e, 0, 3));
        assert_eq!(
            unresolved_routing_drop_reason(&e, 0, 3),
            "Authoritative permission event missing exact routing identity"
        );
    }

    #[test]
    fn authority_keys_cover_every_identity() {
        let mut e = ev(
            AiEventSource::runtime(),
            "Finished",
            AiEventReliability::Authoritative,
        );
        assert_eq!(authority_keys(&e).len(), 1);
        assert!(authority_keys(&e)[0].starts_with("finished|claude|event:"));
        e.session_id = Some(" ABC ".into());
        e.tab_id = Some(Uuid::nil());
        e.directory = Some("/tmp/../tmp/X".into());
        assert_eq!(
            authority_keys(&e),
            [
                "finished|claude|session:abc",
                "finished|claude|tab:00000000-0000-0000-0000-000000000000",
                "finished|claude|dir:/tmp/x",
            ]
        );
        e.event_type = "info".into();
        assert!(authority_keys(&e).is_empty());
    }

    // NotificationEventPreparationTests

    #[test]
    fn prepare_drops_disabled_trigger_without_resolving_tab() {
        let e = ev(
            AiEventSource::claude_code(),
            "finished",
            AiEventReliability::Authoritative,
        );
        let mut state = NotificationTriggerState::default();
        let trigger = triggers::trigger_for_event(&e).unwrap();
        state.set_enabled(false, trigger);
        let mut calls = 0;
        let mut resolver = |_: &TabTarget| {
            calls += 1;
            Some(Uuid::new_v4())
        };
        let decision = prepare(&e, &state, Some(&mut resolver), None);
        assert_eq!(calls, 0);
        assert_eq!(
            decision,
            Preparation::Drop {
                reason: "Trigger claude_code.finished disabled".into()
            }
        );
    }

    #[test]
    fn prepare_resolves_tab_for_enabled_trigger() {
        let expected = Uuid::new_v4();
        let mut e = ev(
            AiEventSource::claude_code(),
            "finished",
            AiEventReliability::Authoritative,
        );
        e.directory = Some("/tmp/chau7".into());
        e.session_id = Some("claude-session-1".into());
        let mut resolver = |target: &TabTarget| {
            assert_eq!(
                *target,
                TabTarget {
                    tool: "Claude".into(),
                    directory: Some("/tmp/chau7".into()),
                    tab_id: None,
                    session_id: Some("claude-session-1".into()),
                }
            );
            Some(expected)
        };
        match prepare(
            &e,
            &NotificationTriggerState::default(),
            Some(&mut resolver),
            None,
        ) {
            Preparation::Proceed(p) => {
                assert_eq!(p.event.tab_id, Some(expected));
                assert_eq!(p.resolution_method, "resolved_via_tab_resolver");
            }
            other => panic!("{other:?}"),
        }
        match prepare(&e, &NotificationTriggerState::default(), None, None) {
            Preparation::Proceed(p) => assert_eq!(p.resolution_method, "unresolved"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn prepare_keeps_explicit_tab_id_without_resolving_again() {
        let explicit = Uuid::new_v4();
        let mut e = ev(
            AiEventSource::claude_code(),
            "finished",
            AiEventReliability::Authoritative,
        );
        e.tab_id = Some(explicit);
        let mut calls = 0;
        let mut resolver = |_: &TabTarget| {
            calls += 1;
            Some(Uuid::new_v4())
        };
        match prepare(
            &e,
            &NotificationTriggerState::default(),
            Some(&mut resolver),
            None,
        ) {
            Preparation::Proceed(p) => {
                assert_eq!(p.event.tab_id, Some(explicit));
                assert_eq!(p.resolution_method, "explicit_tab");
            }
            other => panic!("{other:?}"),
        }
        assert_eq!(calls, 0);
    }

    #[test]
    fn events_for_another_instances_tab_are_dropped() {
        let mut known = KnownTabs::default();
        let mine = Uuid::new_v4();
        let closed_here = Uuid::new_v4();
        known.observe([mine, closed_here]);
        known.observe([mine]);
        let foreign = Uuid::new_v4();
        let decide = |tab: Uuid, known: &KnownTabs| {
            let mut e = ev(
                AiEventSource::codex(),
                "finished",
                AiEventReliability::Authoritative,
            );
            e.tab_id = Some(tab);
            let mut owns = |tab: Uuid| known.owns(tab);
            prepare(
                &e,
                &NotificationTriggerState::default(),
                None,
                Some(&mut owns),
            )
        };
        assert_eq!(
            decide(foreign, &known),
            Preparation::Drop {
                reason: FOREIGN_TAB_REASON.into()
            }
        );
        // A live tab, and one closed in this instance, still resolve.
        for tab in [mine, closed_here] {
            assert!(
                matches!(decide(tab, &known), Preparation::Proceed(_)),
                "{tab}"
            );
        }
    }

    #[test]
    fn known_tabs_are_bounded_oldest_first() {
        let mut known = KnownTabs::default();
        let first = Uuid::new_v4();
        known.observe([first]);
        known.observe((0..KnownTabs::CAPACITY).map(|_| Uuid::new_v4()));
        assert!(!known.owns(first));
        assert_eq!(known.order.len(), KnownTabs::CAPACITY);
    }

    // NotificationStylePlannerTests

    fn codex(t: &str) -> AiEvent {
        AiEvent::new(AiEventSource::codex(), t, "Codex", "done", "t")
    }

    #[test]
    fn style_only_actions_prefer_explicit_enabled_style() {
        let explicit = NotificationActionConfig::new(NotificationActionType::StyleTab)
            .with_config([("style", "attention")]);
        assert_eq!(
            style_only_actions(&codex("finished"), std::slice::from_ref(&explicit)),
            vec![explicit]
        );
    }

    #[test]
    fn style_only_actions_fall_back_to_default_style_when_no_style_action_exists() {
        let actions = style_only_actions(
            &codex("finished"),
            &[NotificationActionConfig::new(
                NotificationActionType::ShowNotification,
            )],
        );
        assert_eq!(actions.len(), 1);
        assert_eq!(actions[0].action_type, NotificationActionType::StyleTab);
        assert_eq!(actions[0].config_value("style"), Some("success"));
        assert_eq!(actions[0].config_value("autoClearSeconds"), None);
    }

    #[test]
    fn style_only_actions_respect_explicit_disabled_style_action() {
        let disabled = NotificationActionConfig::new(NotificationActionType::StyleTab)
            .with_enabled(false)
            .with_config([("style", "attention")]);
        assert!(style_only_actions(&codex("finished"), &[disabled]).is_empty());
    }

    #[test]
    fn supplemental_style_action_only_appears_when_no_style_action_exists() {
        let e = codex("permission");
        let fallback = supplemental_style_action(
            &e,
            &[NotificationActionConfig::new(
                NotificationActionType::DockBounce,
            )],
        )
        .unwrap();
        assert_eq!(fallback.action_type, NotificationActionType::StyleTab);
        assert_eq!(fallback.config_value("style"), Some("attention"));
        let explicit =
            NotificationActionConfig::new(NotificationActionType::StyleTab).with_enabled(false);
        assert!(supplemental_style_action(&e, &[explicit]).is_none());
    }

    #[test]
    fn authoritative_clear_preserves_prompts_and_clears_completed_or_working_evidence() {
        use super::super::canonical::NotificationSemanticKind as K;
        let mut e = codex("finished");
        e.reliability = AiEventReliability::Authoritative;
        for kind in [
            K::TaskFinished,
            K::TaskFailed,
            K::ToolFailed,
            K::AuthenticationSucceeded,
            K::Informational,
        ] {
            assert!(should_clear_persistent_attention_style(&e, kind));
        }
        for kind in [
            K::PermissionRequired,
            K::WaitingForInput,
            K::AttentionRequired,
        ] {
            assert!(!should_clear_persistent_attention_style(&e, kind));
        }
        e.message = "Waiting for your input".into();
        assert!(!should_clear_persistent_attention_style(&e, K::Idle));
        e.message.clear();
        assert!(should_clear_persistent_attention_style(&e, K::Idle));
        e.reliability = AiEventReliability::Fallback;
        assert!(!should_clear_persistent_attention_style(
            &e,
            K::TaskFinished
        ));
    }

    #[test]
    fn shell_and_app_specific_semantics_drive_current_presentation_and_queued_state() {
        use super::super::canonical::NotificationSemanticKind as K;
        for (kind, semantic, style) in [
            ("command_finished", K::TaskFinished, "success"),
            ("command_failed", K::TaskFailed, "error"),
            ("script_succeeded", K::TaskFinished, "success"),
            ("script_failed", K::TaskFailed, "error"),
            ("dev_server_started", K::Informational, "success"),
        ] {
            let e = ev(
                AiEventSource::shell(),
                kind,
                AiEventReliability::Authoritative,
            );
            assert_eq!(semantic_kind(&e), semantic);
            assert_eq!(
                default_style_action(&e).unwrap().config_value("style"),
                Some(style)
            );
        }
        let e = ev(
            AiEventSource::app(),
            "file_conflict",
            AiEventReliability::Authoritative,
        );
        assert_eq!(semantic_kind(&e), K::AttentionRequired);
        assert_eq!(
            default_style_action(&e).unwrap().config_value("style"),
            Some("attention")
        );
    }

    #[test]
    fn default_style_presets() {
        let preset = |t: &str| {
            default_style_action(&codex(t)).map(|a| a.config_value("style").unwrap().to_string())
        };
        assert_eq!(preset("ERROR").as_deref(), Some("error"));
        assert_eq!(preset("context_limit").as_deref(), Some("error"));
        assert_eq!(preset("attention_required").as_deref(), Some("attention"));
        assert_eq!(preset("idle").as_deref(), Some("waiting"));
        assert_eq!(preset("waiting_input").as_deref(), Some("waiting"));
        assert_eq!(preset("finished").as_deref(), Some("success"));
        assert_eq!(preset("agent-turn-complete").as_deref(), Some("success"));
        assert_eq!(preset("tool_failed").as_deref(), Some("error"));
        assert_eq!(
            default_style_action(&codex("finished"))
                .unwrap()
                .config_value("autoClearSeconds"),
            None
        );
        assert_eq!(preset("command_failed"), None);
    }
}
