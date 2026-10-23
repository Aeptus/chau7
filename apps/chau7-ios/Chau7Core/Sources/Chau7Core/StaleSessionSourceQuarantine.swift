import Foundation

public struct StaleSessionSourceKey: Hashable, Sendable {
    public let tabID: UUID
    public let sessionID: String
    public let provider: String

    public init(tabID: UUID, sessionID: String, provider: String) {
        self.tabID = tabID
        self.sessionID = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.provider = provider.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

public enum StaleSessionSourceDecision: Equatable, Sendable {
    /// First confirmed ownership failure gets one exact reconciliation attempt
    /// and one operational warning if that attempt cannot reroute the source.
    case reconcileAndReport
    /// Repeated failures are quarantined with no repeated operational log.
    case suppress
    /// Periodically publish one bounded summary instead of every rejection.
    case reportSummary(suppressedCount: Int)
}

/// Main-confined state machine for a stale external event source. It prevents
/// an append-only hook source from producing an unbounded warning stream while
/// still permitting one exact-session self-healing attempt and periodic health
/// summaries. No terminal content or user input is stored here.
public struct StaleSessionSourceQuarantine: Sendable {
    private struct Entry: Sendable {
        var lastReportAt: Date
        var suppressedCount: Int
    }

    private var entries: [StaleSessionSourceKey: Entry] = [:]
    public let reportInterval: TimeInterval

    public init(reportInterval: TimeInterval = 60) {
        self.reportInterval = max(1, reportInterval)
    }

    public mutating func recordOwnershipFailure(
        for key: StaleSessionSourceKey,
        now: Date = Date()
    ) -> StaleSessionSourceDecision {
        guard var entry = entries[key] else {
            entries[key] = Entry(lastReportAt: now, suppressedCount: 0)
            return .reconcileAndReport
        }

        entry.suppressedCount += 1
        guard now.timeIntervalSince(entry.lastReportAt) >= reportInterval else {
            entries[key] = entry
            return .suppress
        }

        let count = entry.suppressedCount
        entry.lastReportAt = now
        entry.suppressedCount = 0
        entries[key] = entry
        return .reportSummary(suppressedCount: count)
    }

    @discardableResult
    public mutating func clear(_ key: StaleSessionSourceKey) -> Bool {
        entries.removeValue(forKey: key) != nil
    }

    public func contains(_ key: StaleSessionSourceKey) -> Bool {
        entries[key] != nil
    }
}
