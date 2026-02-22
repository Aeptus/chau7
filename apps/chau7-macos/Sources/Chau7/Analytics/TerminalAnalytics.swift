import Foundation
import Chau7Core

// MARK: - Terminal Analytics

/// Aggregates terminal usage analytics from various data sources.
/// Queries PersistentHistoryStore for command stats and the API proxy for LLM usage.
@MainActor
final class TerminalAnalytics: ObservableObject {
    static let shared = TerminalAnalytics()

    @Published var totalCommands: Int = 0
    @Published var successRate: Double = 0
    @Published var avgDuration: TimeInterval = 0
    @Published var topCommands: [FrequentCommand] = []

    var successRateString: String { String(format: "%.0f%%", successRate * 100) }
    var avgDurationString: String { String(format: "%.1fs", avgDuration) }

    private init() {
        refresh()
        Log.info("TerminalAnalytics initialized")
    }

    func refresh() {
        let store = PersistentHistoryStore.shared
        totalCommands = store.totalCount()

        // Compute success rate and average duration from recent records
        let records = store.recent(limit: 1000)
        if !records.isEmpty {
            let withExitCode = records.filter { $0.exitCode != nil }
            if !withExitCode.isEmpty {
                let successes = withExitCode.filter { $0.exitCode == 0 }.count
                successRate = Double(successes) / Double(withExitCode.count)
            }

            let durations = records.compactMap(\.duration)
            if !durations.isEmpty {
                avgDuration = durations.reduce(0, +) / Double(durations.count)
            }
        }

        // Top commands from frequency analysis
        topCommands = store.frequentCommands(limit: 10)

        Log.info("TerminalAnalytics: refreshed (total=\(totalCommands), successRate=\(successRateString))")
    }
}

