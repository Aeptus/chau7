import Foundation
import Chau7Core

/// Owns repository read contracts independently of terminal/window control.
/// Metadata/statistics execute on the calling MCP worker; event snapshots and
/// canonical tab alias allocation retain their existing main-actor ordering.
final class MCPRepositoryQueryService: Sendable {
    private let statsProvider: @Sendable (String) -> RepoStats
    private let frequentCommandsProvider: @Sendable (String, Int) -> [FrequentCommand]

    init(
        statsProvider: @escaping @Sendable (String) -> RepoStats = { RepoStatsProvider.stats(for: $0) },
        frequentCommandsProvider: @escaping @Sendable (String, Int) -> [FrequentCommand] = {
            PersistentHistoryStore.shared.frequentCommandsForRepo(repoRoot: $0, limit: $1)
        }
    ) {
        self.statsProvider = statsProvider
        self.frequentCommandsProvider = frequentCommandsProvider
    }

    func metadataJSON(repoPath: String, cachedMetadata: RepoMetadata?) -> String {
        let metadata = cachedMetadata ?? RepoMetadataStore.load(repoRoot: repoPath)
        let frequentCmds = frequentCommandsProvider(repoPath, 10)

        var result: [String: Any] = [
            "repo_path": repoPath,
            "repo_name": URL(fileURLWithPath: repoPath).lastPathComponent
        ]
        if let desc = metadata.description { result["description"] = desc }
        if !metadata.labels.isEmpty { result["labels"] = metadata.labels }
        if !metadata.favoriteFiles.isEmpty { result["favorite_files"] = metadata.favoriteFiles }
        if let updated = metadata.updatedAt {
            result["updated_at"] = DateFormatters.iso8601NoFractional.string(from: updated)
        }
        if !frequentCmds.isEmpty {
            result["frequent_commands"] = frequentCmds.map(Self.frequentCommandPayload)
        }

        // Aggregated stats from history.db + runs.db
        let stats = statsProvider(repoPath)
        let iso = DateFormatters.iso8601NoFractional
        var statsDict: [String: Any] = [
            "total_commands": stats.totalCommands,
            "successful_commands": stats.successfulCommands,
            "failed_commands": stats.failedCommands,
            "success_rate": stats.successRate,
            "avg_command_duration": stats.averageCommandDuration,
            "total_runs": stats.totalRuns,
            "total_tokens": stats.totalTokens,
            "total_cost": stats.totalCost,
            "total_turns": stats.totalTurns,
            "providers": stats.providers
        ]
        if !stats.topTools.isEmpty {
            statsDict["top_tools"] = stats.topTools.map { [
                "tool": $0.tool, "count": $0.count
            ] as [String: Any] }
        }
        if let lastCmd = stats.lastCommandAt { statsDict["last_command_at"] = iso.string(from: lastCmd) }
        if let lastRun = stats.lastRunAt { statsDict["last_run_at"] = iso.string(from: lastRun) }
        result["stats"] = statsDict

        return encodeAny(result)
    }

    func frequentCommandsJSON(repoPath: String, limit: Int) -> String {
        encodeAny(frequentCommandsProvider(repoPath, limit).map(Self.frequentCommandPayload))
    }

    private static func frequentCommandPayload(_ cmd: FrequentCommand) -> [String: Any] {
        [
            "command": cmd.command,
            "count": cmd.count,
            "last_used": DateFormatters.iso8601NoFractional.string(from: cmd.lastUsed),
            "frecency_score": cmd.frecencyScore
        ]
    }

    @MainActor
    func eventsJSON(
        repoPath: String,
        snapshot: [AIEvent],
        query: RepoEventQuery,
        truncateMessages: Bool,
        tabIDProvider: (UUID) -> String
    ) -> String {
        // Resolve aliases at the same points and in the same order as before.
        // Allocating aliases for every snapshot entry would change tab IDs.
        let events = Array(snapshot.filter { event in
            let alias = query.tabID == nil ? nil : event.tabID.map(tabIDProvider)
            return query.matches(event, resolvedTabID: alias)
        }.suffix(query.limit))
        let result: [[String: Any]] = events.map { event in
            let message = truncateMessages ? String(event.message.prefix(200)) : event.message
            var entry: [String: Any] = [
                "id": event.id.uuidString,
                "source": event.source.rawValue,
                "type": event.type,
                "tool": event.tool,
                "message": message,
                "ts": event.ts
            ]
            if let dir = event.directory { entry["directory"] = dir }
            if let tab = event.tabID { entry["tab_id"] = tabIDProvider(tab) }
            if let session = event.sessionID { entry["session_id"] = session }
            if let producer = event.producer { entry["producer"] = producer }
            entry["reliability"] = event.reliability.rawValue
            return entry
        }
        return encodeAny(["repo_path": repoPath, "count": result.count, "events": result])
    }

    private func encodeAny(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}
