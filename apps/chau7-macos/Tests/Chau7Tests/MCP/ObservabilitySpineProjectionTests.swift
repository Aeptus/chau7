import XCTest
@testable import Chau7
@testable import Chau7Core

/// A4 contract: with a spine attached, Chau7ObservabilityService is a
/// projection — structural producers ingest into the spine, sequence numbers
/// derive from the global spine seq (offset past pre-attach records), and
/// timer changes share the same monotonic space as events.
@MainActor
final class ObservabilitySpineProjectionTests: XCTestCase {

    override func setUp() {
        super.setUp()
        Chau7ObservabilityService.shared.resetForTests()
    }

    override func tearDown() {
        Chau7ObservabilityService.shared.resetForTests()
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 5.0, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    private func latestSeq() -> Int64 {
        let json = Chau7ObservabilityService.shared.runtimeEventsJSON(sinceMillis: nil, limit: 500)
        let payload = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        return (payload?["latest_seq"] as? NSNumber)?.int64Value ?? -1
    }

    private func eventSeqsAndTypes() -> [(seq: Int64, type: String)] {
        let json = Chau7ObservabilityService.shared.runtimeEventsJSON(sinceMillis: nil, limit: 500)
        guard let payload = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let events = payload["events"] as? [[String: Any]] else { return [] }
        return events.compactMap { event in
            guard let seq = (event["seq"] as? NSNumber)?.int64Value,
                  let type = event["type"] as? String else { return nil }
            return (seq, type)
        }
    }

    func testStructuralRecordsRideTheSpineWithMonotonicFloor() {
        let service = Chau7ObservabilityService.shared

        // Pre-attach: two direct records consume the internal counter (1, 2).
        service.recordEvent(type: "app_launched", subsystem: "app_lifecycle")
        service.recordEvent(type: "build_activated", subsystem: "app_lifecycle")
        XCTAssertEqual(eventSeqsAndTypes().map(\.seq), [1, 2])

        // Attach a live spine with a pump (as bootstrap does).
        let spine = EventSpine()
        let host = EventSpineHost()
        host.start(spine: spine) { envelope in
            Chau7ObservabilityService.shared.apply(structural: envelope)
        }
        service.attachSpine(spine)

        // Post-attach records route through the spine…
        service.recordEvent(type: "tab_created", subsystem: "tabs", tabID: "tab_1")
        XCTAssertTrue(waitUntil { self.eventSeqsAndTypes().count == 3 })

        // …and their seqs continue monotonically past the pre-attach ones
        // (floor 2 + spine seq 1 = 3).
        let records = eventSeqsAndTypes()
        XCTAssertEqual(records.map(\.seq), [1, 2, 3])
        XCTAssertEqual(records.last?.type, "tab_created")
        // latest_seq must follow spine-derived records too (regression guard:
        // it previously read the internal counter, which spine mode bypasses).
        XCTAssertEqual(latestSeq(), 3)

        host.stop()
    }

    func testTimerChangesShareTheGlobalSequenceSpace() {
        let service = Chau7ObservabilityService.shared
        let spine = EventSpine()
        let host = EventSpineHost()
        host.start(spine: spine) { envelope in
            Chau7ObservabilityService.shared.apply(structural: envelope)
        }
        service.attachSpine(spine)

        service.recordEvent(type: "tab_created", subsystem: "tabs", tabID: "tab_1")
        service.registerTimer(
            id: "t1", kind: "dispatch", label: "test", subsystem: "tests",
            queueLabel: "q", intervalMs: 100, leewayMs: nil, active: true
        )
        service.recordEvent(type: "tab_closed", subsystem: "tabs", tabID: "tab_1")

        // Both events land in the ring; the timer registered in between.
        XCTAssertTrue(waitUntil { self.eventSeqsAndTypes().count == 2 })
        let seqs = eventSeqsAndTypes().map(\.seq)
        // Event seqs are 1 and 3 — seq 2 was consumed by the timer change,
        // proving one shared monotonic space (no parallel counter).
        XCTAssertEqual(seqs, [1, 3])

        // The timer landed in the inventory via the pump.
        XCTAssertTrue(waitUntil {
            let payload = Chau7ObservabilityService.shared.timerInventoryPayload()
            let timers = payload["timers"] as? [[String: Any]] ?? []
            return timers.contains { ($0["id"] as? String) == "t1" }
        })

        host.stop()
    }

    func testDetachedServiceKeepsLegacyDirectPath() {
        let service = Chau7ObservabilityService.shared
        // No spine attached: records apply synchronously with internal seqs.
        service.recordEvent(type: "approval_waiting", subsystem: "mcp_approvals")
        XCTAssertEqual(eventSeqsAndTypes().map(\.seq), [1])
        XCTAssertEqual(latestSeq(), 1)
    }
}
