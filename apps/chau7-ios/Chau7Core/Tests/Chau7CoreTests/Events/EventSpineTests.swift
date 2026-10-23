import XCTest
@testable import Chau7Core

final class EventSpineTests: XCTestCase {

    private func makeAIEvent(
        type: String = "finished",
        ts: String = DateFormatters.nowISO8601()
    ) -> AIEvent {
        AIEvent(source: .claudeCode, type: type, tool: "Claude Code", message: "done", ts: ts)
    }

    // MARK: - Sequencing

    func testIngestAllocatesDenseMonotonicSequences() {
        let spine = EventSpine()
        let first = spine.ingest(makeAIEvent())
        let second = spine.ingest(structural: StructuralEvent(type: "tab_created", subsystem: "tabs"))
        let third = spine.ingest(makeAIEvent())

        XCTAssertEqual(first.seq, 1)
        XCTAssertEqual(second.seq, 2)
        XCTAssertEqual(third.seq, 3)
        XCTAssertEqual(spine.journal.latestCursor, 3)
    }

    func testConcurrentProducersGetUniqueDenseSequences() {
        let spine = EventSpine()
        let producers = 8
        let perProducer = 250
        let group = DispatchGroup()

        for _ in 0 ..< producers {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0 ..< perProducer {
                    spine.ingest(self.makeAIEvent())
                }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 10), .success)

        let total = UInt64(producers * perProducer)
        XCTAssertEqual(spine.journal.latestCursor, total)

        // Replay the whole journal (capacity default 2000 == total) and assert
        // seqs are dense 1...total.
        let spineCapacityTotal = Int(total)
        let (envelopes, _, hasMore) = spine.journal.envelopes(after: 0, limit: spineCapacityTotal)
        XCTAssertFalse(hasMore)
        XCTAssertEqual(envelopes.map(\.seq), Array(1 ... total))
    }

    // MARK: - Timestamps

    func testIngestPreservesProducerOccurredAtAndStampsIngestedAt() {
        let spine = EventSpine()
        let producerTime = Date(timeIntervalSince1970: 1_700_000_000)
        let ts = DateFormatters.iso8601.string(from: producerTime)

        let before = Date()
        let envelope = spine.ingest(makeAIEvent(ts: ts))
        let after = Date()

        XCTAssertEqual(envelope.occurredAt, producerTime, "occurredAt must be the producer's event time, not ingest time")
        XCTAssertGreaterThanOrEqual(envelope.ingestedAt, before)
        XCTAssertLessThanOrEqual(envelope.ingestedAt, after)
    }

    func testIngestFallsBackToIngestTimeForUnparseableTimestamp() {
        let spine = EventSpine()
        let envelope = spine.ingest(makeAIEvent(ts: "garbage"))
        XCTAssertEqual(envelope.occurredAt, envelope.ingestedAt)
    }

    func testStructuralIngestHonorsExplicitOccurredAt() {
        let spine = EventSpine()
        let occurred = Date(timeIntervalSince1970: 1_600_000_000)
        let envelope = spine.ingest(
            structural: StructuralEvent(type: "telemetry_run_started", subsystem: "telemetry"),
            occurredAt: occurred
        )
        XCTAssertEqual(envelope.occurredAt, occurred)
    }

    // MARK: - Identity

    func testAIEnvelopeReusesAIEventIdentity() {
        let spine = EventSpine()
        let event = makeAIEvent()
        let envelope = spine.ingest(event)
        XCTAssertEqual(envelope.eventID, event.id)
        XCTAssertEqual(envelope.aiEvent, event)
    }

    func testCorrelationIDIsCarried() {
        let spine = EventSpine()
        let envelope = spine.ingest(makeAIEvent(), correlationID: "corr-1")
        XCTAssertEqual(envelope.correlationID, "corr-1")
    }

    // MARK: - Topics assigned at ingest

    func testTopicsAssignedOnceAtIngest() {
        let spine = EventSpine()
        let envelope = spine.ingest(
            structural: StructuralEvent(type: "approval_waiting", subsystem: "mcp_approvals", tabID: "tab_1")
        )
        XCTAssertEqual(
            envelope.topics,
            [EventTopic.approvalState, EventTopic.runtimeEvents, EventTopic.tabState]
        )
    }

    // MARK: - Stream ordering

    func testStreamDeliversEnvelopesInSeqOrder() async {
        let spine = EventSpine()
        let producers = 4
        let perProducer = 100
        let total = producers * perProducer

        let collector = Task { () -> [UInt64] in
            var seqs: [UInt64] = []
            for await envelope in spine.envelopes {
                seqs.append(envelope.seq)
                if seqs.count == total { break }
            }
            return seqs
        }

        await withTaskGroup(of: Void.self) { group in
            for _ in 0 ..< producers {
                group.addTask {
                    for _ in 0 ..< perProducer {
                        spine.ingest(self.makeAIEvent())
                    }
                }
            }
        }

        let seqs = await collector.value
        XCTAssertEqual(seqs, Array(1 ... UInt64(total)), "stream order must equal seq order")
    }
}
