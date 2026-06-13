import Chau7Core
import Foundation

// MARK: - Supporting Types

//
// These value types describe the *data shape* read out of git and surfaced to
// the Repository pane view. They were originally declared at the end of
// `RepositoryPaneModel.swift`, where they bloated a file that already mixed
// status fetching, commit drafting, branch ops, history, stash, parsing, and
// session-aware partitioning. Moving them here is a first scaffolding step
// toward the larger refactor flagged in the side-panel review:
//
//   > "Split `RepositoryPaneModel` into three. Status + Commit + History
//   >  have orthogonal lifecycles; today they all invalidate together."
//
// The next step is to peel `Status`, `Commit`, and `History` into their own
// @Observable sub-states so a search-text bump in history doesn't invalidate
// the status section. That work is intentionally out of scope here — moving
// types without changing observers is a no-op for the SwiftUI invalidation
// graph and a safe prep step.

struct FileStatus: Identifiable {
    let id = UUID()
    let path: String
    let changeType: FileChangeType
    let indexStatus: Character
    let workTreeStatus: Character
}

enum FileChangeType: String {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case copied = "C"
    case unmerged = "U"

    var icon: String {
        switch self {
        case .modified: return "pencil"
        case .added: return "plus"
        case .deleted: return "minus"
        case .renamed: return "arrow.right"
        case .copied: return "doc.on.doc"
        case .unmerged: return "exclamationmark.triangle"
        }
    }

    var color: String {
        switch self {
        case .modified: return "orange"
        case .added: return "green"
        case .deleted: return "red"
        case .renamed: return "blue"
        case .copied: return "purple"
        case .unmerged: return "red"
        }
    }
}

struct CommitEntry: Identifiable {
    var id: String {
        hash
    }

    let hash: String
    let shortHash: String
    let message: String
    let author: String
    let date: Date
    let dateString: String
}

struct StashEntry: Identifiable {
    var id: Int {
        index
    }

    let index: Int
    let description: String
    let branch: String?

    /// Tooltip text for hover.
    var hoverText: String {
        var text = "stash@{\(index)}"
        if let branch { text += " on \(branch)" }
        text += "\n\(description)"
        return text
    }
}

struct BranchDetail {
    let name: String
    let lastCommitHash: String
    let lastCommitMessage: String

    /// Tooltip text for hover.
    var hoverText: String {
        "\(lastCommitHash) \(lastCommitMessage)"
    }
}

struct DiffStat {
    let additions: Int
    let deletions: Int
}

struct TurnSummaryInfo {
    let turnCount: Int
    let toolsUsed: [String: Int]
    let totalTokens: Int
    let inputTokens: Int
    let outputTokens: Int
    let reasoningOutputTokens: Int
    let costEstimateUSD: Double?
    let averageTokensPerTurn: Double?
    let activeDuration: TimeInterval?
    let exitReason: TurnExitReason?
    let backendName: String
    let sessionState: RuntimeSessionStateMachine.State
    let duration: TimeInterval?

    var formattedTokens: String {
        if totalTokens > 1000 {
            return String(format: "%.1fk", Double(totalTokens) / 1000)
        }
        return "\(totalTokens)"
    }

    var formattedDuration: String? {
        guard let d = duration, d > 0 else { return nil }
        if d < 60 { return String(format: "%.0fs", d) }
        let mins = Int(d) / 60
        let secs = Int(d) % 60
        if d < 3600 { return "\(mins)m \(secs)s" }
        let hours = mins / 60
        let remMins = mins % 60
        return "\(hours)h \(remMins)m"
    }

    var formattedActiveDuration: String? {
        guard let activeDuration, activeDuration > 0 else { return nil }
        if activeDuration < 60 { return String(format: "%.0fs", activeDuration) }
        let mins = Int(activeDuration) / 60
        let secs = Int(activeDuration) % 60
        if activeDuration < 3600 { return "\(mins)m \(secs)s" }
        let hours = mins / 60
        let remMins = mins % 60
        return "\(hours)h \(remMins)m"
    }

    var formattedAverageTokensPerTurn: String? {
        guard let averageTokensPerTurn, averageTokensPerTurn > 0 else { return nil }
        let rounded = Int(averageTokensPerTurn.rounded())
        if rounded > 1000 {
            return String(format: "%.1fk", Double(rounded) / 1000)
        }
        return "\(rounded)"
    }

    var formattedCostEstimate: String? {
        guard let costEstimateUSD, costEstimateUSD > 0 else { return nil }
        return LocalizedFormatters.formatCostPrecise(costEstimateUSD)
    }
}
