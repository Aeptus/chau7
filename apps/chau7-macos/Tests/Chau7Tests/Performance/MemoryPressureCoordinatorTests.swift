import XCTest
@testable import Chau7

final class MemoryPressureCoordinatorTests: XCTestCase {
    private final class FakeReclaimable: MemoryReclaimable {
        private(set) var lastLevel: MemoryPressureLevel?
        let bytesToReturn: Int
        init(bytes: Int) {
            self.bytesToReturn = bytes
        }

        func reclaimMemory(_ level: MemoryPressureLevel) -> Int {
            lastLevel = level
            return bytesToReturn
        }
    }

    func testReclaimSumsAcrossRegistrantsAndForwardsLevel() {
        let coordinator = MemoryPressureCoordinator()
        let a = FakeReclaimable(bytes: 100)
        let b = FakeReclaimable(bytes: 250)
        coordinator.register(a)
        coordinator.register(b)

        XCTAssertEqual(coordinator.reclaim(.critical), 350)
        XCTAssertEqual(a.lastLevel, .critical)
        XCTAssertEqual(b.lastLevel, .critical)
        XCTAssertEqual(coordinator.registrantCount, 2)
    }

    func testDeallocatedRegistrantsArePruned() {
        let coordinator = MemoryPressureCoordinator()
        var transient: FakeReclaimable? = FakeReclaimable(bytes: 10)
        coordinator.register(transient!)
        let survivor = FakeReclaimable(bytes: 5)
        coordinator.register(survivor)
        XCTAssertEqual(coordinator.registrantCount, 2)

        transient = nil
        XCTAssertEqual(coordinator.reclaim(.warning), 5, "a freed registrant contributes nothing")
        XCTAssertEqual(coordinator.registrantCount, 1)
    }

    func testRegisterIsIdempotentPerInstance() {
        let coordinator = MemoryPressureCoordinator()
        let a = FakeReclaimable(bytes: 7)
        coordinator.register(a)
        coordinator.register(a)
        XCTAssertEqual(coordinator.registrantCount, 1)
        XCTAssertEqual(coordinator.reclaim(.warning), 7)
    }

    // MARK: - TerminalTranscriptCapture as a reclaimable

    func testTranscriptCaptureCriticalReleasesEntireRingViaCoordinator() {
        let coordinator = MemoryPressureCoordinator()
        let capture = TerminalTranscriptCapture(maxBytes: 1_000_000, memoryPressureCoordinator: coordinator)
        capture.append(Data(repeating: 0x41, count: 4000))
        XCTAssertFalse(capture.isEmpty)

        XCTAssertEqual(coordinator.reclaim(.critical), 4000)
        XCTAssertTrue(capture.isEmpty)
    }

    func testTranscriptCaptureWarningDropsOlderHalf() {
        let capture = TerminalTranscriptCapture(
            maxBytes: 1_000_000,
            memoryPressureCoordinator: MemoryPressureCoordinator()
        )
        capture.append(Data(repeating: 0x41, count: 4000))

        XCTAssertEqual(capture.reclaimMemory(.warning), 2000)
        XCTAssertEqual(capture.tailData(maxBytes: 10000).count, 2000)
    }
}
