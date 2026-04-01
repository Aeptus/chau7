import Foundation

/// Computed snapshot of per-repo metrics from history.db and runs.db.
/// Not persisted — assembled fresh on demand.
struct RepoStats {
    // Command history
    let totalCommands: Int
    let successfulCommands: Int
    let failedCommands: Int
    let averageCommandDuration: TimeInterval

    // AI telemetry
    let totalRuns: Int
    let totalTokens: Int
    let totalCost: Double
    let totalTurns: Int
    let providers: [String]
    let topTools: [(tool: String, count: Int)]

    // Activity
    let lastCommandAt: Date?
    let lastRunAt: Date?

    var successRate: Double {
        totalCommands > 0 ? Double(successfulCommands) / Double(totalCommands) : 0
    }

    static let empty = RepoStats(
        totalCommands: 0, successfulCommands: 0, failedCommands: 0,
        averageCommandDuration: 0, totalRuns: 0, totalTokens: 0,
        totalCost: 0, totalTurns: 0, providers: [], topTools: [],
        lastCommandAt: nil, lastRunAt: nil
    )
}

/// Assembles RepoStats from PersistentHistoryStore + TelemetryStore.
enum RepoStatsProvider {
    static func stats(for repoRoot: String) -> RepoStats {
        let cmdStats = PersistentHistoryStore.shared.commandStatsForRepo(repoRoot: repoRoot)
        let lastCmd = PersistentHistoryStore.shared.lastCommandTimestampForRepo(repoRoot: repoRoot)
        let runStats = TelemetryStore.shared.runStatsForRepo(repoPath: repoRoot)
        let providers = TelemetryStore.shared.providersForRepo(repoPath: repoRoot)
        let topTools = TelemetryStore.shared.toolCallDistributionForRepo(repoPath: repoRoot, limit: 5)

        return RepoStats(
            totalCommands: cmdStats.total,
            successfulCommands: cmdStats.successful,
            failedCommands: cmdStats.failed,
            averageCommandDuration: cmdStats.avgDuration,
            totalRuns: runStats.totalRuns,
            totalTokens: runStats.totalTokens,
            totalCost: runStats.totalCost,
            totalTurns: runStats.totalTurns,
            providers: providers,
            topTools: topTools,
            lastCommandAt: lastCmd,
            lastRunAt: runStats.lastRunAt
        )
    }
}
