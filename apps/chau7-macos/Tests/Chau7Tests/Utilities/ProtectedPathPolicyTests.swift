import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class ProtectedPathPolicyTests: XCTestCase {
    func testUserInitiatedDenialEntersCooldownEvenWhenFeatureDisabled() {
        let settings = FeatureSettings.shared
        let previousAllowProtectedFolderAccess = settings.allowProtectedFolderAccess

        defer {
            settings.allowProtectedFolderAccess = previousAllowProtectedFolderAccess
            ProtectedPathPolicy.resetAccessChecks()
        }

        settings.allowProtectedFolderAccess = false
        ProtectedPathPolicy.resetAccessChecks()

        let path = "/Users/me/Downloads/Repositories/Chau7"

        let initial = ProtectedPathPolicy.accessSnapshotForUserInitiatedAction(path: path)
        XCTAssertEqual(initial.state, .blockedFeatureDisabled)
        XCTAssertEqual(initial.recommendedAction, .enableFeature)

        let denied = ProtectedPathPolicy.recordUserInitiatedDenial(path: path, reason: "testCancel")
        XCTAssertEqual(denied.state, .blockedCooldown)
        XCTAssertEqual(denied.recommendedAction, .waitForCooldown)

        let followUp = ProtectedPathPolicy.accessSnapshotForUserInitiatedAction(path: path)
        XCTAssertEqual(followUp.state, .blockedCooldown)
        XCTAssertEqual(followUp.recommendedAction, .waitForCooldown)
    }

    func testResetAccessChecksClearsUserInitiatedCooldown() {
        let settings = FeatureSettings.shared
        let previousAllowProtectedFolderAccess = settings.allowProtectedFolderAccess

        defer {
            settings.allowProtectedFolderAccess = previousAllowProtectedFolderAccess
            ProtectedPathPolicy.resetAccessChecks()
        }

        settings.allowProtectedFolderAccess = true
        ProtectedPathPolicy.resetAccessChecks()

        let path = "/Users/me/Downloads/Repositories/Chau7"
        _ = ProtectedPathPolicy.recordUserInitiatedDenial(path: path, reason: "testCancel")

        XCTAssertEqual(
            ProtectedPathPolicy.accessSnapshotForUserInitiatedAction(path: path).recommendedAction,
            .waitForCooldown
        )

        ProtectedPathPolicy.resetAccessChecks()

        XCTAssertEqual(
            ProtectedPathPolicy.accessSnapshotForUserInitiatedAction(path: path).recommendedAction,
            .grantAccess
        )
    }
}
#endif
