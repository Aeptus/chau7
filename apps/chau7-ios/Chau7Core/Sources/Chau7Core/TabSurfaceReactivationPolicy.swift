import Foundation

public enum TabSurfaceReactivationEvent: Equatable, Sendable {
    case becameKey
    case becameMain
    case becameVisible
    case deminiaturized
}

public struct TabSurfaceReactivationPlan: Equatable, Sendable {
    public let shouldRequestReveal: Bool
    public let reason: String?

    public init(shouldRequestReveal: Bool, reason: String?) {
        self.shouldRequestReveal = shouldRequestReveal
        self.reason = reason
    }
}

public enum TabSurfaceReactivationPolicy {
    public static let coalescingDelay: TimeInterval = 0.05

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

    public static func plan(
        for events: Set<TabSurfaceReactivationEvent>,
        phase: TabRenderPhase,
        isWindowVisible: Bool,
        isWindowMiniaturized: Bool,
        isOcclusionVisible: Bool
    ) -> TabSurfaceReactivationPlan {
        guard !events.isEmpty else {
            return TabSurfaceReactivationPlan(shouldRequestReveal: false, reason: nil)
        }

        let orderedEvents: [TabSurfaceReactivationEvent] = [
            .becameVisible,
            .deminiaturized,
            .becameMain,
            .becameKey
        ]
        let selectedEvents = orderedEvents.filter(events.contains)
        let shouldRequest = selectedEvents.contains {
            shouldRequestAuthoritativeReveal(
                for: $0,
                phase: phase,
                isWindowVisible: isWindowVisible,
                isWindowMiniaturized: isWindowMiniaturized,
                isOcclusionVisible: isOcclusionVisible
            )
        }

        guard shouldRequest else {
            return TabSurfaceReactivationPlan(shouldRequestReveal: false, reason: nil)
        }

        let reason = selectedEvents.map(reasonFragment(for:)).joined(separator: "+")
        return TabSurfaceReactivationPlan(shouldRequestReveal: true, reason: reason.isEmpty ? nil : reason)
    }

    private static func reasonFragment(for event: TabSurfaceReactivationEvent) -> String {
        switch event {
        case .becameKey:
            return "windowDidBecomeKey"
        case .becameMain:
            return "windowDidBecomeMain"
        case .becameVisible:
            return "windowDidChangeOcclusionState"
        case .deminiaturized:
            return "windowDidDeminiaturize"
        }
    }
}
