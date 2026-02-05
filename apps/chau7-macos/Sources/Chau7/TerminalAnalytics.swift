import Foundation
import SwiftUI
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
    @Published var activeTime: TimeInterval = 0
    @Published var topCommands: [FrequentCommand] = []
    @Published var dailyStats: [DailyStat] = []
    @Published var shellBreakdown: [ShellUsage] = []
    @Published var totalAPICalls: Int = 0
    @Published var totalTokens: Int = 0
    @Published var estimatedCost: Double = 0

    var hasAPIData: Bool { totalAPICalls > 0 }
    var successRateString: String { String(format: "%.0f%%", successRate * 100) }
    var avgDurationString: String { String(format: "%.1fs", avgDuration) }
    var activeTimeString: String { String(format: "%.1fh", activeTime / 3600) }
    var totalTokensString: String { totalTokens > 1000 ? "\(totalTokens / 1000)K" : "\(totalTokens)" }
    var estimatedCostString: String { String(format: "$%.2f", estimatedCost) }

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

// MARK: - Supporting Types

/// Daily aggregated statistics for error-rate charts.
struct DailyStat: Identifiable {
    var id: Date { date }
    let date: Date
    let commandCount: Int
    let errorCount: Int

    var errorRate: Double {
        commandCount > 0 ? Double(errorCount) / Double(commandCount) : 0
    }

    var dayLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEE"
        return fmt.string(from: date)
    }
}

/// Shell usage breakdown with associated display color.
struct ShellUsage: Identifiable {
    var id: String { shell }
    let shell: String
    let count: Int
    let percentage: Int

    var color: Color {
        switch shell.lowercased() {
        case "zsh": return .blue
        case "bash": return .green
        case "fish": return .orange
        default: return .gray
        }
    }
}
