import Foundation

/// A single prompt-response cycle within a run.
public struct TelemetryTurn: Codable, Identifiable, Sendable {
    public let id: String
    public let runID: String
    public let turnIndex: Int
    public let role: TurnRole
    public var content: String?
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    public var outputTokens: Int?
    public var reasoningOutputTokens: Int?
    public var toolCalls: [TelemetryToolCall]
    public var timestamp: Date?
    public var durationMs: Int?

    public init(
        id: String = UUID().uuidString,
        runID: String,
        turnIndex: Int,
        role: TurnRole,
        content: String? = nil,
        inputTokens: Int? = nil,
        cachedInputTokens: Int? = nil,
        outputTokens: Int? = nil,
        reasoningOutputTokens: Int? = nil,
        toolCalls: [TelemetryToolCall] = [],
        timestamp: Date? = nil,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.runID = runID
        self.turnIndex = turnIndex
        self.role = role
        self.content = content
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.toolCalls = toolCalls
        self.timestamp = timestamp
        self.durationMs = durationMs
    }

    public var tokenUsage: TokenUsage {
        TokenUsage(
            inputTokens: inputTokens ?? 0,
            cachedInputTokens: cachedInputTokens ?? 0,
            outputTokens: outputTokens ?? 0,
            reasoningOutputTokens: reasoningOutputTokens ?? 0
        )
    }
}

public enum TurnRole: String, Codable, Sendable {
    case human
    case assistant
    case system
    case toolResult = "tool_result"
}

/// A single tool invocation within a turn.
public struct TelemetryToolCall: Codable, Identifiable, Sendable {
    public let id: String
    public var runID: String
    public var turnID: String
    public let toolName: String
    public var arguments: String?
    public var result: String?
    public var status: ToolCallStatus
    public var durationMs: Int?
    public var callIndex: Int

    public init(
        id: String = UUID().uuidString,
        runID: String,
        turnID: String,
        toolName: String,
        arguments: String? = nil,
        result: String? = nil,
        status: ToolCallStatus = .success,
        durationMs: Int? = nil,
        callIndex: Int = 0
    ) {
        self.id = id
        self.runID = runID
        self.turnID = turnID
        self.toolName = toolName
        self.arguments = arguments
        self.result = result
        self.status = status
        self.durationMs = durationMs
        self.callIndex = callIndex
    }
}

public enum ToolCallStatus: String, Codable, Sendable {
    case success
    case error
    case denied
}
