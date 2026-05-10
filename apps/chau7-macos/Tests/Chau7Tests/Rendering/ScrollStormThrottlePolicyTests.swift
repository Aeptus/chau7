import XCTest
@testable import Chau7Core

final class ScrollStormThrottlePolicyTests: XCTestCase {
    func testObservedAITUIWorkloadEntersScrollStorm() {
        XCTAssertTrue(ScrollStormThrottlePolicy.shouldEnterScrollStorm(dirtyCells: 91, frameCells: 100))
    }

    func testModerateDirtyFrameDoesNotEnterScrollStorm() {
        XCTAssertFalse(ScrollStormThrottlePolicy.shouldEnterScrollStorm(dirtyCells: 84, frameCells: 100))
    }

    func testZeroFrameNeverEntersScrollStorm() {
        XCTAssertFalse(ScrollStormThrottlePolicy.shouldEnterScrollStorm(dirtyCells: 100, frameCells: 0))
    }

    func testLowDirtyFrameRequiresStrictlyBelowHalf() {
        XCTAssertTrue(ScrollStormThrottlePolicy.shouldCountAsLowDirtyFrame(dirtyCells: 49, frameCells: 100))
        XCTAssertFalse(ScrollStormThrottlePolicy.shouldCountAsLowDirtyFrame(dirtyCells: 50, frameCells: 100))
    }
}
