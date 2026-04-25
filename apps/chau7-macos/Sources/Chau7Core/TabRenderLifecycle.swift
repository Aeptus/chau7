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
    public let isInteractive: Bool

    public init(phase: TabRenderPhase, isInteractive: Bool) {
        self.phase = phase
        self.isInteractive = isInteractive
    }
}

public enum TabRenderLifecyclePolicy {
    public static func decide(_ input: TabRenderLifecycleInput) -> TabRenderLifecycleDecision {
        TabRenderLifecycleDecision(
            phase: phase(for: input),
            isInteractive: isInteractive(for: input)
        )
    }

    public static func requiresAuthoritativeReveal(
        previousPhase: TabRenderPhase?,
        nextPhase: TabRenderPhase
    ) -> Bool {
        guard let previousPhase else { return false }
        if !previousPhase.keepsVisibleSurface, nextPhase.keepsVisibleSurface {
            return true
        }
        return previousPhase != .active && nextPhase == .active
    }

    public static func phase(for input: TabRenderLifecycleInput) -> TabRenderPhase {
        if input.isSelectedTab {
            guard input.isWindowVisibleForRendering else {
                return .warm
            }
            if input.isInputPriorityWindow {
                return .active
            }
            // Promote to `.active` when the session is actively producing
            // output even though the window isn't the input-priority
            // (key/main) window. AI-agent observation is a primary use
            // case of Chau7: users expect to see streaming output continue
            // when they glance at another app. The PTY always drains into
            // the Rust grid; what `.passiveVisible` was pausing is just
            // Metal presentation. When there's genuine activity to present,
            // keep presenting. Pre-W3.18 this was `.passiveVisible` and the
            // user-visible symptom was "tab content freezes, then catches
            // up in a burst when I come back."
            if input.hasBackgroundActivity {
                return .active
            }
            return .passiveVisible
        }
        // Non-selected tabs: warm (not hidden) so views stay unhidden in the
        // hierarchy but don't drive active rendering. The shared background
        // drain service handles PTY draining; no per-tab polling needed.
        return .warm
    }

    public static func isInteractive(for input: TabRenderLifecycleInput) -> Bool {
        input.isSelectedTab && input.isInputPriorityWindow
    }

    public static func isInputPriorityWindow(
        hasWindow: Bool,
        isKeyWindow: Bool,
        isMainWindow _: Bool,
        isStartupRestoreActive: Bool
    ) -> Bool {
        if isStartupRestoreActive {
            return true
        }
        guard hasWindow else {
            return true
        }
        return isKeyWindow
    }
}
