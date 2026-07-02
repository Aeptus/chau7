import XCTest
@testable import Chau7
@testable import Chau7Core

/// The durable spine journal: envelopes survive "restarts" (new store over
/// the same file), the sequence space continues across generations, and
/// retention prunes from the oldest end.
final class SpineJournalStoreTests: XCTestCase {

    private var dbPath = ""

    override func setUp() {
        super.setUp()
        dbPath = NSTemporaryDirectory() + "spine-journal-tests-\(UUID().uuidString).db"
    }

    override func tearDown() {
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: dbPath + suffix)
        }
        super.tearDown()
    }

    private func makeEnvelope(seq: UInt64, message: String = "m") -> EventEnvelope {
        EventEnvelope(
            seq: seq,
            eventID: UUID(),
            correlationID: seq.isMultiple(of: 2) ? "corr-\(seq)" : nil,
            occurredAt: Date(timeIntervalSince1970: 1_751_000_000),
            ingestedAt: Date(timeIntervalSince1970: 1_751_000_001),
            topics: ["events.ai"],
            deliveryRequested: true,
            payload: .ai(AIEvent(
                source: .claudeCode,
                type: "finished",
                tool: "Claude Code",
                message: message,
                ts: "2026-07-02T00:00:00Z",
                sessionID: "s-\(seq)"
            ))
        )
    }

    func testPersistAndReadRoundTripsBothPayloadKinds() {
        let store = SpineJournalStore(path: dbPath)
        let ai = makeEnvelope(seq: 1, message: "hello")
        let structural = EventEnvelope(
            seq: 2,
            eventID: UUID(),
            correlationID: nil,
            occurredAt: Date(timeIntervalSince1970: 1_751_000_002),
            ingestedAt: Date(timeIntervalSince1970: 1_751_000_003),
            topics: ["structural.timers"],
            deliveryRequested: false,
            payload: .structural(StructuralEvent(
                type: "timer_changed",
                subsystem: "timers",
                detail: ["timer_id": .string("t1"), "active": .bool(true)]
            ))
        )
        store.persist(ai)
        store.persist(structural)
        store.waitForPendingWrites()

        let read = store.envelopes(after: 0)
        XCTAssertEqual(read, [ai, structural], "envelopes must round-trip byte-equal through Codable")
    }

    func testHighWaterSurvivesRestartAndSeedsSpineContinuity() {
        // Generation 1: a spine backed by the store ingests some events.
        let store1 = SpineJournalStore(path: dbPath)
        let spine1 = EventSpine(startSeq: store1.highWaterSeq())
        for i in 0 ..< 5 {
            let envelope = spine1.ingest(AIEvent(
                source: .claudeCode, type: "finished", tool: "Claude Code",
                message: "gen1-\(i)", ts: "2026-07-02T00:00:00Z", sessionID: "g1-\(i)"
            ))
            store1.persist(envelope)
        }
        store1.waitForPendingWrites()
        XCTAssertEqual(store1.highWaterSeq(), 5)

        // Generation 2 ("app restart"): a fresh store over the same file
        // seeds a fresh spine, and seqs continue — never reused, never
        // backwards. This is what keeps downstream state_version arbitration
        // monotonic across Mac app restarts.
        let store2 = SpineJournalStore(path: dbPath)
        let spine2 = EventSpine(startSeq: store2.highWaterSeq())
        let first = spine2.ingest(AIEvent(
            source: .codex, type: "finished", tool: "Codex",
            message: "gen2-0", ts: "2026-07-02T00:01:00Z", sessionID: "g2-0"
        ))
        store2.persist(first)
        store2.waitForPendingWrites()

        XCTAssertEqual(first.seq, 6, "new generation must continue the persisted sequence space")
        let all = store2.envelopes(after: 0, limit: 10)
        XCTAssertEqual(all.map(\.seq), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(all.last?.aiEvent?.message, "gen2-0")
    }

    func testCursorReadsSpanGenerations() {
        let store1 = SpineJournalStore(path: dbPath)
        for seq in 1 ... 4 {
            store1.persist(makeEnvelope(seq: UInt64(seq)))
        }
        store1.waitForPendingWrites()

        let store2 = SpineJournalStore(path: dbPath)
        let delta = store2.envelopes(after: 2)
        XCTAssertEqual(delta.map(\.seq), [3, 4], "a consumer's cursor stays valid across restarts")
    }

    func testPersistIsIdempotentPerSeq() {
        let store = SpineJournalStore(path: dbPath)
        let envelope = makeEnvelope(seq: 7)
        store.persist(envelope)
        store.persist(envelope)
        store.waitForPendingWrites()
        XCTAssertEqual(store.count(), 1)
    }

    func testRetentionPrunesOldestBeyondLimit() {
        let store = SpineJournalStore(path: dbPath, retentionLimit: 100)
        // Cross the prune batch threshold (512) with room to spare.
        for seq in 1 ... 700 {
            store.persist(makeEnvelope(seq: UInt64(seq)))
        }
        store.waitForPendingWrites()

        // Prune runs every 512 inserts, so the steady-state bound is
        // retentionLimit + batch threshold.
        XCTAssertLessThanOrEqual(store.count(), 100 + 512, "pruning must bound growth")
        XCTAssertGreaterThan(
            store.envelopes(after: 0, limit: 1).first?.seq ?? 0, 1,
            "the oldest rows must have been pruned"
        )
        XCTAssertEqual(store.highWaterSeq(), 700, "pruning never touches the newest rows")
        XCTAssertTrue(store.envelopes(after: 690).map(\.seq).contains(700))
    }
}
