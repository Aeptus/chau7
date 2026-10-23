import Foundation

/// Value snapshot of the store's repository aggregation.
public struct RepositoryRunStatistics: Sendable {
    public let totalRuns: Int
    public let totalTokens: Int
    public let totalCost: Double
    public let totalTurns: Int
    public let lastRunAt: Date?
    public let attributedProxyCost: Double

    public init(totalRuns: Int = 0, totalTokens: Int = 0, totalCost: Double = 0, totalTurns: Int = 0, lastRunAt: Date? = nil, attributedProxyCost: Double = 0) {
        self.totalRuns = totalRuns
        self.totalTokens = totalTokens
        self.totalCost = totalCost
        self.totalTurns = totalTurns
        self.lastRunAt = lastRunAt
        self.attributedProxyCost = attributedProxyCost
    }
}

/// Combines independent totals after removing their retained measured overlap.
public enum RepositoryUsageTotals {
    public static func combinedCost(runCost: Double, proxyCost: Double, attributedProxyCost: Double) -> Double {
        // Only remove overlap present in both retained sources; neither source's
        // retention period proves the other has retained the same full history.
        runCost + proxyCost - min(max(0, attributedProxyCost), max(0, runCost), max(0, proxyCost))
    }
}
