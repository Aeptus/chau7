import XCTest
@testable import Chau7Core

final class TabSurfaceReactivationPolicyTests: XCTestCase {
    func testVisibleSurfaceRequestsRevealWhenWindowBecomesKey() {
        XCTAssertTrue(
            TabSurfaceReactivationPolicy.shouldRequestAuthoritativeReveal(
                for: .becameKey,
                phase: .passiveVisible,
                isWindowVisible: true,
                isWindowMiniaturized: false,
                isOcclusionVisible: true
            )
        )
    }

    func testHiddenPhaseDoesNotRequestReveal() {
        XCTAssertFalse(
            TabSurfaceReactivationPolicy.shouldRequestAuthoritativeReveal(
                for: .becameMain,
                phase: .hidden,
                isWindowVisible: true,
                isWindowMiniaturized: false,
                isOcclusionVisible: true
            )
        )
    }

    func testOcclusionRevealRequiresVisibleOcclusion() {
        XCTAssertFalse(
            TabSurfaceReactivationPolicy.shouldRequestAuthoritativeReveal(
                for: .becameVisible,
                phase: .active,
                isWindowVisible: true,
                isWindowMiniaturized: false,
                isOcclusionVisible: false
            )
        )
        XCTAssertTrue(
            TabSurfaceReactivationPolicy.shouldRequestAuthoritativeReveal(
                for: .becameVisible,
                phase: .active,
                isWindowVisible: true,
                isWindowMiniaturized: false,
                isOcclusionVisible: true
            )
        )
    }

    func testMiniaturizedWindowDoesNotRequestReveal() {
        XCTAssertFalse(
            TabSurfaceReactivationPolicy.shouldRequestAuthoritativeReveal(
                for: .deminiaturized,
                phase: .active,
                isWindowVisible: true,
                isWindowMiniaturized: true,
                isOcclusionVisible: true
            )
        )
    }
}
