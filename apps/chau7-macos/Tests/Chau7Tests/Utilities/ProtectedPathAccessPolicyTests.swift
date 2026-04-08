import XCTest
@testable import Chau7Core

final class ProtectedPathAccessPolicyTests: XCTestCase {
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
}
