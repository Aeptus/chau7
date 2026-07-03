import Chau7Core
import Foundation
import SQLite3

/// Durable backing for the event spine: every envelope the in-memory
/// `GlobalEventJournal` ring holds transiently is also appended here, so
/// event history survives app restarts and the global sequence space stays
/// monotonic across process generations.
///
/// On launch, `highWaterSeq()` seeds `EventSpine(startSeq:)` — the first
/// envelope of the new run continues where the previous run stopped. That
/// continuity is load-bearing downstream: the remote agent stamps
/// `state_version` from spine seqs, and the iOS reconciler's version
/// arbitration assumes versions never go backwards.
///
/// Writes happen on a dedicated serial queue (the spine pump must never
/// block on disk); reads snapshot through the same queue.
final class SpineJournalStore {

    static let shared = SpineJournalStore()

    /// Retained envelope count; the oldest rows beyond this are pruned in
    /// batches so the prune cost stays amortized.
    private let retentionLimit: Int
    private let pruneBatchThreshold = 512

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.chau7.spine.journal", qos: .utility)
    private var insertsSincePruneCheck = 0
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private static var defaultDBPath: String {
        // Isolated test processes get an ephemeral per-process journal so
        // tests never read or pollute the user's real spine history (same
        // guard pattern as the other side-effectful singletons).
        if RuntimeIsolation.isIsolatedTestMode() {
            return NSTemporaryDirectory() + "chau7-spine-tests-\(ProcessInfo.processInfo.processIdentifier).db"
        }
        let dir = RuntimeIsolation.chau7Directory()
            .appendingPathComponent("events", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("spine-journal.db").path
    }

    convenience init() {
        self.init(path: Self.defaultDBPath)
    }

    /// Injectable path + retention for tests.
    init(path: String, retentionLimit: Int = 50000) {
        self.retentionLimit = retentionLimit
        queue.sync { self.open(path: path) }
    }

    deinit {
        // Close after in-flight writes drain, without deinit blocking on the
        // queue — `queue.sync` here is a latent deadlock if the last strong
        // reference is ever released from a task running on `queue` itself.
        let db = self.db
        queue.async {
            if let db {
                sqlite3_close(db)
            }
        }
    }

    // MARK: - Writes

    /// Appends the envelope asynchronously. Seq is the primary key; replays
    /// of an already-persisted seq are ignored (INSERT OR IGNORE), which
    /// makes the call idempotent if a pump restart re-delivers.
    func persist(_ envelope: EventEnvelope) {
        queue.async { [self] in
            guard db != nil else { return }
            guard let payload = try? encoder.encode(envelope) else {
                Log.error("SpineJournalStore: failed to encode envelope seq=\(envelope.seq)")
                return
            }
            let sql = """
            INSERT OR IGNORE INTO envelopes (seq, event_id, correlation_id, ingested_at, envelope_json)
            VALUES (?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(bitPattern: envelope.seq))
            bindText(stmt, 2, envelope.eventID.uuidString)
            if let correlationID = envelope.correlationID {
                bindText(stmt, 3, correlationID)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            sqlite3_bind_double(stmt, 4, envelope.ingestedAt.timeIntervalSince1970)
            payload.withUnsafeBytes { bytes in
                _ = sqlite3_bind_blob(stmt, 5, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            }
            if sqlite3_step(stmt) != SQLITE_DONE {
                Log.error("SpineJournalStore: insert failed for seq=\(envelope.seq)")
            }
            insertsSincePruneCheck += 1
            if insertsSincePruneCheck >= pruneBatchThreshold {
                insertsSincePruneCheck = 0
                pruneLocked()
            }
        }
    }

    // MARK: - Reads

    /// The highest persisted seq (0 if empty). Used to seed
    /// `EventSpine(startSeq:)` at launch.
    func highWaterSeq() -> UInt64 {
        queue.sync {
            scalar("SELECT COALESCE(MAX(seq), 0) FROM envelopes").map { UInt64(bitPattern: $0) } ?? 0
        }
    }

    /// The number of retained envelopes.
    func count() -> Int {
        queue.sync {
            scalar("SELECT COUNT(*) FROM envelopes").map(Int.init) ?? 0
        }
    }

    /// Envelopes with seq strictly greater than `cursor`, oldest first —
    /// the durable equivalent of `GlobalEventJournal.envelopes(after:)`,
    /// spanning process restarts.
    func envelopes(after cursor: UInt64, limit: Int = 100) -> [EventEnvelope] {
        queue.sync {
            guard db != nil else { return [] }
            let sql = "SELECT envelope_json FROM envelopes WHERE seq > ? ORDER BY seq ASC LIMIT ?"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_int64(stmt, 1, Int64(bitPattern: cursor))
            sqlite3_bind_int64(stmt, 2, Int64(limit))
            var result: [EventEnvelope] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let blob = sqlite3_column_blob(stmt, 0) else { continue }
                let length = Int(sqlite3_column_bytes(stmt, 0))
                let data = Data(bytes: blob, count: length)
                if let envelope = try? decoder.decode(EventEnvelope.self, from: data) {
                    result.append(envelope)
                }
            }
            return result
        }
    }

    /// Blocks until all previously enqueued writes have landed. Test hook.
    func waitForPendingWrites() {
        queue.sync {}
    }

    // MARK: - Private

    private func open(path: String) {
        guard sqlite3_open(path, &db) == SQLITE_OK else {
            Log.error("SpineJournalStore: failed to open database at \(path)")
            db = nil
            return
        }
        sqlite3_exec(db, "PRAGMA journal_mode=WAL", nil, nil, nil)
        sqlite3_exec(db, "PRAGMA synchronous=NORMAL", nil, nil, nil)
        let create = """
        CREATE TABLE IF NOT EXISTS envelopes (
            seq INTEGER PRIMARY KEY,
            event_id TEXT NOT NULL,
            correlation_id TEXT,
            ingested_at REAL NOT NULL,
            envelope_json BLOB NOT NULL
        )
        """
        if sqlite3_exec(db, create, nil, nil, nil) != SQLITE_OK {
            Log.error("SpineJournalStore: failed to create envelopes table")
        }
    }

    /// Caller must be on `queue`.
    private func pruneLocked() {
        let sql = """
        DELETE FROM envelopes WHERE seq <= (
            SELECT COALESCE(MAX(seq), 0) - ? FROM envelopes
        )
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, Int64(retentionLimit))
        _ = sqlite3_step(stmt)
    }

    /// Caller must be on `queue`.
    private func scalar(_ sql: String) -> Int64? {
        guard db != nil else { return nil }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private func bindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }
}
