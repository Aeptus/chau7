import Foundation
import Chau7Core

struct TelemetryRepairReport: Sendable {
    var inspectedRuns = 0
    var rebuiltRuns = 0
    var invalidatedRuns = 0
    var skippedRuns = 0
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

            guard let provider = providers.first(where: { $0.canHandle(provider: run.provider) }) else {
                report.skippedRuns += 1
                continue
            }

            guard let content = provider.extractContent(
                runID: run.id,
                sessionID: run.sessionID,
                cwd: run.cwd,
                startedAt: run.startedAt
            ) else {
                store.invalidateRunMetrics(run.id, reason: "historical transcript repair failed to extract content")
                report.invalidatedRuns += 1
                continue
            }

            let normalized = TelemetryMetricsSanitizer.sanitize(content, provider: run.provider)
            if let warning = normalized.warning {
                Log.warn("TelemetryRepairService: \(warning) run=\(run.id)")
            }

            let repaired = normalized.content
            run.model = repaired.model ?? run.model
            run.totalInputTokens = repaired.totalInputTokens
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
            if repaired.tokenUsageState == .invalid {
                report.invalidatedRuns += 1
            } else {
                report.rebuiltRuns += 1
            }
        }

        return report
    }
}
