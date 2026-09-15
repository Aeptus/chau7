import Foundation

public enum ScrollbackRetentionPolicy {
    /// Warm-tab idle reclamation: a deselected (`.warm`) tab whose PTY has
    /// been quiet for this long gets its ring flushed to disk and shrunk to
    /// the viewport floor. The viewport (plus floor tail) stays resident, so
    /// tab switching still paints instantly from RAM; only deep history moves
    /// to disk and is replayed asynchronously on promotion.
    public static let warmIdleFlushDelay: TimeInterval = 300

    /// TUI (agent) tabs compact on a longer idle window and keep a larger
    /// resident tier: never a replay into a live TUI, so the resident tail is
    /// all the scrollback available until the agent exits.
    public static let tuiIdleCompactDelay: TimeInterval = 900
    public static let tuiWarmTierLines = 2000

    /// Aggregate scrollback budget used by the proactive backstop: when the
    /// summed ring estimates of warm tabs exceed this, the largest are
    /// flushed immediately instead of waiting out their idle timers.
    public static let defaultScrollbackBudgetBytes = 500 * 1024 * 1024
    public static let defaultPerTabScrollbackBudgetBytes = TerminalMemoryBudgetPolicy.defaultPerTabScrollbackBytes

    public static func scrollbackBudgetBytes(overrideMB: Int?) -> Int {
        guard let overrideMB, overrideMB > 0 else {
            return defaultScrollbackBudgetBytes
        }
        return overrideMB * 1024 * 1024
    }

    public static func perTabScrollbackBudgetBytes(overrideMB: Int?) -> Int {
        TerminalMemoryBudgetPolicy.normalizedBudgetBytes(
            overrideMB: overrideMB,
            defaultBytes: defaultPerTabScrollbackBudgetBytes
        )
    }

    /// Caps the per-tab bookkeeping trackers (input lines, dangerous-command
    /// lines, line timestamps) that historically inherited the full
    /// `scrollbackLines` value. Rows beyond a few thousand back are useless
    /// to those trackers, but at 10k-100k entries × 4 trackers × 50 tabs they
    /// were a silent multi-hundred-MB amplifier of the scrollback setting.
    public static let maximumTrackerEntries = 5000

    public static func trackerEntryCap(configuredLines: Int) -> Int {
        max(minimumConfiguredLines, min(configuredLines, maximumTrackerEntries))
    }

    /// Pure idle-flush gate: only a still-`.warm` tab that produced no PTY
    /// output since the timer was armed may flush. Missing byte counters
    /// (backend without debug stats) fail closed — never flush a tab we
    /// cannot prove idle.
    public static func shouldIdleFlush(
        phase: TabRenderPhase,
        bytesReceivedWhenArmed: UInt64?,
        bytesReceivedNow: UInt64?
    ) -> Bool {
        guard phase == .warm else { return false }
        guard let bytesReceivedWhenArmed, let bytesReceivedNow else { return false }
        return bytesReceivedWhenArmed == bytesReceivedNow
    }

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
