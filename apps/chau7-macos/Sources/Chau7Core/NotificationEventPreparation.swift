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

        if let explicitTabID = event.tabID {
            if let correctedEvent = rebindAuthoritativeExplicitTabIfNeeded(event, tabResolver: tabResolver),
               correctedEvent.tabID != explicitTabID {
                return .proceed(PreparedEvent(
                    event: correctedEvent,
                    resolutionMethod: "explicit_tab_corrected_via_session"
                ))
            }
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

    private static func rebindAuthoritativeExplicitTabIfNeeded(
        _ event: AIEvent,
        tabResolver: ((TabTarget) -> UUID?)?
    ) -> AIEvent? {
        guard event.reliability == .authoritative,
              event.sessionID != nil,
              let tabResolver else {
            return nil
        }

        let target = TabTarget(
            tool: event.tool,
            directory: event.directory,
            tabID: nil,
            sessionID: event.sessionID
        )

        guard let resolvedTabID = tabResolver(target),
              resolvedTabID != event.tabID else {
            return nil
        }

        return AIEvent(
            id: event.id,
            source: event.source,
            type: event.type,
            rawType: event.rawType,
            tool: event.tool,
            title: event.title,
            message: event.message,
            notificationType: event.notificationType,
            ts: event.ts,
            directory: event.directory,
            tabID: resolvedTabID,
            sessionID: event.sessionID,
            producer: event.producer,
            reliability: event.reliability
        )
    }
}
