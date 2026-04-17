import Foundation

public enum TabRenderPhase: String, Equatable, Sendable {
    case active
    case passiveVisible
    case warm
    case hidden

    public var keepsTerminalStateCurrent: Bool {
        self != .hidden
    }

    public var allowsLivePresentation: Bool {
        self == .active
    }

    public var keepsVisibleSurface: Bool {
        self == .active || self == .passiveVisible
    }
}

public struct TabRenderLifecycleInput: Equatable, Sendable {
    public let isSelectedTab: Bool
    public let isInputPriorityWindow: Bool
    public let isWindowVisibleForRendering: Bool
    public let isPreviousLiveTab: Bool
    public let isPrewarming: Bool
    public let hasBackgroundActivity: Bool
    public let isRenderSuspensionEnabled: Bool
    public let isStartupRestoreActive: Bool
    public let hasPendingRestoreBootstrap: Bool
    public let isMCPControlled: Bool
    public let hasAttachedTerminalView: Bool

    public init(
        isSelectedTab: Bool,
        isInputPriorityWindow: Bool,
        isWindowVisibleForRendering: Bool,
        isPreviousLiveTab: Bool,
        isPrewarming: Bool,
        hasBackgroundActivity: Bool,
        isRenderSuspensionEnabled: Bool,
        isStartupRestoreActive: Bool,
        hasPendingRestoreBootstrap: Bool,
        isMCPControlled: Bool,
        hasAttachedTerminalView: Bool
    ) {
        self.isSelectedTab = isSelectedTab
        self.isInputPriorityWindow = isInputPriorityWindow
        self.isWindowVisibleForRendering = isWindowVisibleForRendering
        self.isPreviousLiveTab = isPreviousLiveTab
        self.isPrewarming = isPrewarming
        self.hasBackgroundActivity = hasBackgroundActivity
        self.isRenderSuspensionEnabled = isRenderSuspensionEnabled
        self.isStartupRestoreActive = isStartupRestoreActive
        self.hasPendingRestoreBootstrap = hasPendingRestoreBootstrap
        self.isMCPControlled = isMCPControlled
        self.hasAttachedTerminalView = hasAttachedTerminalView
    }
}

public struct TabRenderLifecycleDecision: Equatable, Sendable {
    public let phase: TabRenderPhase
    public let keepsLiveHierarchy: Bool
    public let isInteractive: Bool

    public init(phase: TabRenderPhase, keepsLiveHierarchy: Bool, isInteractive: Bool) {
        self.phase = phase
        self.keepsLiveHierarchy = keepsLiveHierarchy
        self.isInteractive = isInteractive
    }
}

public enum TabRenderLifecyclePolicy {
    public static func decide(_ input: TabRenderLifecycleInput) -> TabRenderLifecycleDecision {
        TabRenderLifecycleDecision(
            phase: phase(for: input),
            keepsLiveHierarchy: keepsLiveHierarchy(for: input),
            isInteractive: isInteractive(for: input)
        )
    }

    public static func requiresAuthoritativeReveal(
        previousPhase: TabRenderPhase?,
        nextPhase: TabRenderPhase
    ) -> Bool {
        guard let previousPhase else { return false }
        if !previousPhase.keepsVisibleSurface && nextPhase.keepsVisibleSurface {
            return true
        }
        return previousPhase != .active && nextPhase == .active
    }

    public static func phase(for input: TabRenderLifecycleInput) -> TabRenderPhase {
        if input.isSelectedTab {
            if input.isWindowVisibleForRendering {
                return .active
            }
            return .warm
        }

        if input.hasBackgroundActivity {
            return .warm
        }

        if !input.isRenderSuspensionEnabled {
            return .warm
        }

        if input.isPreviousLiveTab
            || input.isPrewarming
            || input.hasPendingRestoreBootstrap {
            return .warm
        }

        return .hidden
    }

    public static func isInteractive(for input: TabRenderLifecycleInput) -> Bool {
        input.isSelectedTab && input.isInputPriorityWindow
    }

    public static func keepsLiveHierarchy(for input: TabRenderLifecycleInput) -> Bool {
        if input.isSelectedTab {
            return true
        }

        if input.isMCPControlled && !input.hasAttachedTerminalView {
            return true
        }

        return false
    }
}
