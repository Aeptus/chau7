import XCTest
@testable import Chau7

/// Pin scheduling, supersession and cancellation by observing main-queue
/// callbacks rather than assuming a loaded CI host finishes in 150 ms.
@MainActor
final class EditorAutoSaverTests: XCTestCase {
    func testScheduledWorkRunsAfterDelay() async {
        let saver = EditorAutoSaver()
        let completed = expectation(description: "scheduled save")
        var ran = false
        saver.scheduleSave(after: 0.01) {
            ran = true
            completed.fulfill()
        }
        XCTAssertFalse(ran)
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertTrue(ran)
    }

    func testReschedulingSupersedesPreviousWork() async {
        let saver = EditorAutoSaver()
        let completed = expectation(description: "replacement save")
        var firstRan = false
        // Both work items are queued while this actor turn still owns main;
        // replacing the first happens before either callback can execute.
        saver.scheduleSave(after: 0) { firstRan = true }
        saver.scheduleSave(after: 0) { completed.fulfill() }
        await fulfillment(of: [completed], timeout: 3)
        XCTAssertFalse(firstRan, "First scheduled save must be cancelled")
    }

    func testCancelPendingSavePreventsRun() async {
        let saver = EditorAutoSaver()
        var ran = false
        saver.scheduleSave(after: 0) { ran = true }
        saver.cancelPendingSave()
        await drainMainQueue()
        XCTAssertFalse(ran)
    }

    func testStatusClearRunsAfterDelay() async {
        let saver = EditorAutoSaver()
        let completed = expectation(description: "status clear")
        saver.scheduleStatusClear(after: 0.01) { completed.fulfill() }
        await fulfillment(of: [completed], timeout: 3)
    }

    func testCancelStatusClearPreventsRun() async {
        let saver = EditorAutoSaver()
        var ran = false
        saver.scheduleStatusClear(after: 0) { ran = true }
        saver.cancelStatusClear()
        await drainMainQueue()
        XCTAssertFalse(ran)
    }

    private func drainMainQueue() async {
        let drained = expectation(description: "queued callbacks processed")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 3)
    }
}
