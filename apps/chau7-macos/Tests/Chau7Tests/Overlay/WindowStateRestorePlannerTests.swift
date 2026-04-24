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
}
