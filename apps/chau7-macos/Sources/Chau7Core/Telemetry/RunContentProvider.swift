import Foundation

/// Protocol for provider-specific content extraction.
/// Each AI tool (Claude Code, Codex, etc.) stores conversation data differently.
/// Implementations read from the tool's native storage and return normalized content.
public protocol RunContentProvider: Sendable {
    /// Provider identifier this adapter handles (e.g., "claude", "codex").
    var providerName: String { get }

    /// Whether this adapter can handle content extraction for the given provider string.
    func canHandle(provider: String) -> Bool

    /// Extract structured content from the provider's storage.
    ///
    /// Called when a run completes. The implementation should locate the provider's
    /// conversation transcript and extract turns, token usage, model info, and tool calls.
    ///
    /// - Parameters:
    ///   - runID: The telemetry run's unique ID — use this as the parent ID on all
    ///     turns and tool calls so they match the runs table foreign key.
    ///   - sessionID: The AI tool's session ID (e.g., Claude's resume ID)
    ///   - cwd: Working directory of the run
    ///   - startedAt: Run start time (for disambiguation when multiple sessions exist)
    ///   - endedAt: Run end time. Providers should use this to avoid attributing
    ///     later transcript events from a reused session to an earlier run.
    /// - Returns: Extracted content, or nil if unavailable
    func extractContent(
        runID: String,
        sessionID: String?,
        cwd: String,
        startedAt: Date,
        endedAt: Date?
    ) -> ExtractedRunContent?
}

/// Normalized content extracted from a provider's native storage.
public struct ExtractedRunContent: Sendable {
    public var model: String?
    public var turns: [TelemetryTurn]
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
    public var rawTranscriptRef: String?
    public var toolCalls: [TelemetryToolCall]

    public init(
        model: String? = nil,
        turns: [TelemetryTurn] = [],
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
        rawTranscriptRef: String? = nil,
        toolCalls: [TelemetryToolCall] = []
    ) {
        self.model = model
        self.turns = turns
        self.totalInputTokens = totalInputTokens
        self.totalCacheCreationInputTokens = totalCacheCreationInputTokens
        self.totalCacheReadInputTokens = totalCacheReadInputTokens
        let explicitCachedTotal = max(0, (totalCacheCreationInputTokens ?? 0) + (totalCacheReadInputTokens ?? 0))
        if let totalCachedInputTokens {
            self.totalCachedInputTokens = max(totalCachedInputTokens, explicitCachedTotal)
        } else {
            self.totalCachedInputTokens = explicitCachedTotal > 0 ? explicitCachedTotal : nil
        }
        self.totalOutputTokens = totalOutputTokens
        self.totalReasoningOutputTokens = totalReasoningOutputTokens
        self.costUSD = costUSD
        self.tokenUsageSource = tokenUsageSource
        self.tokenUsageState = tokenUsageState
        self.costSource = costSource
        self.costState = costState
        self.rawTranscriptRef = rawTranscriptRef
        self.toolCalls = toolCalls
    }
}
