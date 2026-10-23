import Foundation

public enum TerminalRenderRetryReason: String, Equatable, Sendable {
    case fontNotConfigured
    case gridUnavailable
    case zeroBounds
    case noDrawable
    case zeroCells
    case renderCommitFailed
}

public struct TerminalRenderRetryDecision: Equatable, Sendable {
    public let reason: TerminalRenderRetryReason
    public let consecutiveFailureCount: Int
    public let delay: TimeInterval
    public let shouldLog: Bool
}

public struct TerminalRenderRetrySnapshot: Equatable, Sendable {
    public let lastReason: TerminalRenderRetryReason?
    public let consecutiveFailureCount: Int
}

public enum TerminalRenderRetryPolicy {
    public static func decision(
        reason: TerminalRenderRetryReason,
        consecutiveFailureCount: Int
    ) -> TerminalRenderRetryDecision {
        let safeCount = max(1, consecutiveFailureCount)
        let delay: TimeInterval
        if safeCount <= 3 {
            delay = 0.05
        } else if safeCount <= 10 {
            delay = 0.10
        } else {
            delay = 0.25
        }

        return TerminalRenderRetryDecision(
            reason: reason,
            consecutiveFailureCount: safeCount,
            delay: delay,
            shouldLog: shouldLog(consecutiveFailureCount: safeCount)
        )
    }

    private static func shouldLog(consecutiveFailureCount: Int) -> Bool {
        consecutiveFailureCount == 1
            || consecutiveFailureCount == 3
            || consecutiveFailureCount.isMultiple(of: 10)
    }
}

public struct TerminalRenderRetryState: Equatable, Sendable {
    public private(set) var lastReason: TerminalRenderRetryReason?
    public private(set) var consecutiveFailureCount: Int

    public init(
        lastReason: TerminalRenderRetryReason? = nil,
        consecutiveFailureCount: Int = 0
    ) {
        self.lastReason = lastReason
        self.consecutiveFailureCount = max(0, consecutiveFailureCount)
    }

    public var snapshot: TerminalRenderRetrySnapshot {
        TerminalRenderRetrySnapshot(
            lastReason: lastReason,
            consecutiveFailureCount: consecutiveFailureCount
        )
    }

    @discardableResult
    public mutating func recordFailure(
        reason: TerminalRenderRetryReason
    ) -> TerminalRenderRetryDecision {
        if lastReason == reason {
            consecutiveFailureCount += 1
        } else {
            lastReason = reason
            consecutiveFailureCount = 1
        }

        return TerminalRenderRetryPolicy.decision(
            reason: reason,
            consecutiveFailureCount: consecutiveFailureCount
        )
    }

    public mutating func recordSuccess() {
        lastReason = nil
        consecutiveFailureCount = 0
    }
}
