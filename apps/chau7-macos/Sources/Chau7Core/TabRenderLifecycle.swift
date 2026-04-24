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
            return input.isInputPriorityWindow ? .active : .passiveVisible
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

    /// Decides whether a tab should remain in SwiftUI's live view hierarchy.
    ///
    /// Non-selected tabs rendered as full `SplitPaneView` instances cost
    /// one Metal surface + layout tree per tab — a tab-count linear cost
    /// that defeats the point of retaining the Rust terminal view on the
    /// session model. The live hierarchy is reserved for tabs that need
    /// SwiftUI mounting right now; every other tab falls back to a
    /// lightweight placeholder (`Color.clear.frame(width:0, height:0)`)
    /// while its PTY keeps draining against the retained RustTerminalView.
    ///
    /// Positive signals (keep live):
    ///   - `isSelectedTab` — the user is looking at it.
    ///   - `isPreviousLiveTab` — recently deselected; stays for one short
    ///     handoff window so a rapid re-selection doesn't churn SwiftUI.
    ///   - `isStartupRestoreActive && hasPendingRestoreBootstrap` —
    ///     background tabs whose scrollback replay is still in flight
    ///     during a cold restore.
    ///   - `isMCPControlled && !hasAttachedTerminalView` — MCP-driven
    ///     tabs without a real view need the hierarchy mount so the next
    ///     background exec has a PTY to land on.
    ///
    /// All other tabs — including non-selected tabs that happen to have
    /// `hasBackgroundActivity` — drop to the placeholder. Background
    /// activity is a *polling* concern, not a *mounting* concern: the
    /// shared drain service keeps the session alive regardless of
    /// SwiftUI mount state.
    public static func keepsLiveHierarchy(for input: TabRenderLifecycleInput) -> Bool {
        if input.isSelectedTab { return true }
        if input.isPreviousLiveTab { return true }
        if input.isStartupRestoreActive, input.hasPendingRestoreBootstrap { return true }
        if input.isMCPControlled, !input.hasAttachedTerminalView { return true }
        return false
    }
}
