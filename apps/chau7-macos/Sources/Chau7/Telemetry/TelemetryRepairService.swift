import Foundation
import Chau7Core

struct TelemetryRepairReport: Sendable {
    var inspectedRuns = 0
    var rebuiltRuns = 0
    var invalidatedRuns = 0
    var skippedRuns = 0
}

enum TelemetryRunRepairResult: Sendable {
    case rebuilt
    case invalidated
    case skipped
}

final class TelemetryRepairService {
    static let shared = TelemetryRepairService()

    private let store = TelemetryStore.shared
    private let providers: [RunContentProvider]

    private init() {
        self.providers = [
            ClaudeCodeContentProvider(),
            CodexContentProvider()
        ]
    }

    static func needsTranscriptRepair(_ run: TelemetryRun) -> Bool {
        guard run.endedAt != nil else { return false }
        let hasSessionID = !(run.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard hasSessionID else {
            return false
        }

        let provider = run.provider.lowercased()
        let supportsTranscriptRepair = provider.contains("claude")
            || provider.contains("anthropic")
            || provider.contains("codex")
            || provider.contains("openai")
        guard supportsTranscriptRepair else { return false }

        let needsTranscriptSource = run.rawTranscriptRef == nil
            || run.rawTranscriptRef == "pty_log"
            || run.rawTranscriptRef == "terminal_buffer"
        let needsMetrics = run.tokenUsageState == .missing
            || run.costState == .missing
            || run.costSource == .unavailable
        return needsTranscriptSource || needsMetrics
    }

    func rebuildTranscriptDerivedRuns(limit: Int = 500) -> TelemetryRepairReport {
        let runs = store.listRuns(filter: TelemetryRunFilter(limit: limit))
            .filter { run in
                guard run.endedAt != nil else { return false }
                let provider = run.provider.lowercased()
                return provider.contains("claude") || provider.contains("codex") || provider.contains("anthropic") || provider.contains("openai")
            }

        var report = TelemetryRepairReport()

        for var run in runs {
            report.inspectedRuns += 1

            switch rebuildRun(&run, invalidateOnFailure: true) {
            case .rebuilt:
                report.rebuiltRuns += 1
            case .invalidated:
                report.invalidatedRuns += 1
            case .skipped:
                report.skippedRuns += 1
            }
        }

        return report
    }

    func rebuildRecentIncompleteRuns(limit: Int = 200) -> TelemetryRepairReport {
        let runs = store.listRuns(filter: TelemetryRunFilter(limit: limit))
            .filter(Self.needsTranscriptRepair)

        var report = TelemetryRepairReport()

        for var run in runs {
            report.inspectedRuns += 1

            switch rebuildRun(&run, invalidateOnFailure: false) {
            case .rebuilt:
                report.rebuiltRuns += 1
            case .invalidated:
                report.invalidatedRuns += 1
            case .skipped:
                report.skippedRuns += 1
            }
        }

        return report
    }

    func rebuildRunIfNeeded(runID: String) -> TelemetryRunRepairResult {
        guard var run = store.getRun(runID) else { return .skipped }
        guard Self.needsTranscriptRepair(run) else { return .skipped }
        return rebuildRun(&run, invalidateOnFailure: false)
    }

    private func rebuildRun(_ run: inout TelemetryRun, invalidateOnFailure: Bool) -> TelemetryRunRepairResult {
        guard let provider = providers.first(where: { $0.canHandle(provider: run.provider) }) else {
            return .skipped
        }

        guard let content = provider.extractContent(
            runID: run.id,
            sessionID: run.sessionID,
            cwd: run.cwd,
            startedAt: run.startedAt,
            endedAt: run.endedAt
        ) else {
            if invalidateOnFailure {
                store.invalidateRunMetrics(run.id, reason: "historical transcript repair failed to extract content")
                return .invalidated
            }
            return .skipped
        }

        let normalized = TelemetryMetricsSanitizer.sanitize(content, provider: run.provider)
        if let warning = normalized.warning {
            Log.warn("TelemetryRepairService: \(warning) run=\(run.id)")
        }

        let repaired = normalized.content
        run.model = repaired.model ?? run.model
        run.totalInputTokens = repaired.totalInputTokens
        run.totalCacheCreationInputTokens = repaired.totalCacheCreationInputTokens
        run.totalCacheReadInputTokens = repaired.totalCacheReadInputTokens
        run.totalCachedInputTokens = repaired.totalCachedInputTokens
        run.totalOutputTokens = repaired.totalOutputTokens
        run.totalReasoningOutputTokens = repaired.totalReasoningOutputTokens
        run.costUSD = repaired.costUSD
        run.tokenUsageSource = repaired.tokenUsageSource
        run.tokenUsageState = repaired.tokenUsageState
        run.costSource = repaired.costSource
        run.costState = repaired.costState
        run.rawTranscriptRef = repaired.rawTranscriptRef
        run.turnCount = repaired.turns.count
        if repaired.tokenUsageState == .invalid {
            run.errorMessage = "historical transcript repair invalidated implausible token metrics"
        } else if run.errorMessage == "historical transcript repair invalidated implausible token metrics" {
            run.errorMessage = nil
        }

        store.rewriteCompletedRun(run, turns: repaired.turns, toolCalls: repaired.toolCalls)
        return repaired.tokenUsageState == .invalid ? .invalidated : .rebuilt
    }
}
