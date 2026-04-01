import Foundation

public enum NotificationEventPreparation {
    public struct PreparedEvent: Equatable {
        public let event: AIEvent
        public let resolutionMethod: String

        public init(event: AIEvent, resolutionMethod: String) {
            self.event = event
            self.resolutionMethod = resolutionMethod
        }
    }

    public enum Decision: Equatable {
        case drop(reason: String)
        case proceed(PreparedEvent)
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

        guard event.tabID == nil else {
            return .proceed(PreparedEvent(event: event, resolutionMethod: "explicit_tab"))
        }

        guard let tabResolver else {
            return .proceed(PreparedEvent(event: event, resolutionMethod: "unresolved"))
        }

        let resolvedTabID = tabResolver(event.tabTarget)
        let resolutionMethod = resolvedTabID == nil ? "unresolved" : "resolved_via_tab_resolver"
        return .proceed(PreparedEvent(
            event: event.resolvingTabID(resolvedTabID),
            resolutionMethod: resolutionMethod
        ))
    }
}
