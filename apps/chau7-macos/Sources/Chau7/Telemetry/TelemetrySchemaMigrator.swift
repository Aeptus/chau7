import Chau7Core
import Foundation
import SQLite3

/// Owns the telemetry database schema: table/index creation, the versioned
/// migration ladder, and the ingest-sequence trigger infrastructure.
///
/// Extracted from `TelemetryStore` (Stage 6 of `docs/SOLID-DRY-REVIEW.md`)
/// as a pure code move — the SQL, version transitions, idempotence behavior,
/// and log strings are byte-identical to the pre-split store.
///
/// Threading contract: the migrator operates on an injected connection and
/// performs no synchronization of its own. The caller (`TelemetryStore.open()`)
/// must invoke every method on the store's serial queue, exactly as the
/// original private methods were.
struct TelemetrySchemaMigrator {
    /// Current migration target. Bump this when adding new migrations.
    static let currentSchemaVersion = 5

    private static let ingestSequenceTables = [
        "runs",
        "usage_evidence",
        "remote_client_events",
        "provider_latency_samples"
    ]

    let db: OpaquePointer?

    func createTables() {
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
            total_cache_creation_input_tokens INTEGER,
            total_cache_read_input_tokens INTEGER,
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
            cache_creation_input_tokens INTEGER,
            cache_read_input_tokens INTEGER,
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

        CREATE TABLE IF NOT EXISTS usage_evidence (
            evidence_id TEXT PRIMARY KEY,
            unique_event_key TEXT NOT NULL,
            reconciliation_key TEXT NOT NULL,
            source_kind TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT,
            session_id TEXT,
            run_id TEXT,
            endpoint TEXT,
            project_path TEXT,
            input_tokens INTEGER,
            cache_creation_input_tokens INTEGER,
            cache_read_input_tokens INTEGER,
            output_tokens INTEGER,
            reasoning_output_tokens INTEGER,
            cost_usd REAL,
            token_usage_source TEXT,
            token_usage_state TEXT NOT NULL,
            cost_source TEXT,
            cost_state TEXT NOT NULL,
            pricing_version TEXT,
            source_ref TEXT,
            metadata TEXT,
            observed_at TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        );

        CREATE INDEX IF NOT EXISTS idx_usage_evidence_provider
            ON usage_evidence(provider, observed_at DESC);
        CREATE INDEX IF NOT EXISTS idx_usage_evidence_reconciliation
            ON usage_evidence(reconciliation_key, source_kind);
        CREATE INDEX IF NOT EXISTS idx_usage_evidence_run
            ON usage_evidence(run_id);

        CREATE TABLE IF NOT EXISTS provider_latency_samples (
            sample_id TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            metric_kind TEXT NOT NULL,
            latency_ms INTEGER NOT NULL,
            model TEXT,
            session_id TEXT,
            run_id TEXT,
            round_index INTEGER,
            project_path TEXT,
            source_kind TEXT NOT NULL,
            observed_at TEXT NOT NULL,
            created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
        );

        CREATE INDEX IF NOT EXISTS idx_provider_latency_samples_time
            ON provider_latency_samples(observed_at DESC);
        CREATE INDEX IF NOT EXISTS idx_provider_latency_samples_provider
            ON provider_latency_samples(provider, metric_kind, observed_at DESC);

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

    func schemaVersion() -> Int {
        guard let db else { return 0 }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT MAX(version) FROM schema_version", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    @discardableResult
    func setSchemaVersion(_ version: Int) -> Bool {
        guard let db else { return false }
        let sql = "INSERT OR IGNORE INTO schema_version (version) VALUES (?)"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            Log.warn("TelemetryStore: failed to prepare schema version \(version): \(sqliteError(db))")
            return false
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(version))
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            Log.warn("TelemetryStore: failed to record schema version \(version): \(sqliteError(db))")
            return false
        }
        return true
    }

    func applyMigrations() {
        guard let db else { return }
        let version = schemaVersion()
        guard version < Self.currentSchemaVersion else { return }

        // Version 1 → 2: add columns, backfill state fields, sanitize bad data
        if version < 2 {
            ensureColumn(table: "runs", name: "total_cached_input_tokens", definition: "INTEGER")
            ensureColumn(table: "runs", name: "total_cache_creation_input_tokens", definition: "INTEGER")
            ensureColumn(table: "runs", name: "total_cache_read_input_tokens", definition: "INTEGER")
            ensureColumn(table: "runs", name: "total_reasoning_output_tokens", definition: "INTEGER")
            ensureColumn(table: "runs", name: "token_usage_source", definition: "TEXT")
            ensureColumn(table: "runs", name: "token_usage_state", definition: "TEXT")
            ensureColumn(table: "runs", name: "cost_source", definition: "TEXT")
            ensureColumn(table: "runs", name: "cost_state", definition: "TEXT")

            ensureColumn(table: "turns", name: "cache_creation_input_tokens", definition: "INTEGER")
            ensureColumn(table: "turns", name: "cache_read_input_tokens", definition: "INTEGER")
            ensureColumn(table: "turns", name: "cached_input_tokens", definition: "INTEGER")
            ensureColumn(table: "turns", name: "reasoning_output_tokens", definition: "INTEGER")
            ensureColumn(table: "provider_latency_samples", name: "round_index", definition: "INTEGER")

            sqlite3_exec(
                db,
                """
                UPDATE runs
                SET token_usage_state = COALESCE(token_usage_state,
                    CASE
                        WHEN total_input_tokens IS NULL
                             AND total_cache_creation_input_tokens IS NULL
                             AND total_cache_read_input_tokens IS NULL
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
                    error_message = COALESCE(error_message, 'invalidated historical telemetry metrics that exceeded sanity thresholds')
                WHERE COALESCE(total_input_tokens, 0) > 100000000
                   OR COALESCE(total_cache_creation_input_tokens, 0) > 100000000
                   OR COALESCE(total_cache_read_input_tokens, 0) > 100000000
                   OR COALESCE(total_cached_input_tokens, 0) > 100000000
                   OR COALESCE(total_output_tokens, 0) > 100000000
                   OR COALESCE(total_reasoning_output_tokens, 0) > 100000000
                   OR (
                        COALESCE(total_input_tokens, 0) +
                        COALESCE(
                            total_cached_input_tokens,
                            COALESCE(total_cache_creation_input_tokens, 0) + COALESCE(total_cache_read_input_tokens, 0)
                        ) +
                        COALESCE(total_output_tokens, 0) +
                        COALESCE(total_reasoning_output_tokens, 0)
                      ) > 150000000
                """,
                nil,
                nil,
                nil
            )

            setSchemaVersion(2)
        }

        // Version 2 → 3: mark when transcript repair was last attempted so the
        // repair sweep stops re-reading/re-parsing the same immutable transcript
        // every cycle when its metrics can't be derived.
        if version < 3 {
            ensureColumn(table: "runs", name: "transcript_repair_attempted_at", definition: "TEXT")
            setSchemaVersion(3)
        }

        // Version 3 → 4: monotonic ingest sequence for deterministic ordering.
        // ISO-text timestamps collide at the same millisecond; ingest_seq is a
        // store-assigned insert counter used as an ORDER BY tiebreaker. Old
        // rows keep NULL (no backfill) — the tiebreaker only has to
        // disambiguate rows written after the migration.
        if version < 4 {
            ensureColumn(table: "runs", name: "ingest_seq", definition: "INTEGER")
            ensureColumn(table: "usage_evidence", name: "ingest_seq", definition: "INTEGER")
            ensureColumn(table: "remote_client_events", name: "ingest_seq", definition: "INTEGER")
            setSchemaVersion(4)
        }

        // Version 4 → 5: latency queries already use ingest_seq as their
        // same-timestamp tiebreaker, so the fourth telemetry table must join
        // the shared sequence. The v4 triggers embed the original three-table
        // MAX expression; IF NOT EXISTS cannot update that SQL, so rebuild all
        // four triggers atomically with the new column and version row.
        if version < 5, !migrateToVersion5() {
            Log.warn("TelemetryStore: telemetry schema v5 migration failed; retaining schema v4")
            return
        }

        ensureIngestSequenceInfrastructure()
    }

    /// Triggers assign ingest_seq at insert time from one shared counter
    /// (MAX across all sequenced tables), so no insert statement needs to know
    /// about the column. Idempotent (IF NOT EXISTS) and shared by fresh
    /// databases and migrated ones.
    @discardableResult
    func ensureIngestSequenceInfrastructure(rebuildTriggers: Bool = false) -> Bool {
        guard let db else { return false }

        let sharedSequenceQuery = Self.ingestSequenceTables.enumerated()
            .map { index, table in
                let prefix = index == 0 ? "" : "UNION ALL "
                return "\(prefix)SELECT MAX(ingest_seq) AS seq FROM \(table)"
            }
            .joined(separator: "\n                        ")

        for table in Self.ingestSequenceTables {
            if rebuildTriggers,
               sqlite3_exec(db, "DROP TRIGGER IF EXISTS trg_\(table)_ingest_seq", nil, nil, nil) != SQLITE_OK {
                Log.warn("TelemetryStore: failed to drop ingest_seq trigger for \(table): \(sqliteError(db))")
                return false
            }

            if sqlite3_exec(
                db,
                "CREATE INDEX IF NOT EXISTS idx_\(table)_ingest_seq ON \(table)(ingest_seq)",
                nil, nil, nil
            ) != SQLITE_OK {
                Log.warn("TelemetryStore: failed to create ingest_seq index for \(table): \(sqliteError(db))")
                return false
            }

            let trigger = """
            CREATE TRIGGER IF NOT EXISTS trg_\(table)_ingest_seq
            AFTER INSERT ON \(table)
            WHEN NEW.ingest_seq IS NULL
            BEGIN
                UPDATE \(table)
                SET ingest_seq = (
                    SELECT COALESCE(MAX(seq), 0) + 1 FROM (
                        \(sharedSequenceQuery)
                    )
                )
                WHERE rowid = NEW.rowid;
            END
            """
            if sqlite3_exec(db, trigger, nil, nil, nil) != SQLITE_OK {
                Log.warn("TelemetryStore: failed to create ingest_seq trigger for \(table): \(sqliteError(db))")
                return false
            }
        }
        return true
    }

    @discardableResult
    func ensureColumn(table: String, name: String, definition: String) -> Bool {
        guard let db else { return false }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else {
            Log.warn("TelemetryStore: failed to inspect column \(table).\(name): \(sqliteError(db))")
            return false
        }
        defer { sqlite3_finalize(stmt) }

        while sqlite3_step(stmt) == SQLITE_ROW {
            if let colName = sqlite3_column_text(stmt, 1), String(cString: colName) == name {
                return true
            }
        }

        let sql = "ALTER TABLE \(table) ADD COLUMN \(name) \(definition)"
        if sqlite3_exec(db, sql, nil, nil, nil) != SQLITE_OK {
            Log.warn("TelemetryStore: failed to add column \(table).\(name): \(sqliteError(db))")
            return false
        }
        return true
    }

    private func migrateToVersion5() -> Bool {
        guard let db else { return false }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            Log.warn("TelemetryStore: failed to begin telemetry schema v5 migration: \(sqliteError(db))")
            return false
        }

        var committed = false
        defer {
            if !committed {
                sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            }
        }

        guard ensureColumn(
            table: "provider_latency_samples",
            name: "ingest_seq",
            definition: "INTEGER"
        ), ensureIngestSequenceInfrastructure(rebuildTriggers: true), setSchemaVersion(5) else {
            return false
        }

        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            Log.warn("TelemetryStore: failed to commit telemetry schema v5 migration: \(sqliteError(db))")
            return false
        }
        committed = true
        return true
    }

    private func sqliteError(_ db: OpaquePointer) -> String {
        String(cString: sqlite3_errmsg(db))
    }
}
