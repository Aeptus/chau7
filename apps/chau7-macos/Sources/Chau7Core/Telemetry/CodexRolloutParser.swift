import Foundation

public enum CodexRolloutParser {
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

    public struct ParseResult: Sendable {
        public var model: String?
        public var turns: [TelemetryTurn]
        public var toolCalls: [TelemetryToolCall]
        public var tokenUsage: TokenUsage

        public init(
            model: String? = nil,
            turns: [TelemetryTurn] = [],
            toolCalls: [TelemetryToolCall] = [],
            tokenUsage: TokenUsage = TokenUsage()
        ) {
            self.model = model
            self.turns = turns
            self.toolCalls = toolCalls
            self.tokenUsage = tokenUsage
        }
    }

    public static func parse(
        jsonl text: String,
        runID: String,
        startedAt: Date
    ) -> ParseResult {
        var model: String?
        var turns: [TelemetryTurn] = []
        var toolCalls: [TelemetryToolCall] = []
        var tokenUsage = TokenUsage()
        var turnIndex = 0
        var callIndex = 0

        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            let type = obj["type"] as? String ?? ""
            let payload = obj["payload"] as? [String: Any] ?? [:]
            let timestamp = parseDate(obj["timestamp"] as? String)
            let isInRunWindow = timestamp == nil || timestamp! >= startedAt

            switch type {
            case "turn_context":
                if model == nil, let value = payload["model"] as? String {
                    model = value
                }

            case "response_item":
                guard isInRunWindow else { continue }

                let roleStr = payload["role"] as? String ?? ""
                let role: TurnRole
                switch roleStr {
                case "user":
                    role = .human
                case "assistant":
                    role = .assistant
                case "developer", "system":
                    role = .system
                default:
                    continue
                }

                var contentText = ""
                var turnToolCalls: [TelemetryToolCall] = []
                if let content = payload["content"] as? [[String: Any]] {
                    for block in content {
                        let blockType = block["type"] as? String ?? ""
                        switch blockType {
                        case "output_text", "input_text":
                            if let text = block["text"] as? String {
                                if !contentText.isEmpty { contentText += "\n" }
                                contentText += text
                            }
                        case "function_call":
                            let turnID = "\(runID)-t\(turnIndex)"
                            let call = TelemetryToolCall(
                                id: (block["call_id"] as? String) ?? UUID().uuidString,
                                runID: runID,
                                turnID: turnID,
                                toolName: (block["name"] as? String) ?? "unknown",
                                arguments: block["arguments"] as? String,
                                status: .success,
                                callIndex: callIndex
                            )
                            turnToolCalls.append(call)
                            toolCalls.append(call)
                            callIndex += 1
                        case "function_call_output":
                            if let output = block["output"] as? String {
                                if !contentText.isEmpty { contentText += "\n" }
                                contentText += "[tool_result] \(output)"
                            }
                        default:
                            break
                        }
                    }
                }

                let turnID = "\(runID)-t\(turnIndex)"
                turns.append(
                    TelemetryTurn(
                        id: turnID,
                        runID: runID,
                        turnIndex: turnIndex,
                        role: role,
                        content: contentText.isEmpty ? nil : contentText,
                        toolCalls: turnToolCalls,
                        timestamp: timestamp
                    )
                )
                turnIndex += 1

            case "event_msg":
                guard isInRunWindow,
                      (payload["type"] as? String) == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any]
                else { continue }

                tokenUsage.add(
                    TokenUsage(
                        inputTokens: (last["input_tokens"] as? Int) ?? 0,
                        cachedInputTokens: (last["cached_input_tokens"] as? Int) ?? 0,
                        outputTokens: (last["output_tokens"] as? Int) ?? 0,
                        reasoningOutputTokens: (last["reasoning_output_tokens"] as? Int) ?? 0
                    )
                )

            default:
                break
            }
        }

        return ParseResult(model: model, turns: turns, toolCalls: toolCalls, tokenUsage: tokenUsage)
    }

    public static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return iso8601.date(from: value) ?? iso8601Basic.date(from: value)
    }
}
