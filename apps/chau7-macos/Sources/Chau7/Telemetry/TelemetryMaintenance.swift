import Chau7Core
import Foundation
import SQLite3

struct ProviderLatencyBackfillReport: Sendable {
    var inspectedRuns = 0
    var insertedSamples = 0
    var skippedRuns = 0
}

/// Retention policy for the telemetry database (runs + full transcripts).
/// Single source of truth shared by `FeatureSettings` (the Settings UI) and
/// `TelemetryMaintenance` (the background prune), which reads the value
/// straight from `UserDefaults` so it never touches the main-actor settings
/// object off-main.
enum TelemetryRetention {
    static let defaultsKey = "telemetry.retentionDays"
    /// Default window. AI runs store full turn content and tool-call I/O, so the
    /// DB grows unbounded without this — keep a month by default.
    static let defaultDays = 30
    /// 0 means "keep forever" (no pruning). Upper clamp guards typos.
    static let maxDays = 3650

    static var currentDays: Int {
        UserDefaults.standard.object(forKey: defaultsKey) as? Int ?? defaultDays
    }
}

/// Deferred (post-first-paint) maintenance for the telemetry database:
/// startup backfills, retention pruning, and periodic vacuuming.
///
/// Extracted from `TelemetryStore` (Stage 6 of `docs/SOLID-DRY-REVIEW.md`)
/// as a pure code move — SQL, control flow, and log strings are byte-identical
/// to the pre-split store.
///
/// Threading contract: this type performs no synchronization of its own.
/// Every method must be invoked on the store's serial queue; the store's
/// public forwarders (`scheduleDeferredMaintenance`,
/// `backfillCompletedRunLatencySamples`) do that dispatch. Row parsing and
/// child-row writes go back through the store's on-queue internals so the
/// parsers/binders have exactly one home.
final class TelemetryMaintenance {
    enum PruneOutcome: Equatable {
        case disabled
        case nothingToPrune
        case pruned(deleted: Int, clampedDays: Int)
        case failed(String)
    }

    /// The store owns this object strongly and every entry point is a store
    /// method whose queue block captures the store, so `store` always
    /// outlives any running maintenance work.
    private unowned let store: TelemetryStore
    private var didScheduleDeferredMaintenance = false
    private var didRunDeferredMaintenance = false

    init(store: TelemetryStore) {
        self.store = store
    }

    /// One-shot deferred maintenance pass. Must run on the store's queue.
    func performDeferredMaintenance(reason: String) {
        guard !didScheduleDeferredMaintenance, !didRunDeferredMaintenance else { return }
        didScheduleDeferredMaintenance = true
        Log.info("TelemetryStore: starting deferred maintenance [\(reason)]")
        backfillHistoricalMissingCosts()
        backfillRunUsageEvidence()
        let latencyBackfill = backfillCompletedRunLatencySamples()
        if latencyBackfill.insertedSamples > 0 {
            Log.info(
                "TelemetryStore: backfilled latency samples for \(latencyBackfill.insertedSamples) run(s) " +
                    "(inspected=\(latencyBackfill.inspectedRuns), skipped=\(latencyBackfill.skippedRuns))"
            )
        }
        pruneOldRuns(retentionDays: TelemetryRetention.currentDays)
        runIncrementalVacuumIfNeeded()
        didRunDeferredMaintenance = true
        didScheduleDeferredMaintenance = false
    }

    private func logStartupBackfillScan(
        name: String,
        scannedRows: Int,
        touchedRows: Int,
        startedAt: CFAbsoluteTime,
        extra: String? = nil
    ) {
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0)
        var parts = [
            "TelemetryStore: startup backfill \(name)",
            "scanned=\(scannedRows)",
            "touched=\(touchedRows)",
            "cursorMs=\(elapsedMs)"
        ]
        if let extra, !extra.isEmpty {
            parts.append(extra)
        }
        Log.info(parts.joined(separator: " "))
    }

    /// Delete runs (and, via `ON DELETE CASCADE` + `foreign_keys=ON`, their
    /// turns / tool_calls / latency samples) older than the retention window,
    /// then reclaim the freed disk with a full `VACUUM`.
    ///
    /// A full VACUUM is used deliberately: this database was created without
    /// `auto_vacuum`, so `PRAGMA incremental_vacuum` is a no-op on it — the only
    /// way to shrink the file after deletes is a rewrite. It runs on the store's
    /// serial queue during deferred (post-first-paint) maintenance, and only
    /// when rows were actually removed, so the ~1 GB rewrite is never paid for a
    /// no-op pass.
    ///
    /// `retentionDays <= 0` disables pruning entirely ("keep forever").
    private func pruneOldRuns(retentionDays: Int) {
        guard let db = store.db else { return }
        let startedAt = CFAbsoluteTimeGetCurrent()
        switch Self.deleteRunsOlderThan(retentionDays: retentionDays, in: db) {
        case .disabled:
            Log.info("TelemetryStore: retention disabled (keep forever)")
        case .nothingToPrune:
            break
        case let .failed(message):
            Log.warn("TelemetryStore: retention prune failed: \(message)")
        case let .pruned(deleted, clampedDays):
            let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0)
            Log.info(
                "TelemetryStore: retention prune removed \(deleted) run(s) older than \(clampedDays)d, vacuumed in \(elapsedMs)ms"
            )
        }
    }

    /// Pure deletion core, parameterized on the connection so it can be exercised
    /// against a throwaway database in tests without touching the shared store's
    /// real file. Relies on `foreign_keys=ON` + `ON DELETE CASCADE` to remove the
    /// pruned runs' turns / tool_calls / latency samples, then a full `VACUUM`
    /// (this DB has no `auto_vacuum`, so `incremental_vacuum` can't shrink it).
    @discardableResult
    static func deleteRunsOlderThan(retentionDays: Int, in db: OpaquePointer) -> PruneOutcome {
        guard retentionDays > 0 else { return .disabled }
        let clampedDays = max(1, min(retentionDays, TelemetryRetention.maxDays))
        // started_at is ISO 8601 ('YYYY-MM-DDTHH:MM:...Z'); date('now','-Nd')
        // yields 'YYYY-MM-DD'. The date prefix compares lexicographically, so a
        // run is pruned only once its whole calendar day is past the window.
        let whereClause = "started_at < date('now', '-\(clampedDays) days')"

        var countStmt: OpaquePointer?
        var toDelete = 0
        if sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM runs WHERE \(whereClause)", -1, &countStmt, nil) == SQLITE_OK,
           sqlite3_step(countStmt) == SQLITE_ROW {
            toDelete = Int(sqlite3_column_int(countStmt, 0))
        }
        sqlite3_finalize(countStmt)
        guard toDelete > 0 else { return .nothingToPrune }

        if sqlite3_exec(db, "DELETE FROM runs WHERE \(whereClause)", nil, nil, nil) != SQLITE_OK {
            return .failed(String(cString: sqlite3_errmsg(db)))
        }
        let deleted = Int(sqlite3_changes(db))
        if sqlite3_exec(db, "VACUUM", nil, nil, nil) != SQLITE_OK {
            Log.warn("TelemetryStore: post-prune VACUUM failed: \(String(cString: sqlite3_errmsg(db)))")
        }
        return .pruned(deleted: deleted, clampedDays: clampedDays)
    }

    /// Run PRAGMA incremental_vacuum if more than 7 days have passed since the
    /// last vacuum. WAL mode databases can accumulate free pages over time;
    /// incremental vacuum reclaims them without the full-lock cost of VACUUM.
    private func runIncrementalVacuumIfNeeded() {
        guard let db = store.db else { return }
        let key = "telemetry.store.lastVacuumTime"
        let lastVacuum = UserDefaults.standard.double(forKey: key)
        let now = CFAbsoluteTimeGetCurrent()
        let sevenDays: CFAbsoluteTime = 7 * 24 * 60 * 60
        guard lastVacuum == 0 || (now - lastVacuum) > sevenDays else { return }
        let startedAt = CFAbsoluteTimeGetCurrent()
        sqlite3_exec(db, "PRAGMA incremental_vacuum", nil, nil, nil)
        let elapsedMs = Int((CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0)
        UserDefaults.standard.set(now, forKey: key)
        Log.info("TelemetryStore: incremental vacuum completed in \(elapsedMs)ms")
    }

    private func backfillHistoricalMissingCosts() {
        guard let db = store.db else { return }

        // Only scan runs that actually need cost repair. Runs with
        // cost_state = 'complete' are already done and are skipped.
        let sql = """
        SELECT * FROM runs
        WHERE cost_state IS NOT 'complete'
          AND token_usage_state IS NOT 'invalid'
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var repairedRuns: [TelemetryRun] = []
        var scannedRuns = 0
        let scanStartedAt = CFAbsoluteTimeGetCurrent()
        while sqlite3_step(stmt) == SQLITE_ROW {
            scannedRuns += 1
            guard let run = store.parseRun(stmt),
                  let repaired = TelemetryHistoricalCostBackfill.repairedRun(run) else {
                continue
            }
            repairedRuns.append(repaired)
        }

        logStartupBackfillScan(
            name: "historical_missing_costs",
            scannedRows: scannedRuns,
            touchedRows: repairedRuns.count,
            startedAt: scanStartedAt
        )

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
            store.bindDouble(updateStmt, 1, run.costUSD)
            store.bindText(updateStmt, 2, run.costSource?.rawValue)
            store.bindText(updateStmt, 3, run.costState.rawValue)
            store.bindText(updateStmt, 4, run.id)
            sqlite3_step(updateStmt)
        }

        Log.info("TelemetryStore: backfilled historical cost for \(repairedRuns.count) run(s)")
    }

    private func backfillRunUsageEvidence() {
        guard let db = store.db else { return }

        let sql = """
        SELECT r.*
        FROM runs r
        LEFT JOIN usage_evidence ue
          ON ue.evidence_id = ('run|' || r.run_id)
        WHERE ue.evidence_id IS NULL
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var runs: [TelemetryRun] = []
        var scannedRuns = 0
        let scanStartedAt = CFAbsoluteTimeGetCurrent()
        while sqlite3_step(stmt) == SQLITE_ROW {
            scannedRuns += 1
            guard let run = store.parseRun(stmt) else { continue }
            runs.append(run)
        }

        guard !runs.isEmpty else {
            logStartupBackfillScan(name: "run_usage_evidence", scannedRows: scannedRuns, touchedRows: 0, startedAt: scanStartedAt)
            return
        }

        sqlite3_exec(db, "BEGIN", nil, nil, nil)
        for run in runs {
            store._insertUsageEvidence(UsageEvidence.runSummary(run))
        }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)

        logStartupBackfillScan(
            name: "run_usage_evidence",
            scannedRows: scannedRuns,
            touchedRows: runs.count,
            startedAt: scanStartedAt
        )

        Log.info("TelemetryStore: backfilled usage evidence for \(runs.count) missing run(s)")
    }

    /// On-queue backfill core; the store exposes a `queue.sync` forwarder for
    /// external callers.
    func backfillCompletedRunLatencySamples() -> ProviderLatencyBackfillReport {
        guard let db = store.db else { return ProviderLatencyBackfillReport() }

        // Only process completed runs that:
        // 1. Have no existing latency samples (already backfilled = skip)
        // 2. Have an authoritative transcript source (not null, not empty,
        //    not pty_log/terminal_buffer — these can never produce samples,
        //    so including them causes 541 N+1 queries every launch for nothing)
        let sql = """
        SELECT r.*
        FROM runs r
        WHERE r.ended_at IS NOT NULL
          AND (
                lower(r.provider) LIKE '%codex%'
             OR lower(r.provider) LIKE '%claude%'
             OR lower(r.provider) LIKE '%anthropic%'
             OR lower(r.provider) LIKE '%openai%'
          )
          AND r.raw_transcript_ref IS NOT NULL
          AND TRIM(r.raw_transcript_ref) != ''
          AND r.raw_transcript_ref NOT IN ('pty_log', 'terminal_buffer')
          AND NOT EXISTS (
                SELECT 1 FROM provider_latency_samples pls
                WHERE pls.run_id = r.run_id
                  AND pls.source_kind = 'completed_run_turns'
          )
        ORDER BY r.started_at ASC
        """

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return ProviderLatencyBackfillReport()
        }
        defer { sqlite3_finalize(stmt) }

        let map = store.columnIndexMap(stmt)
        var report = ProviderLatencyBackfillReport()
        let scanStartedAt = CFAbsoluteTimeGetCurrent()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let run = store.parseRun(stmt, map) else { continue }
            report.inspectedRuns += 1
            let turns = store._getTurns(runID: run.id)
            let samples = ProviderLatencyAnalytics.completedRunFirstResponseSamples(run: run, turns: turns)
            if samples.isEmpty {
                // Insert a sentinel so NOT EXISTS skips this run on future launches.
                // Runs that produce no samples (bad timestamps, no human→assistant pairs)
                // would otherwise be rescanned every launch via the N+1 _getTurns query.
                store._insertLatencySentinel(runID: run.id)
                report.skippedRuns += 1
                continue
            }
            for sample in samples {
                store._insertLatencySample(sample)
                report.insertedSamples += 1
            }
        }

        logStartupBackfillScan(
            name: "completed_run_latency_samples",
            scannedRows: report.inspectedRuns,
            touchedRows: report.insertedSamples,
            startedAt: scanStartedAt,
            extra: "skipped=\(report.skippedRuns)"
        )

        return report
    }
}
