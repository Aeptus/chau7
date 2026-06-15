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
    /// When the app is under sustained memory pressure, non-selected tabs are
    /// demoted to `.hidden` (flushing scrollback to disk) instead of held `.warm`.
    public let isUnderMemoryPressure: Bool

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
        hasAttachedTerminalView: Bool,
        isUnderMemoryPressure: Bool = false
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
        self.isUnderMemoryPressure = isUnderMemoryPressure
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
            // Selected tab on a visible window always renders live, whether
            // or not the window is currently key/main. The previous policy
            // (W3.18) only promoted to `.active` when `hasBackgroundActivity`
            // was true — a gate that requires an AI tool session in
            // `running` / `waiting` / `approval` state. That left a real
            // gap on dual-monitor setups: a Chau7 window visible on one
            // screen while the user works on another would freeze at the
            // last frame whenever the gate was false (plain shell output,
            // long compiles, finished AI sessions still showing the result).
            // The PTY drains regardless of phase, so by the time the user
            // glanced over, the visual surface was stale relative to the
            // Rust grid. Visibility-on-screen is the right signal for
            // "render live"; key/main is the signal for "accept input."
            return .active
        }
        // Non-selected tabs: `.hidden` lets ScrollbackMemoryManager flush the
        // scrollback ring to disk and shrink it to the viewport floor (reloaded
        // on re-selection). In many-tab sessions non-selected tabs are the bulk
        // of the footprint because they otherwise keep the full configured
        // scrollback resident. The shared background drain keeps the PTY draining
        // regardless of phase, so background work is unaffected.
        //
        // Under memory pressure, always demote.
        if input.isUnderMemoryPressure {
            return .hidden
        }
        // Otherwise demote proactively for idle tabs — but only once a tab has
        // settled. A tab running/waiting on an AI session keeps
        // `hasBackgroundActivity == true` and stays `.warm` (full fidelity), and
        // a tab still being set up (startup restore / prewarm / restore
        // bootstrap) is left `.warm` so it isn't flushed out from under itself.
        // A short suspension delay upstream means a tab you only glanced away
        // from isn't demoted immediately.
        let isSettledIdleTab = !input.hasBackgroundActivity
            && !input.isStartupRestoreActive
            && !input.isPrewarming
            && !input.hasPendingRestoreBootstrap
        if isSettledIdleTab {
            return .hidden
        }
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
