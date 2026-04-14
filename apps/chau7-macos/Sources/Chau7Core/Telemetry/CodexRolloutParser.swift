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
        public var latestQuotaSnapshot: ProviderQuotaSnapshot?

        public init(
            model: String? = nil,
            turns: [TelemetryTurn] = [],
            toolCalls: [TelemetryToolCall] = [],
            tokenUsage: TokenUsage = TokenUsage(),
            latestQuotaSnapshot: ProviderQuotaSnapshot? = nil
        ) {
            self.model = model
            self.turns = turns
            self.toolCalls = toolCalls
            self.tokenUsage = tokenUsage
            self.latestQuotaSnapshot = latestQuotaSnapshot
        }
    }

    public static func parse(
        jsonl text: String,
        runID: String,
        startedAt: Date,
        endedAt: Date? = nil
    ) -> ParseResult {
        var model: String?
        var turns: [TelemetryTurn] = []
        var toolCalls: [TelemetryToolCall] = []
        var tokenUsage = TokenUsage()
        var latestQuotaSnapshot: ProviderQuotaSnapshot?
        var turnIndex = 0
        var callIndex = 0

        forEachJSONObject(in: text) { obj in
            let type = obj["type"] as? String ?? ""
            let payload = obj["payload"] as? [String: Any] ?? [:]
            let timestamp = parseDate(obj["timestamp"] as? String)
            let isInRunWindow: Bool
            if let timestamp {
                let isBeforeEnd = endedAt.map { timestamp <= $0 } ?? true
                isInRunWindow = timestamp >= startedAt && isBeforeEnd
            } else {
                isInRunWindow = true
            }

            switch type {
            case "turn_context":
                if model == nil, let value = payload["model"] as? String {
                    model = value
                }

            case "response_item":
                guard isInRunWindow else { return }

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
                    return
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
                if let quotaSnapshot = parseQuotaSnapshot(
                    payload: payload,
                    timestamp: timestamp ?? startedAt
                ) {
                    latestQuotaSnapshot = quotaSnapshot
                }

                guard isInRunWindow,
                      (payload["type"] as? String) == "token_count",
                      let info = payload["info"] as? [String: Any],
                      let last = info["last_token_usage"] as? [String: Any]
                else { return }

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

        return ParseResult(
            model: model,
            turns: turns,
            toolCalls: toolCalls,
            tokenUsage: tokenUsage,
            latestQuotaSnapshot: latestQuotaSnapshot
        )
    }

    public static func parseDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        return iso8601.date(from: value) ?? iso8601Basic.date(from: value)
    }

    public static func latestQuotaSnapshot(
        in text: String,
        rawSourceRef: String? = nil
    ) -> ProviderQuotaSnapshot? {
        var latestSnapshot: ProviderQuotaSnapshot?

        forEachJSONObject(in: text) { obj in
            guard let payload = obj["payload"] as? [String: Any],
                  let snapshot = parseQuotaSnapshot(
                      payload: payload,
                      timestamp: parseDate(obj["timestamp"] as? String) ?? Date()
                  ) else {
                return
            }

            latestSnapshot = ProviderQuotaSnapshot(
                provider: snapshot.provider,
                capturedAt: snapshot.capturedAt,
                source: snapshot.source,
                planType: snapshot.planType,
                credits: snapshot.credits,
                rawSourceRef: rawSourceRef,
                windows: snapshot.windows
            )
        }

        return latestSnapshot
    }

    private static func forEachJSONObject(in text: String, _ body: ([String: Any]) -> Void) {
        var buffer = ""

        func flushBufferIfPossible() {
            guard !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let data = buffer.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return
            }
            body(obj)
            buffer.removeAll(keepingCapacity: true)
        }

        for line in text.components(separatedBy: .newlines) {
            if buffer.isEmpty {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                buffer = line
            } else {
                buffer += "\n" + line
            }
            flushBufferIfPossible()
        }

        flushBufferIfPossible()
    }

    private static func parseQuotaSnapshot(
        payload: [String: Any],
        timestamp: Date
    ) -> ProviderQuotaSnapshot? {
        guard let rateLimits = payload["rate_limits"] as? [String: Any] else { return nil }

        var windows: [ProviderQuotaWindowSnapshot] = []
        if let primary = rateLimits["primary"] as? [String: Any],
           let usedPercent = numberValue(primary["used_percent"]) {
            windows.append(
                ProviderQuotaWindowSnapshot(
                    id: "primary",
                    usedPercent: usedPercent,
                    windowMinutes: intValue(primary["window_minutes"]),
                    resetsAt: unixDate(primary["resets_at"])
                )
            )
        }
        if let secondary = rateLimits["secondary"] as? [String: Any],
           let usedPercent = numberValue(secondary["used_percent"]) {
            windows.append(
                ProviderQuotaWindowSnapshot(
                    id: "secondary",
                    usedPercent: usedPercent,
                    windowMinutes: intValue(secondary["window_minutes"]),
                    resetsAt: unixDate(secondary["resets_at"])
                )
            )
        }

        guard !windows.isEmpty else { return nil }
        return ProviderQuotaSnapshot(
            provider: "codex",
            capturedAt: timestamp,
            source: "codex_rollout",
            planType: rateLimits["plan_type"] as? String,
            credits: numberValue(rateLimits["credits"]),
            rawSourceRef: nil,
            windows: windows
        )
    }

    private static func numberValue(_ raw: Any?) -> Double? {
        switch raw {
        case let value as NSNumber:
            return value.doubleValue
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }

    private static func intValue(_ raw: Any?) -> Int? {
        switch raw {
        case let value as NSNumber:
            return value.intValue
        case let value as String:
            return Int(value)
        default:
            return nil
        }
    }

    private static func unixDate(_ raw: Any?) -> Date? {
        guard let seconds = numberValue(raw) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
