import AppKit
import Chau7Core
import Foundation

/// Session-finder registry + identity normalization helpers + scrollback
/// capture utilities for `OverlayTabsModel`. Three concerns:
///
///   1. **Provider session-finder registry** — Codex/Claude/Gemini etc.
///      register a `(directory, referenceDate, claimedSessionIds) -> sessionId?`
///      callback at startup; `findAIResumeSessionId` dispatches to the
///      registered finder for a given provider key. This is the
///      generalization of the older `findClaudeSessionId` / `findCodexSessionId`
///      static helpers (still here for backward compatibility).
///
///   2. **Identity normalization** — `normalizedAIProvider`,
///      `normalizeAISessionId`, `normalizePersistedAISessionId`,
///      `normalizedSessionDirectory`, `isSameSessionDirectory`,
///      `isValidSessionId`, `detectAIAppName`. Pure transforms applied
///      consistently across save and restore paths so a saved provider
///      string compares equal to the live session's effective provider.
///
///   3. **Scrollback capture** — `captureScrollback` (2 overloads),
///      `scrollbackLinesWithinByteLimit`, `stripRestoreArtifacts`,
///      `shellSafeSingleQuote`, `maxPersistedScrollbackBytes`.
///      Wraps `ScrollbackRestoreFilter` (Chau7Core) so the model can
///      capture a session's terminal buffer for persistence.
///
/// Extracted from the larger restore-pipeline file so the domain is
/// findable by name and the file size matches what its name implies.
/// Pure statics; no instance state.
extension OverlayTabsModel {

    static var sessionFinderLock = NSLock()
    static var sessionFinders: [String: (String, Date?, Set<String>) -> String?] = [:]

    static func registerSessionFinder(
        forProviderKey key: String,
        finder: @escaping (String, Date?, Set<String>) -> String?
    ) {
        sessionFinderLock.lock()
        defer { sessionFinderLock.unlock() }
        sessionFinders[key] = finder
    }

    static func findAIResumeSessionId(
        for provider: String,
        directory: String,
        referenceDate: Date?,
        claimedSessionIds: Set<String> = []
    ) -> String? {
        sessionFinderLock.lock()
        let finder = sessionFinders[provider]
        sessionFinderLock.unlock()
        return finder?(directory, referenceDate, claimedSessionIds)
    }

    static func normalizedAIProvider(from value: String?) -> String? {
        guard let value else { return nil }
        return AIResumeParser.normalizeProviderName(value)
    }

    static func normalizeAISessionId(_ sessionId: String?) -> String? {
        guard let sessionId else { return nil }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIResumeParser.isValidSessionId(trimmed) else { return nil }
        return trimmed
    }

    static func normalizePersistedAISessionId(
        _ sessionId: String?,
        source: AISessionIdentitySource?
    ) -> String? {
        guard let sessionId else { return nil }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if AIResumeParser.isValidSessionId(trimmed) {
            return trimmed
        }
        if source == .synthetic, trimmed.hasPrefix("synth:") {
            return trimmed
        }
        return nil
    }

    static func findClaudeSessionId(
        forDirectory directory: String,
        referenceDate: Date? = nil,
        claimedSessionIds: Set<String> = []
    ) -> String? {
        let canonicalDirectory = normalizedSessionDirectory(directory)
        guard !canonicalDirectory.isEmpty else { return nil }

        let matches = ClaudeCodeMonitor.shared
            .sessionCandidates(forDirectory: canonicalDirectory)
            .compactMap { candidate -> (sessionId: String, touchedAt: Date)? in
                guard let normalizedSessionId = normalizeAISessionId(candidate.sessionId) else {
                    return nil
                }
                guard !claimedSessionIds.contains(normalizedSessionId) else { return nil }
                return (sessionId: normalizedSessionId, touchedAt: candidate.lastActivity)
            }

        guard !matches.isEmpty else { return nil }

        if let chosen = AIResumeParser.bestSessionMatch(candidates: matches, referenceDate: referenceDate) {
            if matches.count > 1 {
                Log.trace(
                    "findClaudeSessionId: selected sessionId=\(chosen) from \(matches.count) candidates for dir=\(canonicalDirectory)"
                )
            }
            return chosen
        }

        Log.warn("findClaudeSessionId: multiple session candidates for dir=\(canonicalDirectory); skipping to avoid cross-tab contamination")
        return nil
    }

    static func detectAIAppName(fromOutput output: String?) -> String? {
        guard let output else { return nil }
        return CommandDetection.detectAppFromOutput(output)
    }

    static func normalizedSessionDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = RuntimeIsolation.expandTilde(in: trimmed)
        return URL(fileURLWithPath: expanded).standardized.path
    }

    static func isSameSessionDirectory(_ lhs: String, as rhs: String) -> Bool {
        let left = normalizedSessionDirectory(lhs)
        let right = normalizedSessionDirectory(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.hasPrefix(right + "/")
    }

    static func isValidSessionId(_ id: String) -> Bool {
        AIResumeParser.isValidSessionId(id)
    }

    /// Find the most recent Codex session ID for a given directory.
    /// Scans ~/.codex/sessions/ day directories for session files whose
    /// cwd matches the given directory. Caps total file reads to avoid
    /// blocking the main thread.
    static func findCodexSessionId(
        forDirectory dir: String,
        referenceDate: Date? = nil,
        claimedSessionIds: Set<String> = []
    ) -> String? {
        let fm = FileManager.default
        let sessionsDir = RuntimeIsolation.urlInHome(".codex/sessions", fileManager: fm)

        // Filter helper: only include entries that look like date components (digits only)
        let isDateComponent = { (name: String) -> Bool in
            !name.isEmpty && name.allSatisfy(\.isNumber)
        }

        // Collect year/month/day directories, sorted most-recent-first
        guard let years = try? fm.contentsOfDirectory(atPath: sessionsDir.path) else { return nil }
        var dayDirs: [URL] = []
        for year in years.filter(isDateComponent).sorted().reversed() {
            let yearURL = sessionsDir.appendingPathComponent(year)
            guard let months = try? fm.contentsOfDirectory(atPath: yearURL.path) else { continue }
            for month in months.filter(isDateComponent).sorted().reversed() {
                let monthURL = yearURL.appendingPathComponent(month)
                guard let days = try? fm.contentsOfDirectory(atPath: monthURL.path) else { continue }
                for day in days.filter(isDateComponent).sorted().reversed() {
                    dayDirs.append(monthURL.appendingPathComponent(day))
                }
            }
        }

        // Scan the 7 most recent day directories, capping total file reads
        var filesRead = 0
        var parsedLines = 0
        var matches: [(sessionId: String, touchedAt: Date, rank: Int)] = []
        let maxFileReads = 30
        for dayDir in dayDirs.prefix(7) {
            guard let files = try? fm.contentsOfDirectory(atPath: dayDir.path) else { continue }
            // Sort files reverse-alphabetically (most recent timestamp first)
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }.sorted().reversed()
            for file in jsonlFiles {
                guard filesRead < maxFileReads else { return nil }
                filesRead += 1
                let filePath = dayDir.appendingPathComponent(file).path
                guard let firstLine = readFirstLine(atPath: filePath) else { continue }
                parsedLines += 1
                // Parse session_meta to extract cwd and id
                if let (sessionCwd, sessionId) = parseCodexSessionMeta(firstLine),
                   let rank = DirectoryPathMatcher.bidirectionalPrefixRank(
                       targetPath: dir,
                       candidatePath: sessionCwd
                   ),
                   !claimedSessionIds.contains(sessionId) {
                    let touchedAt = (try? FileManager.default.attributesOfItem(atPath: filePath)[.modificationDate] as? Date) ?? Date.distantPast
                    matches.append((sessionId: sessionId, touchedAt: touchedAt, rank: rank))
                }
            }
        }

        if matches.isEmpty {
            if filesRead == 0 {
                Log.warn("findCodexSessionId: no .jsonl files found in recent directories for dir=\(dir)")
            } else if parsedLines == 0 {
                Log.warn("findCodexSessionId: no readable first lines found while scanning \(filesRead) files for dir=\(dir)")
            } else {
                Log.trace("findCodexSessionId: scanned \(filesRead) files without finding a session_meta match for dir=\(dir)")
            }
            return nil
        }

        let bestRank = matches.map(\.rank).min()
        let rankedMatches = bestRank.map { rank in
            matches
                .filter { $0.rank == rank }
                .map { (sessionId: $0.sessionId, touchedAt: $0.touchedAt) }
        } ?? []

        if let chosen = AIResumeParser.bestSessionMatch(candidates: rankedMatches, referenceDate: referenceDate) {
            if rankedMatches.count > 1 {
                Log.trace("findCodexSessionId: selected sessionId=\(chosen) from \(matches.count) candidates using activity hint for dir=\(dir)")
            }
            return chosen
        }

        Log.warn("findCodexSessionId: multiple session candidates for dir=\(dir); skipping to avoid cross-tab contamination")
        return nil
    }

    /// Read just the first line of a file without loading the entire contents.
    static func readFirstLine(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        // Large JSONL session files can exceed small read buffers due embedded
        // instructions/context, so read until the first newline (or a safe cap).
        let chunkSize = 4096
        let maxLineBytes = 262_144
        var buffer = Data()

        while buffer.count < maxLineBytes {
            let chunk = handle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)

            if let newlineIndex = buffer.firstIndex(of: 10) {
                buffer = Data(buffer.prefix(upTo: newlineIndex))
                break
            }

            if buffer.count >= maxLineBytes {
                Log.warn(
                    """
                    findCodexSessionId: first line exceeded cap while reading \
                    \"\(path)\" (bufferBytes=\(buffer.count), cap=\(maxLineBytes))
                    """
                )
                break
            }
        }

        guard !buffer.isEmpty else { return nil }

        return readFirstLine(from: buffer)
    }

    static func readFirstLine(from data: Data, maxBytes: Int = 262_144) -> String? {
        guard data.count <= maxBytes else {
            return nil
        }

        guard !data.isEmpty else { return nil }

        if let newlineIndex = data.firstIndex(of: 10) {
            return String(decoding: data[..<newlineIndex], as: UTF8.self)
        }

        return String(decoding: data, as: UTF8.self)
    }

    /// Parse the first line of a Codex session file (session_meta JSON)
    /// to extract the cwd and session ID.
    static func parseCodexSessionMeta(_ line: String) -> (cwd: String, id: String)? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "session_meta",
              let payload = json["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String,
              let id = payload["id"] as? String else {
            return nil
        }
        let normalizedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCwd.isEmpty, AIResumeParser.isValidSessionId(normalizedId) else {
            return nil
        }
        return (normalizedCwd, normalizedId)
    }

    static func captureScrollback(from session: TerminalSessionModel?, maxLines: Int) -> String? {
        guard let session else {
            return nil
        }

        return captureScrollback(
            maxLines: maxLines,
            styledData: { session.captureStyledRemoteSnapshot() },
            fallbackData: { session.captureRemoteSnapshot() }
        )
    }

    static func captureScrollback(
        maxLines: Int,
        styledData: () -> Data?,
        fallbackData: () -> Data?
    ) -> String? {
        ScrollbackRestoreFilter.captureScrollback(
            maxLines: maxLines,
            styledData: styledData,
            fallbackData: fallbackData
        )
    }

    static let maxPersistedScrollbackBytes = ScrollbackRestoreFilter.maxPersistedScrollbackBytes

    static func scrollbackLinesWithinByteLimit(_ lines: [String], maxBytes: Int) -> [String]? {
        ScrollbackRestoreFilter.scrollbackLinesWithinByteLimit(lines, maxBytes: maxBytes)
    }

    /// Strips restore command artifacts from scrollback content.
    /// Used on both save (captureScrollback) and inject (restore) paths to handle
    /// scrollback saved by older binaries that didn't have the save-side filter.
    static func stripRestoreArtifacts(from content: String) -> String {
        ScrollbackRestoreFilter.stripRestoreArtifacts(from: content)
    }

    static func shellSafeSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
