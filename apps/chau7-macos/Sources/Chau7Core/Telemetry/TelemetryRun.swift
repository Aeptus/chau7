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
        errorMessage: String? = nil
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
        self.totalCachedInputTokens = totalCachedInputTokens
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
    }

    public var tokenUsage: TokenUsage {
        TokenUsage(
            inputTokens: totalInputTokens ?? 0,
            cachedInputTokens: totalCachedInputTokens ?? 0,
            outputTokens: totalOutputTokens ?? 0,
            reasoningOutputTokens: totalReasoningOutputTokens ?? 0
        )
    }
}

/// Filter criteria for querying runs.
public struct TelemetryRunFilter: Sendable {
    public var sessionID: String?
    public var repoPath: String?
    public var provider: String?
    public var after: Date?
    public var before: Date?
    public var tags: [String]?
    public var limit: Int?
    public var offset: Int?

    public init(
        sessionID: String? = nil,
        repoPath: String? = nil,
        provider: String? = nil,
        after: Date? = nil,
        before: Date? = nil,
        tags: [String]? = nil,
        limit: Int? = nil,
        offset: Int? = nil
    ) {
        self.sessionID = sessionID
        self.repoPath = repoPath
        self.provider = provider
        self.after = after
        self.before = before
        self.tags = tags
        self.limit = limit
        self.offset = offset
    }
}
