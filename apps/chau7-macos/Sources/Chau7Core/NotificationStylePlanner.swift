import Foundation

public enum NotificationStylePlanner {
    public static func defaultStyleAction(for event: AIEvent) -> NotificationActionConfig? {
        // One vocabulary table declares the preset per trigger type; types
        // without a direct row fall back through the event's canonical
        // semantic trigger. This guarantees presentation for normalized
        // completion aliases without duplicating the preset mapping.
        let directPreset = TriggerVocabulary.entry(forType: event.type)?.stylePreset
        let canonicalPreset = SemanticTriggerType(kind: event.notificationSemanticKind)
            .flatMap { TriggerVocabulary.entry(forType: $0.rawValue)?.stylePreset }
        guard let preset = directPreset ?? canonicalPreset else {
            return nil
        }

        return NotificationActionConfig(
            actionType: .styleTab,
            enabled: true,
            // No timer by default: non-persistent styles are acknowledged and
            // cleared when the user selects the tab. Explicit user bindings
            // can still opt into autoClearSeconds.
            config: ["style": preset]
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
