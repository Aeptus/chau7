import Foundation

public enum TabRenderPhase: String, Equatable, Sendable {
    case active
    case backgroundActive
    case warm
    case hidden

    public var keepsTerminalStateCurrent: Bool {
        self != .hidden
    }

    public var allowsLivePresentation: Bool {
        self == .active || self == .backgroundActive
    }

    public var keepsVisibleSurface: Bool {
        self == .active || self == .backgroundActive
    }
}

public struct TabRenderLifecycleInput: Equatable, Sendable {
    public let isSelectedTab: Bool
    public let isInputPriorityWindow: Bool
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

    public init(phase: TabRenderPhase, keepsLiveHierarchy: Bool) {
        self.phase = phase
        self.keepsLiveHierarchy = keepsLiveHierarchy
    }
}

public enum TabRenderLifecyclePolicy {
    public static func decide(_ input: TabRenderLifecycleInput) -> TabRenderLifecycleDecision {
        TabRenderLifecycleDecision(
            phase: phase(for: input),
            keepsLiveHierarchy: keepsLiveHierarchy(for: input)
        )
    }

    public static func requiresAuthoritativeReveal(
        previousPhase: TabRenderPhase?,
        nextPhase: TabRenderPhase
    ) -> Bool {
        guard let previousPhase else { return false }
        return previousPhase != .active && nextPhase == .active
    }

    public static func phase(for input: TabRenderLifecycleInput) -> TabRenderPhase {
        if input.isSelectedTab, input.isInputPriorityWindow {
            return .active
        }

        if input.isSelectedTab {
            return .backgroundActive
        }

        if input.hasBackgroundActivity {
            return .warm
        }

        if !input.isRenderSuspensionEnabled {
            return .warm
        }

        if input.isPreviousLiveTab
            || input.isPrewarming
            || (input.hasPendingRestoreBootstrap && !input.hasAttachedTerminalView) {
            return .warm
        }

        return .hidden
    }

    public static func keepsLiveHierarchy(for input: TabRenderLifecycleInput) -> Bool {
        if input.isSelectedTab || input.hasBackgroundActivity || input.isPreviousLiveTab || input.isPrewarming {
            return true
        }

        if input.isMCPControlled && !input.hasAttachedTerminalView {
            return true
        }

        guard input.hasPendingRestoreBootstrap, !input.hasAttachedTerminalView else {
            return false
        }

        return !input.isStartupRestoreActive
    }
}
