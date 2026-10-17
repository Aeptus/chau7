//! Port of `NotificationActionRequirements.swift`: which notification actions
//! need a resolved tab target.

use super::actions::{NotificationActionConfig, NotificationActionType};

/// True when the (enabled) action must act on a specific resolved tab.
pub fn requires_resolved_tab_target(action: &NotificationActionConfig) -> bool {
    if !action.enabled {
        return false;
    }
    match action.action_type {
        NotificationActionType::StyleTab
        | NotificationActionType::BadgeTab
        | NotificationActionType::ExecuteSnippet => true,
        NotificationActionType::FocusWindow => action.config_bool("focusTab", true),
        _ => false,
    }
}

/// True when any action in the list needs a resolved tab target.
pub fn requires_resolved_tab_target_any(actions: &[NotificationActionConfig]) -> bool {
    actions.iter().any(requires_resolved_tab_target)
}

/// Splits actions into `(tab_scoped, non_tab_scoped)`, preserving order.
pub fn partition_by_resolved_tab_requirement(
    actions: &[NotificationActionConfig],
) -> (Vec<NotificationActionConfig>, Vec<NotificationActionConfig>) {
    let tab_scoped = actions
        .iter()
        .filter(|a| requires_resolved_tab_target(a))
        .cloned()
        .collect();
    let non_tab_scoped = actions
        .iter()
        .filter(|a| !requires_resolved_tab_target(a))
        .cloned()
        .collect();
    (tab_scoped, non_tab_scoped)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_style_action_requires_resolved_tab_target() {
        let config = NotificationActionConfig::new(NotificationActionType::StyleTab);
        assert!(requires_resolved_tab_target(&config));
    }

    #[test]
    fn test_focus_window_without_focus_tab_does_not_require_resolved_tab_target() {
        let config = NotificationActionConfig::new(NotificationActionType::FocusWindow)
            .with_config([("focusTab", "false")]);
        assert!(!requires_resolved_tab_target(&config));
    }

    #[test]
    fn test_partition_separates_tab_scoped_actions() {
        let actions = vec![
            NotificationActionConfig::new(NotificationActionType::ShowNotification),
            NotificationActionConfig::new(NotificationActionType::StyleTab),
            NotificationActionConfig::new(NotificationActionType::FocusWindow)
                .with_config([("focusTab", "false")]),
            NotificationActionConfig::new(NotificationActionType::BadgeTab),
        ];
        let (tab, non_tab) = partition_by_resolved_tab_requirement(&actions);
        let tab_types: Vec<_> = tab.iter().map(|a| a.action_type).collect();
        let non_tab_types: Vec<_> = non_tab.iter().map(|a| a.action_type).collect();
        assert_eq!(
            tab_types,
            vec![
                NotificationActionType::StyleTab,
                NotificationActionType::BadgeTab
            ]
        );
        assert_eq!(
            non_tab_types,
            vec![
                NotificationActionType::ShowNotification,
                NotificationActionType::FocusWindow
            ]
        );
    }

    #[test]
    fn test_disabled_and_default_focus_branches() {
        let disabled =
            NotificationActionConfig::new(NotificationActionType::StyleTab).with_enabled(false);
        assert!(!requires_resolved_tab_target(&disabled));
        // focusTab defaults to true when absent.
        let focus = NotificationActionConfig::new(NotificationActionType::FocusWindow);
        assert!(requires_resolved_tab_target(&focus));
        let snippet = NotificationActionConfig::new(NotificationActionType::ExecuteSnippet);
        assert!(requires_resolved_tab_target_any(&[
            NotificationActionConfig::new(NotificationActionType::PlaySound),
            snippet
        ]));
        assert!(!requires_resolved_tab_target_any(&[]));
    }
}
