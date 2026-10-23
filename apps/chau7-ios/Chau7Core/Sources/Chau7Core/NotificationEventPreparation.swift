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
        _ = triggerState

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

        if NotificationDeliverySemantics.requiresAuthoritativeRouting(event) {
            return .proceed(PreparedEvent(
                event: event,
                resolutionMethod: "awaiting_authoritative_resolution"
            ))
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

        // Use replacingTabID(_:) so repoPath + every other field round-
        // trip cleanly — the hand-rolled rebuild this replaced was
        // silently dropping repoPath, which downstream relies on for
        // per-repo event filtering.
        return event.replacingTabID(resolvedTabID)
    }
}
