import XCTest
@testable import Chau7Core

final class ProtectedPathAccessPolicyTests: XCTestCase {
    func testAccessSnapshotAllowsKnownIdentityFallbackWhenFeatureDisabled() {
        let snapshot = ProtectedPathAccessPolicy.accessSnapshot(
            root: "/Users/me/Downloads",
            isProtectedPath: true,
            isFeatureEnabled: false,
            hasActiveScope: false,
            hasSecurityScopedBookmark: false,
            isDeniedByCooldown: false,
            hasKnownIdentity: true
        )

        XCTAssertEqual(snapshot.state, .blockedFeatureDisabled)
        XCTAssertFalse(snapshot.canProbeLive)
        XCTAssertTrue(snapshot.canUseKnownIdentity)
        XCTAssertEqual(snapshot.recommendedAction, .enableFeature)
    }

    func testAccessSnapshotTreatsStaleBookmarkAsRegrantRequired() {
        let snapshot = ProtectedPathAccessPolicy.accessSnapshot(
            root: "/Users/me/Downloads",
            isProtectedPath: true,
            isFeatureEnabled: true,
            hasActiveScope: false,
            hasSecurityScopedBookmark: false,
            isDeniedByCooldown: false,
            hasKnownIdentity: true,
            bookmarkResolveFailed: true
        )

        XCTAssertEqual(snapshot.state, .blockedStaleBookmark)
        XCTAssertFalse(snapshot.canProbeLive)
        XCTAssertTrue(snapshot.canUseKnownIdentity)
        XCTAssertEqual(snapshot.recommendedAction, .regrantAccess)
    }

    func testAccessSnapshotLeavesUnprotectedPathsAvailable() {
        let snapshot = ProtectedPathAccessPolicy.accessSnapshot(
            root: nil,
            isProtectedPath: false,
            isFeatureEnabled: false,
            hasActiveScope: false,
            hasSecurityScopedBookmark: false,
            isDeniedByCooldown: false,
            hasKnownIdentity: false
        )

        XCTAssertEqual(snapshot.state, .unprotected)
        XCTAssertTrue(snapshot.canProbeLive)
        XCTAssertFalse(snapshot.canUseKnownIdentity)
        XCTAssertEqual(snapshot.recommendedAction, .none)
    }

    func testAutoAccessSkipsWhenFeatureDisabled() {
        XCTAssertEqual(
            ProtectedPathAccessPolicy.autoAccessDecision(
                isFeatureEnabled: false,
                hasActiveScope: false,
                hasSecurityScopedBookmark: true,
                isDeniedByCooldown: false
            ),
            .skipFeatureDisabled
        )
    }

    func testAutoAccessAllowsActiveScopeBeforeAllOtherChecks() {
        XCTAssertEqual(
            ProtectedPathAccessPolicy.autoAccessDecision(
                isFeatureEnabled: true,
                hasActiveScope: true,
                hasSecurityScopedBookmark: false,
                isDeniedByCooldown: true
            ),
            .allowActiveScope
        )
    }

    func testAutoAccessAllowsBookmarkedScope() {
        XCTAssertEqual(
            ProtectedPathAccessPolicy.autoAccessDecision(
                isFeatureEnabled: true,
                hasActiveScope: false,
                hasSecurityScopedBookmark: true,
                isDeniedByCooldown: false
            ),
            .allowBookmarkedScope
        )
    }

    func testAutoAccessRequiresExplicitGrantWithoutBookmark() {
        XCTAssertEqual(
            ProtectedPathAccessPolicy.autoAccessDecision(
                isFeatureEnabled: true,
                hasActiveScope: false,
                hasSecurityScopedBookmark: false,
                isDeniedByCooldown: false
            ),
            .skipNeedsExplicitGrant
        )
    }

    func testAutoAccessHonorsCooldownWithoutProbing() {
        XCTAssertEqual(
            ProtectedPathAccessPolicy.autoAccessDecision(
                isFeatureEnabled: true,
                hasActiveScope: false,
                hasSecurityScopedBookmark: true,
                isDeniedByCooldown: true
            ),
            .skipCooldown
        )
    }

    func testAutoAccessRecognizesStaleBookmark() {
        XCTAssertEqual(
            ProtectedPathAccessPolicy.autoAccessDecision(
                isFeatureEnabled: true,
                hasActiveScope: false,
                hasSecurityScopedBookmark: false,
                isDeniedByCooldown: false,
                bookmarkResolveFailed: true
            ),
            .skipStaleBookmark
        )
    }
}
