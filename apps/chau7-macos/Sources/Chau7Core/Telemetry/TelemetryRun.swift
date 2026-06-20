import Foundation

/// A single AI tool invocation from process start to exit.
/// This is the primary unit of observation in Chau7's telemetry system.
public struct TelemetryRun: Codable, Identifiable, Sendable {
    public let id: String
    public var sessionID: String?
    public var tabID: String?
    public let provider: String
    public var model: String?
    public let cwd: String
    public var repoPath: String?
    public let startedAt: Date
    public var endedAt: Date?
    public var durationMs: Int?
    public var exitStatus: Int?
    public var totalInputTokens: Int?
    public var totalCacheCreationInputTokens: Int?
    public var totalCacheReadInputTokens: Int?
    public var totalCachedInputTokens: Int?
    public var totalOutputTokens: Int?
    public var totalReasoningOutputTokens: Int?
    public var costUSD: Double?
    public var tokenUsageSource: TokenUsageSource?
    public var tokenUsageState: TelemetryMetricState
    public var costSource: CostSource?
    public var costState: TelemetryMetricState
    public var turnCount: Int
    public var tags: [String]
    public var metadata: [String: String]
    public var rawTranscriptRef: String?
    public var parentRunID: String?
    public var errorMessage: String?
    /// When transcript repair last attempted this (immutable, ended) run.
    /// Non-nil means "already attempted" — the repair sweep skips it so it
    /// doesn't re-read/re-parse the same transcript every cycle when metrics
    /// can't be derived (no pricing, unparseable/oversized transcript, etc.).
    public var transcriptRepairAttemptedAt: Date?

    public init(
        id: String = UUID().uuidString,
        sessionID: String? = nil,
        tabID: String? = nil,
        provider: String,
        model: String? = nil,
        cwd: String,
        repoPath: String? = nil,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        durationMs: Int? = nil,
        exitStatus: Int? = nil,
        totalInputTokens: Int? = nil,
        totalCacheCreationInputTokens: Int? = nil,
        totalCacheReadInputTokens: Int? = nil,
        totalCachedInputTokens: Int? = nil,
        totalOutputTokens: Int? = nil,
        totalReasoningOutputTokens: Int? = nil,
        costUSD: Double? = nil,
        tokenUsageSource: TokenUsageSource? = nil,
        tokenUsageState: TelemetryMetricState = .missing,
        costSource: CostSource? = nil,
        costState: TelemetryMetricState = .missing,
        turnCount: Int = 0,
        tags: [String] = [],
        metadata: [String: String] = [:],
        rawTranscriptRef: String? = nil,
        parentRunID: String? = nil,
        errorMessage: String? = nil,
        transcriptRepairAttemptedAt: Date? = nil
    ) {
        self.id = id
        self.sessionID = sessionID
        self.tabID = tabID
        self.provider = provider
        self.model = model
        self.cwd = cwd
        self.repoPath = repoPath
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.durationMs = durationMs
        self.exitStatus = exitStatus
        self.totalInputTokens = totalInputTokens
        self.totalCacheCreationInputTokens = totalCacheCreationInputTokens
        self.totalCacheReadInputTokens = totalCacheReadInputTokens
        // Reuse TokenUsage's shared reconciliation so persisted runs obey
        // the same `cached ≥ creation + read` invariant as runtime
        // aggregates. Optional handling is local: nil input + zero
        // explicit breakdown stays nil (distinguishes "no signal" from
        // "zero cached input" in persisted snapshots).
        let creation = max(0, totalCacheCreationInputTokens ?? 0)
        let read = max(0, totalCacheReadInputTokens ?? 0)
        if let totalCachedInputTokens {
            self.totalCachedInputTokens = TokenUsage.reconcileCachedInputTokens(
                supplied: totalCachedInputTokens,
                creation: creation,
                read: read
            )
        } else {
            let explicit = creation + read
            self.totalCachedInputTokens = explicit > 0 ? explicit : nil
        }
        self.totalOutputTokens = totalOutputTokens
        self.totalReasoningOutputTokens = totalReasoningOutputTokens
        self.costUSD = costUSD
        self.tokenUsageSource = tokenUsageSource
        self.tokenUsageState = tokenUsageState
        self.costSource = costSource
        self.costState = costState
        self.turnCount = turnCount
        self.tags = tags
        self.metadata = metadata
        self.rawTranscriptRef = rawTranscriptRef
        self.parentRunID = parentRunID
        self.errorMessage = errorMessage
        self.transcriptRepairAttemptedAt = transcriptRepairAttemptedAt
    }

    public var tokenUsage: TokenUsage {
        TokenUsage(
            inputTokens: totalInputTokens ?? 0,
            cacheCreationInputTokens: totalCacheCreationInputTokens ?? 0,
            cacheReadInputTokens: totalCacheReadInputTokens ?? 0,
            cachedInputTokens: totalCachedInputTokens ?? 0,
            outputTokens: totalOutputTokens ?? 0,
            reasoningOutputTokens: totalReasoningOutputTokens ?? 0
        )
    }
}

public extension TelemetryRun {
    /// Copies sanitized content fields (model, token totals, cost, source/state,
    /// transcript ref, turn count) onto the run. When the token state is invalid,
    /// sets `errorMessage` to `invalidMessage`; when valid and `clearOnValid` is
    /// true, clears `errorMessage` iff it currently equals `invalidMessage` (so a
    /// re-validating repair removes its own stale marker). Shared by
    /// TelemetryRecorder.extractCompletedRunContent and
    /// TelemetryRepairService.rebuildRun.
    mutating func applyContent(
        _ content: ExtractedRunContent,
        invalidMessage: String,
        clearOnValid: Bool
    ) {
        model = content.model ?? model
        totalInputTokens = content.totalInputTokens
        totalCacheCreationInputTokens = content.totalCacheCreationInputTokens
        totalCacheReadInputTokens = content.totalCacheReadInputTokens
        totalCachedInputTokens = content.totalCachedInputTokens
        totalOutputTokens = content.totalOutputTokens
        totalReasoningOutputTokens = content.totalReasoningOutputTokens
        costUSD = content.costUSD
        tokenUsageSource = content.tokenUsageSource
        tokenUsageState = content.tokenUsageState
        costSource = content.costSource
        costState = content.costState
        rawTranscriptRef = content.rawTranscriptRef
        turnCount = content.turns.count
        if content.tokenUsageState == .invalid {
            errorMessage = invalidMessage
        } else if clearOnValid, errorMessage == invalidMessage {
            errorMessage = nil
        }
    }
}

/// Filter criteria for querying runs.
public struct TelemetryRunFilter: Sendable {
    public var sessionID: String?
    public var repoPath: String?
    public var provider: String?
    public var parentRunID: String?
    public var after: Date?
    public var before: Date?
    public var tags: [String]?
    public var limit: Int?
    public var offset: Int?
    /// When true, only return completed runs that need transcript repair
    /// (missing transcript source, missing metrics, or unavailable cost).
    public var needsTranscriptRepair = false

    public init(
        sessionID: String? = nil,
        repoPath: String? = nil,
        provider: String? = nil,
        parentRunID: String? = nil,
        after: Date? = nil,
        before: Date? = nil,
        tags: [String]? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        needsTranscriptRepair: Bool = false
    ) {
        self.sessionID = sessionID
        self.repoPath = repoPath
        self.provider = provider
        self.parentRunID = parentRunID
        self.after = after
        self.before = before
        self.tags = tags
        self.limit = limit
        self.offset = offset
        self.needsTranscriptRepair = needsTranscriptRepair
    }
}
