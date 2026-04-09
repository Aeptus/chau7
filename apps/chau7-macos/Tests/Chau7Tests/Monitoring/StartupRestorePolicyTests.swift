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

        let summary = tracker.end(at: startedAt.addingTimeInterval(1.25))
        XCTAssertEqual(summary?.durationMs, 1250)
        XCTAssertEqual(summary?.protectedRoots, ["/Users/me/Downloads"])
        XCTAssertEqual(summary?.protectedPathDeferrals, 2)
        XCTAssertEqual(summary?.debouncedSnippetResolves, 1)
        XCTAssertEqual(summary?.completedSnippetResolves, 1)
        XCTAssertEqual(summary?.delayedResumePrefills, 1)
        XCTAssertEqual(summary?.queuedResumePrefills, 1)
        XCTAssertEqual(summary?.deliveredResumePrefills, 1)
        XCTAssertFalse(tracker.isActive)
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
}
