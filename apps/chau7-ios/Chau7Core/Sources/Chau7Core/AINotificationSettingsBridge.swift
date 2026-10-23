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
    /// Actions surfaced as the primary AI-coding toggles. Derived from
    /// `NotificationActionType.isAICodingPrimary` so adding a new action
    /// to the catalog is a single switch-case decision rather than a
    /// separate edit to this file.
    private static let managedActionTypes: Set<NotificationActionType> = Set(
        NotificationActionType.allCases.filter(\.isAICodingPrimary)
    )

    public static func managedTriggerTypes(for event: AINotificationPrimaryEvent) -> [String] {
        switch event {
        case .finished:
            return ["finished"]
        case .permission:
            return ["permission", "waiting_input", "attention_required"]
        case .failed:
            return [event.rawValue]
        }
    }

    public static func groupTriggerId(
        for event: AINotificationPrimaryEvent,
        group: NotificationTriggerGroup = NotificationTriggerCatalog.aiCodingGroup
    ) -> String {
        group.groupTriggerId(for: event.rawValue)
    }

    public static func preference(
        for _: AINotificationPrimaryEvent,
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
        let triggerTypes = Set(managedTriggerTypes(for: event))
        return catalog.contains {
            group.contains(source: $0.source)
                && triggerTypes.contains($0.type)
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
        let triggerTypes = Set(managedTriggerTypes(for: event))
        for type in triggerTypes {
            updated.setGroupEnabled(enabled, groupId: group.id, type: type)
        }
        for trigger in catalog where group.contains(source: trigger.source) && triggerTypes.contains(trigger.type) {
            updated.removeOverride(for: trigger)
        }
        return updated
    }

    public static func updatedActions(
        for _: AINotificationPrimaryEvent,
        preference: AINotificationPrimaryPreference,
        currentActions: [NotificationActionConfig],
        defaultActions: [NotificationActionConfig]
    ) -> [NotificationActionConfig] {
        let resolvedActions = currentActions.isEmpty ? defaultActions : currentActions
        let unmanagedActions = resolvedActions.filter { !managedActionTypes.contains($0.actionType) }
        // Build the managed-action template dictionary base from defaults,
        // then override with resolved (user-customized) values. Written this
        // way so the merge semantics are obvious without cross-referencing
        // Swift's `Dictionary(_:uniquingKeysWith:)` — `uniquingKeysWith`
        // fires on duplicate *inserts* and the `existing` closure parameter
        // refers to the *first* insert. Previously this built the dict from
        // `resolvedActions + defaultActions` with `existing` wins, which
        // meant "resolved wins over default" via ordering + closure — two
        // layers of indirection to get a simple override.
        var managedTemplates: [NotificationActionType: NotificationActionConfig] = Dictionary(
            uniqueKeysWithValues: defaultActions.map { ($0.actionType, $0) }
        )
        for action in resolvedActions {
            managedTemplates[action.actionType] = action
        }

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
