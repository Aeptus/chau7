//! Port of `apps/chau7-macos/Sources/Chau7Core/AINotificationSettingsBridge.swift`.
//!
//! Maps the three primary AI notification toggles (finished, failed,
//! permission) to the underlying trigger ids, the "All AI Sources" group
//! trigger state and the action lists shown in Settings ("AI Notification
//! Essentials").

use std::collections::{HashMap, HashSet};

use crate::notifications::actions::{NotificationActionConfig, NotificationActionType};
use crate::notifications::triggers::{
    self, NotificationTrigger, NotificationTriggerGroup, NotificationTriggerState,
};

/// Raw value of `NotificationTriggerCatalog.aiCodingGroup.id`.
pub const AI_CODING_GROUP_ID: &str = "ai_coding";

const MANAGED_ACTION_TYPES: [NotificationActionType; 4] = [
    NotificationActionType::ShowNotification,
    NotificationActionType::StyleTab,
    NotificationActionType::PlaySound,
    NotificationActionType::DockBounce,
];

/// The three primary toggles (`AINotificationPrimaryEvent`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum AiNotificationPrimaryEvent {
    Finished,
    Failed,
    Permission,
}

impl AiNotificationPrimaryEvent {
    pub const ALL: [Self; 3] = [Self::Finished, Self::Failed, Self::Permission];

    /// The Swift raw value (also the `id`).
    pub fn raw_value(self) -> &'static str {
        match self {
            Self::Finished => "finished",
            Self::Failed => "failed",
            Self::Permission => "permission",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Finished => "Finished",
            Self::Failed => "Failed",
            Self::Permission => "Permission Request",
        }
    }

    pub fn summary(self) -> &'static str {
        match self {
            Self::Finished => "Task completed and is ready for review.",
            Self::Failed => "Task failed or exited with an error.",
            Self::Permission => "The agent needs your input to continue.",
        }
    }
}

/// Which managed actions are on for a primary event
/// (`AINotificationPrimaryPreference`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct AiNotificationPrimaryPreference {
    pub show_notification: bool,
    pub style_tab: bool,
    pub play_sound: bool,
    pub dock_bounce: bool,
    pub has_additional_actions: bool,
}

fn is_managed(action_type: NotificationActionType) -> bool {
    MANAGED_ACTION_TYPES.contains(&action_type)
}

/// Trigger types controlled by a primary toggle
/// (`AINotificationSettingsBridge.managedTriggerTypes`).
pub fn managed_trigger_types(event: AiNotificationPrimaryEvent) -> Vec<&'static str> {
    match event {
        AiNotificationPrimaryEvent::Finished => vec!["finished"],
        AiNotificationPrimaryEvent::Permission => {
            vec!["permission", "waiting_input", "attention_required"]
        }
        AiNotificationPrimaryEvent::Failed => vec![event.raw_value()],
    }
}

/// Group trigger id for a primary event: `"<group id>.<type>"`
/// (`NotificationTriggerGroup.groupTriggerId`), for example
/// `ai_coding.finished`.
pub fn group_trigger_id(event: AiNotificationPrimaryEvent, group_id: &str) -> String {
    format!("{group_id}.{}", event.raw_value())
}

fn resolved<'a>(
    current: &'a [NotificationActionConfig],
    defaults: &'a [NotificationActionConfig],
) -> &'a [NotificationActionConfig] {
    if current.is_empty() {
        defaults
    } else {
        current
    }
}

/// Reads the managed toggles out of an action list, falling back to the
/// defaults when the current list is empty
/// (`AINotificationSettingsBridge.preference`).
pub fn preference(
    _event: AiNotificationPrimaryEvent,
    current_actions: &[NotificationActionConfig],
    default_actions: &[NotificationActionConfig],
) -> AiNotificationPrimaryPreference {
    let actions = resolved(current_actions, default_actions);
    let enabled =
        |t: NotificationActionType| actions.iter().any(|a| a.enabled && a.action_type == t);
    AiNotificationPrimaryPreference {
        show_notification: enabled(NotificationActionType::ShowNotification),
        style_tab: enabled(NotificationActionType::StyleTab),
        play_sound: enabled(NotificationActionType::PlaySound),
        dock_bounce: enabled(NotificationActionType::DockBounce),
        has_additional_actions: actions.iter().any(|a| !is_managed(a.action_type)),
    }
}

/// True when any AI trigger the primary toggle manages is enabled
/// (`AINotificationSettingsBridge.isEffectivelyEnabled`, built-in catalog and
/// the "All AI Sources" group).
pub fn is_effectively_enabled(
    event: AiNotificationPrimaryEvent,
    state: &NotificationTriggerState,
) -> bool {
    is_effectively_enabled_in(event, state, triggers::ai_coding_group(), triggers::all())
}

/// [`is_effectively_enabled`] with an explicit group and catalog.
pub fn is_effectively_enabled_in(
    event: AiNotificationPrimaryEvent,
    state: &NotificationTriggerState,
    group: &NotificationTriggerGroup,
    catalog: &[NotificationTrigger],
) -> bool {
    let types: HashSet<&str> = managed_trigger_types(event).into_iter().collect();
    catalog.iter().any(|t| {
        group.contains(&t.source) && types.contains(t.trigger_type.as_str()) && state.is_enabled(t)
    })
}

/// Sets the group overrides for every managed trigger type and clears the
/// per-source overrides of those triggers
/// (`AINotificationSettingsBridge.updatedStateForPrimaryToggle`).
pub fn updated_state_for_primary_toggle(
    state: &NotificationTriggerState,
    event: AiNotificationPrimaryEvent,
    enabled: bool,
) -> NotificationTriggerState {
    updated_state_for_primary_toggle_in(
        state,
        event,
        enabled,
        triggers::ai_coding_group(),
        triggers::all(),
    )
}

/// [`updated_state_for_primary_toggle`] with an explicit group and catalog.
pub fn updated_state_for_primary_toggle_in(
    state: &NotificationTriggerState,
    event: AiNotificationPrimaryEvent,
    enabled: bool,
    group: &NotificationTriggerGroup,
    catalog: &[NotificationTrigger],
) -> NotificationTriggerState {
    let mut updated = state.clone();
    let types = managed_trigger_types(event);
    for t in &types {
        updated.set_group_enabled(enabled, &group.id, t);
    }
    for trigger in catalog {
        if group.contains(&trigger.source) && types.contains(&trigger.trigger_type.as_str()) {
            updated.remove_override(trigger);
        }
    }
    updated
}

/// Rewrites an action list from a preference: the four managed actions first
/// (show, sound, dock bounce, tab style) keeping any existing config, then
/// all unmanaged actions untouched
/// (`AINotificationSettingsBridge.updatedActions`).
pub fn updated_actions(
    _event: AiNotificationPrimaryEvent,
    preference: &AiNotificationPrimaryPreference,
    current_actions: &[NotificationActionConfig],
    default_actions: &[NotificationActionConfig],
) -> Vec<NotificationActionConfig> {
    let actions = resolved(current_actions, default_actions);
    let unmanaged: Vec<NotificationActionConfig> = actions
        .iter()
        .filter(|a| !is_managed(a.action_type))
        .cloned()
        .collect();

    // First template per action type wins (current actions before defaults).
    let mut templates: HashMap<NotificationActionType, &NotificationActionConfig> = HashMap::new();
    for action in actions.iter().chain(default_actions.iter()) {
        templates.entry(action.action_type).or_insert(action);
    }

    let desired = [
        (
            NotificationActionType::ShowNotification,
            preference.show_notification,
        ),
        (NotificationActionType::PlaySound, preference.play_sound),
        (NotificationActionType::DockBounce, preference.dock_bounce),
        (NotificationActionType::StyleTab, preference.style_tab),
    ];

    let mut result: Vec<NotificationActionConfig> = desired
        .iter()
        .map(|(action_type, enabled)| match templates.get(action_type) {
            Some(template) => NotificationActionConfig {
                id: template.id,
                action_type: template.action_type,
                enabled: *enabled,
                config: template.config.clone(),
            },
            None => NotificationActionConfig::new(*action_type).with_enabled(*enabled),
        })
        .collect();
    result.extend(unmanaged);
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ai::event::AiEventSource;
    use NotificationActionType as T;

    fn types(actions: &[NotificationActionConfig]) -> Vec<NotificationActionType> {
        actions.iter().map(|a| a.action_type).collect()
    }

    fn cfg(
        action_type: NotificationActionType,
        pairs: &[(&str, &str)],
    ) -> NotificationActionConfig {
        NotificationActionConfig::new(action_type).with_config(pairs.iter().copied())
    }

    fn codex(t: &str) -> &'static NotificationTrigger {
        triggers::trigger(&AiEventSource::codex(), t).unwrap()
    }

    #[test]
    fn preference_uses_default_actions_when_current_actions_are_empty() {
        let defaults = [
            NotificationActionConfig::new(T::ShowNotification),
            NotificationActionConfig::new(T::StyleTab),
        ];
        let pref = preference(AiNotificationPrimaryEvent::Finished, &[], &defaults);
        assert!(pref.show_notification);
        assert!(pref.style_tab);
        assert!(!pref.play_sound);
        assert!(!pref.dock_bounce);
        assert!(!pref.has_additional_actions);
    }

    #[test]
    fn preference_detects_additional_actions() {
        let current = [
            NotificationActionConfig::new(T::ShowNotification),
            cfg(T::RunScript, &[("path", "/tmp/a.sh")]),
        ];
        let pref = preference(AiNotificationPrimaryEvent::Failed, &current, &[]);
        assert!(pref.show_notification);
        assert!(pref.has_additional_actions);
    }

    #[test]
    fn updated_actions_preserves_unknown_actions_and_managed_configs() {
        let custom_sound = cfg(T::PlaySound, &[("sound", "Purr"), ("volume", "60")]);
        let extra = cfg(T::RunScript, &[("path", "/tmp/hook.sh")]);
        let updated = updated_actions(
            AiNotificationPrimaryEvent::Permission,
            &AiNotificationPrimaryPreference {
                show_notification: true,
                style_tab: false,
                play_sound: true,
                dock_bounce: false,
                has_additional_actions: true,
            },
            &[custom_sound.clone(), extra],
            &[NotificationActionConfig::new(T::ShowNotification)],
        );
        assert_eq!(
            types(&updated),
            [
                T::ShowNotification,
                T::PlaySound,
                T::DockBounce,
                T::StyleTab,
                T::RunScript
            ]
        );
        let sound = updated
            .iter()
            .find(|a| a.action_type == T::PlaySound)
            .unwrap();
        assert_eq!(sound.config_value("sound"), Some("Purr"));
        assert_eq!(sound.id, custom_sound.id);
        assert_eq!(updated.last().unwrap().action_type, T::RunScript);
        let by = |t: T| updated.iter().find(|a| a.action_type == t).unwrap().enabled;
        assert!(!by(T::DockBounce));
        assert!(!by(T::StyleTab));
    }

    #[test]
    fn updated_actions_can_disable_managed_actions_without_removing_extras() {
        let extra = cfg(T::Webhook, &[("url", "https://example.com")]);
        let updated = updated_actions(
            AiNotificationPrimaryEvent::Finished,
            &AiNotificationPrimaryPreference {
                show_notification: false,
                style_tab: false,
                play_sound: false,
                dock_bounce: false,
                has_additional_actions: true,
            },
            &[extra],
            &[
                NotificationActionConfig::new(T::ShowNotification),
                NotificationActionConfig::new(T::StyleTab),
            ],
        );
        assert_eq!(
            types(&updated),
            [
                T::ShowNotification,
                T::PlaySound,
                T::DockBounce,
                T::StyleTab,
                T::Webhook
            ]
        );
        assert!(updated[..4].iter().all(|a| !a.enabled));
        assert_eq!(updated[4].action_type, T::Webhook);
    }

    #[test]
    fn is_effectively_enabled_uses_per_trigger_overrides() {
        let trigger = codex("finished");
        let mut state = NotificationTriggerState::default();
        state.set_group_enabled(false, &triggers::ai_coding_group().id, "finished");
        state.set_enabled(true, trigger);
        assert!(is_effectively_enabled(
            AiNotificationPrimaryEvent::Finished,
            &state
        ));
    }

    #[test]
    fn updated_state_for_primary_toggle_clears_per_source_overrides() {
        let trigger = codex("finished");
        let mut state = NotificationTriggerState::default();
        state.set_enabled(false, trigger);
        let updated =
            updated_state_for_primary_toggle(&state, AiNotificationPrimaryEvent::Finished, true);
        assert_eq!(updated.overrides.get(&trigger.id), None);
        assert_eq!(
            updated.group_overrides.get("ai_coding.finished"),
            Some(&true)
        );
    }

    #[test]
    fn finished_primary_event_no_longer_covers_waiting_input() {
        let waiting = codex("waiting_input");
        let finished = codex("finished");
        let mut state = NotificationTriggerState::default();
        state.set_enabled(false, finished);
        state.set_enabled(true, waiting);
        let updated =
            updated_state_for_primary_toggle(&state, AiNotificationPrimaryEvent::Finished, false);
        assert_eq!(updated.overrides.get(&waiting.id), Some(&true));
        assert_eq!(
            updated.group_overrides.get("ai_coding.finished"),
            Some(&false)
        );
        assert_eq!(updated.group_overrides.get("ai_coding.waiting_input"), None);
    }

    #[test]
    fn permission_primary_event_covers_waiting_input() {
        let waiting = codex("waiting_input");
        let mut state = NotificationTriggerState::default();
        state.set_enabled(true, waiting);
        assert!(is_effectively_enabled(
            AiNotificationPrimaryEvent::Permission,
            &state
        ));
    }

    #[test]
    fn permission_primary_toggle_also_controls_attention_required() {
        let attention = codex("attention_required");
        let mut state = NotificationTriggerState::default();
        state.set_enabled(true, attention);
        let updated =
            updated_state_for_primary_toggle(&state, AiNotificationPrimaryEvent::Permission, false);
        assert_eq!(updated.overrides.get(&attention.id), None);
        for key in [
            "ai_coding.permission",
            "ai_coding.waiting_input",
            "ai_coding.attention_required",
        ] {
            assert_eq!(updated.group_overrides.get(key), Some(&false));
        }
    }

    #[test]
    fn managed_trigger_types_per_event() {
        use AiNotificationPrimaryEvent as E;
        assert_eq!(managed_trigger_types(E::Finished), ["finished"]);
        assert_eq!(managed_trigger_types(E::Failed), ["failed"]);
        assert_eq!(
            managed_trigger_types(E::Permission),
            ["permission", "waiting_input", "attention_required"]
        );
    }

    #[test]
    fn group_trigger_id_joins_group_and_event() {
        assert_eq!(
            group_trigger_id(AiNotificationPrimaryEvent::Finished, AI_CODING_GROUP_ID),
            "ai_coding.finished"
        );
        assert_eq!(triggers::ai_coding_group().id, AI_CODING_GROUP_ID);
    }

    #[test]
    fn primary_event_metadata() {
        use AiNotificationPrimaryEvent as E;
        assert_eq!(E::ALL.len(), 3);
        assert_eq!(E::Permission.title(), "Permission Request");
        assert_eq!(E::Failed.summary(), "Task failed or exited with an error.");
        assert_eq!(E::Finished.raw_value(), "finished");
    }
}
