import Foundation

public enum TelemetryMetricState: String, Codable, CaseIterable, Sendable {
    case complete
    case estimated
    case missing
    case invalid
}

public enum TokenUsageSource: String, Codable, CaseIterable, Sendable {
    case proxy
    case transcriptDelta
    case transcriptSnapshot
    case providerEstimate
    case unknown
}

public enum CostSource: String, Codable, CaseIterable, Sendable {
    case observed
    case estimated
    case unavailable
}

/// Canonical token accounting shared across runtime, proxy, and telemetry persistence.
///
/// Semantics:
/// - `inputTokens`: uncached input tokens sent to the model
/// - `cachedInputTokens`: backward-compatible combined cached input bucket
/// - `cacheCreationInputTokens`: cache-write input tokens when reported separately
/// - `cacheReadInputTokens`: cache-read input tokens when reported separately
/// - `outputTokens`: normal model output tokens
/// - `reasoningOutputTokens`: hidden or reasoning-only output tokens when reported
public struct TokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var cachedInputTokens: Int
    public var cacheCreationInputTokens: Int
    public var cacheReadInputTokens: Int
    public var outputTokens: Int
    public var reasoningOutputTokens: Int

    public init(
        inputTokens: Int = 0,
        cacheCreationInputTokens: Int = 0,
        cacheReadInputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0
    ) {
        self.inputTokens = max(0, inputTokens)
        self.cacheCreationInputTokens = max(0, cacheCreationInputTokens)
        self.cacheReadInputTokens = max(0, cacheReadInputTokens)
        self.cachedInputTokens = TokenUsage.reconcileCachedInputTokens(
            supplied: cachedInputTokens,
            creation: self.cacheCreationInputTokens,
            read: self.cacheReadInputTokens
        )
        self.outputTokens = max(0, outputTokens)
        self.reasoningOutputTokens = max(0, reasoningOutputTokens)
    }

    /// Enforces the invariant `cachedInputTokens ≥ cacheCreationInputTokens +
    /// cacheReadInputTokens` across every call site that stores a cached-input
    /// total. The explicit breakdown is authoritative — a provider that
    /// reports only a combined `supplied` counter can't validly claim less
    /// than the sum of components seen, so the result is clamped up. All
    /// inputs are clamped non-negative.
    ///
    /// Shared by `TokenUsage.init` (runtime aggregates) and
    /// `TelemetryRun.init` (persisted run snapshots) so billing math reads
    /// one reconciliation rule instead of two parallel implementations.
    public static func reconcileCachedInputTokens(
        supplied: Int,
        creation: Int,
        read: Int
    ) -> Int {
        let explicit = max(0, creation) + max(0, read)
        return max(max(0, supplied), explicit)
    }

    public var hasAnyTokens: Bool {
        totalTokens > 0
    }

    /// Input + output shown in most user-facing summaries.
    public var totalVisibleTokens: Int {
        inputTokens + outputTokens
    }

    /// Best effort billable total when providers expose cache and reasoning counters.
    public var totalBillableTokens: Int {
        inputTokens + effectiveCachedInputTokens + outputTokens + reasoningOutputTokens
    }

    /// Backward-compatible aggregate used by older surfaces.
    public var totalTokens: Int {
        totalVisibleTokens
    }

    public mutating func add(_ other: TokenUsage) {
        inputTokens += other.inputTokens
        cachedInputTokens += other.cachedInputTokens
        cacheCreationInputTokens += other.cacheCreationInputTokens
        cacheReadInputTokens += other.cacheReadInputTokens
        outputTokens += other.outputTokens
        reasoningOutputTokens += other.reasoningOutputTokens
    }

    public var effectiveCachedInputTokens: Int {
        max(cachedInputTokens, cacheCreationInputTokens + cacheReadInputTokens)
    }

    public var uncategorizedCachedInputTokens: Int {
        max(0, cachedInputTokens - (cacheCreationInputTokens + cacheReadInputTokens))
    }
}
