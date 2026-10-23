import XCTest
@testable import Chau7Core

final class WindowStateRestorePlannerTests: XCTestCase {
    func testBackupRestoreDropsBestMatchingPrimaryWindowEvenWhenNotFirst() {
        let primaryOnly = UUID()
        let a = UUID()
        let b = UUID()

        let backup = [
            WindowStateRestorePlanner.CandidateWindow(tabIDs: [primaryOnly]),
            WindowStateRestorePlanner.CandidateWindow(tabIDs: [a, b])
        ]

        let restored = WindowStateRestorePlanner.additionalWindowsFromBackup(
            currentPrimaryTabIDs: [a, b],
            backupWindows: backup
        )

        XCTAssertEqual(restored, [backup[0]])
    }

    func testBackupRestoreFallsBackToDropFirstWhenNoWindowMatchesPrimary() {
        let backup = [
            WindowStateRestorePlanner.CandidateWindow(tabIDs: [UUID()]),
            WindowStateRestorePlanner.CandidateWindow(tabIDs: [UUID(), UUID()])
        ]

        let restored = WindowStateRestorePlanner.additionalWindowsFromBackup(
            currentPrimaryTabIDs: [UUID()],
            backupWindows: backup
        )

        XCTAssertEqual(restored, [backup[1]])
    }

    func testBackupRestoreReturnsNoAdditionalWindowsForSingleWindowBackup() {
        let backup = [
            WindowStateRestorePlanner.CandidateWindow(tabIDs: [UUID(), UUID()])
        ]

        let restored = WindowStateRestorePlanner.additionalWindowsFromBackup(
            currentPrimaryTabIDs: [],
            backupWindows: backup
        )

        XCTAssertTrue(restored.isEmpty)
    }

    // MARK: - claimTabs (cross-window per-tab dedup)

    func testClaimTabsDropsIDsAlreadyClaimedByPrimaryWindow() {
        let shared = UUID()
        let unique = UUID()

        let claims = WindowStateRestorePlanner.claimTabs(
            alreadyClaimed: [shared],
            windows: [[shared, unique]]
        )

        XCTAssertEqual(claims, [[.dropDuplicate, .restore]])
    }

    func testClaimTabsFirstWindowWinsAcrossWindows() {
        let shared = UUID()
        let w2Only = UUID()

        let claims = WindowStateRestorePlanner.claimTabs(
            alreadyClaimed: [],
            windows: [[shared], [shared, w2Only], [shared]]
        )

        XCTAssertEqual(claims, [
            [.restore],
            [.dropDuplicate, .restore],
            [.dropDuplicate]
        ])
    }

    func testClaimTabsDropsDuplicatesWithinOneWindow() {
        let dup = UUID()

        let claims = WindowStateRestorePlanner.claimTabs(
            alreadyClaimed: [],
            windows: [[dup, dup, dup]]
        )

        XCTAssertEqual(claims, [[.restore, .dropDuplicate, .dropDuplicate]])
    }

    func testClaimTabsAlwaysRestoresUnparseableIDs() {
        let claims = WindowStateRestorePlanner.claimTabs(
            alreadyClaimed: [],
            windows: [[nil, nil], [nil]]
        )

        XCTAssertEqual(claims, [[.restore, .restore], [.restore]])
    }

    func testClaimTabsPartiallyDuplicatedWindowKeepsUniqueTabs() {
        // The old >50%-overlap heuristic restored BOTH copies of a window
        // sharing 1 of 3 tabs with window 0; per-tab claims keep only the
        // unique tabs.
        let shared = UUID()
        let uniqueA = UUID()
        let uniqueB = UUID()

        let claims = WindowStateRestorePlanner.claimTabs(
            alreadyClaimed: [shared],
            windows: [[uniqueA, shared, uniqueB]]
        )

        XCTAssertEqual(claims, [[.restore, .dropDuplicate, .restore]])
    }
}
