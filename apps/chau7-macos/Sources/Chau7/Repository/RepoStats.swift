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
    let proxyCallCount: Int
    let proxyTokens: Int
    let proxyCost: Double
    let proxyProviders: [String]
    let proxyHourlyCost: [ProxyHourlyAnalyticsPoint]

    // Activity
    let lastCommandAt: Date?
    let lastRunAt: Date?
    let lastProxyCallAt: Date?

    var successRate: Double {
        totalCommands > 0 ? Double(successfulCommands) / Double(totalCommands) : 0
    }

    var lastActiveAt: Date? {
        [lastCommandAt, lastRunAt, lastProxyCallAt].compactMap { $0 }.max()
    }

    var combinedCost: Double {
        totalCost + proxyCost
    }

    static let empty = RepoStats(
        totalCommands: 0, successfulCommands: 0, failedCommands: 0,
        averageCommandDuration: 0, totalRuns: 0, totalTokens: 0,
        totalCost: 0, totalTurns: 0, providers: [], topTools: [],
        proxyCallCount: 0, proxyTokens: 0, proxyCost: 0, proxyProviders: [],
        proxyHourlyCost: [], lastCommandAt: nil, lastRunAt: nil, lastProxyCallAt: nil
    )
}

/// Assembles RepoStats from PersistentHistoryStore + TelemetryStore.
enum RepoStatsProvider {
    static func stats(for repoRoot: String, providerFilterKey: String? = nil) -> RepoStats {
        let cmdStats = PersistentHistoryStore.shared.commandStatsForRepo(repoRoot: repoRoot)
        let lastCmd = PersistentHistoryStore.shared.lastCommandTimestampForRepo(repoRoot: repoRoot)
        let runStats = TelemetryStore.shared.runStatsForRepo(repoPath: repoRoot, providerFilterKey: providerFilterKey)
        let providers = TelemetryStore.shared.providersForRepo(repoPath: repoRoot, providerFilterKey: providerFilterKey)
        let topTools = TelemetryStore.shared.toolCallDistributionForRepo(repoPath: repoRoot, limit: 5)
        let proxyStats = ProxyAnalyticsStore.shared.repoSummary(projectPath: repoRoot, providerFilterKey: providerFilterKey)

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
            proxyCallCount: proxyStats.callCount,
            proxyTokens: proxyStats.totalTokens,
            proxyCost: proxyStats.totalCostUSD,
            proxyProviders: proxyStats.providers,
            proxyHourlyCost: proxyStats.hourlyCost,
            lastCommandAt: lastCmd,
            lastRunAt: runStats.lastRunAt,
            lastProxyCallAt: proxyStats.lastCallAt
        )
    }
}
