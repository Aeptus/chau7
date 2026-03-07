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
    ///   - sessionID: The AI tool's session ID (e.g., Claude's resume ID)
    ///   - cwd: Working directory of the run
    ///   - startedAt: Run start time (for disambiguation when multiple sessions exist)
    /// - Returns: Extracted content, or nil if unavailable
    func extractContent(
        sessionID: String?,
        cwd: String,
        startedAt: Date
    ) -> ExtractedRunContent?
}

/// Normalized content extracted from a provider's native storage.
public struct ExtractedRunContent: Sendable {
    public var model: String?
    public var turns: [TelemetryTurn]
    public var totalInputTokens: Int?
    public var totalOutputTokens: Int?
    public var costUSD: Double?
    public var rawTranscriptRef: String?
    public var toolCalls: [TelemetryToolCall]

    public init(
        model: String? = nil,
        turns: [TelemetryTurn] = [],
        totalInputTokens: Int? = nil,
        totalOutputTokens: Int? = nil,
        costUSD: Double? = nil,
        rawTranscriptRef: String? = nil,
        toolCalls: [TelemetryToolCall] = []
    ) {
        self.model = model
        self.turns = turns
        self.totalInputTokens = totalInputTokens
        self.totalOutputTokens = totalOutputTokens
        self.costUSD = costUSD
        self.rawTranscriptRef = rawTranscriptRef
        self.toolCalls = toolCalls
    }
}
