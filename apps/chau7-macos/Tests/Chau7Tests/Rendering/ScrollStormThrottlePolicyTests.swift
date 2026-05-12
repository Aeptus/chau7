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

    func testFullscreenAgentStreamClassifiesAsScrollStormAndExitsOnIdleFrames() {
        let fullscreenCells = 273 * 79

        XCTAssertTrue(
            ScrollStormThrottlePolicy.shouldEnterScrollStorm(
                dirtyCells: fullscreenCells * 9 / 10,
                frameCells: fullscreenCells
            )
        )
        XCTAssertTrue(
            ScrollStormThrottlePolicy.shouldCountAsLowDirtyFrame(
                dirtyCells: fullscreenCells / 3,
                frameCells: fullscreenCells
            )
        )
        XCTAssertFalse(
            ScrollStormThrottlePolicy.shouldCountAsLowDirtyFrame(
                dirtyCells: (fullscreenCells + 1) / 2,
                frameCells: fullscreenCells
            )
        )
    }

    func testInteractiveSingleRowDoesNotEnterScrollStorm() {
        let fullscreenColumns = 273
        let fullscreenCells = fullscreenColumns * 79

        XCTAssertFalse(
            ScrollStormThrottlePolicy.shouldEnterScrollStorm(
                dirtyCells: fullscreenColumns,
                frameCells: fullscreenCells
            )
        )
        XCTAssertTrue(
            ScrollStormThrottlePolicy.shouldCountAsLowDirtyFrame(
                dirtyCells: fullscreenColumns,
                frameCells: fullscreenCells
            )
        )
    }
}
