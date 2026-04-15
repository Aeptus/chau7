import Foundation

public enum TabSurfaceReactivationEvent: Equatable, Sendable {
    case becameKey
    case becameMain
    case becameVisible
    case deminiaturized
}

public enum TabSurfaceReactivationPolicy {
    public static func shouldRequestAuthoritativeReveal(
        for event: TabSurfaceReactivationEvent,
        phase: TabRenderPhase,
        isWindowVisible: Bool,
        isWindowMiniaturized: Bool,
        isOcclusionVisible: Bool
    ) -> Bool {
        guard phase.keepsVisibleSurface else { return false }
        guard isWindowVisible, !isWindowMiniaturized else { return false }

        switch event {
        case .becameKey, .becameMain, .deminiaturized:
            return true
        case .becameVisible:
            return isOcclusionVisible
        }
    }
}
