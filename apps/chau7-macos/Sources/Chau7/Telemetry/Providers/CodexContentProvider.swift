import Foundation
import Chau7Core

// Extracts run content from OpenAI Codex CLI's storage.
//
// Codex stores data in two places:
//   1. SQLite: ~/.codex/state_5.sqlite — `threads` table with session metadata
//   2. JSONL:  ~/.codex/sessions/<year>/<month>/<day>/rollout-<ts>-<id>.jsonl
//
// JSONL line types:
//   - session_meta: id, cwd, model_provider, cli_version, agent info
//   - turn_context: model, cwd, sandbox info
//   - response_item: role (developer/user/assistant), content blocks
//   - event_msg: type=token_count with total/last token usage
import SQLite3

final class CodexContentProvider: RunContentProvider {
    let providerName = "codex"

    func canHandle(provider: String) -> Bool {
        let lower = provider.lowercased()
        return lower.contains("codex") || lower.contains("openai") || lower == "gpt"
    }

    func extractContent(runID: String, sessionID: String?, cwd: String, startedAt: Date) -> ExtractedRunContent? {
        // Try JSONL first (richer data), fall back to SQLite
        if let sessionID,
           let result = extractFromJSONL(runID: runID, sessionID: sessionID, cwd: cwd, startedAt: startedAt) {
            return result
        }
        if let sessionID {
            return extractFromSQLite(runID: runID, sessionID: sessionID)
        }
        return nil
    }

    // MARK: - JSONL Extraction

    private func extractFromJSONL(runID: String, sessionID: String, cwd: String, startedAt: Date) -> ExtractedRunContent? {
        guard let file = findRolloutFile(sessionID: sessionID, startedAt: startedAt) else {
            return nil
        }

        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) else { return nil }

        var model: String?
        var turns: [TelemetryTurn] = []
        var toolCalls: [TelemetryToolCall] = []
        var totalInputTokens: Int?
        var totalOutputTokens: Int?
        var turnIndex = 0
        var callIndex = 0

        for line in text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any]
            else { continue }

            let type = obj["type"] as? String ?? ""
            let payload = obj["payload"] as? [String: Any] ?? [:]
            let timestamp = obj["timestamp"] as? String

            switch type {
            case "turn_context":
                if model == nil, let m = payload["model"] as? String {
                    model = m
                }

            case "response_item":
                let roleStr = payload["role"] as? String ?? ""
                let role: TurnRole
                switch roleStr {
                case "user": role = .human
                case "assistant": role = .assistant
                case "developer", "system": role = .system
                default: continue
                }

                var contentText = ""
                var turnToolCalls: [TelemetryToolCall] = []

                if let content = payload["content"] as? [[String: Any]] {
                    for block in content {
                        let blockType = block["type"] as? String ?? ""
                        switch blockType {
                        case "output_text", "input_text":
                            if let t = block["text"] as? String {
                                if !contentText.isEmpty { contentText += "\n" }
                                contentText += t
                            }
                        case "function_call":
                            let turnID = "\(runID)-t\(turnIndex)"
                            let toolName = (block["name"] as? String) ?? "unknown"
                            let args = block["arguments"] as? String
                            let call = TelemetryToolCall(
                                id: (block["call_id"] as? String) ?? UUID().uuidString,
                                runID: runID, turnID: turnID,
                                toolName: toolName,
                                arguments: args,
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
                let isoDate = timestamp.flatMap { Self.parseISO8601($0) }
                turns.append(TelemetryTurn(
                    id: turnID, runID: runID, turnIndex: turnIndex,
                    role: role,
                    content: contentText.isEmpty ? nil : contentText,
                    toolCalls: turnToolCalls,
                    timestamp: isoDate
                ))
                turnIndex += 1

            case "event_msg":
                let eventType = payload["type"] as? String ?? ""
                if eventType == "token_count",
                   let info = payload["info"] as? [String: Any],
                   let total = info["total_token_usage"] as? [String: Any] {
                    // Take the cumulative total (last token_count event has the final sum)
                    totalInputTokens = total["input_tokens"] as? Int
                    totalOutputTokens = total["output_tokens"] as? Int
                }

            default:
                break
            }
        }

        guard !turns.isEmpty else { return nil }

        return ExtractedRunContent(
            model: model,
            turns: turns,
            totalInputTokens: totalInputTokens,
            totalOutputTokens: totalOutputTokens,
            rawTranscriptRef: file.path,
            toolCalls: toolCalls
        )
    }

    // MARK: - SQLite Fallback

    private func extractFromSQLite(runID: String, sessionID: String) -> ExtractedRunContent? {
        let dbPath = RuntimeIsolation.pathInHome(".codex/state_5.sqlite")
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        let sql = "SELECT * FROM threads WHERE id = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        // Extract all needed data while stmt is valid
        let tokensIdx = colIndex(stmt, "tokens_used")
        let tokensUsed = tokensIdx >= 0 ? Int(sqlite3_column_int(stmt, tokensIdx)) : 0
        let firstMessage = colString(stmt, "first_user_message")
        let rolloutPath = colString(stmt, "rollout_path")

        // If rollout file exists, prefer JSONL extraction (richer data).
        // We've already extracted what we need from stmt, so defer cleanup is safe.
        if let rolloutPath,
           FileManager.default.fileExists(atPath: rolloutPath) {
            if let result = extractFromJSONL(runID: runID, sessionID: sessionID, cwd: "", startedAt: .distantPast) {
                return result
            }
        }

        // Build a minimal turn from the first user message
        var turns: [TelemetryTurn] = []
        if let msg = firstMessage, !msg.isEmpty {
            turns.append(TelemetryTurn(
                id: "\(runID)-t0",
                runID: runID, turnIndex: 0, role: .human,
                content: msg
            ))
        }

        return ExtractedRunContent(
            turns: turns,
            totalInputTokens: tokensUsed > 0 ? tokensUsed : nil,
            rawTranscriptRef: rolloutPath
        )
    }

    // MARK: - File Resolution

    /// Codex rollout files: ~/.codex/sessions/<year>/<month>/<day>/rollout-<ts>-<id>.jsonl
    private func findRolloutFile(sessionID: String, startedAt: Date) -> URL? {
        let sessionsDir = RuntimeIsolation.urlInHome(".codex/sessions")

        let cal = Calendar.current
        let year = String(format: "%04d", cal.component(.year, from: startedAt))
        let month = String(format: "%02d", cal.component(.month, from: startedAt))
        let day = String(format: "%02d", cal.component(.day, from: startedAt))

        let dayDir = sessionsDir
            .appendingPathComponent(year)
            .appendingPathComponent(month)
            .appendingPathComponent(day)

        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dayDir, includingPropertiesForKeys: nil
        ) else { return nil }

        // Match by session ID in filename: rollout-<timestamp>-<session-id>.jsonl
        for file in files where file.pathExtension == "jsonl" {
            if file.lastPathComponent.contains(sessionID) {
                return file
            }
        }

        // Also check previous day (session might have started near midnight)
        let prevDate = cal.date(byAdding: .day, value: -1, to: startedAt) ?? startedAt
        let prevDay = String(format: "%02d", cal.component(.day, from: prevDate))
        let prevMonth = String(format: "%02d", cal.component(.month, from: prevDate))
        let prevYear = String(format: "%04d", cal.component(.year, from: prevDate))

        let prevDayDir = sessionsDir
            .appendingPathComponent(prevYear)
            .appendingPathComponent(prevMonth)
            .appendingPathComponent(prevDay)

        if let prevFiles = try? FileManager.default.contentsOfDirectory(
            at: prevDayDir, includingPropertiesForKeys: nil
        ) {
            for file in prevFiles where file.pathExtension == "jsonl" {
                if file.lastPathComponent.contains(sessionID) {
                    return file
                }
            }
        }

        return nil
    }

    // MARK: - SQLite Helpers

    private func colIndex(_ stmt: OpaquePointer?, _ name: String) -> Int32 {
        guard let stmt else { return -1 }
        let count = sqlite3_column_count(stmt)
        for i in 0 ..< count {
            if let cn = sqlite3_column_name(stmt, i), String(cString: cn) == name {
                return i
            }
        }
        return -1
    }

    private func colString(_ stmt: OpaquePointer?, _ name: String) -> String? {
        guard let stmt else { return nil }
        let idx = colIndex(stmt, name)
        guard idx >= 0, let ptr = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: ptr)
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func parseISO8601(_ string: String) -> Date? {
        isoFormatter.date(from: string)
    }
}
