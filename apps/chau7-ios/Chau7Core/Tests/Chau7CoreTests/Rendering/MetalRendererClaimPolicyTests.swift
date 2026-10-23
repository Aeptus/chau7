import Chau7Core
import XCTest

final class MetalRendererClaimPolicyTests: XCTestCase {
    func testInteractiveCurrentFocusOwnerMayClaimRenderer() {
        XCTAssertTrue(
            MetalRendererClaimPolicy.shouldClaim(
                isInteractive: true,
                isAuthoritativeFocusOwner: true
            )
        )
    }

    func testStaleInteractiveUpdateCannotClaimRenderer() {
        XCTAssertFalse(
            MetalRendererClaimPolicy.shouldClaim(
                isInteractive: true,
                isAuthoritativeFocusOwner: false
            )
        )
    }

    func testNonInteractivePaneCannotClaimRendererEvenWhenFocused() {
        XCTAssertFalse(
            MetalRendererClaimPolicy.shouldClaim(
                isInteractive: false,
                isAuthoritativeFocusOwner: true
            )
        )
    }
}
