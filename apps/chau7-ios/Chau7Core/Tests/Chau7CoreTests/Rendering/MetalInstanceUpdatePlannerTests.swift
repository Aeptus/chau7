import XCTest
import Chau7Core

final class MetalInstanceUpdatePlannerTests: XCTestCase {
    func testReturnsEmptyWhenNoRows() {
        let rows = MetalInstanceUpdatePlanner.rowsToRefresh(
            totalRows: 0,
            dirtyRows: IndexSet(integersIn: 0 ..< 5),
            fullRefresh: false,
            previousCursorRow: 1,
            currentCursorRow: 2,
            cursorNeedsRefresh: true
        )
        XCTAssertTrue(rows.isEmpty)
    }

    func testFullRefreshReturnsAllRows() {
        let rows = MetalInstanceUpdatePlanner.rowsToRefresh(
            totalRows: 10,
            dirtyRows: IndexSet([2]),
            fullRefresh: true,
            previousCursorRow: nil,
            currentCursorRow: nil,
            cursorNeedsRefresh: false
        )
        XCTAssertEqual(rows, IndexSet(integersIn: 0 ..< 10))
    }

    func testDirtyRowsClampedToRange() {
        let rows = MetalInstanceUpdatePlanner.rowsToRefresh(
            totalRows: 5,
            dirtyRows: IndexSet([-1, 1, 5, 10]),
            fullRefresh: false,
            previousCursorRow: nil,
            currentCursorRow: nil,
            cursorNeedsRefresh: false
        )
        XCTAssertEqual(rows, IndexSet([1]))
    }

    func testCursorRowsAddedWhenNeedsRefresh() {
        let rows = MetalInstanceUpdatePlanner.rowsToRefresh(
            totalRows: 10,
            dirtyRows: IndexSet([1]),
            fullRefresh: false,
            previousCursorRow: 3,
            currentCursorRow: 5,
            cursorNeedsRefresh: true
        )
        XCTAssertEqual(rows, IndexSet([1, 3, 5]))
    }

    func testCursorRowsSkippedWhenCursorDoesNotNeedRefresh() {
        let rows = MetalInstanceUpdatePlanner.rowsToRefresh(
            totalRows: 10,
            dirtyRows: IndexSet([1]),
            fullRefresh: false,
            previousCursorRow: 3,
            currentCursorRow: 5,
            cursorNeedsRefresh: false
        )
        XCTAssertEqual(rows, IndexSet([1]))
    }

    func testOutOfRangeCursorRowsDropped() {
        let rows = MetalInstanceUpdatePlanner.rowsToRefresh(
            totalRows: 5,
            dirtyRows: IndexSet(),
            fullRefresh: false,
            previousCursorRow: -1,
            currentCursorRow: 100,
            cursorNeedsRefresh: true
        )
        XCTAssertTrue(rows.isEmpty)
    }
}
