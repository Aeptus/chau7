public enum ScrollbackRetentionPolicy {
    public static let minimumConfiguredLines = 100
    public static let maximumConfiguredLines = 100_000
    /// Scrollback lines kept resident for a `.hidden` tab after its ring is
    /// flushed to disk — enough to show a couple of screens instantly on return
    /// while the rest reloads lazily. ~200 lines ≈ <1 MB/tab vs. tens of MB for
    /// the full configured ring.
    public static let defaultHiddenViewportFloor = 200

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
