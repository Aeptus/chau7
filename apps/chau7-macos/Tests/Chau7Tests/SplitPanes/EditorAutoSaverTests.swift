import XCTest
@testable import Chau7

/// Direct tests for the extracted EditorAutoSaver. The integration path is
/// covered through TextEditorModel by AttachedSessionNoteTests and
/// CloseDirtyEditorPolicyTests; these tests pin the work-item scheduling
/// contract — schedule supersedes, cancel skips the run — without the
/// model in the picture.
final class EditorAutoSaverTests: XCTestCase {

    func testScheduledWorkRunsAfterDelay() {
        let saver = EditorAutoSaver()
        var ran = false

        saver.scheduleSave(after: 0.05) { ran = true }

        // The dispatched work won't fire until the run loop spins.
        XCTAssertFalse(ran)
        spinRunLoop(seconds: 0.15)
        XCTAssertTrue(ran)
    }

    func testReschedulingSupersedesPreviousWork() {
        let saver = EditorAutoSaver()
        var firstRan = false
        var secondRan = false

        saver.scheduleSave(after: 0.1) { firstRan = true }
        // Reschedule before the first deadline fires — first must be cancelled.
        saver.scheduleSave(after: 0.05) { secondRan = true }

        spinRunLoop(seconds: 0.25)
        XCTAssertFalse(firstRan, "First scheduled save must be cancelled")
        XCTAssertTrue(secondRan)
    }

    func testCancelPendingSavePreventsRun() {
        let saver = EditorAutoSaver()
        var ran = false

        saver.scheduleSave(after: 0.05) { ran = true }
        saver.cancelPendingSave()

        spinRunLoop(seconds: 0.2)
        XCTAssertFalse(ran)
    }

    func testStatusClearRunsAfterDelay() {
        let saver = EditorAutoSaver()
        var ran = false

        saver.scheduleStatusClear(after: 0.05) { ran = true }
        spinRunLoop(seconds: 0.15)
        XCTAssertTrue(ran)
    }

    func testCancelStatusClearPreventsRun() {
        let saver = EditorAutoSaver()
        var ran = false

        saver.scheduleStatusClear(after: 0.05) { ran = true }
        saver.cancelStatusClear()

        spinRunLoop(seconds: 0.2)
        XCTAssertFalse(ran)
    }

    private func spinRunLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }
}
