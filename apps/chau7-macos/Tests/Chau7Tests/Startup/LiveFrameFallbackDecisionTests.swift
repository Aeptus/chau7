import XCTest
@testable import Chau7

/// SPM-runnable tests for `StartupRestoreCoordinator.shouldSynthesizeLiveFrameFallback`.
///
/// The fallback fires ~5s after `noteWindowVisible` and synthesizes a
/// live-frame for windows whose natural callback never arrived. The
/// decision is gated on two flags only — extracted as a pure function
/// so the rule is unit-testable without needing DispatchQueue timing.
final class LiveFrameFallbackDecisionTests: XCTestCase {

    /// Coordinator inactive: never synthesize. The fallback's whole purpose
    /// is unblocking startup-restore completion; once the coordinator has
    /// ended (post-startup steady state), there's nothing to unblock.
    func testCoordinatorInactiveNeverSynthesizes() {
        XCTAssertFalse(
            StartupRestoreCoordinator.shouldSynthesizeLiveFrameFallback(
                isCoordinatorActive: false,
                hasReportedLiveFrame: false
            )
        )
        // Even if a frame was somehow reported, no synthesis when inactive.
        XCTAssertFalse(
            StartupRestoreCoordinator.shouldSynthesizeLiveFrameFallback(
                isCoordinatorActive: false,
                hasReportedLiveFrame: true
            )
        )
    }

    /// Coordinator active, frame already reported: skip synthesis. The
    /// natural callback arrived first; synthesizing would either be a
    /// no-op (tracker dedups) or a misleading log line.
    func testActiveAndAlreadyReportedSkipsSynthesis() {
        XCTAssertFalse(
            StartupRestoreCoordinator.shouldSynthesizeLiveFrameFallback(
                isCoordinatorActive: true,
                hasReportedLiveFrame: true
            )
        )
    }

    /// Coordinator active, no frame yet: synthesize. This is the production
    /// scenario the fallback is designed for — window visible, but the
    /// `didBecomeMain → noteSelectedTabLiveFrame` callback chain never
    /// completed (e.g. multi-window startup with rapid main-window swaps).
    func testActiveAndMissingFrameSynthesizes() {
        XCTAssertTrue(
            StartupRestoreCoordinator.shouldSynthesizeLiveFrameFallback(
                isCoordinatorActive: true,
                hasReportedLiveFrame: false
            )
        )
    }

    /// Synthesis-delay constant is shorter than AppDelegate's 8s
    /// coordinator-end backstop. If this invariant breaks, the fallback
    /// becomes redundant — the coordinator-ended kick would fire first
    /// and the synthesis path becomes dead code.
    func testSynthesisDelayIsShorterThanCoordinatorEndBackstop() {
        XCTAssertLessThan(
            StartupRestoreCoordinator.liveFrameSynthesisDelay,
            8.0,
            "Live-frame fallback must fire before the AppDelegate coordinator-end backstop (8s) to be useful"
        )
        XCTAssertGreaterThanOrEqual(
            StartupRestoreCoordinator.liveFrameSynthesisDelay,
            3.0,
            "Live-frame fallback must give natural callbacks reasonable time to arrive (>=3s)"
        )
    }
}
