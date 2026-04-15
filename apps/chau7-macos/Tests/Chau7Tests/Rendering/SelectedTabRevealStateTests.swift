import XCTest
@testable import Chau7Core

final class SelectedTabRevealStateTests: XCTestCase {
    func testSelectingSnapshotBackedTabStartsRevealHandoff() {
        var state = SelectedTabRevealState()
        let tabID = UUID()

        let started = state.select(tabID: tabID, hasSnapshot: true, now: 10)

        XCTAssertTrue(started)
        XCTAssertEqual(state.selectedTabID, tabID)
        XCTAssertEqual(state.phase, .showingSnapshot)
        XCTAssertEqual(state.generation, 1)
        XCTAssertFalse(state.isTerminalReady)
    }

    func testSelectingLiveTabSkipsRevealHandoff() {
        var state = SelectedTabRevealState()
        let tabID = UUID()

        let started = state.select(tabID: tabID, hasSnapshot: false, now: 10)

        XCTAssertFalse(started)
        XCTAssertEqual(state.selectedTabID, tabID)
        XCTAssertEqual(state.phase, .live)
        XCTAssertEqual(state.generation, 0)
        XCTAssertTrue(state.isTerminalReady)
    }

    func testLiveFramePresentationRecordedOnlyOnceForCurrentSnapshotReveal() {
        var state = SelectedTabRevealState()
        let tabID = UUID()
        _ = state.select(tabID: tabID, hasSnapshot: true, now: 10)

        XCTAssertTrue(state.noteLiveFramePresented(for: tabID, now: 10.2))
        XCTAssertFalse(state.noteLiveFramePresented(for: tabID, now: 10.4))
        XCTAssertFalse(state.noteLiveFramePresented(for: UUID(), now: 10.5))
    }

    func testCommitLiveRevealCalculatesRevealTimings() {
        var state = SelectedTabRevealState()
        let tabID = UUID()
        _ = state.select(tabID: tabID, hasSnapshot: true, now: 10)
        _ = state.noteLiveFramePresented(for: tabID, now: 10.15)

        let completion = state.commitLiveReveal(for: tabID, now: 10.18)

        XCTAssertEqual(completion?.tabID, tabID)
        XCTAssertEqual(completion?.totalMs, 180)
        XCTAssertEqual(completion?.postPresentMs, 30)
        XCTAssertEqual(state.phase, .live)
        XCTAssertTrue(state.isTerminalReady)
    }

    func testForceLiveRevealCompletesWithoutPresentedFrame() {
        var state = SelectedTabRevealState()
        let tabID = UUID()
        _ = state.select(tabID: tabID, hasSnapshot: true, now: 10)

        let completion = state.forceLiveReveal(for: tabID, now: 10.25)

        XCTAssertEqual(completion?.tabID, tabID)
        XCTAssertEqual(completion?.totalMs, 250)
        XCTAssertNil(completion?.postPresentMs)
        XCTAssertEqual(state.phase, .live)
    }

    func testClearSelectionResetsRevealState() {
        var state = SelectedTabRevealState(selectedTabID: UUID(), phase: .showingSnapshot, generation: 3, startedAt: 10, firstFramePresentedAt: 10.1)

        state.clearSelection()

        XCTAssertNil(state.selectedTabID)
        XCTAssertEqual(state.phase, .live)
        XCTAssertEqual(state.generation, 3)
        XCTAssertNil(state.startedAt)
        XCTAssertNil(state.firstFramePresentedAt)
    }
}
