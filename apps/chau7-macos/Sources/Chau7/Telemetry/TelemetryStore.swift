import Foundation
import SQLite3
import Chau7Core

/// SQLite-backed store for telemetry run records, turns, and tool calls.
/// Thread-safe: all database access is serialized on a dedicated queue.
final class TelemetryStore {
    static let shared = TelemetryStore()

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.chau7.telemetry.store")

    private static var dbPath: String {
        let dir = NSHomeDirectory() + "/.chau7/telemetry"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/runs.db"
    }

    private init() {
        queue.sync { self.open() }
    }

    deinit {
        queue.sync {
            if let db = self.db {
                sqlite3_close(db)
            }
        }
    }

    // MARK: - Setup

    private func open() {
        let path = Self.dbPath
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            Log.error("TelemetryStore: failed to open database at \(path)")
            return
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil)
        createTables()
    }

    private func createTables() {
        let sql = """
        CREATE TABLE IF NOT EXISTS runs (
            run_id TEXT PRIMARY KEY,
            session_id TEXT,
            tab_id TEXT,
            provider TEXT NOT NULL,
            model TEXT,
            cwd TEXT NOT NULL,
            repo_path TEXT,
            started_at TEXT NOT NULL,
            ended_at TEXT,
            duration_ms INTEGER,
            exit_status INTEGER,
            total_input_tokens INTEGER,
            total_output_tokens INTEGER,
            cost_usd REAL,
            turn_count INTEGER DEFAULT 0,
            tags TEXT,
            metadata TEXT,
            raw_transcript_ref TEXT,
            parent_run_id TEXT,
            error_message TEXT,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        );

        CREATE INDEX IF NOT EXISTS idx_runs_session ON runs(session_id);
        CREATE INDEX IF NOT EXISTS idx_runs_repo ON runs(repo_path);
        CREATE INDEX IF NOT EXISTS idx_runs_provider ON runs(provider);
        CREATE INDEX IF NOT EXISTS idx_runs_started ON runs(started_at);
        CREATE INDEX IF NOT EXISTS idx_runs_tab ON runs(tab_id);

        CREATE TABLE IF NOT EXISTS turns (
            turn_id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
            turn_index INTEGER NOT NULL,
            role TEXT NOT NULL,
            content TEXT,
            input_tokens INTEGER,
            output_tokens INTEGER,
            tool_calls TEXT,
            timestamp TEXT,
            duration_ms INTEGER
        );

        CREATE INDEX IF NOT EXISTS idx_turns_run ON turns(run_id, turn_index);

        CREATE TABLE IF NOT EXISTS tool_calls (
            call_id TEXT PRIMARY KEY,
            run_id TEXT NOT NULL REFERENCES runs(run_id) ON DELETE CASCADE,
            turn_id TEXT NOT NULL REFERENCES turns(turn_id) ON DELETE CASCADE,
            tool_name TEXT NOT NULL,
            arguments TEXT,
            result TEXT,
            status TEXT,
            duration_ms INTEGER,
            call_index INTEGER NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_tool_calls_run ON tool_calls(run_id);
        CREATE INDEX IF NOT EXISTS idx_tool_calls_name ON tool_calls(tool_name);

        CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY,
            applied_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        );

        INSERT OR IGNORE INTO schema_version (version) VALUES (1);
        """

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            Log.error("TelemetryStore: schema creation failed: \(msg)")
            sqlite3_free(errMsg)
        }
    }

    // MARK: - Write

    func insertRun(_ run: TelemetryRun) {
        queue.async { [weak self] in
            self?._insertRun(run)
        }
    }

    func insertRunSync(_ run: TelemetryRun) {
        queue.sync { _insertRun(run) }
    }

    private func _insertRun(_ run: TelemetryRun) {
        guard let db else { return }
        let sql = """
        INSERT OR REPLACE INTO runs
        (run_id, session_id, tab_id, provider, model, cwd, repo_path,
         started_at, ended_at, duration_ms, exit_status,
         total_input_tokens, total_output_tokens, cost_usd,
         turn_count, tags, metadata, raw_transcript_ref, parent_run_id, error_message)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, run.id)
        bindText(stmt, 2, run.sessionID)
        bindText(stmt, 3, run.tabID)
        bindText(stmt, 4, run.provider)
        bindText(stmt, 5, run.model)
        bindText(stmt, 6, run.cwd)
        bindText(stmt, 7, run.repoPath)
        bindText(stmt, 8, Self.isoString(from: run.startedAt))
        bindText(stmt, 9, run.endedAt.map { Self.isoString(from: $0) })
        bindInt(stmt, 10, run.durationMs)
        bindInt(stmt, 11, run.exitStatus)
        bindInt(stmt, 12, run.totalInputTokens)
        bindInt(stmt, 13, run.totalOutputTokens)
        bindDouble(stmt, 14, run.costUSD)
        bindInt(stmt, 15, run.turnCount)
        bindText(stmt, 16, Self.encodeJSON(run.tags))
        bindText(stmt, 17, Self.encodeJSON(run.metadata))
        bindText(stmt, 18, run.rawTranscriptRef)
        bindText(stmt, 19, run.parentRunID)
        bindText(stmt, 20, run.errorMessage)

        if sqlite3_step(stmt) != SQLITE_DONE {
            Log.warn("TelemetryStore: insert run failed for \(run.id)")
        }
    }

    func insertTurns(_ turns: [TelemetryTurn]) {
        queue.async { [weak self] in
            guard let self else { return }
            for turn in turns { self._insertTurn(turn) }
        }
    }

    private func _insertTurn(_ turn: TelemetryTurn) {
        guard let db else { return }
        let sql = """
        INSERT OR REPLACE INTO turns
        (turn_id, run_id, turn_index, role, content, input_tokens, output_tokens,
         tool_calls, timestamp, duration_ms)
        VALUES (?,?,?,?,?,?,?,?,?,?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, turn.id)
        bindText(stmt, 2, turn.runID)
        bindInt(stmt, 3, turn.turnIndex)
        bindText(stmt, 4, turn.role.rawValue)
        bindText(stmt, 5, turn.content)
        bindInt(stmt, 6, turn.inputTokens)
        bindInt(stmt, 7, turn.outputTokens)
        bindText(stmt, 8, Self.encodeJSON(turn.toolCalls))
        bindText(stmt, 9, turn.timestamp.map { Self.isoString(from: $0) })
        bindInt(stmt, 10, turn.durationMs)

        if sqlite3_step(stmt) != SQLITE_DONE {
            Log.warn("TelemetryStore: insert turn failed for \(turn.id)")
        }
    }

    func insertToolCalls(_ calls: [TelemetryToolCall]) {
        queue.async { [weak self] in
            guard let self else { return }
            for call in calls { self._insertToolCall(call) }
        }
    }

    private func _insertToolCall(_ call: TelemetryToolCall) {
        guard let db else { return }
        let sql = """
        INSERT OR REPLACE INTO tool_calls
        (call_id, run_id, turn_id, tool_name, arguments, result, status, duration_ms, call_index)
        VALUES (?,?,?,?,?,?,?,?,?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, call.id)
        bindText(stmt, 2, call.runID)
        bindText(stmt, 3, call.turnID)
        bindText(stmt, 4, call.toolName)
        bindText(stmt, 5, call.arguments)
        bindText(stmt, 6, call.result)
        bindText(stmt, 7, call.status.rawValue)
        bindInt(stmt, 8, call.durationMs)
        bindInt(stmt, 9, call.callIndex)

        if sqlite3_step(stmt) != SQLITE_DONE {
            Log.warn("TelemetryStore: insert tool_call failed for \(call.id)")
        }
    }

    func updateRunTags(_ runID: String, tags: [String]) {
        queue.async { [weak self] in
            guard let self, let db = self.db else { return }
            let sql = "UPDATE runs SET tags = ? WHERE run_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            self.bindText(stmt, 1, Self.encodeJSON(tags))
            self.bindText(stmt, 2, runID)
            sqlite3_step(stmt)
        }
    }

    // MARK: - Read

    func getRun(_ runID: String) -> TelemetryRun? {
        queue.sync { _getRun(runID) }
    }

    private func _getRun(_ runID: String) -> TelemetryRun? {
        guard let db else { return nil }
        let sql = "SELECT * FROM runs WHERE run_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, runID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return parseRun(stmt)
    }

    func listRuns(filter: TelemetryRunFilter = TelemetryRunFilter()) -> [TelemetryRun] {
        queue.sync { _listRuns(filter: filter) }
    }

    private func _listRuns(filter: TelemetryRunFilter) -> [TelemetryRun] {
        guard let db else { return [] }
        var clauses: [String] = []
        var values: [String] = []

        if let v = filter.sessionID {
            clauses.append("session_id = ?")
            values.append(v)
        }
        if let v = filter.repoPath {
            clauses.append("repo_path = ?")
            values.append(v)
        }
        if let v = filter.provider {
            clauses.append("provider = ?")
            values.append(v)
        }
        if let v = filter.after {
            clauses.append("started_at >= ?")
            values.append(Self.isoString(from: v))
        }
        if let v = filter.before {
            clauses.append("started_at <= ?")
            values.append(Self.isoString(from: v))
        }

        var sql = "SELECT * FROM runs"
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY started_at DESC"
        if let limit = filter.limit { sql += " LIMIT \(limit)" }
        if let offset = filter.offset { sql += " OFFSET \(offset)" }

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        for (i, val) in values.enumerated() {
            bindText(stmt, Int32(i + 1), val)
        }

        var runs: [TelemetryRun] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let run = parseRun(stmt) {
                runs.append(run)
            }
        }
        return runs
    }

    func getTurns(runID: String) -> [TelemetryTurn] {
        queue.sync { _getTurns(runID: runID) }
    }

    private func _getTurns(runID: String) -> [TelemetryTurn] {
        guard let db else { return [] }
        let sql = "SELECT * FROM turns WHERE run_id = ? ORDER BY turn_index"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, runID)

        var turns: [TelemetryTurn] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let turn = parseTurn(stmt) { turns.append(turn) }
        }
        return turns
    }

    func getToolCalls(runID: String) -> [TelemetryToolCall] {
        queue.sync { _getToolCalls(runID: runID) }
    }

    private func _getToolCalls(runID: String) -> [TelemetryToolCall] {
        guard let db else { return [] }
        let sql = "SELECT * FROM tool_calls WHERE run_id = ? ORDER BY call_index"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, runID)

        var calls: [TelemetryToolCall] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            calls.append(parseToolCall(stmt))
        }
        return calls
    }

    func latestRunForRepo(_ repoPath: String, provider: String? = nil) -> TelemetryRun? {
        queue.sync {
            guard let db else { return nil }
            var sql = "SELECT * FROM runs WHERE repo_path = ?"
            var vals = [repoPath]
            if let p = provider {
                sql += " AND provider = ?"
                vals.append(p)
            }
            sql += " ORDER BY started_at DESC LIMIT 1"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            for (i, v) in vals.enumerated() { bindText(stmt, Int32(i + 1), v) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return parseRun(stmt)
        }
    }

    func listSessions(repoPath: String? = nil) -> [[String: Any]] {
        queue.sync {
            guard let db else { return [] }
            var sql = """
            SELECT session_id, provider, repo_path, COUNT(*) as run_count,
                   MAX(started_at) as last_active
            FROM runs WHERE session_id IS NOT NULL
            """
            var vals: [String] = []
            if let rp = repoPath {
                sql += " AND repo_path = ?"
                vals.append(rp)
            }
            sql += " GROUP BY session_id ORDER BY last_active DESC"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            for (i, v) in vals.enumerated() { bindText(stmt, Int32(i + 1), v) }

            var results: [[String: Any]] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                results.append([
                    "session_id": colText(stmt, 0) ?? "",
                    "provider": colText(stmt, 1) ?? "",
                    "repo_path": colText(stmt, 2) ?? "",
                    "run_count": Int(sqlite3_column_int(stmt, 3)),
                    "last_active": colText(stmt, 4) ?? ""
                ])
            }
            return results
        }
    }

    func runCount() -> Int {
        queue.sync {
            guard let db else { return 0 }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM runs", -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int(stmt, 0))
        }
    }

    // MARK: - Row Parsing

    private func parseRun(_ stmt: OpaquePointer?) -> TelemetryRun? {
        guard let stmt else { return nil }
        guard let runID = colByName(stmt, "run_id"),
              let provider = colByName(stmt, "provider"),
              let cwd = colByName(stmt, "cwd"),
              let startedAtStr = colByName(stmt, "started_at"),
              let startedAt = Self.isoDate(from: startedAtStr)
        else { return nil }

        return TelemetryRun(
            id: runID,
            sessionID: colByName(stmt, "session_id"),
            tabID: colByName(stmt, "tab_id"),
            provider: provider,
            model: colByName(stmt, "model"),
            cwd: cwd,
            repoPath: colByName(stmt, "repo_path"),
            startedAt: startedAt,
            endedAt: colByName(stmt, "ended_at").flatMap { Self.isoDate(from: $0) },
            durationMs: intByName(stmt, "duration_ms"),
            exitStatus: intByName(stmt, "exit_status"),
            totalInputTokens: intByName(stmt, "total_input_tokens"),
            totalOutputTokens: intByName(stmt, "total_output_tokens"),
            costUSD: doubleByName(stmt, "cost_usd"),
            turnCount: intByName(stmt, "turn_count") ?? 0,
            tags: Self.decodeJSON(colByName(stmt, "tags")) ?? [],
            metadata: Self.decodeJSON(colByName(stmt, "metadata")) ?? [:],
            rawTranscriptRef: colByName(stmt, "raw_transcript_ref"),
            parentRunID: colByName(stmt, "parent_run_id"),
            errorMessage: colByName(stmt, "error_message")
        )
    }

    private func parseTurn(_ stmt: OpaquePointer?) -> TelemetryTurn? {
        guard let stmt,
              let turnID = colByName(stmt, "turn_id"),
              let runID = colByName(stmt, "run_id"),
              let roleStr = colByName(stmt, "role"),
              let role = TurnRole(rawValue: roleStr)
        else { return nil }

        let toolCalls: [TelemetryToolCall] = Self.decodeJSON(colByName(stmt, "tool_calls")) ?? []
        return TelemetryTurn(
            id: turnID, runID: runID,
            turnIndex: intByName(stmt, "turn_index") ?? 0,
            role: role,
            content: colByName(stmt, "content"),
            inputTokens: intByName(stmt, "input_tokens"),
            outputTokens: intByName(stmt, "output_tokens"),
            toolCalls: toolCalls,
            timestamp: colByName(stmt, "timestamp").flatMap { Self.isoDate(from: $0) },
            durationMs: intByName(stmt, "duration_ms")
        )
    }

    private func parseToolCall(_ stmt: OpaquePointer?) -> TelemetryToolCall {
        TelemetryToolCall(
            id: colByName(stmt, "call_id") ?? UUID().uuidString,
            runID: colByName(stmt, "run_id") ?? "",
            turnID: colByName(stmt, "turn_id") ?? "",
            toolName: colByName(stmt, "tool_name") ?? "",
            arguments: colByName(stmt, "arguments"),
            result: colByName(stmt, "result"),
            status: ToolCallStatus(rawValue: colByName(stmt, "status") ?? "") ?? .success,
            durationMs: intByName(stmt, "duration_ms"),
            callIndex: intByName(stmt, "call_index") ?? 0
        )
    }

    // MARK: - SQLite Bind/Read Helpers

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let v = value {
            sqlite3_bind_text(stmt, index, (v as NSString).utf8String, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let v = value { sqlite3_bind_int64(stmt, index, Int64(v)) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func bindDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let v = value { sqlite3_bind_double(stmt, index, v) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func colText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    private func colByName(_ stmt: OpaquePointer?, _ name: String) -> String? {
        guard let stmt else { return nil }
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            if let cn = sqlite3_column_name(stmt, i), String(cString: cn) == name {
                guard let ptr = sqlite3_column_text(stmt, i) else { return nil }
                return String(cString: ptr)
            }
        }
        return nil
    }

    private func intByName(_ stmt: OpaquePointer?, _ name: String) -> Int? {
        guard let stmt else { return nil }
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            if let cn = sqlite3_column_name(stmt, i), String(cString: cn) == name {
                if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
                return Int(sqlite3_column_int64(stmt, i))
            }
        }
        return nil
    }

    private func doubleByName(_ stmt: OpaquePointer?, _ name: String) -> Double? {
        guard let stmt else { return nil }
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            if let cn = sqlite3_column_name(stmt, i), String(cString: cn) == name {
                if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
                return sqlite3_column_double(stmt, i)
            }
        }
        return nil
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static func isoString(from date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static func isoDate(from string: String) -> Date? {
        isoFormatter.date(from: string)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeJSON<T: Decodable>(_ json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
