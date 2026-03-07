import Foundation

/// Pure scheduling helpers for monitoring timers.
///
/// These are stateless functions extracted from app-level monitors
/// (`ClaudeCodeMonitor`, `HistoryIdleMonitor`, `ProcessResourceMonitor`,
/// `NotificationManager`) to enable unit testing via `Chau7Core`.
public enum MonitoringSchedule {

    // MARK: - Claude Code idle check

    /// Computes the delay until the next idle check should fire.
    /// - Parameters:
    ///   - now: Current timestamp
    ///   - minimumInterval: Floor for the returned delay
    ///   - idleThreshold: Seconds of inactivity before a session is considered idle
    ///   - activeSessionDates: Last-activity timestamps for sessions in active/responding state
    /// - Returns: Delay in seconds, or nil if no sessions need monitoring
    public static func nextIdleCheckDelay(
        now: Date,
        minimumInterval: TimeInterval,
        idleThreshold: TimeInterval,
        activeSessionDates: [Date]
    ) -> TimeInterval? {
        let threshold = max(minimumInterval, idleThreshold)
        var minimumRemaining = Double.infinity

        for lastActivity in activeSessionDates {
            let remaining = threshold - now.timeIntervalSince(lastActivity)
            minimumRemaining = min(minimumRemaining, remaining)
        }

        guard minimumRemaining.isFinite else { return nil }
        return max(minimumInterval, minimumRemaining)
    }

    // MARK: - History idle check

    /// Computes the delay until the next history idle/stale check should fire.
    /// - Parameters:
    ///   - now: Current timestamp
    ///   - minimumCheckInterval: Floor for the returned delay
    ///   - idleSeconds: Seconds of inactivity before a session is considered idle
    ///   - staleSeconds: Seconds of inactivity before a session is considered stale
    ///   - lastSeen: Map of session ID to last-seen timestamp
    /// - Returns: Delay in seconds, or nil if no sessions need monitoring
    public static func nextHistoryCheckDelay(
        now: Date,
        minimumCheckInterval: TimeInterval,
        idleSeconds: TimeInterval,
        staleSeconds: TimeInterval,
        lastSeen: [String: Date]
    ) -> TimeInterval? {
        let safeIdleSeconds = max(minimumCheckInterval, idleSeconds)
        let safeStaleSeconds = max(safeIdleSeconds + 1.0, staleSeconds)

        var nextDeadline = Date.distantFuture
        for (_, lastSeenAt) in lastSeen {
            let nextIdle = lastSeenAt.addingTimeInterval(safeIdleSeconds)
            if nextIdle < nextDeadline {
                nextDeadline = nextIdle
            }

            let nextStale = lastSeenAt.addingTimeInterval(safeStaleSeconds)
            if nextStale < nextDeadline {
                nextDeadline = nextStale
            }
        }

        guard nextDeadline != Date.distantFuture else { return nil }

        let remaining = nextDeadline.timeIntervalSince(now)
        return max(minimumCheckInterval, remaining)
    }

    // MARK: - Process resource polling

    public static let defaultMinimumPollInterval: TimeInterval = 0.75
    public static let defaultMaxPollInterval: TimeInterval = 3.0
    public static let defaultBackoffMultiplier = 1.8
    public static let defaultMaxConsecutiveNoDataPolls = 8

    /// Computes the next poll interval with exponential backoff.
    /// - Parameters:
    ///   - consecutiveNoDataPolls: How many consecutive polls returned no data
    ///   - minimumPollInterval: Shortest allowed interval
    ///   - maxPollInterval: Longest allowed interval (cap)
    ///   - backoffMultiplier: Exponential base for backoff
    ///   - maxConsecutiveNoDataPolls: Cap on the exponent to avoid overflow
    /// - Returns: Next poll interval in seconds (always positive)
    public static func nextPollInterval(
        consecutiveNoDataPolls: Int,
        minimumPollInterval: TimeInterval = defaultMinimumPollInterval,
        maxPollInterval: TimeInterval = defaultMaxPollInterval,
        backoffMultiplier: Double = defaultBackoffMultiplier,
        maxConsecutiveNoDataPolls: Int = defaultMaxConsecutiveNoDataPolls
    ) -> TimeInterval {
        guard consecutiveNoDataPolls > 0 else {
            return minimumPollInterval
        }
        let clamped = min(consecutiveNoDataPolls, maxConsecutiveNoDataPolls)
        let backoff = pow(backoffMultiplier, Double(clamped))
        return min(maxPollInterval, minimumPollInterval * backoff)
    }

    // MARK: - Notification coalescing

    public static let defaultCoalescingWindow: TimeInterval = 0.25

    /// Generates a coalescing key for notification deduplication.
    /// Events with the same key within the coalescing window are merged (last wins).
    public static func notificationCoalescingKey(for event: AIEvent) -> String {
        let normalizedTool = event.tool
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let normalizedType = event.type
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return "\(event.source.rawValue)|\(normalizedType)|\(normalizedTool)"
    }
}
