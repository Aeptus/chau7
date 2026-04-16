import Foundation

public enum InactiveRetainedFrameRefreshAction: Equatable, Sendable {
    case skip
    case updatePending
    case schedule
}

public struct InactiveRetainedFrameRefreshDecision: Equatable, Sendable {
    public let action: InactiveRetainedFrameRefreshAction
    public let targetVersion: UInt64?
    public let delay: TimeInterval
    public let allowForcedSync: Bool

    public init(
        action: InactiveRetainedFrameRefreshAction,
        targetVersion: UInt64?,
        delay: TimeInterval,
        allowForcedSync: Bool
    ) {
        self.action = action
        self.targetVersion = targetVersion
        self.delay = delay
        self.allowForcedSync = allowForcedSync
    }

    public static let skip = InactiveRetainedFrameRefreshDecision(
        action: .skip,
        targetVersion: nil,
        delay: 0,
        allowForcedSync: false
    )
}

public enum InactiveRetainedFrameRefreshPolicy {
    public static func decide(
        phase: TabRenderPhase,
        hasRetainedFrameSourceReady: Bool,
        contentVersion: UInt64,
        sourceVersion: UInt64,
        lastRenderedVersion: UInt64,
        pendingVersion: UInt64?,
        now: TimeInterval,
        lastRefreshAt: TimeInterval,
        minInterval: TimeInterval
    ) -> InactiveRetainedFrameRefreshDecision {
        guard phase != .active else { return .skip }
        guard contentVersion > lastRenderedVersion else { return .skip }

        let allowForcedSync = !hasRetainedFrameSourceReady || sourceVersion < contentVersion

        if let pendingVersion {
            guard pendingVersion < contentVersion else { return .skip }
            return InactiveRetainedFrameRefreshDecision(
                action: .updatePending,
                targetVersion: contentVersion,
                delay: 0,
                allowForcedSync: allowForcedSync
            )
        }

        let delay = max(0, minInterval - (now - lastRefreshAt))
        return InactiveRetainedFrameRefreshDecision(
            action: .schedule,
            targetVersion: contentVersion,
            delay: delay,
            allowForcedSync: allowForcedSync
        )
    }
}
