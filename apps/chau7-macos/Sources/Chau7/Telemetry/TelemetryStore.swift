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
        let dir = RuntimeIsolation.chau7Directory()
            .appendingPathComponent("telemetry", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("runs.db").path
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
        verifyIntegrity()
        createTables()
        applyMigrations()
        backfillHistoricalMissingCosts()
    }

    /// Quick integrity check on startup. If the database is corrupt, log and
    /// recreate it rather than silently failing every insert.
    private func verifyIntegrity() {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA quick_check", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW,
           let result = sqlite3_column_text(stmt, 0) {
            let check = String(cString: result)
            if check != "ok" {
                Log.error("TelemetryStore: database integrity check failed: \(check)")
                // Close and delete the corrupt database; createTables will recreate it
                sqlite3_close(self.db)
                self.db = nil
                let path = Self.dbPath
                try? FileManager.default.removeItem(atPath: path)
                if sqlite3_open(path, &self.db) == SQLITE_OK {
                    sqlite3_exec(self.db, "PRAGMA journal_mode=WAL", nil, nil, nil)
                    sqlite3_exec(self.db, "PRAGMA foreign_keys=ON", nil, nil, nil)
                    Log.info("TelemetryStore: recreated database after corruption")
                }
            }
        }
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
            total_cached_input_tokens INTEGER,
            total_output_tokens INTEGER,
            total_reasoning_output_tokens INTEGER,
            cost_usd REAL,
            token_usage_source TEXT,
            token_usage_state TEXT,
            cost_source TEXT,
            cost_state TEXT,
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
            cached_input_tokens INTEGER,
            output_tokens INTEGER,
            reasoning_output_tokens INTEGER,
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

        CREATE TABLE IF NOT EXISTS remote_client_events (
            event_id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            device_id TEXT,
            device_name TEXT,
            app_version TEXT NOT NULL,
            session_id TEXT,
            event_type TEXT NOT NULL,
            status TEXT,
            tab_id INTEGER,
            tab_title TEXT,
            message TEXT,
            metadata TEXT,
            timestamp TEXT NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_remote_client_events_time
            ON remote_client_events(timestamp DESC);
        CREATE INDEX IF NOT EXISTS idx_remote_client_events_device
            ON remote_client_events(device_id);
        CREATE INDEX IF NOT EXISTS idx_remote_client_events_session
            ON remote_client_events(session_id);
        CREATE INDEX IF NOT EXISTS idx_remote_client_events_type
            ON remote_client_events(event_type);

        INSERT OR IGNORE INTO schema_version (version) VALUES (1);
        """

        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            Log.error("TelemetryStore: schema creation failed: \(msg)")
            sqlite3_free(errMsg)
        }
    }

    private func applyMigrations() {
        guard let db else { return }
        ensureColumn(table: "runs", name: "total_cached_input_tokens", definition: "INTEGER")
        ensureColumn(table: "runs", name: "total_reasoning_output_tokens", definition: "INTEGER")
        ensureColumn(table: "runs", name: "token_usage_source", definition: "TEXT")
        ensureColumn(table: "runs", name: "token_usage_state", definition: "TEXT")
        ensureColumn(table: "runs", name: "cost_source", definition: "TEXT")
        ensureColumn(table: "runs", name: "cost_state", definition: "TEXT")

        ensureColumn(table: "turns", name: "cached_input_tokens", definition: "INTEGER")
        ensureColumn(table: "turns", name: "reasoning_output_tokens", definition: "INTEGER")

        sqlite3_exec(
            db,
            """
            UPDATE runs
            SET token_usage_state = COALESCE(token_usage_state,
                CASE
                    WHEN total_input_tokens IS NULL
                         AND total_cached_input_tokens IS NULL
                         AND total_output_tokens IS NULL
                         AND total_reasoning_output_tokens IS NULL
                    THEN 'missing'
                    ELSE 'complete'
                END
            ),
            cost_state = COALESCE(cost_state,
                CASE
                    WHEN cost_usd IS NULL THEN 'missing'
                    ELSE 'complete'
                END
            ),
            cost_source = COALESCE(cost_source,
                CASE
                    WHEN cost_usd IS NULL THEN 'unavailable'
                    ELSE 'observed'
                END
            )
            """,
            nil,
            nil,
            nil
        )

        sqlite3_exec(
            db,
            """
            UPDATE runs
            SET total_input_tokens = NULL,
                total_cached_input_tokens = NULL,
                total_output_tokens = NULL,
                total_reasoning_output_tokens = NULL,
                cost_usd = NULL,
                token_usage_source = NULL,
                token_usage_state = 'invalid',
                cost_source = 'unavailable',
                cost_state = 'missing',
                error_message = COALESCE(error_message, 'invalidated historical telemetry metrics that exceeded sanity thresholds')
            WHERE COALESCE(total_input_tokens, 0) > 100000000
               OR COALESCE(total_cached_input_tokens, 0) > 100000000
               OR COALESCE(total_output_tokens, 0) > 100000000
               OR COALESCE(total_reasoning_output_tokens, 0) > 100000000
               OR (
                    COALESCE(total_input_tokens, 0) +
                    COALESCE(total_cached_input_tokens, 0) +
                    COALESCE(total_output_tokens, 0) +
                    COALESCE(total_reasoning_output_tokens, 0)
                  ) > 150000000
            """,
            nil,
            nil,
            nil
        )
    }

    private func ensureColumn(table: String, name: String, definition: String) {
        guard let db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let colName = sqlite3_column_text(stmt, 1), String(cString: colName) == name {
                return
            }
        }

        let sql = "ALTER TABLE \(table) ADD COLUMN \(name) \(definition)"
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            Log.warn("TelemetryStore: failed to add column \(table).\(name)")
        }
    }

    private func backfillHistoricalMissingCosts() {
        guard let db else { return }

        let sql = """
        SELECT * FROM runs
        WHERE (cost_usd IS NULL
               OR COALESCE(cost_state, 'missing') = 'missing'
               OR COALESCE(cost_source, 'unavailable') = 'unavailable')
          AND COALESCE(token_usage_state, 'missing') != 'invalid'
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var repairedRuns: [TelemetryRun] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let run = parseRun(stmt),
                  let repaired = TelemetryHistoricalCostBackfill.repairedRun(run) else {
                continue
            }
            repairedRuns.append(repaired)
        }

        guard !repairedRuns.isEmpty else { return }

        let updateSQL = """
        UPDATE runs
        SET cost_usd = ?, cost_source = ?, cost_state = ?
        WHERE run_id = ?
        """

        var updateStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, updateSQL, -1, &updateStmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(updateStmt) }

        for run in repairedRuns {
            sqlite3_reset(updateStmt)
            sqlite3_clear_bindings(updateStmt)
            bindDouble(updateStmt, 1, run.costUSD)
            bindText(updateStmt, 2, run.costSource?.rawValue)
            bindText(updateStmt, 3, run.costState.rawValue)
            bindText(updateStmt, 4, run.id)
            sqlite3_step(updateStmt)
        }

        Log.info("TelemetryStore: backfilled historical cost for \(repairedRuns.count) run(s)")
    }

    // MARK: - Write

    /// Insert a new run record. Use finalizeRun() to update it on completion.
    /// Uses INSERT OR IGNORE — safe to call multiple times for the same run ID.
    func insertRun(_ run: TelemetryRun) {
        queue.async { [weak self] in
            self?._insertRun(run)
        }
    }

    private func _insertRun(_ run: TelemetryRun) {
        guard let db else { return }
        let sql = """
        INSERT OR IGNORE INTO runs
        (run_id, session_id, tab_id, provider, model, cwd, repo_path,
         started_at, ended_at, duration_ms, exit_status,
         total_input_tokens, total_cached_input_tokens, total_output_tokens, total_reasoning_output_tokens,
         cost_usd, token_usage_source, token_usage_state, cost_source, cost_state,
         turn_count, tags, metadata, raw_transcript_ref, parent_run_id, error_message)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
        bindInt(stmt, 13, run.totalCachedInputTokens)
        bindInt(stmt, 14, run.totalOutputTokens)
        bindInt(stmt, 15, run.totalReasoningOutputTokens)
        bindDouble(stmt, 16, run.costUSD)
        bindText(stmt, 17, run.tokenUsageSource?.rawValue)
        bindText(stmt, 18, run.tokenUsageState.rawValue)
        bindText(stmt, 19, run.costSource?.rawValue)
        bindText(stmt, 20, run.costState.rawValue)
        bindInt(stmt, 21, run.turnCount)
        bindText(stmt, 22, Self.encodeJSON(run.tags))
        bindText(stmt, 23, Self.encodeJSON(run.metadata))
        bindText(stmt, 24, run.rawTranscriptRef)
        bindText(stmt, 25, run.parentRunID)
        bindText(stmt, 26, run.errorMessage)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let err = String(cString: sqlite3_errmsg(db))
            Log.warn("TelemetryStore: insert run failed for \(run.id): \(err)")
        }
    }

    /// Atomically finalize a run and persist its turns + tool calls.
    /// Uses UPDATE (not INSERT OR REPLACE) to avoid cascading deletes on child rows.
    func finalizeRun(_ run: TelemetryRun, turns: [TelemetryTurn], toolCalls: [TelemetryToolCall]) {
        queue.async { [weak self] in
            guard let self, let db = db else { return }

            // Begin transaction — run update + children must be atomic
            sqlite3_exec(db, "BEGIN", nil, nil, nil)

            // UPDATE the existing run row (never delete/re-insert)
            let updateSQL = """
            UPDATE runs SET
                session_id = ?, model = ?, ended_at = ?, duration_ms = ?, exit_status = ?,
                total_input_tokens = ?, total_cached_input_tokens = ?, total_output_tokens = ?,
                total_reasoning_output_tokens = ?, cost_usd = ?, token_usage_source = ?,
                token_usage_state = ?, cost_source = ?, cost_state = ?,
                turn_count = ?, raw_transcript_ref = ?, error_message = ?
            WHERE run_id = ?
            """
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
                bindText(stmt, 1, run.sessionID)
                bindText(stmt, 2, run.model)
                bindText(stmt, 3, run.endedAt.map { Self.isoString(from: $0) })
                bindInt(stmt, 4, run.durationMs)
                bindInt(stmt, 5, run.exitStatus)
                bindInt(stmt, 6, run.totalInputTokens)
                bindInt(stmt, 7, run.totalCachedInputTokens)
                bindInt(stmt, 8, run.totalOutputTokens)
                bindInt(stmt, 9, run.totalReasoningOutputTokens)
                bindDouble(stmt, 10, run.costUSD)
                bindText(stmt, 11, run.tokenUsageSource?.rawValue)
                bindText(stmt, 12, run.tokenUsageState.rawValue)
                bindText(stmt, 13, run.costSource?.rawValue)
                bindText(stmt, 14, run.costState.rawValue)
                bindInt(stmt, 15, run.turnCount)
                bindText(stmt, 16, run.rawTranscriptRef)
                bindText(stmt, 17, run.errorMessage)
                bindText(stmt, 18, run.id)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }

            // Insert turns
            for turn in turns {
                _insertTurn(turn)
            }

            // Insert tool calls
            for call in toolCalls {
                _insertToolCall(call)
            }

            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    func insertTurns(_ turns: [TelemetryTurn]) {
        queue.async { [weak self] in
            guard let self else { return }
            for turn in turns {
                _insertTurn(turn)
            }
        }
    }

    private func _insertTurn(_ turn: TelemetryTurn) {
        guard let db else { return }
        let sql = """
        INSERT OR IGNORE INTO turns
        (turn_id, run_id, turn_index, role, content, input_tokens, cached_input_tokens, output_tokens,
         reasoning_output_tokens, tool_calls, timestamp, duration_ms)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
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
        bindInt(stmt, 7, turn.cachedInputTokens)
        bindInt(stmt, 8, turn.outputTokens)
        bindInt(stmt, 9, turn.reasoningOutputTokens)
        bindText(stmt, 10, Self.encodeJSON(turn.toolCalls))
        bindText(stmt, 11, turn.timestamp.map { Self.isoString(from: $0) })
        bindInt(stmt, 12, turn.durationMs)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let err = String(cString: sqlite3_errmsg(db))
            Log.warn("TelemetryStore: insert turn failed for \(turn.id): \(err)")
        }
    }

    func insertToolCalls(_ calls: [TelemetryToolCall]) {
        queue.async { [weak self] in
            guard let self else { return }
            for call in calls {
                _insertToolCall(call)
            }
        }
    }

    private func _insertToolCall(_ call: TelemetryToolCall) {
        guard let db else { return }
        let sql = """
        INSERT OR IGNORE INTO tool_calls
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
            let err = String(cString: sqlite3_errmsg(db))
            Log.warn("TelemetryStore: insert tool_call failed for \(call.id): \(err)")
        }
    }

    func updateRunSessionID(_ runID: String, sessionID: String) {
        queue.async { [weak self] in
            guard let self, let db = db else { return }
            let sql = "UPDATE runs SET session_id = ? WHERE run_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, sessionID)
            bindText(stmt, 2, runID)
            sqlite3_step(stmt)
        }
    }

    func updateRunTags(_ runID: String, tags: [String]) {
        queue.async { [weak self] in
            guard let self, let db = db else { return }
            let sql = "UPDATE runs SET tags = ? WHERE run_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, Self.encodeJSON(tags))
            bindText(stmt, 2, runID)
            sqlite3_step(stmt)
        }
    }

    func updateRunLiveMetrics(_ run: TelemetryRun) {
        queue.async { [weak self] in
            guard let self, let db = db else { return }
            let sql = """
            UPDATE runs SET
                model = ?, total_input_tokens = ?, total_cached_input_tokens = ?,
                total_output_tokens = ?, total_reasoning_output_tokens = ?, cost_usd = ?,
                token_usage_source = ?, token_usage_state = ?, cost_source = ?, cost_state = ?,
                turn_count = ?, error_message = ?
            WHERE run_id = ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, run.model)
            bindInt(stmt, 2, run.totalInputTokens)
            bindInt(stmt, 3, run.totalCachedInputTokens)
            bindInt(stmt, 4, run.totalOutputTokens)
            bindInt(stmt, 5, run.totalReasoningOutputTokens)
            bindDouble(stmt, 6, run.costUSD)
            bindText(stmt, 7, run.tokenUsageSource?.rawValue)
            bindText(stmt, 8, run.tokenUsageState.rawValue)
            bindText(stmt, 9, run.costSource?.rawValue)
            bindText(stmt, 10, run.costState.rawValue)
            bindInt(stmt, 11, run.turnCount)
            bindText(stmt, 12, run.errorMessage)
            bindText(stmt, 13, run.id)
            sqlite3_step(stmt)
        }
    }

    func rewriteCompletedRun(_ run: TelemetryRun, turns: [TelemetryTurn], toolCalls: [TelemetryToolCall]) {
        queue.sync {
            guard let db else { return }
            sqlite3_exec(db, "BEGIN", nil, nil, nil)

            deleteChildren(table: "tool_calls", runID: run.id)
            deleteChildren(table: "turns", runID: run.id)

            let updateSQL = """
            UPDATE runs SET
                session_id = ?, tab_id = ?, provider = ?, model = ?, cwd = ?, repo_path = ?,
                started_at = ?, ended_at = ?, duration_ms = ?, exit_status = ?,
                total_input_tokens = ?, total_cached_input_tokens = ?, total_output_tokens = ?,
                total_reasoning_output_tokens = ?, cost_usd = ?, token_usage_source = ?,
                token_usage_state = ?, cost_source = ?, cost_state = ?, turn_count = ?,
                tags = ?, metadata = ?, raw_transcript_ref = ?, parent_run_id = ?, error_message = ?
            WHERE run_id = ?
            """

            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, updateSQL, -1, &stmt, nil) == SQLITE_OK {
                bindText(stmt, 1, run.sessionID)
                bindText(stmt, 2, run.tabID)
                bindText(stmt, 3, run.provider)
                bindText(stmt, 4, run.model)
                bindText(stmt, 5, run.cwd)
                bindText(stmt, 6, run.repoPath)
                bindText(stmt, 7, Self.isoString(from: run.startedAt))
                bindText(stmt, 8, run.endedAt.map { Self.isoString(from: $0) })
                bindInt(stmt, 9, run.durationMs)
                bindInt(stmt, 10, run.exitStatus)
                bindInt(stmt, 11, run.totalInputTokens)
                bindInt(stmt, 12, run.totalCachedInputTokens)
                bindInt(stmt, 13, run.totalOutputTokens)
                bindInt(stmt, 14, run.totalReasoningOutputTokens)
                bindDouble(stmt, 15, run.costUSD)
                bindText(stmt, 16, run.tokenUsageSource?.rawValue)
                bindText(stmt, 17, run.tokenUsageState.rawValue)
                bindText(stmt, 18, run.costSource?.rawValue)
                bindText(stmt, 19, run.costState.rawValue)
                bindInt(stmt, 20, run.turnCount)
                bindText(stmt, 21, Self.encodeJSON(run.tags))
                bindText(stmt, 22, Self.encodeJSON(run.metadata))
                bindText(stmt, 23, run.rawTranscriptRef)
                bindText(stmt, 24, run.parentRunID)
                bindText(stmt, 25, run.errorMessage)
                bindText(stmt, 26, run.id)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }

            for turn in turns {
                _insertTurn(turn)
            }
            for call in toolCalls {
                _insertToolCall(call)
            }

            sqlite3_exec(db, "COMMIT", nil, nil, nil)
        }
    }

    func invalidateRunMetrics(_ runID: String, reason: String?) {
        queue.sync {
            guard let db else { return }
            let sql = """
            UPDATE runs
            SET total_input_tokens = NULL,
                total_cached_input_tokens = NULL,
                total_output_tokens = NULL,
                total_reasoning_output_tokens = NULL,
                cost_usd = NULL,
                token_usage_source = NULL,
                token_usage_state = 'invalid',
                cost_source = 'unavailable',
                cost_state = 'missing',
                error_message = COALESCE(?, error_message)
            WHERE run_id = ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, reason)
            bindText(stmt, 2, runID)
            sqlite3_step(stmt)
        }
    }

    private func deleteChildren(table: String, runID: String) {
        guard let db else { return }
        let sql = "DELETE FROM \(table) WHERE run_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, runID)
        sqlite3_step(stmt)
    }

    func insertRemoteClientEvent(_ event: RemoteClientTelemetryEvent) {
        queue.async { [weak self] in
            self?._insertRemoteClientEvent(event)
        }
    }

    private func _insertRemoteClientEvent(_ event: RemoteClientTelemetryEvent) {
        guard let db else { return }
        let sql = """
        INSERT OR IGNORE INTO remote_client_events
        (event_id, source, device_id, device_name, app_version, session_id,
         event_type, status, tab_id, tab_title, message, metadata, timestamp)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, event.id)
        bindText(stmt, 2, event.source)
        bindText(stmt, 3, event.deviceID)
        bindText(stmt, 4, event.deviceName)
        bindText(stmt, 5, event.appVersion)
        bindText(stmt, 6, event.sessionID)
        bindText(stmt, 7, event.eventType.rawValue)
        bindText(stmt, 8, event.status)
        if let tabID = event.tabID {
            sqlite3_bind_int64(stmt, 9, Int64(tabID))
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        bindText(stmt, 10, event.tabTitle)
        bindText(stmt, 11, event.message)
        bindText(stmt, 12, Self.encodeJSON(event.metadata))
        bindText(stmt, 13, Self.isoString(from: event.timestamp))

        if sqlite3_step(stmt) != SQLITE_DONE {
            let err = String(cString: sqlite3_errmsg(db))
            Log.warn("TelemetryStore: insert remote client event failed for \(event.id): \(err)")
        }
    }

    func listRemoteClientEvents(limit: Int = 100) -> [RemoteClientTelemetryEvent] {
        queue.sync { _listRemoteClientEvents(limit: limit) }
    }

    private func _listRemoteClientEvents(limit: Int) -> [RemoteClientTelemetryEvent] {
        guard let db else { return [] }
        let sql = """
        SELECT * FROM remote_client_events
        ORDER BY timestamp DESC
        LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(limit))

        var events: [RemoteClientTelemetryEvent] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let event = parseRemoteClientEvent(stmt) {
                events.append(event)
            }
        }
        return events
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
        if let v = filter.parentRunID {
            clauses.append("parent_run_id = ?")
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
        if let limit = filter.limit {
            sql += " LIMIT \(limit)"
            if let offset = filter.offset { sql += " OFFSET \(offset)" }
        }

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

    /// Aggregate tool call counts for a run, sorted by frequency.
    func toolCallSummary(runID: String) -> [(tool: String, count: Int)] {
        queue.sync {
            guard let db else { return [] }
            let sql = """
                SELECT tool_name, COUNT(*) as cnt FROM tool_calls
                WHERE run_id = ? GROUP BY tool_name ORDER BY cnt DESC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, runID)
            var results: [(tool: String, count: Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(stmt, 0))
                let count = Int(sqlite3_column_int(stmt, 1))
                results.append((tool: name, count: count))
            }
            return results
        }
    }

    /// Aggregate run statistics for a repository.
    func runStatsForRepo(repoPath: String, providerFilterKey: String? = nil) -> (totalRuns: Int, totalTokens: Int, totalCost: Double, totalTurns: Int, lastRunAt: Date?) {
        queue.sync {
            guard let db else { return (0, 0, 0, 0, nil) }
            let sql = """
                SELECT provider,
                       COUNT(*) as cnt,
                       COALESCE(SUM(total_input_tokens + total_cached_input_tokens + total_output_tokens + total_reasoning_output_tokens), 0) as tokens,
                       COALESCE(SUM(cost_usd), 0) as cost,
                       COALESCE(SUM(turn_count), 0) as turns,
                       MAX(started_at) as last_run
                FROM runs WHERE repo_path = ?
                GROUP BY provider
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return (0, 0, 0, 0, nil) }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, repoPath)

            var totalRuns = 0
            var totalTokens = 0
            var totalCost = 0.0
            var totalTurns = 0
            var lastRunAt: Date?
            let formatter = ISO8601DateFormatter()

            while sqlite3_step(stmt) == SQLITE_ROW {
                let rawProvider = colText(stmt, 0)
                guard AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey) else { continue }

                totalRuns += Int(sqlite3_column_int(stmt, 1))
                totalTokens += Int(sqlite3_column_int64(stmt, 2))
                totalCost += sqlite3_column_double(stmt, 3)
                totalTurns += Int(sqlite3_column_int(stmt, 4))
                if sqlite3_column_type(stmt, 5) != SQLITE_NULL,
                   let text = sqlite3_column_text(stmt, 5),
                   let date = formatter.date(from: String(cString: text)),
                   (lastRunAt == nil || date > lastRunAt!) {
                    lastRunAt = date
                }
            }

            return (totalRuns, totalTokens, totalCost, totalTurns, lastRunAt)
        }
    }

    /// Distinct AI providers used in a repository.
    func providersForRepo(repoPath: String, providerFilterKey: String? = nil) -> [String] {
        queue.sync {
            guard let db else { return [] }
            let sql = "SELECT DISTINCT provider FROM runs WHERE repo_path = ? ORDER BY provider"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, repoPath)
            var results: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let rawProvider = String(cString: sqlite3_column_text(stmt, 0))
                if AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey),
                   let key = AnalyticsProvider.key(for: rawProvider) {
                    results.insert(key)
                }
            }
            return AnalyticsProvider.sortKeys(results)
        }
    }

    /// Most used tools across all runs in a repository.
    func toolCallDistributionForRepo(repoPath: String, limit: Int = 5) -> [(tool: String, count: Int)] {
        queue.sync {
            guard let db else { return [] }
            let sql = """
                SELECT tc.tool_name, COUNT(*) as cnt FROM tool_calls tc
                JOIN runs r ON tc.run_id = r.run_id
                WHERE r.repo_path = ?
                GROUP BY tc.tool_name ORDER BY cnt DESC LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, repoPath)
            sqlite3_bind_int(stmt, 2, Int32(limit))
            var results: [(tool: String, count: Int)] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let tool = String(cString: sqlite3_column_text(stmt, 0))
                let count = Int(sqlite3_column_int(stmt, 1))
                results.append((tool: tool, count: count))
            }
            return results
        }
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
            for (i, v) in vals.enumerated() {
                bindText(stmt, Int32(i + 1), v)
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return parseRun(stmt)
        }
    }

    func latestRunForTab(_ tabID: String, provider: String? = nil) -> TelemetryRun? {
        queue.sync {
            guard let db else { return nil }
            var sql = "SELECT * FROM runs WHERE tab_id = ?"
            var vals = [tabID]
            if let provider {
                sql += " AND provider = ?"
                vals.append(provider)
            }
            sql += " ORDER BY started_at DESC LIMIT 1"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            for (index, value) in vals.enumerated() {
                bindText(stmt, Int32(index + 1), value)
            }
            guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
            return parseRun(stmt)
        }
    }

    func listSessions(repoPath: String? = nil) -> [[String: Any]] {
        queue.sync {
            guard let db else { return [] }
            var sql = """
            WITH filtered_runs AS (
                SELECT *
                FROM runs
                WHERE session_id IS NOT NULL
            """
            var vals: [String] = []
            if let rp = repoPath {
                sql += " AND repo_path = ?"
                vals.append(rp)
            }
            sql += """
            ),
            session_rollup AS (
                SELECT session_id,
                       COUNT(*) AS run_count,
                       MAX(started_at) AS last_active
                FROM filtered_runs
                GROUP BY session_id
            )
            SELECT session_rollup.session_id,
                   (
                       SELECT provider
                       FROM filtered_runs latest
                       WHERE latest.session_id = session_rollup.session_id
                         AND latest.provider IS NOT NULL
                       ORDER BY latest.started_at DESC, latest.created_at DESC
                       LIMIT 1
                   ) AS provider,
                   (
                       SELECT repo_path
                       FROM filtered_runs latest
                       WHERE latest.session_id = session_rollup.session_id
                         AND latest.repo_path IS NOT NULL
                       ORDER BY latest.started_at DESC, latest.created_at DESC
                       LIMIT 1
                   ) AS repo_path,
                   session_rollup.run_count,
                   session_rollup.last_active
            FROM session_rollup
            ORDER BY session_rollup.last_active DESC
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            for (i, v) in vals.enumerated() {
                bindText(stmt, Int32(i + 1), v)
            }

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

    // MARK: - Aggregation Queries

    /// Token usage aggregated per tab, ordered by total tokens descending.
    func tokenUsagePerTab(after: Date? = nil, providerFilterKey: String? = nil) -> [TabTokenConsumption] {
        queue.sync {
            guard let db else { return [] }
            var sql = """
            WITH filtered_runs AS (
                SELECT *
                FROM runs
                WHERE tab_id IS NOT NULL
                  AND COALESCE(token_usage_state, 'missing') != 'invalid'
            """
            if after != nil {
                sql += " AND started_at >= ?"
            }
            sql += """
            ),
            tab_provider_rollup AS (
                SELECT tab_id,
                       provider,
                       COUNT(*) AS run_count,
                       SUM(CASE WHEN COALESCE(cost_state, 'missing') IN ('complete', 'estimated') AND cost_usd IS NOT NULL THEN 1 ELSE 0 END) AS priced_run_count,
                       SUM(CASE WHEN COALESCE(cost_state, 'missing') = 'missing' OR cost_usd IS NULL THEN 1 ELSE 0 END) AS missing_cost_run_count,
                       COALESCE(SUM(total_input_tokens),0) AS total_input_tokens,
                       COALESCE(SUM(total_cached_input_tokens),0) AS total_cached_input_tokens,
                       COALESCE(SUM(total_output_tokens),0) AS total_output_tokens,
                       COALESCE(SUM(total_reasoning_output_tokens),0) AS total_reasoning_output_tokens,
                       COALESCE(SUM(cost_usd),0) AS total_cost_usd,
                       MAX(started_at || '|' || created_at || '|' || run_id) AS latest_key
                FROM filtered_runs
                GROUP BY tab_id, provider
            ),
            latest_per_tab_provider AS (
                SELECT filtered_runs.tab_id,
                       filtered_runs.provider,
                       COALESCE(filtered_runs.repo_path, filtered_runs.cwd) AS last_location_path,
                       (filtered_runs.started_at || '|' || filtered_runs.created_at || '|' || filtered_runs.run_id) AS latest_key
                FROM filtered_runs
            )
            SELECT tab_provider_rollup.tab_id,
                   tab_provider_rollup.provider,
                   tab_provider_rollup.run_count,
                   tab_provider_rollup.priced_run_count,
                   tab_provider_rollup.missing_cost_run_count,
                   tab_provider_rollup.total_input_tokens,
                   tab_provider_rollup.total_cached_input_tokens,
                   tab_provider_rollup.total_output_tokens,
                   tab_provider_rollup.total_reasoning_output_tokens,
                   tab_provider_rollup.total_cost_usd,
                   tab_provider_rollup.latest_key,
                   latest_per_tab_provider.last_location_path
            FROM tab_provider_rollup
            LEFT JOIN latest_per_tab_provider
              ON latest_per_tab_provider.tab_id = tab_provider_rollup.tab_id
             AND latest_per_tab_provider.provider = tab_provider_rollup.provider
             AND latest_per_tab_provider.latest_key = tab_provider_rollup.latest_key
            ORDER BY
                tab_provider_rollup.total_input_tokens + tab_provider_rollup.total_cached_input_tokens +
                tab_provider_rollup.total_output_tokens + tab_provider_rollup.total_reasoning_output_tokens DESC
            """

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            if let after {
                bindText(stmt, 1, Self.isoString(from: after))
            }

            struct TabAggregate {
                var runCount = 0
                var pricedRunCount = 0
                var missingCostRunCount = 0
                var totalInputTokens = 0
                var totalCachedInputTokens = 0
                var totalOutputTokens = 0
                var totalReasoningOutputTokens = 0
                var totalCostUSD = 0.0
                var lastProvider: String?
                var lastLocationPath: String?
                var latestKey = ""
            }

            var aggregated: [String: TabAggregate] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let tabID = colText(stmt, 0) else { continue }
                let rawProvider = colText(stmt, 1)
                guard AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey) else { continue }

                var aggregate = aggregated[tabID] ?? TabAggregate()
                aggregate.runCount += Int(sqlite3_column_int64(stmt, 2))
                aggregate.pricedRunCount += Int(sqlite3_column_int64(stmt, 3))
                aggregate.missingCostRunCount += Int(sqlite3_column_int64(stmt, 4))
                aggregate.totalInputTokens += Int(sqlite3_column_int64(stmt, 5))
                aggregate.totalCachedInputTokens += Int(sqlite3_column_int64(stmt, 6))
                aggregate.totalOutputTokens += Int(sqlite3_column_int64(stmt, 7))
                aggregate.totalReasoningOutputTokens += Int(sqlite3_column_int64(stmt, 8))
                aggregate.totalCostUSD += sqlite3_column_double(stmt, 9)

                let latestKey = colText(stmt, 10) ?? ""
                if latestKey >= aggregate.latestKey {
                    aggregate.latestKey = latestKey
                    aggregate.lastProvider = AnalyticsProvider.key(for: rawProvider)
                    aggregate.lastLocationPath = colText(stmt, 11)
                }
                aggregated[tabID] = aggregate
            }
            return aggregated.map { tabID, aggregate in
                TabTokenConsumption(
                    tabID: tabID,
                    runCount: aggregate.runCount,
                    pricedRunCount: aggregate.pricedRunCount,
                    missingCostRunCount: aggregate.missingCostRunCount,
                    totalInputTokens: aggregate.totalInputTokens,
                    totalCachedInputTokens: aggregate.totalCachedInputTokens,
                    totalOutputTokens: aggregate.totalOutputTokens,
                    totalReasoningOutputTokens: aggregate.totalReasoningOutputTokens,
                    totalCostUSD: aggregate.totalCostUSD,
                    lastProvider: aggregate.lastProvider,
                    lastLocationPath: aggregate.lastLocationPath
                )
            }
            .sorted { lhs, rhs in
                if lhs.totalBillableTokens != rhs.totalBillableTokens {
                    return lhs.totalBillableTokens > rhs.totalBillableTokens
                }
                return lhs.tabID < rhs.tabID
            }
        }
    }

    /// Token usage aggregated per provider, ordered by cost descending.
    func consumptionPerProvider(after: Date? = nil, providerFilterKey: String? = nil) -> [ProviderConsumptionStats] {
        queue.sync {
            guard let db else { return [] }
            var sql = """
            SELECT provider, COUNT(*),
                   SUM(CASE WHEN COALESCE(cost_state, 'missing') IN ('complete', 'estimated') AND cost_usd IS NOT NULL THEN 1 ELSE 0 END),
                   SUM(CASE WHEN COALESCE(cost_state, 'missing') = 'missing' OR cost_usd IS NULL THEN 1 ELSE 0 END),
                   COALESCE(SUM(total_input_tokens),0),
                   COALESCE(SUM(total_cached_input_tokens),0),
                   COALESCE(SUM(total_output_tokens),0),
                   COALESCE(SUM(total_reasoning_output_tokens),0),
                   COALESCE(SUM(cost_usd),0)
            FROM runs WHERE provider IS NOT NULL
              AND COALESCE(token_usage_state, 'missing') != 'invalid'
            """
            if after != nil {
                sql += " AND started_at >= ?"
            }
            sql += " GROUP BY provider ORDER BY COALESCE(SUM(cost_usd),0) DESC"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            if let after {
                bindText(stmt, 1, Self.isoString(from: after))
            }

            var aggregated: [String: ProviderConsumptionStats] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let rawProvider = colText(stmt, 0),
                      AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey),
                      let provider = AnalyticsProvider.key(for: rawProvider) else {
                    continue
                }

                let current = aggregated[provider]
                aggregated[provider] = ProviderConsumptionStats(
                    provider: provider,
                    runCount: (current?.runCount ?? 0) + Int(sqlite3_column_int64(stmt, 1)),
                    pricedRunCount: (current?.pricedRunCount ?? 0) + Int(sqlite3_column_int64(stmt, 2)),
                    missingCostRunCount: (current?.missingCostRunCount ?? 0) + Int(sqlite3_column_int64(stmt, 3)),
                    totalInputTokens: (current?.totalInputTokens ?? 0) + Int(sqlite3_column_int64(stmt, 4)),
                    totalCachedInputTokens: (current?.totalCachedInputTokens ?? 0) + Int(sqlite3_column_int64(stmt, 5)),
                    totalOutputTokens: (current?.totalOutputTokens ?? 0) + Int(sqlite3_column_int64(stmt, 6)),
                    totalReasoningOutputTokens: (current?.totalReasoningOutputTokens ?? 0) + Int(sqlite3_column_int64(stmt, 7)),
                    totalCostUSD: (current?.totalCostUSD ?? 0) + sqlite3_column_double(stmt, 8)
                )
            }
            return aggregated.values.sorted { lhs, rhs in
                if lhs.totalCostUSD != rhs.totalCostUSD {
                    return lhs.totalCostUSD > rhs.totalCostUSD
                }
                if lhs.totalBillableTokens != rhs.totalBillableTokens {
                    return lhs.totalBillableTokens > rhs.totalBillableTokens
                }
                return AnalyticsProvider.displayName(for: lhs.provider)
                    .localizedCaseInsensitiveCompare(AnalyticsProvider.displayName(for: rhs.provider)) == .orderedAscending
            }
        }
    }

    /// Daily cost trend for the last N days.
    func dailyCostTrend(days: Int = 7, providerFilterKey: String? = nil) -> [(date: String, cost: Double, tokens: Int, pricedRunCount: Int, totalRunCount: Int)] {
        queue.sync {
            guard let db else { return [] }
            let sql = """
            SELECT date(datetime(started_at, 'localtime')) as day,
                   provider,
                   COUNT(*),
                   SUM(CASE WHEN COALESCE(cost_state, 'missing') IN ('complete', 'estimated') AND cost_usd IS NOT NULL THEN 1 ELSE 0 END),
                   COALESCE(SUM(cost_usd), 0),
                   COALESCE(SUM(total_input_tokens), 0) +
                   COALESCE(SUM(total_cached_input_tokens), 0) +
                   COALESCE(SUM(total_output_tokens), 0) +
                   COALESCE(SUM(total_reasoning_output_tokens), 0)
            FROM runs
            WHERE started_at >= date('now', '-\(max(1, min(days, 90))) days')
              AND COALESCE(token_usage_state, 'missing') != 'invalid'
            GROUP BY day, provider ORDER BY day
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var aggregated: [String: (cost: Double, tokens: Int, pricedRuns: Int, totalRuns: Int)] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let day = colText(stmt, 0) else { continue }
                let rawProvider = colText(stmt, 1)
                guard AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey) else { continue }

                let totalRuns = Int(sqlite3_column_int64(stmt, 2))
                let pricedRuns = Int(sqlite3_column_int64(stmt, 3))
                let cost = sqlite3_column_double(stmt, 4)
                let tokens = Int(sqlite3_column_int64(stmt, 5))
                var current = aggregated[day] ?? (0, 0, 0, 0)
                current.cost += cost
                current.tokens += tokens
                current.pricedRuns += pricedRuns
                current.totalRuns += totalRuns
                aggregated[day] = current
            }
            return aggregated.keys.sorted().map { day in
                let item = aggregated[day] ?? (0, 0, 0, 0)
                return (day, item.cost, item.tokens, item.pricedRuns, item.totalRuns)
            }
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
            totalCachedInputTokens: intByName(stmt, "total_cached_input_tokens"),
            totalOutputTokens: intByName(stmt, "total_output_tokens"),
            totalReasoningOutputTokens: intByName(stmt, "total_reasoning_output_tokens"),
            costUSD: doubleByName(stmt, "cost_usd"),
            tokenUsageSource: colByName(stmt, "token_usage_source").flatMap(TokenUsageSource.init(rawValue:)),
            tokenUsageState: colByName(stmt, "token_usage_state").flatMap(TelemetryMetricState.init(rawValue:)) ?? .missing,
            costSource: colByName(stmt, "cost_source").flatMap(CostSource.init(rawValue:)),
            costState: colByName(stmt, "cost_state").flatMap(TelemetryMetricState.init(rawValue:)) ?? .missing,
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
            cachedInputTokens: intByName(stmt, "cached_input_tokens"),
            outputTokens: intByName(stmt, "output_tokens"),
            reasoningOutputTokens: intByName(stmt, "reasoning_output_tokens"),
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

    private func parseRemoteClientEvent(_ stmt: OpaquePointer?) -> RemoteClientTelemetryEvent? {
        guard let stmt,
              let id = colByName(stmt, "event_id"),
              let source = colByName(stmt, "source"),
              let appVersion = colByName(stmt, "app_version"),
              let rawEventType = colByName(stmt, "event_type"),
              let eventType = RemoteClientTelemetryEventType(rawValue: rawEventType),
              let timestampString = colByName(stmt, "timestamp"),
              let timestamp = Self.isoDate(from: timestampString)
        else { return nil }

        let tabID = intByName(stmt, "tab_id").map(UInt32.init)
        return RemoteClientTelemetryEvent(
            id: id,
            source: source,
            deviceID: colByName(stmt, "device_id"),
            deviceName: colByName(stmt, "device_name"),
            appVersion: appVersion,
            sessionID: colByName(stmt, "session_id"),
            eventType: eventType,
            status: colByName(stmt, "status"),
            tabID: tabID,
            tabTitle: colByName(stmt, "tab_title"),
            message: colByName(stmt, "message"),
            metadata: Self.decodeJSON(colByName(stmt, "metadata")) ?? [:],
            timestamp: timestamp
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
        for i in 0 ..< count {
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
        for i in 0 ..< count {
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
        for i in 0 ..< count {
            if let cn = sqlite3_column_name(stmt, i), String(cString: cn) == name {
                if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
                return sqlite3_column_double(stmt, i)
            }
        }
        return nil
    }

    static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    static func isoString(from date: Date) -> String {
        isoFormatter.string(from: date)
    }

    private static func isoDate(from string: String) -> Date? {
        isoFormatter.date(from: string)
    }

    private static func encodeJSON(_ value: some Encodable) -> String? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeJSON<T: Decodable>(_ json: String?) -> T? {
        guard let json, let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }
}
