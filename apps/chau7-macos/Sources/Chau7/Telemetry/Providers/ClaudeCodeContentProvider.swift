import Foundation
import Chau7Core

/// Extracts run content from Claude Code's JSONL transcript files.
///
/// Claude Code stores conversation data in:
///   ~/.claude/projects/<project-hash>/<session-id>/subagents/agent-<id>.jsonl
///
/// Each JSONL line contains:
///   - sessionId, cwd, version, gitBranch, message.role (user/assistant)
///   - Assistant messages have: model, usage.input_tokens, usage.output_tokens
///   - Content blocks: text, tool_use, tool_result
final class ClaudeCodeContentProvider: RunContentProvider {
    let providerName = "claude"

    func canHandle(provider: String) -> Bool {
        let lower = provider.lowercased()
        return lower.contains("claude") || lower == "anthropic"
    }

    func extractContent(runID: String, sessionID: String?, cwd: String, startedAt: Date) -> ExtractedRunContent? {
        guard let sessionID, !sessionID.isEmpty else { return nil }

        // Resolve the project directory hash from cwd
        guard let projectDir = resolveProjectDir(cwd: cwd),
              let sessionDir = findSessionDir(projectDir: projectDir, sessionID: sessionID)
        else { return nil }

        // Parse JSONL files: try subagents/ first, then session root.
        // Claude Code versions differ in where they write conversation data.
        let subagentsDir = sessionDir.appendingPathComponent("subagents")
        var jsonlFiles = (try? FileManager.default.contentsOfDirectory(
            at: subagentsDir, includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "jsonl" }) ?? []

        // Fallback: check for JSONL files directly in the session directory
        if jsonlFiles.isEmpty {
            jsonlFiles = (try? FileManager.default.contentsOfDirectory(
                at: sessionDir, includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "jsonl" }) ?? []
        }

        if jsonlFiles.isEmpty { return nil }

        var allTurns: [TelemetryTurn] = []
        var allToolCalls: [TelemetryToolCall] = []
        var totalInput = 0
        var totalOutput = 0
        var model: String?
        var turnIndex = 0
        var callIndex = 0

        for file in jsonlFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }

            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let message = obj["message"] as? [String: Any]
                else { continue }

                let roleStr = (message["role"] as? String) ?? (obj["type"] as? String) ?? ""

                // Extract model from assistant messages
                if let m = message["model"] as? String, model == nil {
                    model = m
                }

                // Extract token usage
                if let usage = message["usage"] as? [String: Any] {
                    let input = (usage["input_tokens"] as? Int) ?? 0
                    let cacheCreation = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                    let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                    let output = (usage["output_tokens"] as? Int) ?? 0
                    totalInput += input + cacheCreation + cacheRead
                    totalOutput += output
                }

                // Build turn
                let role: TurnRole
                switch roleStr {
                case "user": role = .human
                case "assistant": role = .assistant
                case "system": role = .system
                default: continue
                }

                // Extract content text and tool calls from content blocks
                var contentText = ""
                var turnToolCalls: [TelemetryToolCall] = []

                if let content = message["content"] as? [[String: Any]] {
                    for block in content {
                        let blockType = block["type"] as? String ?? ""
                        switch blockType {
                        case "text":
                            if let t = block["text"] as? String {
                                if !contentText.isEmpty { contentText += "\n" }
                                contentText += t
                            }
                        case "tool_use":
                            let turnID = "\(runID)-t\(turnIndex)"
                            let toolName = (block["name"] as? String) ?? "unknown"
                            var argsJSON: String?
                            if let input = block["input"] {
                                if let data = try? JSONSerialization.data(withJSONObject: input) {
                                    argsJSON = String(data: data, encoding: .utf8)
                                }
                            }
                            let call = TelemetryToolCall(
                                id: (block["id"] as? String) ?? UUID().uuidString,
                                runID: runID, turnID: turnID,
                                toolName: toolName,
                                arguments: argsJSON,
                                status: .success,
                                callIndex: callIndex
                            )
                            turnToolCalls.append(call)
                            allToolCalls.append(call)
                            callIndex += 1
                        case "tool_result":
                            if let resultContent = block["content"] as? String {
                                if !contentText.isEmpty { contentText += "\n" }
                                contentText += "[tool_result] \(resultContent)"
                            }
                        default:
                            break
                        }
                    }
                } else if let content = message["content"] as? String {
                    contentText = content
                }

                let turnID = "\(runID)-t\(turnIndex)"
                let turn = TelemetryTurn(
                    id: turnID,
                    runID: runID,
                    turnIndex: turnIndex,
                    role: role,
                    content: contentText.isEmpty ? nil : contentText,
                    inputTokens: role == .assistant ? (message["usage"] as? [String: Any])?["input_tokens"] as? Int : nil,
                    outputTokens: role == .assistant ? (message["usage"] as? [String: Any])?["output_tokens"] as? Int : nil,
                    toolCalls: turnToolCalls
                )
                allTurns.append(turn)
                turnIndex += 1
            }
        }

        guard !allTurns.isEmpty else { return nil }

        return ExtractedRunContent(
            model: model,
            turns: allTurns,
            totalInputTokens: totalInput > 0 ? totalInput : nil,
            totalOutputTokens: totalOutput > 0 ? totalOutput : nil,
            rawTranscriptRef: sessionDir.path,
            toolCalls: allToolCalls
        )
    }

    // MARK: - Path Resolution

    /// Claude Code hashes project paths for directory names.
    /// Format: ~/.claude/projects/<hashed-path>/<session-id>/
    private func resolveProjectDir(cwd: String) -> URL? {
        let claudeProjects = RuntimeIsolation.urlInHome(".claude/projects")

        // Claude uses the path with / replaced by - and leading -
        // e.g., /Users/chris/Downloads/Chau7 -> -Users-chris-Downloads-Chau7
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: claudeProjects, includingPropertiesForKeys: nil
        ) else { return nil }

        // Try to match the cwd against project directory names
        let normalizedCwd = cwd.replacingOccurrences(of: "/", with: "-")
        for entry in entries {
            let dirName = entry.lastPathComponent
            // Check if the directory name matches our cwd pattern
            if normalizedCwd.hasSuffix(dirName) || dirName.hasSuffix(normalizedCwd) || dirName == normalizedCwd {
                return entry
            }
            // Also check partial match (cwd might be a subdirectory)
            let stripped = dirName.hasPrefix("-") ? String(dirName.dropFirst()) : dirName
            let cwdStripped = normalizedCwd.hasPrefix("-") ? String(normalizedCwd.dropFirst()) : normalizedCwd
            if stripped == cwdStripped {
                return entry
            }
        }

        // Fallback: check if any project dir contains a session subdirectory
        // by using the cwd path components to find a match
        let cwdComponents = cwd.split(separator: "/")
        for entry in entries {
            let dirName = entry.lastPathComponent
            let dirComponents = dirName.split(separator: "-").filter { !$0.isEmpty }
            // Check if the last N components of cwd match the last N of dirName
            if dirComponents.count >= 2 {
                let lastTwo = dirComponents.suffix(2).joined(separator: "-")
                let cwdLastTwo = cwdComponents.suffix(2).joined(separator: "-")
                if lastTwo == cwdLastTwo {
                    return entry
                }
            }
        }

        return nil
    }

    private func findSessionDir(projectDir: URL, sessionID: String) -> URL? {
        let candidate = projectDir.appendingPathComponent(sessionID)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        // Session might be stored without the full UUID — check partial matches
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: nil
        ) else { return nil }

        for entry in entries {
            if entry.lastPathComponent.hasPrefix(sessionID.prefix(8)) {
                return entry
            }
        }
        return nil
    }
}
