import XCTest
@testable import Chau7Core

final class StartupRestorePolicyTests: XCTestCase {
    func testTrackerSummarizesStartupRestoreMetrics() {
        var tracker = StartupRestoreTracker()
        let startedAt = Date(timeIntervalSince1970: 100)
        tracker.begin(at: startedAt)

        XCTAssertTrue(tracker.noteProtectedPathDeferral(root: "/Users/me/Downloads"))
        XCTAssertFalse(tracker.noteProtectedPathDeferral(root: "/Users/me/Downloads"))
        tracker.noteSnippetResolveDebounced()
        tracker.noteSnippetResolveCompleted()
        tracker.noteResumePrefillDelayed()
        tracker.noteResumePrefillQueued()
        tracker.noteResumePrefillDelivered()
        tracker.noteRestoreBootstrapStarted()
        tracker.noteRestoreBootstrapSettled()
        tracker.noteRestorePreviewShown()
        tracker.noteRestorePreviewDiscarded()
        tracker.noteWindowVisible(windowNumber: 7, at: startedAt.addingTimeInterval(0.2))
        XCTAssertEqual(
            tracker.noteSelectedTabLiveFrame(windowNumber: 7, at: startedAt.addingTimeInterval(0.55)),
            350
        )
        XCTAssertNil(
            tracker.noteSelectedTabLiveFrame(windowNumber: 7, at: startedAt.addingTimeInterval(0.75))
        )

        let summary = tracker.end(at: startedAt.addingTimeInterval(1.25))
        XCTAssertEqual(summary?.durationMs, 1250)
        XCTAssertEqual(summary?.protectedRoots, ["/Users/me/Downloads"])
        XCTAssertEqual(summary?.protectedPathDeferrals, 2)
        XCTAssertEqual(summary?.debouncedSnippetResolves, 1)
        XCTAssertEqual(summary?.completedSnippetResolves, 1)
        XCTAssertEqual(summary?.delayedResumePrefills, 1)
        XCTAssertEqual(summary?.queuedResumePrefills, 1)
        XCTAssertEqual(summary?.deliveredResumePrefills, 1)
        XCTAssertEqual(summary?.restoreBootstrapStarted, 1)
        XCTAssertEqual(summary?.restoreBootstrapSettled, 1)
        XCTAssertEqual(summary?.restorePreviewShown, 1)
        XCTAssertEqual(summary?.restorePreviewDiscarded, 1)
        XCTAssertEqual(summary?.selectedTabLiveFrameCount, 1)
        XCTAssertEqual(summary?.firstWindowVisibleMs, 200)
        XCTAssertEqual(summary?.firstSelectedTabLiveFrameSinceStartMs, 550)
        XCTAssertEqual(summary?.firstSelectedTabLiveFrameMs, 350)
        XCTAssertEqual(summary?.slowestSelectedTabLiveFrameMs, 350)
        XCTAssertFalse(tracker.isActive)
    }

    func testTrackerReadinessUsesVisibleWindowCount() {
        var tracker = StartupRestoreTracker()
        let startedAt = Date(timeIntervalSince1970: 100)
        tracker.begin(at: startedAt)
        tracker.noteWindowVisible(windowNumber: 1, at: startedAt.addingTimeInterval(0.2))
        tracker.noteWindowVisible(windowNumber: 2, at: startedAt.addingTimeInterval(0.25))

        XCTAssertFalse(tracker.isReadyForVisibleStartupCompletion(expectedWindowCount: 2))

        _ = tracker.noteSelectedTabLiveFrame(windowNumber: 1, at: startedAt.addingTimeInterval(0.4))
        XCTAssertFalse(tracker.isReadyForVisibleStartupCompletion(expectedWindowCount: 2))

        _ = tracker.noteSelectedTabLiveFrame(windowNumber: 2, at: startedAt.addingTimeInterval(0.55))
        XCTAssertTrue(tracker.isReadyForVisibleStartupCompletion(expectedWindowCount: 2))
    }

    func testSnippetResolvePolicyDebouncesHomePathDuringStartupRestore() {
        XCTAssertTrue(
            StartupSnippetResolvePolicy.shouldDebounce(
                isStartupRestoreActive: true,
                path: "/Users/me",
                homePath: "/Users/me"
            )
        )
    }

    func testSnippetResolvePolicyDebouncesImmediateChildrenOfHomeDuringStartupRestore() {
        XCTAssertTrue(
            StartupSnippetResolvePolicy.shouldDebounce(
                isStartupRestoreActive: true,
                path: "/Users/me/Documents",
                homePath: "/Users/me"
            )
        )
    }

    func testSnippetResolvePolicyDoesNotDebounceNestedRepoPath() {
        XCTAssertFalse(
            StartupSnippetResolvePolicy.shouldDebounce(
                isStartupRestoreActive: true,
                path: "/Users/me/Downloads/Repositories/Chau7",
                homePath: "/Users/me"
            )
        )
    }

    func testResumePrefillPolicyRetriesForMissingViewDuringStartupRestore() {
        XCTAssertEqual(
            StartupResumePrefillPolicy.noViewDecision(
                isStartupRestoreActive: true,
                remainingAttempts: 10
            ),
            .retryWaitingForView
        )
    }

    func testResumePrefillPolicyQueuesOutsideStartupRestore() {
        XCTAssertEqual(
            StartupResumePrefillPolicy.noViewDecision(
                isStartupRestoreActive: false,
                remainingAttempts: 10
            ),
            .queueSessionPrefill
        )
    }

    func testResumePrefillPolicyWarnsOnlyOutsideStartupRestore() {
        XCTAssertFalse(StartupResumePrefillPolicy.shouldWarnAboutNotReady(isStartupRestoreActive: true))
        XCTAssertTrue(StartupResumePrefillPolicy.shouldWarnAboutNotReady(isStartupRestoreActive: false))
    }

    func testWindowPresentationPolicyPrioritizesSelectedRestoreDuringStartup() {
        XCTAssertEqual(
            StartupWindowPresentationPolicy.restoreExecutionDelay(
                isStartupRestoreActive: true,
                isSelectedTab: true,
                defaultDelay: 0.8
            ),
            StartupWindowPresentationPolicy.selectedTabRestoreDelay
        )
        XCTAssertEqual(
            StartupWindowPresentationPolicy.restoreExecutionDelay(
                isStartupRestoreActive: true,
                isSelectedTab: false,
                defaultDelay: 0.8
            ),
            StartupWindowPresentationPolicy.backgroundTabRestoreDelay
        )
        XCTAssertEqual(
            StartupWindowPresentationPolicy.restoreExecutionDelay(
                isStartupRestoreActive: false,
                isSelectedTab: false,
                defaultDelay: 0.8
            ),
            0.8
        )
    }

    func testWindowPresentationPolicyDefersBackgroundRestoreTabsDuringStartup() {
        XCTAssertFalse(
            StartupWindowPresentationPolicy.shouldKeepTabInLiveHierarchy(
                isStartupRestoreActive: true,
                isSelectedTab: false,
                isPreviousLiveTab: false,
                isMCPControlled: false,
                hasAttachedTerminalView: false,
                hasPendingRestoreBootstrap: true
            )
        )
    }

    func testWindowPresentationPolicyKeepsSelectedAndMCPTabsLiveDuringStartup() {
        XCTAssertTrue(
            StartupWindowPresentationPolicy.shouldKeepTabInLiveHierarchy(
                isStartupRestoreActive: true,
                isSelectedTab: true,
                isPreviousLiveTab: false,
                isMCPControlled: false,
                hasAttachedTerminalView: false,
                hasPendingRestoreBootstrap: true
            )
        )
        XCTAssertTrue(
            StartupWindowPresentationPolicy.shouldKeepTabInLiveHierarchy(
                isStartupRestoreActive: true,
                isSelectedTab: false,
                isPreviousLiveTab: false,
                isMCPControlled: true,
                hasAttachedTerminalView: false,
                hasPendingRestoreBootstrap: false
            )
        )
    }

    func testWindowPresentationPolicyAllowsDeferredRestoreTabsAfterStartup() {
        XCTAssertTrue(
            StartupWindowPresentationPolicy.shouldKeepTabInLiveHierarchy(
                isStartupRestoreActive: false,
                isSelectedTab: false,
                isPreviousLiveTab: false,
                isMCPControlled: false,
                hasAttachedTerminalView: false,
                hasPendingRestoreBootstrap: true
            )
        )
    }

    func testWindowPresentationPolicyWaitsForSurfaceWhenStartupHasNoSnapshot() {
        XCTAssertFalse(
            StartupWindowPresentationPolicy.shouldRevealWindowImmediately(
                isStartupRestoreActive: true,
                isSelectedSurfaceLivePresentable: false
            )
        )
    }

    func testWindowPresentationPolicyRevealsImmediatelyWhenLiveSurfaceIsAlreadyReady() {
        XCTAssertTrue(
            StartupWindowPresentationPolicy.shouldRevealWindowImmediately(
                isStartupRestoreActive: true,
                isSelectedSurfaceLivePresentable: true
            )
        )
    }

    func testWindowPresentationPolicyRevealsImmediatelyOutsideStartup() {
        XCTAssertTrue(
            StartupWindowPresentationPolicy.shouldRevealWindowImmediately(
                isStartupRestoreActive: false,
                isSelectedSurfaceLivePresentable: false
            )
        )
    }

    func testWindowPresentationPolicyUsesLoadingCoverForForcedRevealWithoutLiveSurface() {
        XCTAssertTrue(
            StartupWindowPresentationPolicy.shouldShowLoadingCoverAfterReveal(
                revealWasForced: true,
                isSelectedSurfaceLivePresentable: false
            )
        )
        XCTAssertFalse(
            StartupWindowPresentationPolicy.shouldShowLoadingCoverAfterReveal(
                revealWasForced: false,
                isSelectedSurfaceLivePresentable: false
            )
        )
        XCTAssertFalse(
            StartupWindowPresentationPolicy.shouldShowLoadingCoverAfterReveal(
                revealWasForced: true,
                isSelectedSurfaceLivePresentable: true
            )
        )
    }

    func testFallbackRecoveryPolicyRetriesForcedCompletionWithoutAllLiveFrames() {
        XCTAssertTrue(
            StartupRestoreFallbackRecoveryPolicy.shouldRetry(
                forceRequested: true,
                recordedLiveFrameWindows: 0,
                expectedWindowCount: 2,
                attempts: 0
            )
        )
        XCTAssertTrue(
            StartupRestoreFallbackRecoveryPolicy.shouldRetry(
                forceRequested: true,
                recordedLiveFrameWindows: 1,
                expectedWindowCount: 2,
                attempts: 1
            )
        )
    }

    func testFallbackRecoveryPolicyStopsRetryingOnceLimitReachedOrAllFramesRecorded() {
        XCTAssertFalse(
            StartupRestoreFallbackRecoveryPolicy.shouldRetry(
                forceRequested: true,
                recordedLiveFrameWindows: 2,
                expectedWindowCount: 2,
                attempts: 0
            )
        )
        XCTAssertFalse(
            StartupRestoreFallbackRecoveryPolicy.shouldRetry(
                forceRequested: true,
                recordedLiveFrameWindows: 1,
                expectedWindowCount: 2,
                attempts: StartupRestoreFallbackRecoveryPolicy.maxRecoveryAttempts
            )
        )
        XCTAssertFalse(
            StartupRestoreFallbackRecoveryPolicy.shouldRetry(
                forceRequested: false,
                recordedLiveFrameWindows: 0,
                expectedWindowCount: 2,
                attempts: 0
            )
        )
    }
}
