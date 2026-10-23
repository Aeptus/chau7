import XCTest
@testable import Chau7Core

final class GridSyncStrategyPolicyTests: XCTestCase {
    func testUsesPartialSyncForModerateDirtyRows() {
        XCTAssertTrue(
            GridSyncStrategyPolicy.shouldUsePartialSync(
                canCompare: true,
                dirtyRowCount: 40,
                gridRows: 80
            )
        )
    }

    func testUsesPartialSyncForNearlyFullFrameWhenOneRowRemainsClean() {
        XCTAssertTrue(
            GridSyncStrategyPolicy.shouldUsePartialSync(
                canCompare: true,
                dirtyRowCount: 79,
                gridRows: 80
            )
        )
    }

    func testUsesFullSyncWhenEveryRowIsDirty() {
        XCTAssertFalse(
            GridSyncStrategyPolicy.shouldUsePartialSync(
                canCompare: true,
                dirtyRowCount: 80,
                gridRows: 80
            )
        )
    }

    func testUsesFullSyncWhenDiffingIsUnavailable() {
        XCTAssertFalse(
            GridSyncStrategyPolicy.shouldUsePartialSync(
                canCompare: false,
                dirtyRowCount: 12,
                gridRows: 80
            )
        )
    }
}
