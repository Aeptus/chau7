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
    public let requestCount: Int
    public let pricedRequestCount: Int

    public init(
        inputTokens: Int?,
        cacheCreationInputTokens: Int?,
        cacheReadInputTokens: Int?,
        outputTokens: Int?,
        reasoningOutputTokens: Int?,
        costUSD: Double?,
        requestCount: Int = 1,
        pricedRequestCount: Int = 0
    ) {
        self.inputTokens = inputTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.costUSD = costUSD
        self.tokenUsageSource = .proxy
        self.costSource = costUSD == nil ? .unavailable : .observed
        self.requestCount = requestCount
        self.pricedRequestCount = pricedRequestCount
    }
}

/// Matches proxy observations to runs without inventing attribution for unrelated calls.
public enum TelemetryProxyAttribution {
    public static func attribute(
        observations: [UsageEvidence],
        runs: [TelemetryRun]
    ) -> [String: ProxyRunAttribution] {
        var totals: [String: Totals] = [:]
        var seen = Set<String>()
        for observation in observations where observation.sourceKind == .proxy {
            // Run summaries are derived aggregates, never request observations.
            guard !observation.uniqueEventKey.hasPrefix("run|"),
                  seen.insert(observation.uniqueEventKey).inserted else { continue }
            guard let run = bestRun(for: observation, runs: runs) else { continue }
            totals[run.id, default: Totals()].add(observation)
        }
        return totals.mapValues(ProxyRunAttribution.init(totals:))
    }

    private static func bestRun(for observation: UsageEvidence, runs: [TelemetryRun]) -> TelemetryRun? {
        let candidates = runs.filter { run in
            providerMatches(observation.provider, run.provider) &&
                observation.observedAt >= run.startedAt &&
                observation.observedAt < (run.endedAt ?? Date.distantFuture)
        }
        // Each supplied identity constrains the same candidate set. Do not fall
        // back to a weaker identity when a stronger one is wrong or ambiguous.
        var matches = candidates
        var hasIdentity = false
        if let runID = observation.runID {
            hasIdentity = true
            matches = matches.filter { $0.id == runID }
        }
        if let tabID = observation.metadata["tab_id"], !tabID.isEmpty {
            hasIdentity = true
            matches = matches.filter { $0.tabID == tabID }
        }
        if let sessionID = observation.sessionID {
            hasIdentity = true
            matches = matches.filter { $0.sessionID == sessionID }
        }
        if let projectPath = observation.projectPath {
            hasIdentity = true
            matches = matches.filter { ($0.repoPath ?? $0.cwd) == projectPath }
        }
        guard hasIdentity, matches.count == 1 else { return nil }
        return matches.first
    }

    private static func providerMatches(_ observation: String, _ run: String) -> Bool {
        let observation = observation.lowercased()
        let run = run.lowercased()
        if observation == run { return true }
        return (observation == "openai" && run.contains("codex"))
            || (observation.contains("anthropic") && run.contains("claude"))
            || (observation == "anthropic" && run == "claude")
    }

    fileprivate struct Totals {
        var requestCount = 0
        var pricedRequestCount = 0
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
            requestCount += 1
            if let value = evidence.accountingInputTokens {
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
            if let value = evidence.accountingOutputTokens {
                outputTokens += value
                hasOutput = true
            }
            if let value = evidence.reasoningOutputTokens {
                reasoningOutputTokens += value
                hasReasoning = true
            }
            if let value = evidence.costUSD {
                pricedRequestCount += 1
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
            costUSD: totals.hasCost ? totals.costUSD : nil,
            requestCount: totals.requestCount,
            pricedRequestCount: totals.pricedRequestCount
        )
    }
}

public extension ProxyRunAttribution {
    /// Requests are measured, but interception cannot prove complete run coverage.
    func applying(to run: TelemetryRun) -> TelemetryRun {
        var updated = run
        updated.totalInputTokens = inputTokens
        updated.totalCacheCreationInputTokens = cacheCreationInputTokens
        updated.totalCacheReadInputTokens = cacheReadInputTokens
        updated.totalCachedInputTokens = cacheCreationInputTokens == nil && cacheReadInputTokens == nil
            ? nil : (cacheCreationInputTokens ?? 0) + (cacheReadInputTokens ?? 0)
        updated.totalOutputTokens = outputTokens
        updated.totalReasoningOutputTokens = reasoningOutputTokens
        updated.costUSD = costUSD
        updated.tokenUsageSource = .proxy
        updated.tokenUsageState = inputTokens == nil && outputTokens == nil && updated.totalCachedInputTokens == nil ? .missing : .partial
        updated.costSource = costSource
        updated.costState = costUSD == nil ? .missing : .partial
        updated.metadata["proxy_request_count"] = String(requestCount)
        updated.metadata["proxy_priced_request_count"] = String(pricedRequestCount)
        updated.metadata["proxy_coverage"] = "partial_retained_observations"
        return updated
    }
}
