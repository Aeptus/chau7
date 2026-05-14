import Foundation

/// Pure policy for turning terminal session state into tab-level attention.
///
/// Notifications are delivery side effects. This state is the invariant the UI
/// must keep true: a tab with a waiting/approval session should visibly show
/// persistent attention until the session state proves it is no longer blocked.
public enum TabAttentionKind: String, Codable, CaseIterable, Equatable {
    case none
    case waitingForInput
    case approvalRequired

    public var priority: Int {
        switch self {
        case .none: return 0
        case .waitingForInput: return 10
        case .approvalRequired: return 20
        }
    }

    public var isInteractive: Bool {
        self != .none
    }

    public static func fromStatus(_ rawStatus: String?) -> TabAttentionKind {
        switch rawStatus {
        case "waitingForInput":
            return .waitingForInput
        case "approvalRequired":
            return .approvalRequired
        default:
            return .none
        }
    }

    public static func strongest(statuses: [String]) -> TabAttentionKind {
        statuses
            .map { fromStatus($0) }
            .max { $0.priority < $1.priority } ?? .none
    }
}

public struct TabAttentionSnapshot: Equatable {
    public let rawStatuses: [String]
    public let currentOwnedKind: TabAttentionKind
    public let hasVisibleStyle: Bool

    public init(
        rawStatuses: [String],
        currentOwnedKind: TabAttentionKind,
        hasVisibleStyle: Bool
    ) {
        self.rawStatuses = rawStatuses
        self.currentOwnedKind = currentOwnedKind
        self.hasVisibleStyle = hasVisibleStyle
    }
}

public enum TabAttentionReconcileAction: String, Codable, Equatable {
    case none
    case apply
    case repairMissingStyle
    case clearOwnedStyle
    case releaseOwnership
}

public struct TabAttentionDecision: Equatable {
    public let desiredKind: TabAttentionKind
    public let action: TabAttentionReconcileAction
    public let shouldApplyStyle: Bool
    public let shouldClearVisibleStyle: Bool
    public let nextOwnedKind: TabAttentionKind
    public let reason: String

    public init(
        desiredKind: TabAttentionKind,
        action: TabAttentionReconcileAction,
        shouldApplyStyle: Bool,
        shouldClearVisibleStyle: Bool,
        nextOwnedKind: TabAttentionKind,
        reason: String
    ) {
        self.desiredKind = desiredKind
        self.action = action
        self.shouldApplyStyle = shouldApplyStyle
        self.shouldClearVisibleStyle = shouldClearVisibleStyle
        self.nextOwnedKind = nextOwnedKind
        self.reason = reason
    }
}

public enum TabAttentionStatePolicy {
    public static func reconcile(_ snapshot: TabAttentionSnapshot) -> TabAttentionDecision {
        let desiredKind = TabAttentionKind.strongest(statuses: snapshot.rawStatuses)

        if desiredKind.isInteractive {
            if snapshot.currentOwnedKind == desiredKind {
                if snapshot.hasVisibleStyle {
                    return decision(
                        desiredKind: desiredKind,
                        action: .none,
                        nextOwnedKind: desiredKind,
                        reason: "state_attention_already_visible"
                    )
                }
                return decision(
                    desiredKind: desiredKind,
                    action: .repairMissingStyle,
                    shouldApplyStyle: true,
                    nextOwnedKind: desiredKind,
                    reason: "state_attention_style_missing"
                )
            }

            return decision(
                desiredKind: desiredKind,
                action: .apply,
                shouldApplyStyle: true,
                nextOwnedKind: desiredKind,
                reason: "state_requires_attention"
            )
        }

        guard snapshot.currentOwnedKind.isInteractive else {
            return decision(
                desiredKind: .none,
                action: .none,
                nextOwnedKind: .none,
                reason: "state_does_not_require_attention"
            )
        }

        if snapshot.hasVisibleStyle {
            return decision(
                desiredKind: .none,
                action: .clearOwnedStyle,
                shouldClearVisibleStyle: true,
                nextOwnedKind: .none,
                reason: "state_attention_resolved"
            )
        }

        return decision(
            desiredKind: .none,
            action: .releaseOwnership,
            nextOwnedKind: .none,
            reason: "state_attention_already_cleared"
        )
    }

    private static func decision(
        desiredKind: TabAttentionKind,
        action: TabAttentionReconcileAction,
        shouldApplyStyle: Bool = false,
        shouldClearVisibleStyle: Bool = false,
        nextOwnedKind: TabAttentionKind,
        reason: String
    ) -> TabAttentionDecision {
        TabAttentionDecision(
            desiredKind: desiredKind,
            action: action,
            shouldApplyStyle: shouldApplyStyle,
            shouldClearVisibleStyle: shouldClearVisibleStyle,
            nextOwnedKind: nextOwnedKind,
            reason: reason
        )
    }
}
