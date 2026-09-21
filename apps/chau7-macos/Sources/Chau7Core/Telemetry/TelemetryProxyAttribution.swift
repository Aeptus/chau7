import Foundation

/// Measured usage totals attributed to one telemetry run.
public struct ProxyRunAttribution: Equatable, Sendable {
    public let inputTokens: Int?
    public let cacheCreationInputTokens: Int?
    public let cacheReadInputTokens: Int?
    public let outputTokens: Int?
    public let reasoningOutputTokens: Int?
    public let costUSD: Double?
    public let tokenUsageSource: TokenUsageSource
    public let costSource: CostSource

    public init(
        inputTokens: Int?,
        cacheCreationInputTokens: Int?,
        cacheReadInputTokens: Int?,
        outputTokens: Int?,
        reasoningOutputTokens: Int?,
        costUSD: Double?
    ) {
        self.inputTokens = inputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.costUSD = costUSD
        self.tokenUsageSource = .proxy
        self.costSource = .observed
    }
}

/// Matches proxy observations to runs without inventing attribution for unrelated calls.
public enum TelemetryProxyAttribution {
    public static func attribute(
        observations: [UsageEvidence],
        runs: [TelemetryRun]
    ) -> [String: ProxyRunAttribution] {
        var totals: [String: Totals] = [:]
        for observation in observations where observation.sourceKind == .proxy {
            guard let run = bestRun(for: observation, runs: runs) else { continue }
            totals[run.id, default: Totals()].add(observation)
        }
        return totals.mapValues(ProxyRunAttribution.init(totals:))
    }

    private static func bestRun(for observation: UsageEvidence, runs: [TelemetryRun]) -> TelemetryRun? {
        let candidates = runs.filter { run in
            providerMatches(observation.provider, run.provider) &&
                observation.observedAt >= run.startedAt &&
                observation.observedAt <= (run.endedAt ?? Date.distantFuture)
        }
        guard !candidates.isEmpty else { return nil }

        if let tabID = observation.metadata["tab_id"], !tabID.isEmpty,
           let match = candidates.first(where: { $0.tabID == tabID }) {
            return match
        }
        if let sessionID = observation.sessionID,
           let match = candidates.first(where: { $0.sessionID == sessionID }) {
            return match
        }
        guard let projectPath = observation.projectPath else { return nil }
        return candidates.first { ($0.repoPath ?? $0.cwd) == projectPath }
    }

    private static func providerMatches(_ observation: String, _ run: String) -> Bool {
        let observation = observation.lowercased()
        let run = run.lowercased()
        if observation == run { return true }
        return (observation == "openai" && run.contains("codex"))
            || (observation.contains("anthropic") && run.contains("claude"))
            || (observation == "anthropic" && run == "claude")
    }

    private struct Totals {
        var inputTokens = 0
        var cacheCreationInputTokens = 0
        var cacheReadInputTokens = 0
        var outputTokens = 0
        var reasoningOutputTokens = 0
        var costUSD = 0.0
        var hasInput = false
        var hasCacheCreation = false
        var hasCacheRead = false
        var hasOutput = false
        var hasReasoning = false
        var hasCost = false

        mutating func add(_ evidence: UsageEvidence) {
            if let value = evidence.inputTokens {
                inputTokens += value
                hasInput = true
            }
            if let value = evidence.cacheCreationInputTokens {
                cacheCreationInputTokens += value
                hasCacheCreation = true
            }
            if let value = evidence.cacheReadInputTokens {
                cacheReadInputTokens += value
                hasCacheRead = true
            }
            if let value = evidence.outputTokens {
                outputTokens += value
                hasOutput = true
            }
            if let value = evidence.reasoningOutputTokens {
                reasoningOutputTokens += value
                hasReasoning = true
            }
            if let value = evidence.costUSD {
                costUSD += value
                hasCost = true
            }
        }
    }
}

private extension ProxyRunAttribution {
    init(totals: TelemetryProxyAttribution.Totals) {
        self.init(
            inputTokens: totals.hasInput ? totals.inputTokens : nil,
            cacheCreationInputTokens: totals.hasCacheCreation ? totals.cacheCreationInputTokens : nil,
            cacheReadInputTokens: totals.hasCacheRead ? totals.cacheReadInputTokens : nil,
            outputTokens: totals.hasOutput ? totals.outputTokens : nil,
            reasoningOutputTokens: totals.hasReasoning ? totals.reasoningOutputTokens : nil,
            costUSD: totals.hasCost ? totals.costUSD : nil
        )
    }
}
