import XCTest
@testable import Chau7

/// SPM-runnable tests for `TerminalSessionModel.shouldForceClearShellLoadingForOSC7Deadlock`.
///
/// The decision controls when resume-prefill aborts waiting for OSC 7
/// (directory-report) and unblocks the typed `claude --resume` /
/// `codex resume` command. Threshold is conditional on whether startup-
/// restore is active because multi-tab cold boot demonstrably runs longer
/// than the post-startup steady-state threshold.
final class OSC7DeadlockDecisionTests: XCTestCase {

    // MARK: - isShellLoading guard

    /// If the shell is not loading, no force-clear regardless of retry count.
    /// (Other code paths handle non-loading state; this gate would be
    /// redundant noise in the log.)
    func testNotLoadingNeverForceClears() {
        for retries in 0 ... 20 {
            for isStartupActive in [true, false] {
                XCTAssertFalse(
                    TerminalSessionModel.shouldForceClearShellLoadingForOSC7Deadlock(
                        retries: retries,
                        isShellLoading: false,
                        isStartupRestoreActive: isStartupActive
                    ),
                    "Not-loading must short-circuit (retries=\(retries), startup=\(isStartupActive))"
                )
            }
        }
    }

    // MARK: - Post-startup threshold (6)

    /// Post-startup, retries below the steady-state threshold must NOT
    /// force-clear. retry=5 is one below 6.
    func testPostStartupBelowThresholdDoesNotForceClear() {
        XCTAssertFalse(
            TerminalSessionModel.shouldForceClearShellLoadingForOSC7Deadlock(
                retries: 5,
                isShellLoading: true,
                isStartupRestoreActive: false
            )
        )
    }

    /// Post-startup, retry=6 hits the steady-state threshold.
    func testPostStartupAtThresholdForceClears() {
        XCTAssertTrue(
            TerminalSessionModel.shouldForceClearShellLoadingForOSC7Deadlock(
                retries: 6,
                isShellLoading: true,
                isStartupRestoreActive: false
            )
        )
    }

    /// Post-startup, retries above the steady-state threshold force-clear.
    func testPostStartupAboveThresholdForceClears() {
        for retries in 7 ... 12 {
            XCTAssertTrue(
                TerminalSessionModel.shouldForceClearShellLoadingForOSC7Deadlock(
                    retries: retries,
                    isShellLoading: true,
                    isStartupRestoreActive: false
                ),
                "Retry=\(retries) post-startup should force-clear"
            )
        }
    }

    // MARK: - Startup-active threshold (8)

    /// During startup-restore, retry=6 (the post-startup threshold) is
    /// NOT enough — shells need more headroom under simultaneous-spawn load.
    /// This is the production fix for the user's observed
    /// "Resume prefill: force-clearing isShellLoading after 6 retries"
    /// log lines firing during multi-tab cold boot.
    func testStartupActiveAtSteadyStateThresholdDoesNotForceClear() {
        XCTAssertFalse(
            TerminalSessionModel.shouldForceClearShellLoadingForOSC7Deadlock(
                retries: 6,
                isShellLoading: true,
                isStartupRestoreActive: true
            ),
            "Retry=6 during startup must NOT force-clear (was the previous bug)"
        )
        XCTAssertFalse(
            TerminalSessionModel.shouldForceClearShellLoadingForOSC7Deadlock(
                retries: 7,
                isShellLoading: true,
                isStartupRestoreActive: true
            ),
            "Retry=7 during startup also below the new startup threshold"
        )
    }

    /// Startup-active, retry=8 hits the new startup threshold.
    func testStartupActiveAtThresholdForceClears() {
        XCTAssertTrue(
            TerminalSessionModel.shouldForceClearShellLoadingForOSC7Deadlock(
                retries: 8,
                isShellLoading: true,
                isStartupRestoreActive: true
            )
        )
    }

    /// Startup-active, retries above the startup threshold force-clear.
    func testStartupActiveAboveThresholdForceClears() {
        for retries in 9 ... 15 {
            XCTAssertTrue(
                TerminalSessionModel.shouldForceClearShellLoadingForOSC7Deadlock(
                    retries: retries,
                    isShellLoading: true,
                    isStartupRestoreActive: true
                ),
                "Retry=\(retries) during startup should force-clear"
            )
        }
    }

    // MARK: - Boundary

    /// retry=0 never force-clears. (Sanity guard against off-by-one.)
    func testZeroRetriesNeverForceClears() {
        for isStartupActive in [true, false] {
            XCTAssertFalse(
                TerminalSessionModel.shouldForceClearShellLoadingForOSC7Deadlock(
                    retries: 0,
                    isShellLoading: true,
                    isStartupRestoreActive: isStartupActive
                )
            )
        }
    }

    /// Negative retries are nonsensical but must not crash. The implementation
    /// should treat them as "below threshold" (false).
    func testNegativeRetriesDoesNotForceClear() {
        XCTAssertFalse(
            TerminalSessionModel.shouldForceClearShellLoadingForOSC7Deadlock(
                retries: -1,
                isShellLoading: true,
                isStartupRestoreActive: false
            )
        )
    }
}
