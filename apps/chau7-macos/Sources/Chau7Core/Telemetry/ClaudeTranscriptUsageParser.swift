import Foundation

public enum ClaudeTranscriptUsageParser {
    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let iso8601Basic: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public struct State: Sendable {
        public var model: String?
        public var turns: [TelemetryTurn] = []
        public var toolCalls: [TelemetryToolCall] = []
        public var tokenUsage = TokenUsage()
        public var turnIndex = 0
        public var callIndex = 0
        public var seenUsageKeys: Set<String> = []

        public init() {}
    }

    public static func ingest(
        jsonl text: String,
        runID: String,
        startedAt: Date,
        endedAt: Date? = nil,
        state: inout State
    ) {
        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let message = obj["message"] as? [String: Any]
            else { continue }

            if let timestamp = parseDate(obj["timestamp"] as? String) {
                if timestamp < startedAt {
                    continue
                }
                if let endedAt, timestamp > endedAt {
                    continue
                }
            }

            let roleStr = (message["role"] as? String) ?? (obj["type"] as? String) ?? ""
            let role: TurnRole
            switch roleStr {
            case "user":
                role = .human
            case "assistant":
                role = .assistant
            case "system":
                role = .system
            default:
                continue
            }

            if let model = message["model"] as? String, state.model == nil {
                state.model = model
            }

            let usageKey = requestUsageKey(obj: obj, message: message)
            let shouldCountUsage = role == .assistant && usageKey.map { state.seenUsageKeys.insert($0).inserted } ?? true

            var turnUsage = TokenUsage()
            if shouldCountUsage, let usage = message["usage"] as? [String: Any] {
                let cacheCreationTokens = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                let cacheReadTokens = (usage["cache_read_input_tokens"] as? Int) ?? 0
                turnUsage = TokenUsage(
                    inputTokens: (usage["input_tokens"] as? Int) ?? 0,
                    cacheCreationInputTokens: cacheCreationTokens,
                    cacheReadInputTokens: cacheReadTokens,
                    cachedInputTokens: cacheCreationTokens + cacheReadTokens,
                    outputTokens: (usage["output_tokens"] as? Int) ?? 0,
                    reasoningOutputTokens: (usage["reasoning_output_tokens"] as? Int) ?? 0
                )
                state.tokenUsage.add(turnUsage)
            }

            var contentText = ""
            var turnToolCalls: [TelemetryToolCall] = []

            if let content = message["content"] as? [[String: Any]] {
                for block in content {
                    let blockType = block["type"] as? String ?? ""
                    switch blockType {
                    case "text":
                        if let text = block["text"] as? String {
                            if !contentText.isEmpty { contentText += "\n" }
                            contentText += text
                        }
                    case "tool_use":
                        let turnID = "\(runID)-t\(state.turnIndex)"
                        let toolName = (block["name"] as? String) ?? "unknown"
                        var argsJSON: String?
                        if let input = block["input"],
                           let data = try? JSONSerialization.data(withJSONObject: input) {
                            argsJSON = String(data: data, encoding: .utf8)
                        }
                        let call = TelemetryToolCall(
                            id: (block["id"] as? String) ?? UUID().uuidString,
                            runID: runID,
                            turnID: turnID,
                            toolName: toolName,
                            arguments: argsJSON,
                            status: .success,
                            callIndex: state.callIndex
                        )
                        turnToolCalls.append(call)
                        state.toolCalls.append(call)
                        state.callIndex += 1
                    case "tool_result":
                        if let result = block["content"] as? String {
                            if !contentText.isEmpty { contentText += "\n" }
                            contentText += "[tool_result] \(result)"
                        }
                    default:
                        break
                    }
                }
            } else if let content = message["content"] as? String {
                contentText = content
            }

            let turnID = "\(runID)-t\(state.turnIndex)"
            state.turns.append(
                TelemetryTurn(
                    id: turnID,
                    runID: runID,
                    turnIndex: state.turnIndex,
                    role: role,
                    content: contentText.isEmpty ? nil : contentText,
                    inputTokens: shouldCountUsage ? turnUsage.inputTokens : nil,
                    cacheCreationInputTokens: shouldCountUsage ? turnUsage.cacheCreationInputTokens : nil,
                    cacheReadInputTokens: shouldCountUsage ? turnUsage.cacheReadInputTokens : nil,
                    cachedInputTokens: shouldCountUsage ? turnUsage.cachedInputTokens : nil,
                    outputTokens: shouldCountUsage ? turnUsage.outputTokens : nil,
                    reasoningOutputTokens: shouldCountUsage ? turnUsage.reasoningOutputTokens : nil,
                    toolCalls: turnToolCalls,
                    timestamp: parseDate(obj["timestamp"] as? String)
                )
            )
            state.turnIndex += 1
        }
    }

    public static func requestUsageKey(obj: [String: Any], message: [String: Any]) -> String? {
        if let requestID = obj["requestId"] as? String, !requestID.isEmpty {
            return requestID
        }
        if let messageID = message["id"] as? String, !messageID.isEmpty {
            return messageID
        }
        if let uuid = obj["uuid"] as? String, !uuid.isEmpty {
            return uuid
        }
        return nil
    }

    public static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return iso8601.date(from: value) ?? iso8601Basic.date(from: value)
    }
}
