import Foundation
import SQLite3
import Chau7Core

/// SQLite-backed store for telemetry run records, turns, and tool calls.
/// Thread-safe: all database access is serialized on a dedicated queue.
///
/// Schema creation/migrations live in `TelemetrySchemaMigrator`; deferred
/// maintenance (backfills, retention prune, vacuum) lives in
/// `TelemetryMaintenance`. Both collaborators run exclusively on this store's
/// serial queue and reach shared row parsing / binding through the store's
/// on-queue internals.
final class TelemetryStore {
    static let shared = TelemetryStore()

    /// Only the store mutates the handle (open/integrity recovery). The
    /// internal getter exists for `TelemetryMaintenance`, which reads it
    /// on the store's queue only.
    private(set) var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.chau7.telemetry.store")
    private let checkpointLogWalThresholdBytes: Int64 = 8 * 1024 * 1024
    private let checkpointLogRemainingFramesThreshold: Int32 = 1000
    private lazy var maintenance = TelemetryMaintenance(store: self)

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
        // Close after in-flight writes drain, without deinit blocking on the
        // queue — `queue.sync` here is a latent deadlock if the last strong
        // reference is ever released from a task running on `queue` itself
        // (same fix as SpineJournalStore.deinit).
        let db = self.db
        queue.async {
            if let db {
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
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA foreign_keys=ON", nil, nil, nil)
        verifyIntegrity()
        let migrator = TelemetrySchemaMigrator(db: db)
        migrator.createTables()
        migrator.applyMigrations()
    }

    // MARK: - Maintenance (forwarders — implementation in TelemetryMaintenance)

    func scheduleDeferredMaintenance(reason: String) {
        queue.async {
            self.maintenance.performDeferredMaintenance(reason: reason)
        }
    }

    func backfillCompletedRunLatencySamples() -> ProviderLatencyBackfillReport {
        queue.sync {
            maintenance.backfillCompletedRunLatencySamples()
        }
    }

    typealias PruneOutcome = TelemetryMaintenance.PruneOutcome

    /// Test-visible seam for the retention prune; see
    /// `TelemetryMaintenance.deleteRunsOlderThan` for the semantics.
    @discardableResult
    static func deleteRunsOlderThan(retentionDays: Int, in db: OpaquePointer) -> PruneOutcome {
        TelemetryMaintenance.deleteRunsOlderThan(retentionDays: retentionDays, in: db)
    }

    private func commitWriteTransaction(_ db: OpaquePointer?, reason: String) {
        guard let db else { return }
        let rc = sqlite3_exec(db, "COMMIT", nil, nil, nil)
        if rc != SQLITE_OK {
            let detail = String(cString: sqlite3_errmsg(db))
            Log.warn("TelemetryStore: commit failed for \(reason): rc=\(rc) detail=\(detail)")
            return
        }
        logCheckpointProbe(db, reason: reason)
    }

    private func logCheckpointProbe(_ db: OpaquePointer?, reason: String) {
        guard let db else { return }
        var totalFrames: Int32 = 0
        var checkpointedFrames: Int32 = 0
        let startedAt = CFAbsoluteTimeGetCurrent()
        let rc = sqlite3_wal_checkpoint_v2(
            db,
            nil,
            SQLITE_CHECKPOINT_PASSIVE,
            &totalFrames,
            &checkpointedFrames
        )
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0)
        let remainingFrames = max(totalFrames - checkpointedFrames, 0)
        let walBytes = Self.fileSize(atPath: "\(Self.dbPath)-wal") ?? 0
        let detail = String(cString: sqlite3_errmsg(db))
        let message =
            "TelemetryStore: checkpoint probe after \(reason) " +
            "rc=\(rc) totalFrames=\(totalFrames) checkpointedFrames=\(checkpointedFrames) " +
            "remainingFrames=\(remainingFrames) walBytes=\(walBytes) elapsedMs=\(elapsedMs) detail=\(detail)"
        if rc != SQLITE_OK ||
            remainingFrames >= checkpointLogRemainingFramesThreshold ||
            walBytes >= checkpointLogWalThresholdBytes {
            Log.info(message)
        } else {
            Log.trace(message)
        }
    }

    private static func fileSize(atPath path: String) -> Int64? {
        guard let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
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
         total_input_tokens, total_cache_creation_input_tokens, total_cache_read_input_tokens,
         total_cached_input_tokens, total_output_tokens, total_reasoning_output_tokens,
         cost_usd, token_usage_source, token_usage_state, cost_source, cost_state,
         turn_count, tags, metadata, raw_transcript_ref, parent_run_id, error_message)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
        bindInt(stmt, 13, run.totalCacheCreationInputTokens)
        bindInt(stmt, 14, run.totalCacheReadInputTokens)
        bindInt(stmt, 15, run.totalCachedInputTokens)
        bindInt(stmt, 16, run.totalOutputTokens)
        bindInt(stmt, 17, run.totalReasoningOutputTokens)
        bindDouble(stmt, 18, run.costUSD)
        bindText(stmt, 19, run.tokenUsageSource?.rawValue)
        bindText(stmt, 20, run.tokenUsageState.rawValue)
        bindText(stmt, 21, run.costSource?.rawValue)
        bindText(stmt, 22, run.costState.rawValue)
        bindInt(stmt, 23, run.turnCount)
        bindText(stmt, 24, Self.encodeJSON(run.tags))
        bindText(stmt, 25, Self.encodeJSON(run.metadata))
        bindText(stmt, 26, run.rawTranscriptRef)
        bindText(stmt, 27, run.parentRunID)
        bindText(stmt, 28, run.errorMessage)

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
                total_input_tokens = ?, total_cache_creation_input_tokens = ?, total_cache_read_input_tokens = ?,
                total_cached_input_tokens = ?, total_output_tokens = ?, total_reasoning_output_tokens = ?,
                cost_usd = ?, token_usage_source = ?, token_usage_state = ?, cost_source = ?, cost_state = ?,
                turn_count = ?, raw_transcript_ref = ?, error_message = ?, metadata = ?
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
                bindInt(stmt, 7, run.totalCacheCreationInputTokens)
                bindInt(stmt, 8, run.totalCacheReadInputTokens)
                bindInt(stmt, 9, run.totalCachedInputTokens)
                bindInt(stmt, 10, run.totalOutputTokens)
                bindInt(stmt, 11, run.totalReasoningOutputTokens)
                bindDouble(stmt, 12, run.costUSD)
                bindText(stmt, 13, run.tokenUsageSource?.rawValue)
                bindText(stmt, 14, run.tokenUsageState.rawValue)
                bindText(stmt, 15, run.costSource?.rawValue)
                bindText(stmt, 16, run.costState.rawValue)
                bindInt(stmt, 17, run.turnCount)
                bindText(stmt, 18, run.rawTranscriptRef)
                bindText(stmt, 19, run.errorMessage)
                // Persist metadata mutated after run start (e.g. deferred
                // content-extraction markers set by runEnded).
                bindText(stmt, 20, Self.encodeJSON(run.metadata))
                bindText(stmt, 21, run.id)
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

            _insertUsageEvidence(UsageEvidence.runSummary(run))
            upsertCompletedRunLatencySamples(run: run, turns: turns)

            commitWriteTransaction(db, reason: "finalizeRun")
        }
    }

    func insertTurns(_ turns: [TelemetryTurn]) {
        queue.async { [weak self] in
            guard let self, let db else { return }
            if turns.count > 1 { sqlite3_exec(db, "BEGIN", nil, nil, nil) }
            for turn in turns {
                _insertTurn(turn)
            }
            if turns.count > 1 { commitWriteTransaction(db, reason: "insertTurns") }
        }
    }

    private func _insertTurn(_ turn: TelemetryTurn) {
        guard let db else { return }
        let sql = """
        INSERT OR IGNORE INTO turns
        (turn_id, run_id, turn_index, role, content, input_tokens,
         cache_creation_input_tokens, cache_read_input_tokens, cached_input_tokens,
         output_tokens, reasoning_output_tokens, tool_calls, timestamp, duration_ms)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
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
        bindInt(stmt, 7, turn.cacheCreationInputTokens)
        bindInt(stmt, 8, turn.cacheReadInputTokens)
        bindInt(stmt, 9, turn.cachedInputTokens)
        bindInt(stmt, 10, turn.outputTokens)
        bindInt(stmt, 11, turn.reasoningOutputTokens)
        bindText(stmt, 12, Self.encodeJSON(turn.toolCalls))
        bindText(stmt, 13, turn.timestamp.map { Self.isoString(from: $0) })
        bindInt(stmt, 14, turn.durationMs)

        if sqlite3_step(stmt) != SQLITE_DONE {
            let err = String(cString: sqlite3_errmsg(db))
            Log.warn("TelemetryStore: insert turn failed for \(turn.id): \(err)")
        }
    }

    func insertToolCalls(_ calls: [TelemetryToolCall]) {
        queue.async { [weak self] in
            guard let self, let db else { return }
            if calls.count > 1 { sqlite3_exec(db, "BEGIN", nil, nil, nil) }
            for call in calls {
                _insertToolCall(call)
            }
            if calls.count > 1 { commitWriteTransaction(db, reason: "insertToolCalls") }
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
                model = ?, total_input_tokens = ?, total_cache_creation_input_tokens = ?,
                total_cache_read_input_tokens = ?, total_cached_input_tokens = ?,
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
            bindInt(stmt, 3, run.totalCacheCreationInputTokens)
            bindInt(stmt, 4, run.totalCacheReadInputTokens)
            bindInt(stmt, 5, run.totalCachedInputTokens)
            bindInt(stmt, 6, run.totalOutputTokens)
            bindInt(stmt, 7, run.totalReasoningOutputTokens)
            bindDouble(stmt, 8, run.costUSD)
            bindText(stmt, 9, run.tokenUsageSource?.rawValue)
            bindText(stmt, 10, run.tokenUsageState.rawValue)
            bindText(stmt, 11, run.costSource?.rawValue)
            bindText(stmt, 12, run.costState.rawValue)
            bindInt(stmt, 13, run.turnCount)
            bindText(stmt, 14, run.errorMessage)
            bindText(stmt, 15, run.id)
            sqlite3_step(stmt)
        }
    }

    func insertUsageEvidence(_ evidence: UsageEvidence) {
        queue.async { [weak self] in
            self?._insertUsageEvidence(evidence)
        }
    }

    func insertLatencySample(_ sample: ProviderLatencySample) {
        queue.async { [weak self] in
            self?._insertLatencySample(sample)
        }
    }

    /// On-queue write core, shared with `TelemetryMaintenance`.
    func _insertUsageEvidence(_ evidence: UsageEvidence) {
        guard let db else { return }
        let sql = """
        INSERT INTO usage_evidence
        (evidence_id, unique_event_key, reconciliation_key, source_kind, provider, model,
         session_id, run_id, endpoint, project_path,
         input_tokens, cache_creation_input_tokens, cache_read_input_tokens, output_tokens, reasoning_output_tokens,
         cost_usd, token_usage_source, token_usage_state, cost_source, cost_state,
         pricing_version, source_ref, metadata, observed_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(evidence_id) DO UPDATE SET
            unique_event_key = excluded.unique_event_key,
            reconciliation_key = excluded.reconciliation_key,
            source_kind = excluded.source_kind,
            provider = excluded.provider,
            model = excluded.model,
            session_id = excluded.session_id,
            run_id = excluded.run_id,
            endpoint = excluded.endpoint,
            project_path = excluded.project_path,
            input_tokens = excluded.input_tokens,
            cache_creation_input_tokens = excluded.cache_creation_input_tokens,
            cache_read_input_tokens = excluded.cache_read_input_tokens,
            output_tokens = excluded.output_tokens,
            reasoning_output_tokens = excluded.reasoning_output_tokens,
            cost_usd = excluded.cost_usd,
            token_usage_source = excluded.token_usage_source,
            token_usage_state = excluded.token_usage_state,
            cost_source = excluded.cost_source,
            cost_state = excluded.cost_state,
            pricing_version = excluded.pricing_version,
            source_ref = excluded.source_ref,
            metadata = excluded.metadata,
            observed_at = excluded.observed_at
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, evidence.id)
        bindText(stmt, 2, evidence.uniqueEventKey)
        bindText(stmt, 3, evidence.reconciliationKey)
        bindText(stmt, 4, evidence.sourceKind.rawValue)
        bindText(stmt, 5, evidence.provider)
        bindText(stmt, 6, evidence.model)
        bindText(stmt, 7, evidence.sessionID)
        bindText(stmt, 8, evidence.runID)
        bindText(stmt, 9, evidence.endpoint)
        bindText(stmt, 10, evidence.projectPath)
        bindInt(stmt, 11, evidence.inputTokens)
        bindInt(stmt, 12, evidence.cacheCreationInputTokens)
        bindInt(stmt, 13, evidence.cacheReadInputTokens)
        bindInt(stmt, 14, evidence.outputTokens)
        bindInt(stmt, 15, evidence.reasoningOutputTokens)
        bindDouble(stmt, 16, evidence.costUSD)
        bindText(stmt, 17, evidence.tokenUsageSource?.rawValue)
        bindText(stmt, 18, evidence.tokenUsageState.rawValue)
        bindText(stmt, 19, evidence.costSource?.rawValue)
        bindText(stmt, 20, evidence.costState.rawValue)
        bindText(stmt, 21, evidence.pricingVersion)
        bindText(stmt, 22, evidence.sourceRef)
        bindText(stmt, 23, Self.encodeJSON(evidence.metadata))
        bindText(stmt, 24, Self.isoString(from: evidence.observedAt))

        if sqlite3_step(stmt) != SQLITE_DONE {
            let err = String(cString: sqlite3_errmsg(db))
            Log.warn("TelemetryStore: insert usage evidence failed for \(evidence.id): \(err)")
        }
    }

    /// On-queue write core, shared with `TelemetryMaintenance`.
    func _insertLatencySample(_ sample: ProviderLatencySample) {
        guard let db else { return }
        let sql = """
        INSERT INTO provider_latency_samples
        (sample_id, provider, metric_kind, latency_ms, model, session_id, run_id, round_index, project_path, source_kind, observed_at)
        VALUES (?,?,?,?,?,?,?,?,?,?,?)
        ON CONFLICT(sample_id) DO UPDATE SET
            provider = excluded.provider,
            metric_kind = excluded.metric_kind,
            latency_ms = excluded.latency_ms,
            model = excluded.model,
            session_id = excluded.session_id,
            run_id = excluded.run_id,
            round_index = excluded.round_index,
            project_path = excluded.project_path,
            source_kind = excluded.source_kind,
            observed_at = excluded.observed_at
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        bindText(stmt, 1, sample.id)
        bindText(stmt, 2, sample.provider)
        bindText(stmt, 3, sample.metricKind.rawValue)
        bindInt(stmt, 4, sample.latencyMs)
        bindText(stmt, 5, sample.model)
        bindText(stmt, 6, sample.sessionID)
        bindText(stmt, 7, sample.runID)
        bindInt(stmt, 8, sample.roundIndex)
        bindText(stmt, 9, sample.projectPath)
        bindText(stmt, 10, sample.sourceKind)
        bindText(stmt, 11, Self.isoString(from: sample.timestamp))

        if sqlite3_step(stmt) != SQLITE_DONE {
            let err = String(cString: sqlite3_errmsg(db))
            Log.warn("TelemetryStore: insert latency sample failed for \(sample.id): \(err)")
        }
    }

    /// Insert a zero-value sentinel so the NOT EXISTS filter in the backfill
    /// query skips this run on subsequent launches. The sentinel has a
    /// recognizable source_kind so it can be distinguished from real samples.
    func _insertLatencySentinel(runID: String) {
        guard let db else { return }
        let sql = """
        INSERT OR IGNORE INTO provider_latency_samples
        (sample_id, provider, metric_kind, latency_ms, run_id, source_kind, observed_at)
        VALUES (?, 'sentinel', 'first_response', 0, ?, 'completed_run_turns', datetime('now'))
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let sampleID = "sentinel|\(runID)"
        bindText(stmt, 1, sampleID)
        bindText(stmt, 2, runID)
        sqlite3_step(stmt)
    }

    private func deleteLatencySamples(
        runID: String,
        metricKind: ProviderLatencyMetricKind,
        sourceKind: String? = nil
    ) {
        guard let db else { return }
        let sql: String
        if sourceKind != nil {
            sql = "DELETE FROM provider_latency_samples WHERE run_id = ? AND metric_kind = ? AND source_kind = ?"
        } else {
            sql = "DELETE FROM provider_latency_samples WHERE run_id = ? AND metric_kind = ?"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, runID)
        bindText(stmt, 2, metricKind.rawValue)
        if let sourceKind {
            bindText(stmt, 3, sourceKind)
        }
        sqlite3_step(stmt)
    }

    private func upsertCompletedRunLatencySamples(run: TelemetryRun, turns: [TelemetryTurn]) {
        let sourceKind = "completed_run_turns"
        let samples = ProviderLatencyAnalytics.completedRunFirstResponseSamples(
            run: run,
            turns: turns,
            sourceKind: sourceKind
        )
        // _insertLatencySample uses ON CONFLICT DO UPDATE — upsert is idempotent,
        // no need to delete first. The delete-then-insert pattern was causing the
        // startup backfill to redo all work every launch.
        for sample in samples {
            _insertLatencySample(sample)
        }
    }

    func rewriteCompletedRun(_ run: TelemetryRun, turns: [TelemetryTurn], toolCalls: [TelemetryToolCall]) {
        queue.async { [self] in
            guard let db else { return }
            sqlite3_exec(db, "BEGIN", nil, nil, nil)

            deleteChildren(table: "tool_calls", runID: run.id)
            deleteChildren(table: "turns", runID: run.id)

            let updateSQL = """
            UPDATE runs SET
                session_id = ?, tab_id = ?, provider = ?, model = ?, cwd = ?, repo_path = ?,
                started_at = ?, ended_at = ?, duration_ms = ?, exit_status = ?,
                total_input_tokens = ?, total_cache_creation_input_tokens = ?, total_cache_read_input_tokens = ?,
                total_cached_input_tokens = ?, total_output_tokens = ?, total_reasoning_output_tokens = ?,
                cost_usd = ?, token_usage_source = ?, token_usage_state = ?, cost_source = ?, cost_state = ?, turn_count = ?,
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
                bindInt(stmt, 12, run.totalCacheCreationInputTokens)
                bindInt(stmt, 13, run.totalCacheReadInputTokens)
                bindInt(stmt, 14, run.totalCachedInputTokens)
                bindInt(stmt, 15, run.totalOutputTokens)
                bindInt(stmt, 16, run.totalReasoningOutputTokens)
                bindDouble(stmt, 17, run.costUSD)
                bindText(stmt, 18, run.tokenUsageSource?.rawValue)
                bindText(stmt, 19, run.tokenUsageState.rawValue)
                bindText(stmt, 20, run.costSource?.rawValue)
                bindText(stmt, 21, run.costState.rawValue)
                bindInt(stmt, 22, run.turnCount)
                bindText(stmt, 23, Self.encodeJSON(run.tags))
                bindText(stmt, 24, Self.encodeJSON(run.metadata))
                bindText(stmt, 25, run.rawTranscriptRef)
                bindText(stmt, 26, run.parentRunID)
                bindText(stmt, 27, run.errorMessage)
                bindText(stmt, 28, run.id)
                sqlite3_step(stmt)
                sqlite3_finalize(stmt)
            }

            for turn in turns {
                _insertTurn(turn)
            }
            for call in toolCalls {
                _insertToolCall(call)
            }

            _insertUsageEvidence(UsageEvidence.runSummary(run))
            upsertCompletedRunLatencySamples(run: run, turns: turns)

            commitWriteTransaction(db, reason: "rewriteCompletedRun")
        }
    }

    func invalidateRunMetrics(_ runID: String, reason: String?) {
        queue.sync {
            guard let db else { return }
            let sql = """
            UPDATE runs
            SET total_input_tokens = NULL,
                total_cache_creation_input_tokens = NULL,
                total_cache_read_input_tokens = NULL,
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

            if let refreshedRun = _getRun(runID) {
                _insertUsageEvidence(UsageEvidence.runSummary(refreshedRun))
            }
        }
    }

    /// Records that transcript repair was attempted for `runID`. Ended-run
    /// transcripts are immutable, so a single attempt is authoritative — this
    /// stamp lets the repair sweep skip the run instead of re-reading and
    /// re-parsing its transcript every cycle when metrics can't be derived
    /// (no model pricing, oversized/unparseable rollout, etc.).
    func markTranscriptRepairAttempted(_ runID: String, at date: Date) {
        queue.sync {
            guard let db else { return }
            let sql = "UPDATE runs SET transcript_repair_attempted_at = ? WHERE run_id = ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            bindText(stmt, 1, Self.isoString(from: date))
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
        ORDER BY timestamp DESC, ingest_seq DESC
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

    func listUsageEvidence(
        provider: String? = nil,
        runID: String? = nil,
        reconciliationKey: String? = nil,
        limit: Int = 500
    ) -> [UsageEvidence] {
        queue.sync {
            _listUsageEvidence(
                provider: provider,
                runID: runID,
                reconciliationKey: reconciliationKey,
                limit: limit
            )
        }
    }

    private func _listUsageEvidence(
        provider: String?,
        runID: String?,
        reconciliationKey: String?,
        limit: Int
    ) -> [UsageEvidence] {
        guard let db else { return [] }

        var conditions: [String] = []
        var bindValues: [String?] = []
        if let provider {
            conditions.append("provider = ?")
            bindValues.append(provider.lowercased())
        }
        if let runID {
            conditions.append("run_id = ?")
            bindValues.append(runID)
        }
        if let reconciliationKey {
            conditions.append("reconciliation_key = ?")
            bindValues.append(reconciliationKey)
        }

        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
        let sql = """
        SELECT * FROM usage_evidence
        \(whereClause)
        ORDER BY observed_at DESC, ingest_seq DESC
        LIMIT ?
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var index: Int32 = 1
        for value in bindValues {
            bindText(stmt, index, value)
            index += 1
        }
        sqlite3_bind_int64(stmt, index, Int64(limit))

        var evidence: [UsageEvidence] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = parseUsageEvidence(stmt) {
                evidence.append(row)
            }
        }
        return evidence
    }

    func reconcileUsageEvidence(provider: String? = nil, limit: Int = 2000) -> UsageReconciliationReport {
        UsageReconciliationService.reconcile(
            listUsageEvidence(provider: provider, limit: limit)
        )
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
        if filter.needsTranscriptRepair {
            clauses.append("""
            ended_at IS NOT NULL
            AND session_id IS NOT NULL AND TRIM(session_id) != ''
            AND (lower(provider) LIKE '%claude%' OR lower(provider) LIKE '%anthropic%'
                 OR lower(provider) LIKE '%codex%' OR lower(provider) LIKE '%openai%')
            AND transcript_repair_attempted_at IS NULL
            AND (raw_transcript_ref IS NULL
                 OR raw_transcript_ref IN ('pty_log', 'terminal_buffer')
                 OR token_usage_state = 'missing'
                 OR cost_state = 'missing'
                 OR cost_source = 'unavailable')
            """)
        }

        var sql = "SELECT * FROM runs"
        if !clauses.isEmpty {
            sql += " WHERE " + clauses.joined(separator: " AND ")
        }
        sql += " ORDER BY started_at DESC, ingest_seq DESC"
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

        let map = columnIndexMap(stmt)
        var runs: [TelemetryRun] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let run = parseRun(stmt, map) {
                runs.append(run)
            }
        }
        return runs
    }

    func getTurns(runID: String) -> [TelemetryTurn] {
        queue.sync { _getTurns(runID: runID) }
    }

    /// On-queue read core, shared with `TelemetryMaintenance`.
    func _getTurns(runID: String) -> [TelemetryTurn] {
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

            while sqlite3_step(stmt) == SQLITE_ROW {
                let rawProvider = colText(stmt, 0)
                guard AnalyticsProvider.matches(rawProvider, filterKey: providerFilterKey) else { continue }

                totalRuns += Int(sqlite3_column_int(stmt, 1))
                totalTokens += Int(sqlite3_column_int64(stmt, 2))
                totalCost += sqlite3_column_double(stmt, 3)
                totalTurns += Int(sqlite3_column_int(stmt, 4))
                if sqlite3_column_type(stmt, 5) != SQLITE_NULL,
                   let text = sqlite3_column_text(stmt, 5),
                   let date = DateFormatters.parseISO8601(String(cString: text)),
                   lastRunAt == nil || date > lastRunAt! {
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
            sql += " ORDER BY started_at DESC, ingest_seq DESC LIMIT 1"

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
            sql += " ORDER BY started_at DESC, ingest_seq DESC LIMIT 1"

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
            // Single-pass CTE using ROW_NUMBER to pick the latest run per session,
            // avoiding correlated subqueries that fired once per session row.
            var sql = """
            WITH filtered_runs AS (
                SELECT *,
                       ROW_NUMBER() OVER (PARTITION BY session_id ORDER BY started_at DESC, created_at DESC, ingest_seq DESC) AS rn
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
            ),
            latest_run AS (
                SELECT session_id, provider, repo_path
                FROM filtered_runs
                WHERE rn = 1
            )
            SELECT sr.session_id,
                   lr.provider,
                   lr.repo_path,
                   sr.run_count,
                   sr.last_active
            FROM session_rollup sr
            LEFT JOIN latest_run lr ON lr.session_id = sr.session_id
            ORDER BY sr.last_active DESC
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

    /// Persisted provider latency samples ordered by observation time.
    func latencySamples(
        after: Date? = nil,
        providerFilterKey: String? = nil,
        metricKind: ProviderLatencyMetricKind? = nil
    ) -> [ProviderLatencySample] {
        queue.sync {
            guard let db else { return [] }
            var sql = """
            SELECT sample_id, provider, metric_kind, latency_ms, model, session_id, run_id, round_index, project_path, source_kind, observed_at
            FROM provider_latency_samples
            WHERE 1 = 1
            """
            if after != nil {
                sql += " AND observed_at >= ?"
            }
            if metricKind != nil {
                sql += " AND metric_kind = ?"
            }
            sql += " ORDER BY observed_at ASC, ingest_seq ASC"

            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }

            var bindIndex: Int32 = 1
            if let after {
                bindText(stmt, bindIndex, Self.isoString(from: after))
                bindIndex += 1
            }
            if let metricKind {
                bindText(stmt, bindIndex, metricKind.rawValue)
            }

            var samples: [ProviderLatencySample] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let provider = colText(stmt, 1),
                      AnalyticsProvider.matches(provider, filterKey: providerFilterKey),
                      let normalizedProvider = AIResumeParser.normalizeProviderName(provider) ?? AnalyticsProvider.key(for: provider),
                      let metricRaw = colText(stmt, 2),
                      let kind = ProviderLatencyMetricKind(rawValue: metricRaw),
                      let observedAt = colText(stmt, 10).flatMap({ Self.isoDate(from: $0) }) else {
                    continue
                }

                samples.append(
                    ProviderLatencySample(
                        id: colText(stmt, 0) ?? UUID().uuidString,
                        provider: normalizedProvider,
                        metricKind: kind,
                        latencyMs: Int(sqlite3_column_int64(stmt, 3)),
                        timestamp: observedAt,
                        model: colText(stmt, 4),
                        sessionID: colText(stmt, 5),
                        runID: colText(stmt, 6),
                        roundIndex: intByColumn(stmt, 7),
                        projectPath: colText(stmt, 8),
                        sourceKind: colText(stmt, 9) ?? "telemetry"
                    )
                )
            }
            return ProviderLatencyAnalytics.canonicalLatencySamples(samples)
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

    /// The run parser is internal (not private) so `TelemetryMaintenance` can
    /// reuse it on the store's queue instead of duplicating it.
    func parseRun(_ stmt: OpaquePointer?) -> TelemetryRun? {
        parseRun(stmt, columnIndexMap(stmt))
    }

    func parseRun(_ stmt: OpaquePointer?, _ map: [String: Int32]) -> TelemetryRun? {
        guard let stmt else { return nil }
        guard let runID = colByName(stmt, "run_id", map),
              let provider = colByName(stmt, "provider", map),
              let cwd = colByName(stmt, "cwd", map),
              let startedAtStr = colByName(stmt, "started_at", map),
              let startedAt = Self.isoDate(from: startedAtStr)
        else { return nil }

        return TelemetryRun(
            id: runID,
            sessionID: colByName(stmt, "session_id", map),
            tabID: colByName(stmt, "tab_id", map),
            provider: provider,
            model: colByName(stmt, "model", map),
            cwd: cwd,
            repoPath: colByName(stmt, "repo_path", map),
            startedAt: startedAt,
            endedAt: colByName(stmt, "ended_at", map).flatMap { Self.isoDate(from: $0) },
            durationMs: intByName(stmt, "duration_ms", map),
            exitStatus: intByName(stmt, "exit_status", map),
            totalInputTokens: intByName(stmt, "total_input_tokens", map),
            totalCacheCreationInputTokens: intByName(stmt, "total_cache_creation_input_tokens", map),
            totalCacheReadInputTokens: intByName(stmt, "total_cache_read_input_tokens", map),
            totalCachedInputTokens: intByName(stmt, "total_cached_input_tokens", map),
            totalOutputTokens: intByName(stmt, "total_output_tokens", map),
            totalReasoningOutputTokens: intByName(stmt, "total_reasoning_output_tokens", map),
            costUSD: doubleByName(stmt, "cost_usd", map),
            tokenUsageSource: colByName(stmt, "token_usage_source", map).flatMap(TokenUsageSource.init(rawValue:)),
            tokenUsageState: colByName(stmt, "token_usage_state", map).flatMap(TelemetryMetricState.init(rawValue:)) ?? .missing,
            costSource: colByName(stmt, "cost_source", map).flatMap(CostSource.init(rawValue:)),
            costState: colByName(stmt, "cost_state", map).flatMap(TelemetryMetricState.init(rawValue:)) ?? .missing,
            turnCount: intByName(stmt, "turn_count", map) ?? 0,
            tags: Self.decodeJSON(colByName(stmt, "tags", map)) ?? [],
            metadata: Self.decodeJSON(colByName(stmt, "metadata", map)) ?? [:],
            rawTranscriptRef: colByName(stmt, "raw_transcript_ref", map),
            parentRunID: colByName(stmt, "parent_run_id", map),
            errorMessage: colByName(stmt, "error_message", map),
            transcriptRepairAttemptedAt: colByName(stmt, "transcript_repair_attempted_at", map).flatMap { Self.isoDate(from: $0) }
        )
    }

    private func parseTurn(_ stmt: OpaquePointer?) -> TelemetryTurn? {
        let map = columnIndexMap(stmt)
        guard let stmt,
              let turnID = colByName(stmt, "turn_id", map),
              let runID = colByName(stmt, "run_id", map),
              let roleStr = colByName(stmt, "role", map),
              let role = TurnRole(rawValue: roleStr)
        else { return nil }

        let toolCalls: [TelemetryToolCall] = Self.decodeJSON(colByName(stmt, "tool_calls", map)) ?? []
        return TelemetryTurn(
            id: turnID, runID: runID,
            turnIndex: intByName(stmt, "turn_index", map) ?? 0,
            role: role,
            content: colByName(stmt, "content", map),
            inputTokens: intByName(stmt, "input_tokens", map),
            cacheCreationInputTokens: intByName(stmt, "cache_creation_input_tokens", map),
            cacheReadInputTokens: intByName(stmt, "cache_read_input_tokens", map),
            cachedInputTokens: intByName(stmt, "cached_input_tokens", map),
            outputTokens: intByName(stmt, "output_tokens", map),
            reasoningOutputTokens: intByName(stmt, "reasoning_output_tokens", map),
            toolCalls: toolCalls,
            timestamp: colByName(stmt, "timestamp", map).flatMap { Self.isoDate(from: $0) },
            durationMs: intByName(stmt, "duration_ms", map)
        )
    }

    private func parseToolCall(_ stmt: OpaquePointer?) -> TelemetryToolCall {
        let map = columnIndexMap(stmt)
        return TelemetryToolCall(
            id: colByName(stmt, "call_id", map) ?? UUID().uuidString,
            runID: colByName(stmt, "run_id", map) ?? "",
            turnID: colByName(stmt, "turn_id", map) ?? "",
            toolName: colByName(stmt, "tool_name", map) ?? "",
            arguments: colByName(stmt, "arguments", map),
            result: colByName(stmt, "result", map),
            status: ToolCallStatus(rawValue: colByName(stmt, "status", map) ?? "") ?? .success,
            durationMs: intByName(stmt, "duration_ms", map),
            callIndex: intByName(stmt, "call_index", map) ?? 0
        )
    }

    private func parseUsageEvidence(_ stmt: OpaquePointer?) -> UsageEvidence? {
        let map = columnIndexMap(stmt)
        guard let stmt,
              let id = colByName(stmt, "evidence_id", map),
              let uniqueEventKey = colByName(stmt, "unique_event_key", map),
              let reconciliationKey = colByName(stmt, "reconciliation_key", map),
              let rawSourceKind = colByName(stmt, "source_kind", map),
              let sourceKind = UsageEvidenceSourceKind(rawValue: rawSourceKind),
              let provider = colByName(stmt, "provider", map),
              let observedAtString = colByName(stmt, "observed_at", map),
              let observedAt = Self.isoDate(from: observedAtString)
        else { return nil }

        return UsageEvidence(
            id: id,
            uniqueEventKey: uniqueEventKey,
            reconciliationKey: reconciliationKey,
            sourceKind: sourceKind,
            provider: provider,
            model: colByName(stmt, "model", map),
            sessionID: colByName(stmt, "session_id", map),
            runID: colByName(stmt, "run_id", map),
            endpoint: colByName(stmt, "endpoint", map),
            projectPath: colByName(stmt, "project_path", map),
            inputTokens: intByName(stmt, "input_tokens", map),
            cacheCreationInputTokens: intByName(stmt, "cache_creation_input_tokens", map),
            cacheReadInputTokens: intByName(stmt, "cache_read_input_tokens", map),
            outputTokens: intByName(stmt, "output_tokens", map),
            reasoningOutputTokens: intByName(stmt, "reasoning_output_tokens", map),
            costUSD: doubleByName(stmt, "cost_usd", map),
            tokenUsageSource: colByName(stmt, "token_usage_source", map).flatMap(TokenUsageSource.init(rawValue:)),
            tokenUsageState: colByName(stmt, "token_usage_state", map).flatMap(TelemetryMetricState.init(rawValue:)) ?? .missing,
            costSource: colByName(stmt, "cost_source", map).flatMap(CostSource.init(rawValue:)),
            costState: colByName(stmt, "cost_state", map).flatMap(TelemetryMetricState.init(rawValue:)) ?? .missing,
            pricingVersion: colByName(stmt, "pricing_version", map),
            sourceRef: colByName(stmt, "source_ref", map),
            observedAt: observedAt,
            metadata: Self.decodeJSON(colByName(stmt, "metadata", map)) ?? [:]
        )
    }

    private func parseRemoteClientEvent(_ stmt: OpaquePointer?) -> RemoteClientTelemetryEvent? {
        let map = columnIndexMap(stmt)
        guard let stmt,
              let id = colByName(stmt, "event_id", map),
              let source = colByName(stmt, "source", map),
              let appVersion = colByName(stmt, "app_version", map),
              let rawEventType = colByName(stmt, "event_type", map),
              let eventType = RemoteClientTelemetryEventType(rawValue: rawEventType),
              let timestampString = colByName(stmt, "timestamp", map),
              let timestamp = Self.isoDate(from: timestampString)
        else { return nil }

        let tabID = intByName(stmt, "tab_id", map).map(UInt32.init)
        return RemoteClientTelemetryEvent(
            id: id,
            source: source,
            deviceID: colByName(stmt, "device_id", map),
            deviceName: colByName(stmt, "device_name", map),
            appVersion: appVersion,
            sessionID: colByName(stmt, "session_id", map),
            eventType: eventType,
            status: colByName(stmt, "status", map),
            tabID: tabID,
            tabTitle: colByName(stmt, "tab_title", map),
            message: colByName(stmt, "message", map),
            metadata: Self.decodeJSON(colByName(stmt, "metadata", map)) ?? [:],
            timestamp: timestamp
        )
    }

    // MARK: - SQLite Bind/Read Helpers

    /// bindText/bindDouble/columnIndexMap are internal (not private) so
    /// `TelemetryMaintenance` can reuse them for its backfill statements.
    func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
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

    func bindDouble(_ stmt: OpaquePointer?, _ index: Int32, _ value: Double?) {
        if let v = value { sqlite3_bind_double(stmt, index, v) }
        else { sqlite3_bind_null(stmt, index) }
    }

    private func colText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let ptr = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: ptr)
    }

    /// Builds a column-name → index map for a prepared statement.
    /// Call once after prepare, then use the map for O(1) lookups per field.
    func columnIndexMap(_ stmt: OpaquePointer?) -> [String: Int32] {
        guard let stmt else { return [:] }
        let count = sqlite3_column_count(stmt)
        var map: [String: Int32] = [:]
        map.reserveCapacity(Int(count))
        for i in 0 ..< count {
            if let cn = sqlite3_column_name(stmt, i) {
                map[String(cString: cn)] = i
            }
        }
        return map
    }

    private func colByName(_ stmt: OpaquePointer?, _ name: String, _ map: [String: Int32]) -> String? {
        guard let stmt, let i = map[name] else { return nil }
        guard let ptr = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: ptr)
    }

    private func intByColumn(_ stmt: OpaquePointer?, _ index: Int32) -> Int? {
        guard let stmt else { return nil }
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(stmt, index))
    }

    private func intByName(_ stmt: OpaquePointer?, _ name: String, _ map: [String: Int32]) -> Int? {
        guard let stmt, let i = map[name] else { return nil }
        if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
        return Int(sqlite3_column_int64(stmt, i))
    }

    private func doubleByName(_ stmt: OpaquePointer?, _ name: String, _ map: [String: Int32]) -> Double? {
        guard let stmt, let i = map[name] else { return nil }
        if sqlite3_column_type(stmt, i) == SQLITE_NULL { return nil }
        return sqlite3_column_double(stmt, i)
    }

    static let isoFormatter = DateFormatters.iso8601

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
