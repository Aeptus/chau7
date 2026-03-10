import XCTest
@testable import Chau7Core

final class EventJournalTests: XCTestCase {

    // MARK: - Basic Operations

    func testEmptyJournal() {
        let journal = EventJournal()
        XCTAssertEqual(journal.latestCursor, 0)
        XCTAssertEqual(journal.count, 0)

        let (events, cursor, hasMore) = journal.events(after: 0)
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(cursor, 0)
        XCTAssertFalse(hasMore)
    }

    func testAppendAndRead() {
        let journal = EventJournal()
        let e1 = journal.append(sessionID: "s1", turnID: nil, type: "session_ready")
        XCTAssertEqual(e1.seq, 1)
        XCTAssertEqual(e1.sessionID, "s1")
        XCTAssertEqual(e1.type, "session_ready")

        let e2 = journal.append(sessionID: "s1", turnID: "t1", type: "turn_started")
        XCTAssertEqual(e2.seq, 2)

        XCTAssertEqual(journal.latestCursor, 2)
        XCTAssertEqual(journal.count, 2)
    }

    func testCursorBasedReading() {
        let journal = EventJournal()
        journal.append(sessionID: "s1", turnID: nil, type: "a")
        journal.append(sessionID: "s1", turnID: nil, type: "b")
        journal.append(sessionID: "s1", turnID: nil, type: "c")

        // Read all from start
        let (all, cursor1, _) = journal.events(after: 0)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.map(\.type), ["a", "b", "c"])
        XCTAssertEqual(cursor1, 3)

        // Read after cursor 2 — should get only "c"
        let (tail, cursor2, _) = journal.events(after: 2)
        XCTAssertEqual(tail.count, 1)
        XCTAssertEqual(tail[0].type, "c")
        XCTAssertEqual(cursor2, 3)

        // Read after latest — nothing new
        let (empty, cursor3, _) = journal.events(after: 3)
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(cursor3, 3)
    }

    func testLimitParameter() {
        let journal = EventJournal()
        for i in 1...10 {
            journal.append(sessionID: "s1", turnID: nil, type: "e\(i)")
        }

        let (batch, cursor, hasMore) = journal.events(after: 0, limit: 3)
        XCTAssertEqual(batch.count, 3)
        XCTAssertEqual(batch.map(\.type), ["e1", "e2", "e3"])
        XCTAssertEqual(cursor, 3)
        XCTAssertTrue(hasMore)

        // Continue from cursor
        let (batch2, cursor2, hasMore2) = journal.events(after: cursor, limit: 3)
        XCTAssertEqual(batch2.count, 3)
        XCTAssertEqual(batch2.map(\.type), ["e4", "e5", "e6"])
        XCTAssertEqual(cursor2, 6)
        XCTAssertTrue(hasMore2)
    }

    // MARK: - Ring Buffer Eviction

    func testRingBufferEviction() {
        let journal = EventJournal(capacity: 5)

        // Fill exactly to capacity
        for i in 1...5 {
            journal.append(sessionID: "s1", turnID: nil, type: "e\(i)")
        }
        XCTAssertEqual(journal.count, 5)
        XCTAssertEqual(journal.latestCursor, 5)

        // Add 3 more — first 3 should be evicted
        for i in 6...8 {
            journal.append(sessionID: "s1", turnID: nil, type: "e\(i)")
        }
        XCTAssertEqual(journal.count, 5)
        XCTAssertEqual(journal.latestCursor, 8)

        // Reading from 0 should get the 5 surviving events
        let (events, cursor, _) = journal.events(after: 0)
        XCTAssertEqual(events.count, 5)
        XCTAssertEqual(events.map(\.type), ["e4", "e5", "e6", "e7", "e8"])
        XCTAssertEqual(cursor, 8)
    }

    func testOldCursorGetsOldestAvailable() {
        let journal = EventJournal(capacity: 3)

        for i in 1...10 {
            journal.append(sessionID: "s1", turnID: nil, type: "e\(i)")
        }

        // Cursor 2 is long gone — should get from oldest available
        let (events, _, _) = journal.events(after: 2)
        XCTAssertTrue(events.count <= 3)
        // All returned events should have seq > 7 (the 3 retained are 8, 9, 10)
        for event in events {
            XCTAssertGreaterThan(event.seq, 7)
        }
    }

    // MARK: - Data Payload

    func testEventDataPayload() {
        let journal = EventJournal()
        let event = journal.append(
            sessionID: "s1",
            turnID: "t1",
            type: "tool_use",
            data: ["tool": "Write", "file": "main.swift"]
        )
        XCTAssertEqual(event.data["tool"], "Write")
        XCTAssertEqual(event.data["file"], "main.swift")
        XCTAssertEqual(event.turnID, "t1")
    }

    // MARK: - Thread Safety

    func testConcurrentAppendAndRead() {
        let journal = EventJournal(capacity: 100)
        let iterations = 500
        let expectation = self.expectation(description: "concurrent")
        expectation.expectedFulfillmentCount = 3

        // Writer 1
        DispatchQueue.global().async {
            for i in 0..<iterations {
                journal.append(sessionID: "s1", turnID: nil, type: "w1_\(i)")
            }
            expectation.fulfill()
        }

        // Writer 2
        DispatchQueue.global().async {
            for i in 0..<iterations {
                journal.append(sessionID: "s1", turnID: nil, type: "w2_\(i)")
            }
            expectation.fulfill()
        }

        // Reader
        DispatchQueue.global().async {
            var cursor: UInt64 = 0
            var totalRead = 0
            for _ in 0..<200 {
                let (events, newCursor, _) = journal.events(after: cursor, limit: 50)
                cursor = newCursor
                totalRead += events.count
                // Verify monotonic sequence
                if events.count > 1 {
                    for i in 1..<events.count {
                        XCTAssertGreaterThan(events[i].seq, events[i - 1].seq)
                    }
                }
            }
            expectation.fulfill()
        }

        waitForExpectations(timeout: 10)
        XCTAssertEqual(journal.latestCursor, UInt64(iterations * 2))
    }

    // MARK: - Edge Cases

    func testSingleCapacity() {
        let journal = EventJournal(capacity: 1)
        journal.append(sessionID: "s1", turnID: nil, type: "first")
        journal.append(sessionID: "s1", turnID: nil, type: "second")

        XCTAssertEqual(journal.count, 1)
        let (events, _, _) = journal.events(after: 0)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].type, "second")
    }

    func testOldestAvailableCursor() {
        let journal = EventJournal(capacity: 3)

        XCTAssertEqual(journal.oldestAvailableCursor, 0)

        journal.append(sessionID: "s1", turnID: nil, type: "a")
        XCTAssertEqual(journal.oldestAvailableCursor, 1)

        journal.append(sessionID: "s1", turnID: nil, type: "b")
        journal.append(sessionID: "s1", turnID: nil, type: "c")
        XCTAssertEqual(journal.oldestAvailableCursor, 1)

        // Wrap around — oldest should advance
        journal.append(sessionID: "s1", turnID: nil, type: "d")
        XCTAssertEqual(journal.oldestAvailableCursor, 2)
    }
}
