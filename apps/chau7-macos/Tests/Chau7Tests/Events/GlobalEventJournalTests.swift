import XCTest
@testable import Chau7Core

final class GlobalEventJournalTests: XCTestCase {

    private func makeSpine(capacity: Int) -> EventSpine {
        EventSpine(capacity: capacity)
    }

    private func ingest(_ spine: EventSpine, count: Int) {
        for i in 0 ..< count {
            spine.ingest(structural: StructuralEvent(type: "tab_created", subsystem: "tabs", detail: ["i": .number(Double(i))]))
        }
    }

    // MARK: - Cursor reads

    func testCursorReadReturnsOnlyNewerEnvelopes() {
        let spine = makeSpine(capacity: 10)
        ingest(spine, count: 5)

        let (envelopes, cursor, hasMore) = spine.journal.envelopes(after: 2, limit: 10)
        XCTAssertEqual(envelopes.map(\.seq), [3, 4, 5])
        XCTAssertEqual(cursor, 5)
        XCTAssertFalse(hasMore)
    }

    func testCursorReadRespectsLimitAndReportsHasMore() {
        let spine = makeSpine(capacity: 10)
        ingest(spine, count: 6)

        let (first, cursor, hasMore) = spine.journal.envelopes(after: 0, limit: 4)
        XCTAssertEqual(first.map(\.seq), [1, 2, 3, 4])
        XCTAssertTrue(hasMore)

        let (rest, finalCursor, finalHasMore) = spine.journal.envelopes(after: cursor, limit: 4)
        XCTAssertEqual(rest.map(\.seq), [5, 6])
        XCTAssertEqual(finalCursor, 6)
        XCTAssertFalse(finalHasMore)
    }

    func testCursorAtLatestReturnsNothing() {
        let spine = makeSpine(capacity: 10)
        ingest(spine, count: 3)
        let (envelopes, cursor, hasMore) = spine.journal.envelopes(after: 3, limit: 10)
        XCTAssertTrue(envelopes.isEmpty)
        XCTAssertEqual(cursor, 3)
        XCTAssertFalse(hasMore)
    }

    // MARK: - Replay across wrap (eviction)

    func testStaleCursorReadsFromOldestAvailableAfterWrap() {
        let spine = makeSpine(capacity: 4)
        ingest(spine, count: 10) // seqs 1...10; only 7...10 retained

        XCTAssertEqual(spine.journal.oldestAvailableCursor, 7)
        XCTAssertEqual(spine.journal.latestCursor, 10)
        XCTAssertEqual(spine.journal.count, 4)

        // Cursor 2 is long evicted — read resumes from oldest available.
        let (envelopes, cursor, hasMore) = spine.journal.envelopes(after: 2, limit: 10)
        XCTAssertEqual(envelopes.map(\.seq), [7, 8, 9, 10])
        XCTAssertEqual(cursor, 10)
        XCTAssertFalse(hasMore)
    }

    func testSequenceSurvivesEviction() {
        let spine = makeSpine(capacity: 2)
        ingest(spine, count: 5)
        XCTAssertEqual(spine.journal.latestCursor, 5, "seq space must be monotonic across eviction")
        let (envelopes, _, _) = spine.journal.envelopes(after: 0, limit: 10)
        XCTAssertEqual(envelopes.map(\.seq), [4, 5])
    }

    // MARK: - Empty journal

    func testEmptyJournalBehaviour() {
        let spine = makeSpine(capacity: 4)
        XCTAssertEqual(spine.journal.latestCursor, 0)
        XCTAssertEqual(spine.journal.oldestAvailableCursor, 0)
        XCTAssertEqual(spine.journal.count, 0)
        let (envelopes, cursor, hasMore) = spine.journal.envelopes(after: 0, limit: 10)
        XCTAssertTrue(envelopes.isEmpty)
        XCTAssertEqual(cursor, 0)
        XCTAssertFalse(hasMore)
    }
}
