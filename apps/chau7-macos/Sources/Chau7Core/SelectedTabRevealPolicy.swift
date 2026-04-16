import Foundation

public enum SelectedTabRevealTrigger: Equatable, Sendable {
    case selectionChange
    case explicitRefresh
    case startup
    case restoreBootstrap
    case reactivation
    case other
}

public struct SelectedTabRevealRequest: Equatable, Sendable {
    public let trigger: SelectedTabRevealTrigger
    public let keepsVisibleSurface: Bool
    public let hasAttachedRenderer: Bool
    public let isCurrentlyLivePresentable: Bool

    public init(
        trigger: SelectedTabRevealTrigger,
        keepsVisibleSurface: Bool,
        hasAttachedRenderer: Bool,
        isCurrentlyLivePresentable: Bool
    ) {
        self.trigger = trigger
        self.keepsVisibleSurface = keepsVisibleSurface
        self.hasAttachedRenderer = hasAttachedRenderer
        self.isCurrentlyLivePresentable = isCurrentlyLivePresentable
    }
}

public enum SelectedTabRevealPolicy {
    /// A selected-surface reveal should only block presentation when we are
    /// switching tabs or bootstrapping a surface that may not yet have a stable
    /// presented frame. Reactivating an already-live selected tab should repaint
    /// in place and keep the current surface visible.
    public static func shouldAwaitVisibleFrame(for request: SelectedTabRevealRequest) -> Bool {
        guard request.keepsVisibleSurface else { return false }

        switch request.trigger {
        case .reactivation:
            return !(request.hasAttachedRenderer && request.isCurrentlyLivePresentable)
        case .selectionChange, .explicitRefresh, .startup, .restoreBootstrap, .other:
            return true
        }
    }
}
