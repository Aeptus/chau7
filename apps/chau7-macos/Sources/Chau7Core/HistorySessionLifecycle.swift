import Foundation

public enum HistorySessionState: String, Sendable {
    case active
    case idle
    case closed
}

public struct HistorySessionTransitionDecision: Equatable, Sendable {
    public let shouldPersistState: Bool
    public let emitsFinishedEvent: Bool
    public let isReactivation: Bool

    public init(shouldPersistState: Bool, emitsFinishedEvent: Bool, isReactivation: Bool) {
        self.shouldPersistState = shouldPersistState
        self.emitsFinishedEvent = emitsFinishedEvent
        self.isReactivation = isReactivation
    }
}

public enum HistorySessionLifecycle {
    public static func evaluate(
        previousState: HistorySessionState?,
        nextState: HistorySessionState,
        lastActivityKind: HistoryEntryActivityKind = .unknown
    ) -> HistorySessionTransitionDecision {
        let isReactivation = previousState == .closed && nextState == .active
        let sessionEnded = nextState == .idle || nextState == .closed
        let wasActiveOrNew = previousState == .active || previousState == nil
        return HistorySessionTransitionDecision(
            shouldPersistState: true,
            emitsFinishedEvent: wasActiveOrNew && sessionEnded && lastActivityKind.supportsFinishedEvent,
            isReactivation: isReactivation
        )
    }
}
