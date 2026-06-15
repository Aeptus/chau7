public enum ScrollbackRetentionPolicy {
    public static let minimumConfiguredLines = 100
    public static let maximumConfiguredLines = 100_000
    public static let defaultHiddenViewportFloor = 50

    public static func normalizedConfiguredLines(_ lines: Int) -> Int {
        max(minimumConfiguredLines, min(lines, maximumConfiguredLines))
    }

    public static func ringCapacity(
        for phase: TabRenderPhase,
        configuredLines: Int,
        hiddenViewportFloor: Int = defaultHiddenViewportFloor
    ) -> Int {
        switch phase {
        case .active, .passiveVisible, .warm:
            return normalizedConfiguredLines(configuredLines)
        case .hidden:
            return max(0, hiddenViewportFloor)
        }
    }

    public static func shouldFlushToDisk(from oldPhase: TabRenderPhase, to newPhase: TabRenderPhase) -> Bool {
        oldPhase != newPhase && newPhase == .hidden && oldPhase != .hidden
    }

    public static func shouldReloadFromDisk(from oldPhase: TabRenderPhase, to newPhase: TabRenderPhase) -> Bool {
        oldPhase != newPhase && oldPhase == .hidden && newPhase != .hidden
    }
}
