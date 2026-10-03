import Foundation
import SQLite3
import Chau7Core

/// Owns measured run reconciliation on TelemetryStore's serial queue only.
/// Query budgets fail closed; retained observations never imply full coverage.
final class TelemetryProxyRunReconciler {
    private unowned let store: TelemetryStore
    private let runLimit = 500
    private let evidenceLimit = 5000

    init(store: TelemetryStore) {
        self.store = store
    }

    func reconcile(around date: Date) {
        let candidates = runs(start: date, end: date)
        guard let start = candidates.map(\.startedAt).min(),
              candidates.count <= runLimit else { return }
        let end = candidates.map { $0.endedAt ?? Date() }.max() ?? date
        reconcile(start: start, end: end)
    }

    func backfill() {
        guard let db = store.db else { return }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT * FROM runs ORDER BY started_at DESC LIMIT 501", -1, &stmt, nil) == SQLITE_OK else { return }
        var retained: [TelemetryRun] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let run = store.parseRun(stmt) { retained.append(run) }
        }
        sqlite3_finalize(stmt)
        // Backfill only bounded retained windows; older unavailable evidence is
        // never reconstructed from tokens or attributed by project alone in a tie.
        // Process connected windows once instead of rescanning the same
        // long-running/overlapping sessions for every retained run.
        var window: (start: Date, end: Date)?
        let now = Date()
        for run in retained.prefix(runLimit).sorted(by: { $0.startedAt < $1.startedAt }) {
            let end = run.endedAt ?? now
            if let current = window, run.startedAt <= current.end {
                window = (current.start, max(current.end, end))
            } else {
                if let current = window { reconcile(start: current.start, end: current.end) }
                window = (run.startedAt, end)
            }
        }
        if let current = window { reconcile(start: current.start, end: current.end) }
    }

    private func reconcile(start: Date, end: Date) {
        let candidates = runs(start: start, end: end)
        let observations = evidence(start: start, end: end)
        guard candidates.count <= runLimit, observations.count <= evidenceLimit else {
            Log.warn("Telemetry proxy reconciliation deferred: retained window exceeds query budget")
            return
        }
        let attributed = TelemetryProxyAttribution.attribute(observations: observations, runs: candidates)
        for run in candidates where run.startedAt >= start && (run.endedAt.map { $0 <= end } ?? true) {
            if let measured = attributed[run.id] {
                saveBaseline(run)
                update(measured.applying(to: run))
            } else if run.tokenUsageSource == .proxy {
                // A newly discovered overlapping run can revoke an earlier match.
                // Restore the independent transcript/estimated baseline, never
                // leave an old first-match measurement attributed to the wrong run.
                update(restoringBaseline(to: run))
            }
        }
    }

    private func runs(start: Date, end: Date) -> [TelemetryRun] {
        guard let db = store.db else { return [] }
        let sql = "SELECT * FROM runs WHERE julianday(started_at) <= julianday(?) AND (ended_at IS NULL OR julianday(ended_at) >= julianday(?)) LIMIT 501"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        // SQLite's time precision is lower than the Core matcher. Widen the SQL
        // prefilter; the pure helper enforces exact half-open boundaries.
        store.bindText(stmt, 1, TelemetryStore.isoString(from: end.addingTimeInterval(1)))
        store.bindText(stmt, 2, TelemetryStore.isoString(from: start.addingTimeInterval(-1)))
        var result: [TelemetryRun] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let run = store.parseRun(stmt) { result.append(run) }
        }
        return result
    }

    private func evidence(start: Date, end: Date) -> [UsageEvidence] {
        guard let db = store.db else { return [] }
        let sql = "SELECT * FROM usage_evidence WHERE source_kind = 'proxy' AND unique_event_key NOT LIKE 'run|%' AND julianday(observed_at) >= julianday(?) AND julianday(observed_at) <= julianday(?) ORDER BY observed_at, ingest_seq LIMIT 5001"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        store.bindText(stmt, 1, TelemetryStore.isoString(from: start.addingTimeInterval(-1)))
        store.bindText(stmt, 2, TelemetryStore.isoString(from: end.addingTimeInterval(1)))
        var result: [UsageEvidence] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let row = store.parseUsageEvidence(stmt) { result.append(row) }
        }
        return result
    }

    private func saveBaseline(_ run: TelemetryRun) {
        guard run.tokenUsageSource != .proxy, let db = store.db,
              let data = try? JSONEncoder().encode(run), let json = String(data: data, encoding: .utf8) else { return }
        var stmt: OpaquePointer?
        let sql = "INSERT INTO proxy_run_baselines(run_id, snapshot) VALUES (?, ?) ON CONFLICT(run_id) DO UPDATE SET snapshot = excluded.snapshot"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        store.bindText(stmt, 1, run.id)
        store.bindText(stmt, 2, json)
        sqlite3_step(stmt)
    }

    private func restoringBaseline(to run: TelemetryRun) -> TelemetryRun {
        var baseline = TelemetryRun(id: run.id, provider: run.provider, cwd: run.cwd)
        if let db = store.db {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT snapshot FROM proxy_run_baselines WHERE run_id = ?", -1, &stmt, nil) == SQLITE_OK {
                store.bindText(stmt, 1, run.id)
                if sqlite3_step(stmt) == SQLITE_ROW, let text = sqlite3_column_text(stmt, 0),
                   let data = String(cString: text).data(using: .utf8), let decoded = try? JSONDecoder().decode(TelemetryRun.self, from: data) {
                    baseline = decoded
                }
            }
            sqlite3_finalize(stmt)
        }
        var restored = run
        restored.totalInputTokens = baseline.totalInputTokens
        restored.totalCacheCreationInputTokens = baseline.totalCacheCreationInputTokens
        restored.totalCacheReadInputTokens = baseline.totalCacheReadInputTokens
        restored.totalCachedInputTokens = baseline.totalCachedInputTokens
        restored.totalOutputTokens = baseline.totalOutputTokens
        restored.totalReasoningOutputTokens = baseline.totalReasoningOutputTokens
        restored.costUSD = baseline.costUSD
        restored.tokenUsageSource = baseline.tokenUsageSource
        restored.tokenUsageState = baseline.tokenUsageState
        restored.costSource = baseline.costSource
        restored.costState = baseline.costState
        for key in restored.metadata.keys.filter({ $0.hasPrefix("proxy_") }) {
            restored.metadata.removeValue(forKey: key)
        }
        return restored
    }

    private func update(_ run: TelemetryRun) {
        guard let db = store.db else { return }
        let sql = """
        UPDATE runs SET total_input_tokens=?, total_cache_creation_input_tokens=?, total_cache_read_input_tokens=?,
        total_cached_input_tokens=?, total_output_tokens=?, total_reasoning_output_tokens=?, cost_usd=?,
        token_usage_source=?, token_usage_state=?, cost_source=?, cost_state=?, metadata=? WHERE run_id=?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        for (
            index,
            value
        ) in [run.totalInputTokens, run.totalCacheCreationInputTokens, run.totalCacheReadInputTokens, run.totalCachedInputTokens, run.totalOutputTokens, run.totalReasoningOutputTokens]
            .enumerated() {
            if let value { sqlite3_bind_int64(stmt, Int32(index + 1), Int64(value)) } else { sqlite3_bind_null(stmt, Int32(index + 1)) }
        }
        store.bindDouble(stmt, 7, run.costUSD)
        store.bindText(stmt, 8, run.tokenUsageSource?.rawValue)
        store.bindText(stmt, 9, run.tokenUsageState.rawValue)
        store.bindText(stmt, 10, run.costSource?.rawValue)
        store.bindText(stmt, 11, run.costState.rawValue)
        let metadata = (try? JSONEncoder().encode(run.metadata)).flatMap { String(data: $0, encoding: .utf8) }
        store.bindText(stmt, 12, metadata)
        store.bindText(stmt, 13, run.id)
        if sqlite3_step(stmt) == SQLITE_DONE { store._insertUsageEvidence(UsageEvidence.runSummary(run)) }
    }
}
