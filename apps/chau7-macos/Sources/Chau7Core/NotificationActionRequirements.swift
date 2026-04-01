import Foundation

public enum NotificationActionRequirements {
    public static func requiresResolvedTabTarget(_ action: NotificationActionConfig) -> Bool {
        guard action.enabled else { return false }

        switch action.actionType {
        case .styleTab, .badgeTab, .executeSnippet:
            return true
        case .focusWindow:
            return action.configBool("focusTab", default: true)
        default:
            return false
        }
    }

    public static func requiresResolvedTabTarget(actions: [NotificationActionConfig]) -> Bool {
        actions.contains(where: requiresResolvedTabTarget)
    }

    public static func partitionByResolvedTabRequirement(
        _ actions: [NotificationActionConfig]
    ) -> (tabScoped: [NotificationActionConfig], nonTabScoped: [NotificationActionConfig]) {
        let tabScoped = actions.filter(requiresResolvedTabTarget)
        let nonTabScoped = actions.filter { !requiresResolvedTabTarget($0) }
        return (tabScoped, nonTabScoped)
    }
}
