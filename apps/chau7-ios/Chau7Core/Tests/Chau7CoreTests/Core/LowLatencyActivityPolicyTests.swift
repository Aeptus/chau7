import XCTest
@testable import Chau7Core

final class LowLatencyActivityPolicyTests: XCTestCase {
    func testHoldsWhileAppIsActive() {
        XCTAssertTrue(
            LowLatencyActivityPolicy.shouldHoldActivity(
                LowLatencyActivityPolicyInput(
                    isAppActive: true,
                    hasLatencyCriticalScopes: false,
                    hasVisibleLiveWindows: false
                )
            )
        )
    }

    func testHoldsWhileExplicitScopeIsActive() {
        XCTAssertTrue(
            LowLatencyActivityPolicy.shouldHoldActivity(
                LowLatencyActivityPolicyInput(
                    isAppActive: false,
                    hasLatencyCriticalScopes: true,
                    hasVisibleLiveWindows: false
                )
            )
        )
    }

    func testHoldsWhileVisibleLiveWindowRemains() {
        XCTAssertTrue(
            LowLatencyActivityPolicy.shouldHoldActivity(
                LowLatencyActivityPolicyInput(
                    isAppActive: false,
                    hasLatencyCriticalScopes: false,
                    hasVisibleLiveWindows: true
                )
            )
        )
    }

    func testReleasesWhenAppIsInactiveAndNoVisibleLiveWindowsOrScopesRemain() {
        XCTAssertFalse(
            LowLatencyActivityPolicy.shouldHoldActivity(
                LowLatencyActivityPolicyInput(
                    isAppActive: false,
                    hasLatencyCriticalScopes: false,
                    hasVisibleLiveWindows: false
                )
            )
        )
    }
}
