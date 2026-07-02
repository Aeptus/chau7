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
    private static let rolloutFileIndexLock = NSLock()
    private static var rolloutFileIndexByRoot: [String: [String: URL]] = [:]

    func canHandle(provider: String) -> Bool {
        let lower = provider.lowercased()
        return lower.contains("codex") || lower.contains("openai") || lower == "gpt"
    }

    func extractContent(runID: String, sessionID: String?, cwd: String, startedAt: Date, endedAt: Date?) -> ExtractedRunContent? {
        // Try JSONL first (richer data), fall back to SQLite
        if let sessionID,
           let result = extractFromJSONL(runID: runID, sessionID: sessionID, cwd: cwd, startedAt: startedAt, endedAt: endedAt) {
            return result
        }
        if let sessionID {
            return extractFromSQLite(runID: runID, sessionID: sessionID, startedAt: startedAt, endedAt: endedAt)
        }
        return nil
    }

    // MARK: - JSONL Extraction

    private func extractFromJSONL(runID: String, sessionID: String, cwd: String, startedAt: Date, endedAt: Date?) -> ExtractedRunContent? {
        guard let file = findRolloutFile(sessionID: sessionID, startedAt: startedAt) else {
            return nil
        }

        return extractFromJSONL(file: file, runID: runID, startedAt: startedAt, endedAt: endedAt)
    }

    private func extractFromJSONL(file: URL, runID: String, startedAt: Date, endedAt: Date?) -> ExtractedRunContent? {
        guard FileManager.default.fileExists(atPath: file.path) else {
            return nil
        }

        guard let reading = BoundedTranscriptReader.read(at: file) else { return nil }
        if let originalBytes = reading.truncatedFromBytes {
            Log.warn("CodexContentProvider: rollout \(file.lastPathComponent) is \(originalBytes / 1_048_576)MB; parsed last \(BoundedTranscriptReader.defaultMaxBytes / 1_048_576)MB to avoid OOM")
        }

        let parsed = CodexRolloutParser.parse(jsonl: reading.text, runID: runID, startedAt: startedAt, endedAt: endedAt)
        guard !parsed.turns.isEmpty || parsed.tokenUsage.hasAnyTokens else { return nil }
        let estimatedCost = ModelPricingTable.estimatedCostUSD(for: parsed.tokenUsage, modelID: parsed.model, providerHint: providerName)

        return ExtractedRunContent(
            model: parsed.model,
            turns: parsed.turns,
            totalInputTokens: parsed.tokenUsage.inputTokens > 0 ? parsed.tokenUsage.inputTokens : nil,
            totalCacheCreationInputTokens: parsed.tokenUsage.cacheCreationInputTokens > 0 ? parsed.tokenUsage.cacheCreationInputTokens : nil,
            totalCacheReadInputTokens: parsed.tokenUsage.cacheReadInputTokens > 0 ? parsed.tokenUsage.cacheReadInputTokens : nil,
            totalCachedInputTokens: parsed.tokenUsage.cachedInputTokens > 0 ? parsed.tokenUsage.cachedInputTokens : nil,
            totalOutputTokens: parsed.tokenUsage.outputTokens > 0 ? parsed.tokenUsage.outputTokens : nil,
            totalReasoningOutputTokens: parsed.tokenUsage.reasoningOutputTokens > 0 ? parsed.tokenUsage.reasoningOutputTokens : nil,
            costUSD: estimatedCost,
            tokenUsageSource: .transcriptDelta,
            tokenUsageState: .complete,
            costSource: estimatedCost != nil ? .estimated : .unavailable,
            costState: estimatedCost != nil ? .estimated : .missing,
            rawTranscriptRef: file.path,
            toolCalls: parsed.toolCalls
        )
    }

    // MARK: - SQLite Fallback

    /// Open `~/.codex/state_5.sqlite` read-only, prepare `sql`, bind
    /// `sessionID` as the single parameter, and pass the row-positioned
    /// statement to `body`. Returns nil if the database is missing, the
    /// statement fails to prepare, or no row matches. Both
    /// `extractFromSQLite` and `lookupRolloutPathInSQLite` route through
    /// here to share the open/prepare/bind/step ladder.
    private func queryCodexThreads<T>(
        sql: String, sessionID: String, body: (OpaquePointer?) -> T?
    ) -> T? {
        let dbPath = RuntimeIsolation.pathInHome(".codex/state_5.sqlite")
        guard FileManager.default.fileExists(atPath: dbPath) else { return nil }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_close(db) }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, (sessionID as NSString).utf8String, -1, nil)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return body(stmt)
    }

    private func extractFromSQLite(runID: String, sessionID: String, startedAt: Date, endedAt: Date?) -> ExtractedRunContent? {
        queryCodexThreads(
            sql: "SELECT * FROM threads WHERE id = ? LIMIT 1",
            sessionID: sessionID
        ) { stmt -> ExtractedRunContent? in
            // Extract all needed data while stmt is valid
            let tokensIdx = colIndex(stmt, "tokens_used")
            let tokensUsed = tokensIdx >= 0 ? Int(sqlite3_column_int(stmt, tokensIdx)) : 0
            let firstMessage = colString(stmt, "first_user_message")
            let rolloutPath = colString(stmt, "rollout_path")

            // If rollout file exists, prefer JSONL extraction (richer data).
            // We've already extracted what we need from stmt, so defer cleanup is safe.
            if let rolloutPath,
               FileManager.default.fileExists(atPath: rolloutPath) {
                if let result = extractFromJSONL(
                    file: URL(fileURLWithPath: rolloutPath),
                    runID: runID,
                    startedAt: startedAt,
                    endedAt: endedAt
                ) {
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

            let usage = TokenUsage(inputTokens: tokensUsed)
            let estimatedCost = ModelPricingTable.estimatedCostUSD(for: usage, modelID: nil, providerHint: providerName)

            return ExtractedRunContent(
                turns: turns,
                totalInputTokens: tokensUsed > 0 ? tokensUsed : nil,
                costUSD: estimatedCost,
                tokenUsageSource: tokensUsed > 0 ? .transcriptSnapshot : nil,
                tokenUsageState: tokensUsed > 0 ? .estimated : .missing,
                costSource: estimatedCost != nil ? .estimated : .unavailable,
                costState: estimatedCost != nil ? .estimated : .missing,
                rawTranscriptRef: rolloutPath
            )
        }
    }

    // MARK: - File Resolution

    /// Codex rollout files: ~/.codex/sessions/<year>/<month>/<day>/rollout-<ts>-<id>.jsonl
    private func findRolloutFile(sessionID: String, startedAt: Date) -> URL? {
        if let rolloutPath = lookupRolloutPathInSQLite(sessionID: sessionID) {
            let rolloutURL = URL(fileURLWithPath: rolloutPath)
            if FileManager.default.fileExists(atPath: rolloutURL.path) {
                return rolloutURL
            }
        }

        let sessionsDir = RuntimeIsolation.urlInHome(".codex/sessions")

        let cal = Calendar.current
        let year = String(format: "%04d", cal.component(.year, from: startedAt))
        let month = String(format: "%02d", cal.component(.month, from: startedAt))
        let day = String(format: "%02d", cal.component(.day, from: startedAt))

        let dayDir = sessionsDir
            .appendingPathComponent(year)
            .appendingPathComponent(month)
            .appendingPathComponent(day)

        if let files = try? FileManager.default.contentsOfDirectory(
            at: dayDir, includingPropertiesForKeys: nil
        ) {
            // Match by session ID in filename: rollout-<timestamp>-<session-id>.jsonl
            for file in files where file.pathExtension == "jsonl" {
                if file.lastPathComponent.contains(sessionID) {
                    return file
                }
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

        if let globalMatch = globallyFindRolloutFile(sessionID: sessionID, root: sessionsDir) {
            return globalMatch
        }

        return nil
    }

    private func globallyFindRolloutFile(sessionID: String, root: URL) -> URL? {
        Self.rolloutFileIndexLock.lock()
        if Self.rolloutFileIndexByRoot[root.path] == nil {
            Self.rolloutFileIndexByRoot[root.path] = buildRolloutFileIndex(root: root)
        }
        let match = Self.rolloutFileIndexByRoot[root.path]?[sessionID]
        Self.rolloutFileIndexLock.unlock()
        return match
    }

    private func lookupRolloutPathInSQLite(sessionID: String) -> String? {
        queryCodexThreads(
            sql: "SELECT rollout_path FROM threads WHERE id = ? LIMIT 1",
            sessionID: sessionID
        ) { stmt -> String? in
            guard let ptr = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: ptr)
        }
    }

    private func buildRolloutFileIndex(root: URL) -> [String: URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return [:]
        }

        var index: [String: URL] = [:]
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  let sessionID = sessionIDFromRolloutFilename(fileURL.lastPathComponent) else {
                continue
            }
            index[sessionID] = fileURL
        }
        return index
    }

    private func sessionIDFromRolloutFilename(_ filename: String) -> String? {
        guard filename.hasPrefix("rollout-"), filename.hasSuffix(".jsonl") else { return nil }
        let stem = String(filename.dropLast(".jsonl".count))
        guard stem.count >= 36 else { return nil }
        let sessionIDStart = stem.index(stem.endIndex, offsetBy: -36)
        let sessionID = String(stem[sessionIDStart...])
        return sessionID.contains("-") ? sessionID : nil
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

    private static let isoFormatter = DateFormatters.iso8601

    private static func parseISO8601(_ string: String) -> Date? {
        isoFormatter.date(from: string)
    }
}
