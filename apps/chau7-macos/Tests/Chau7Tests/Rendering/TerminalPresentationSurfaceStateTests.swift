import XCTest
@testable import Chau7Core

final class TerminalPresentationSurfaceStateTests: XCTestCase {
    func testBeginRevealStartsAwaitingLiveFramePhaseAndAwaitsVisibleFrame() {
        var state = TerminalPresentationSurfaceState()

        let started = state.beginReveal(shouldAwaitVisibleFrame: true, now: 10)

        XCTAssertTrue(started)
        XCTAssertEqual(state.phase, .awaitingLiveFrame)
        XCTAssertEqual(state.generation, 1)
        XCTAssertFalse(state.isLivePresentable)
        XCTAssertTrue(state.awaitingVisibleFrameReady)
    }

    func testBeginLiveRevealWithoutAwaitingKeepsSurfaceLive() {
        var state = TerminalPresentationSurfaceState()

        let started = state.beginReveal(shouldAwaitVisibleFrame: false, now: 10)

        XCTAssertFalse(started)
        XCTAssertEqual(state.phase, .live)
        XCTAssertEqual(state.generation, 0)
        XCTAssertTrue(state.isLivePresentable)
        XCTAssertFalse(state.awaitingVisibleFrameReady)
    }

    func testVisibleFramePresentationClearsAwaitingFlagAndRecordsFirstFrame() {
        var state = TerminalPresentationSurfaceState()
        _ = state.beginReveal(shouldAwaitVisibleFrame: true, now: 10)

        XCTAssertTrue(state.noteVisibleFramePresented(now: 10.2))
        XCTAssertFalse(state.awaitingVisibleFrameReady)
        XCTAssertEqual(state.firstFramePresentedAt, 10.2)
        XCTAssertEqual(state.lastVisibleFramePresentedAt, 10.2)
        XCTAssertFalse(state.noteVisibleFramePresented(now: 10.4))
    }

    func testCommitLiveRevealComputesTimingAndReturnsToLive() {
        var state = TerminalPresentationSurfaceState()
        _ = state.beginReveal(shouldAwaitVisibleFrame: true, now: 10)
        _ = state.noteVisibleFramePresented(now: 10.15)

        let completion = state.commitLiveReveal(now: 10.18)

        XCTAssertEqual(completion?.totalMs, 180)
        XCTAssertEqual(completion?.postPresentMs, 30)
        XCTAssertEqual(state.phase, .live)
        XCTAssertTrue(state.isLivePresentable)
        XCTAssertFalse(state.awaitingVisibleFrameReady)
        XCTAssertNil(state.firstFramePresentedAt)
        XCTAssertEqual(state.lastVisibleFramePresentedAt, 10.15)
    }

    func testForceLiveRevealWithoutPresentedFrameClearsAwaitingState() {
        var state = TerminalPresentationSurfaceState()
        _ = state.beginReveal(shouldAwaitVisibleFrame: true, now: 10)

        let completion = state.forceLiveReveal(now: 10.25)

        XCTAssertEqual(completion?.totalMs, 250)
        XCTAssertNil(completion?.postPresentMs)
        XCTAssertEqual(state.phase, .live)
        XCTAssertFalse(state.awaitingVisibleFrameReady)
    }

    func testForceLiveRevealCanPreserveVisibleFrameHandoffForStartupTimeout() {
        var state = TerminalPresentationSurfaceState()
        _ = state.beginReveal(shouldAwaitVisibleFrame: true, now: 10)

        let completion = state.forceLiveReveal(
            now: 10.25,
            preserveVisibleFrameHandoff: true
        )

        XCTAssertEqual(completion?.totalMs, 250)
        XCTAssertNil(completion?.postPresentMs)
        XCTAssertEqual(state.phase, .live)
        XCTAssertTrue(state.awaitingVisibleFrameReady)
        XCTAssertNil(state.firstFramePresentedAt)
        XCTAssertNil(state.lastVisibleFramePresentedAt)

        XCTAssertTrue(state.noteVisibleFramePresented(now: 10.3))
        XCTAssertFalse(state.awaitingVisibleFrameReady)
        XCTAssertNil(
            state.firstFramePresentedAt,
            "The reveal was already forced live, but the later real frame must remain replayable."
        )
        XCTAssertEqual(state.lastVisibleFramePresentedAt, 10.3)
    }

    func testBeginRevealClearsPreviousVisibleFrameReplayMarker() {
        var state = TerminalPresentationSurfaceState()
        _ = state.beginReveal(shouldAwaitVisibleFrame: true, now: 10)
        _ = state.noteVisibleFramePresented(now: 10.2)
        _ = state.commitLiveReveal(now: 10.25)

        _ = state.beginReveal(shouldAwaitVisibleFrame: true, now: 20)

        XCTAssertNil(state.firstFramePresentedAt)
        XCTAssertNil(state.lastVisibleFramePresentedAt)
        XCTAssertTrue(state.awaitingVisibleFrameReady)
    }
}
