import Chau7Core
import XCTest

final class TranscriptRepairRetryGateTests: XCTestCase {
    func testDelayedFlushRetriesAtTwoTenAndSixtySeconds() {
        let gate = TranscriptRepairRetryGate()
        let start = Date(timeIntervalSince1970: 1000)
        for second in [2.0, 10, 60] {
            let now = start.addingTimeInterval(second)
            XCTAssertTrue(gate.begin("run", now: now))
            XCTAssertFalse(gate.begin("run", now: now), "concurrent sweeps must coalesce")
            gate.finish("run", succeeded: false, now: now)
            XCTAssertTrue(gate.deferredIDs(now: now).contains("run"), "cooled-down runs must not starve the next sweep page")
            XCTAssertFalse(gate.begin("run", now: now), "failed reads must back off")
        }
        XCTAssertFalse(gate.begin("run", now: start.addingTimeInterval(61)))
        XCTAssertTrue(gate.begin("run", now: start.addingTimeInterval(361)))
        gate.finish("run", succeeded: true, now: start.addingTimeInterval(361))
        XCTAssertFalse(gate.deferredIDs(now: start.addingTimeInterval(361)).contains("run"))
    }

    func testFailuresNeverPermanentlyDisableDiscoveryOrBlockAnotherRun() {
        XCTAssertEqual(TranscriptRepairRetryGate.delay(afterFailures: Int.max), 3600)
        let gate = TranscriptRepairRetryGate()
        let now = Date()
        XCTAssertTrue(gate.begin("first", now: now))
        gate.finish("first", succeeded: false, now: now)
        XCTAssertTrue(gate.begin("second", now: now))
        XCTAssertTrue(gate.begin("first", now: now.addingTimeInterval(3600)))
    }
}
