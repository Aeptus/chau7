import Foundation
import Chau7Core

/// Reads Claude Code JSONL transcript files incrementally to extract token usage.
///
/// Maintains per-file byte offsets so each `readNewTokens()` call only processes
/// lines appended since the last read — suitable for polling during active turns.
///
/// Reuses the same transcript path resolution and token field extraction as
/// `ClaudeCodeContentProvider` (lines 62–70).
final class IncrementalTranscriptReader {
    private let sessionDir: URL
    private var fileOffsets: [URL: UInt64] = [:]

    /// Cumulative totals across all reads.
    private(set) var cumulativeInput = 0
    private(set) var cumulativeOutput = 0
    private(set) var cumulativeCacheCreation = 0
    private(set) var cumulativeCacheRead = 0

    init?(cwd: String, claudeSessionID: String?) {
        guard let sessionID = claudeSessionID, !sessionID.isEmpty else {
            Log.debug("IncrementalTranscriptReader: no session ID, token tracking disabled")
            return nil
        }
        guard let projectDir = Self.resolveProjectDir(cwd: cwd) else {
            Log.debug("IncrementalTranscriptReader: could not resolve project dir for cwd=\(cwd)")
            return nil
        }
        guard let sessionDir = Self.findSessionDir(projectDir: projectDir, sessionID: sessionID) else {
            Log.debug("IncrementalTranscriptReader: session dir not found for session=\(sessionID)")
            return nil
        }
        self.sessionDir = sessionDir
    }

    /// Read new lines since last call. Returns the incremental token deltas.
    func readNewTokens() -> (input: Int, output: Int, cacheCreation: Int, cacheRead: Int) {
        let subagentsDir = sessionDir.appendingPathComponent("subagents")
        guard let jsonlFiles = try? FileManager.default.contentsOfDirectory(
            at: subagentsDir, includingPropertiesForKeys: nil
        ).filter({ $0.pathExtension == "jsonl" }) else {
            return (0, 0, 0, 0)
        }

        var deltaInput = 0
        var deltaOutput = 0
        var deltaCacheCreation = 0
        var deltaCacheRead = 0

        for file in jsonlFiles {
            let offset = fileOffsets[file] ?? 0

            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }

            // Seek to where we left off
            handle.seek(toFileOffset: offset)
            let data = handle.availableData
            guard !data.isEmpty else { continue }

            // Only advance offset up to the last complete line (newline byte).
            // Any trailing partial line will be re-read on the next call.
            let newlineByte = UInt8(ascii: "\n")
            let safeCount: Int
            if let lastNewline = data.lastIndex(of: newlineByte) {
                safeCount = lastNewline + 1 // include the newline itself
            } else {
                // No complete line yet — don't advance, retry next time
                continue
            }
            fileOffsets[file] = offset + UInt64(safeCount)

            // Parse new complete lines
            guard let text = String(data: data[data.startIndex ..< data.index(data.startIndex, offsetBy: safeCount)], encoding: .utf8) else { continue }
            for line in text.components(separatedBy: .newlines) where !line.isEmpty {
                guard let lineData = line.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                      let message = obj["message"] as? [String: Any],
                      let usage = message["usage"] as? [String: Any]
                else { continue }

                // Same field extraction as ClaudeCodeContentProvider lines 62-70
                let input = (usage["input_tokens"] as? Int) ?? 0
                let cacheCreation = (usage["cache_creation_input_tokens"] as? Int) ?? 0
                let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
                let output = (usage["output_tokens"] as? Int) ?? 0

                deltaInput += input
                deltaOutput += output
                deltaCacheCreation += cacheCreation
                deltaCacheRead += cacheRead
            }
        }

        cumulativeInput += deltaInput
        cumulativeOutput += deltaOutput
        cumulativeCacheCreation += deltaCacheCreation
        cumulativeCacheRead += deltaCacheRead

        return (deltaInput, deltaOutput, deltaCacheCreation, deltaCacheRead)
    }

    // MARK: - Path Resolution (mirrors ClaudeCodeContentProvider)

    private static func resolveProjectDir(cwd: String) -> URL? {
        let claudeProjects = RuntimeIsolation.urlInHome(".claude/projects")

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: claudeProjects, includingPropertiesForKeys: nil
        ) else { return nil }

        let normalizedCwd = cwd.replacingOccurrences(of: "/", with: "-")
        for entry in entries {
            let dirName = entry.lastPathComponent
            if normalizedCwd.hasSuffix(dirName) || dirName.hasSuffix(normalizedCwd) || dirName == normalizedCwd {
                return entry
            }
            let stripped = dirName.hasPrefix("-") ? String(dirName.dropFirst()) : dirName
            let cwdStripped = normalizedCwd.hasPrefix("-") ? String(normalizedCwd.dropFirst()) : normalizedCwd
            if stripped == cwdStripped {
                return entry
            }
        }

        let cwdComponents = cwd.split(separator: "/")
        for entry in entries {
            let dirName = entry.lastPathComponent
            let dirComponents = dirName.split(separator: "-").filter { !$0.isEmpty }
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

    private static func findSessionDir(projectDir: URL, sessionID: String) -> URL? {
        let candidate = projectDir.appendingPathComponent(sessionID)
        if FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: projectDir, includingPropertiesForKeys: nil
        ) else { return nil }

        for entry in entries {
            if entry.lastPathComponent.hasPrefix(String(sessionID.prefix(8))) {
                return entry
            }
        }
        return nil
    }
}
