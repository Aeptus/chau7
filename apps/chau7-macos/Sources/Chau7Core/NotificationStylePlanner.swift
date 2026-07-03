import Foundation

public enum NotificationStylePlanner {
    public static func defaultStyleAction(for event: AIEvent) -> NotificationActionConfig? {
        // One vocabulary table declares the preset per trigger type; types
        // without a preset (informational ones) get no default styling.
        guard let preset = TriggerVocabulary.entry(forType: event.type)?.stylePreset else {
            return nil
        }

        return NotificationActionConfig(
            actionType: .styleTab,
            enabled: true,
            config: ["style": preset, "autoClearSeconds": "30"]
        )
    }

    public static func styleOnlyActions(
        for event: AIEvent,
        from resolvedActions: [NotificationActionConfig]
    ) -> [NotificationActionConfig] {
        let enabledStyleActions = resolvedActions.filter { $0.enabled && $0.actionType == .styleTab }
        if !enabledStyleActions.isEmpty {
            return enabledStyleActions
        }

        let hasExplicitStyleAction = resolvedActions.contains { $0.actionType == .styleTab }
        guard !hasExplicitStyleAction, let fallback = defaultStyleAction(for: event) else {
            return []
        }
        return [fallback]
    }

    public static func supplementalStyleAction(
        for event: AIEvent,
        from resolvedActions: [NotificationActionConfig]
    ) -> NotificationActionConfig? {
        guard !resolvedActions.contains(where: { $0.actionType == .styleTab }) else {
            return nil
        }
        return defaultStyleAction(for: event)
    }
}
