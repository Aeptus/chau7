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

        var state = ClaudeTranscriptUsageParser.State()

        for file in jsonlFiles.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let data = try? Data(contentsOf: file),
                  let text = String(data: data, encoding: .utf8) else { continue }
            ClaudeTranscriptUsageParser.ingest(jsonl: text, runID: runID, startedAt: startedAt, state: &state)
        }

        guard !state.turns.isEmpty else { return nil }

        return ExtractedRunContent(
            model: state.model,
            turns: state.turns,
            totalInputTokens: state.tokenUsage.inputTokens > 0 ? state.tokenUsage.inputTokens : nil,
            totalCachedInputTokens: state.tokenUsage.cachedInputTokens > 0 ? state.tokenUsage.cachedInputTokens : nil,
            totalOutputTokens: state.tokenUsage.outputTokens > 0 ? state.tokenUsage.outputTokens : nil,
            totalReasoningOutputTokens: state.tokenUsage.reasoningOutputTokens > 0 ? state.tokenUsage.reasoningOutputTokens : nil,
            tokenUsageSource: .transcriptDelta,
            tokenUsageState: .complete,
            costSource: .unavailable,
            costState: .missing,
            rawTranscriptRef: sessionDir.path,
            toolCalls: state.toolCalls
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
