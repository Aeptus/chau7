import SwiftUI
import Chau7Core

/// Groups runs by repo for a high-level view of AI activity per project.
struct SessionsExplorerView: View {
    @State private var repoGroups: [RepoRunGroup] = []

    var body: some View {
        Group {
            if repoGroups.isEmpty {
                VStack {
                    Spacer()
                    Text("No AI sessions recorded yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(repoGroups) { group in
                    RepoGroupRow(group: group)
                }
                .listStyle(.plain)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        let allRuns = TelemetryStore.shared.listRuns(filter: TelemetryRunFilter(limit: 500))
        var byRepo: [String: [TelemetryRun]] = [:]
        for run in allRuns {
            let key = run.repoPath ?? (run.cwd.isEmpty ? "Unknown" : run.cwd)
            byRepo[key, default: []].append(run)
        }
        repoGroups = byRepo.map { path, runs in
            let providers = Set(runs.map(\.provider))
            let totalTokens = runs.reduce(0) { $0 + $1.tokenUsage.totalBillableTokens }
            let totalTurns = runs.reduce(0) { $0 + $1.turnCount }
            let lastActive = runs.map(\.startedAt).max() ?? Date.distantPast
            let cmdStats = PersistentHistoryStore.shared.commandStatsForRepo(repoRoot: path)
            let runStats = TelemetryStore.shared.runStatsForRepo(repoPath: path)
            return RepoRunGroup(
                repoPath: path,
                repoName: URL(fileURLWithPath: path).lastPathComponent,
                runCount: runs.count,
                providers: providers.sorted(),
                totalTokens: totalTokens,
                totalTurns: totalTurns,
                totalCost: runStats.totalCost,
                totalCommands: cmdStats.total,
                successRate: cmdStats.total > 0 ? Double(cmdStats.successful) / Double(cmdStats.total) : 0,
                lastActive: lastActive
            )
        }
        .sorted { $0.lastActive > $1.lastActive }
    }
}

private struct RepoRunGroup: Identifiable {
    let repoPath: String
    var id: String {
        repoPath
    }

    let repoName: String
    let runCount: Int
    let providers: [String]
    let totalTokens: Int
    let totalTurns: Int
    let totalCost: Double
    let totalCommands: Int
    let successRate: Double
    let lastActive: Date
}

private struct RepoGroupRow: View {
    let group: RepoRunGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.blue)
                Text(group.repoName)
                    .font(.system(size: 13, weight: .semibold))

                Spacer()

                Text(relativeTime)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 12) {
                // Provider badges
                ForEach(group.providers, id: \.self) { provider in
                    Text(provider.capitalized)
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(providerColor(provider).opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .foregroundStyle(providerColor(provider))
                }

                Spacer()

                if group.totalCommands > 0 {
                    Text("\(group.totalCommands) cmds")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    // Success rate badge
                    let rate = group.successRate
                    Text(String(format: "%.0f%%", rate * 100))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(rate > 0.9 ? .green : rate > 0.7 ? .yellow : .red)
                }

                Text("\(group.runCount) runs")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                if group.totalTokens > 0 {
                    Text(formatTokens(group.totalTokens))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.blue)
                }

                if group.totalCost > 0 {
                    Text(String(format: "$%.2f", group.totalCost))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.orange)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private var relativeTime: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: group.lastActive, relativeTo: Date())
    }

    private func providerColor(_ provider: String) -> Color {
        switch provider.lowercased() {
        case "claude": return .purple
        case "codex": return .green
        case "cline": return .orange
        case "chatgpt": return .teal
        default: return .secondary
        }
    }

    private func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1000 { return String(format: "%.0fK", Double(count) / 1000) }
        return "\(count)"
    }
}
