import Foundation

public enum NotificationEventPreparation {
    public enum Decision: Equatable {
        case drop(reason: String)
        case proceed(AIEvent)
    }

    public static func prepare(
        _ event: AIEvent,
        triggerState: NotificationTriggerState,
        tabResolver: ((TabTarget) -> UUID?)?
    ) -> Decision {
        if let trigger = NotificationTriggerCatalog.trigger(for: event),
           !triggerState.isEnabled(for: trigger) {
            return .drop(reason: "Trigger \(trigger.id) disabled")
        }

        guard event.tabID == nil, let tabResolver else {
            return .proceed(event)
        }

        return .proceed(event.resolvingTabID(tabResolver(event.tabTarget)))
    }
}
