import Foundation

public enum AINotificationPrimaryEvent: String, CaseIterable, Identifiable, Sendable {
    case finished
    case failed
    case permission

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .finished: return "Finished"
        case .failed: return "Failed"
        case .permission: return "Permission Request"
        }
    }

    public var summary: String {
        switch self {
        case .finished: return "Task completed and is ready for review."
        case .failed: return "Task failed or exited with an error."
        case .permission: return "The agent needs your input to continue."
        }
    }
}

public struct AINotificationPrimaryPreference: Equatable, Sendable {
    public var showNotification: Bool
    public var styleTab: Bool
    public var playSound: Bool
    public var dockBounce: Bool
    public var hasAdditionalActions: Bool

    public init(
        showNotification: Bool,
        styleTab: Bool,
        playSound: Bool,
        dockBounce: Bool,
        hasAdditionalActions: Bool
    ) {
        self.showNotification = showNotification
        self.styleTab = styleTab
        self.playSound = playSound
        self.dockBounce = dockBounce
        self.hasAdditionalActions = hasAdditionalActions
    }
}

public enum AINotificationSettingsBridge {
    private static let managedActionTypes: Set<NotificationActionType> = [
        .showNotification, .styleTab, .playSound, .dockBounce
    ]

    public static func groupTriggerId(
        for event: AINotificationPrimaryEvent,
        group: NotificationTriggerGroup = NotificationTriggerCatalog.aiCodingGroup
    ) -> String {
        group.groupTriggerId(for: event.rawValue)
    }

    public static func preference(
        for event: AINotificationPrimaryEvent,
        currentActions: [NotificationActionConfig],
        defaultActions: [NotificationActionConfig]
    ) -> AINotificationPrimaryPreference {
        let resolvedActions = currentActions.isEmpty ? defaultActions : currentActions
        let actionTypes = Set(resolvedActions.filter(\.enabled).map(\.actionType))
        let extraActions = resolvedActions.contains { !managedActionTypes.contains($0.actionType) }

        return AINotificationPrimaryPreference(
            showNotification: actionTypes.contains(.showNotification),
            styleTab: actionTypes.contains(.styleTab),
            playSound: actionTypes.contains(.playSound),
            dockBounce: actionTypes.contains(.dockBounce),
            hasAdditionalActions: extraActions
        )
    }

    public static func isEffectivelyEnabled(
        for event: AINotificationPrimaryEvent,
        state: NotificationTriggerState,
        group: NotificationTriggerGroup = NotificationTriggerCatalog.aiCodingGroup,
        catalog: [NotificationTrigger] = NotificationTriggerCatalog.all
    ) -> Bool {
        catalog.contains {
            group.contains(source: $0.source)
                && $0.type == event.rawValue
                && state.isEnabled(for: $0)
        }
    }

    public static func updatedStateForPrimaryToggle(
        _ state: NotificationTriggerState,
        event: AINotificationPrimaryEvent,
        enabled: Bool,
        group: NotificationTriggerGroup = NotificationTriggerCatalog.aiCodingGroup,
        catalog: [NotificationTrigger] = NotificationTriggerCatalog.all
    ) -> NotificationTriggerState {
        var updated = state
        updated.setGroupEnabled(enabled, groupId: group.id, type: event.rawValue)
        for trigger in catalog where group.contains(source: trigger.source) && trigger.type == event.rawValue {
            updated.removeOverride(for: trigger)
        }
        return updated
    }

    public static func updatedActions(
        for event: AINotificationPrimaryEvent,
        preference: AINotificationPrimaryPreference,
        currentActions: [NotificationActionConfig],
        defaultActions: [NotificationActionConfig]
    ) -> [NotificationActionConfig] {
        let resolvedActions = currentActions.isEmpty ? defaultActions : currentActions
        let unmanagedActions = resolvedActions.filter { !managedActionTypes.contains($0.actionType) }
        let managedTemplates = Dictionary(
            (resolvedActions + defaultActions).map { ($0.actionType, $0) },
            uniquingKeysWith: { existing, _ in existing }
        )

        let desiredOrder: [(NotificationActionType, Bool)] = [
            (.showNotification, preference.showNotification),
            (.playSound, preference.playSound),
            (.dockBounce, preference.dockBounce),
            (.styleTab, preference.styleTab)
        ]

        let managedActions = desiredOrder.map { actionType, isEnabled -> NotificationActionConfig in
            if let template = managedTemplates[actionType] {
                return NotificationActionConfig(
                    id: template.id,
                    actionType: template.actionType,
                    enabled: isEnabled,
                    config: template.config
                )
            }
            return NotificationActionConfig(actionType: actionType, enabled: isEnabled)
        }

        return managedActions + unmanagedActions
    }
}
