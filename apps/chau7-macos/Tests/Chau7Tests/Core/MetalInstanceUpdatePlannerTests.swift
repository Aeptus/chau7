import XCTest
@testable import Chau7Core

final class MetalInstanceUpdatePlannerTests: XCTestCase {
    func testFullRefreshReturnsEveryRow() {
        let rows = MetalInstanceUpdatePlanner.rowsToRefresh(
            totalRows: 4,
            dirtyRows: IndexSet([1]),
            fullRefresh: true,
            previousCursorRow: 2,
            currentCursorRow: 3,
            cursorNeedsRefresh: true
        )

        XCTAssertEqual(rows, IndexSet(integersIn: 0 ..< 4))
    }

    func testCursorRefreshAddsPreviousAndCurrentRows() {
        let rows = MetalInstanceUpdatePlanner.rowsToRefresh(
            totalRows: 6,
            dirtyRows: IndexSet([1, 4]),
            fullRefresh: false,
            previousCursorRow: 2,
            currentCursorRow: 5,
            cursorNeedsRefresh: true
        )

        XCTAssertEqual(rows, IndexSet([1, 2, 4, 5]))
    }

    func testCursorRefreshDeduplicatesSharedRow() {
        let rows = MetalInstanceUpdatePlanner.rowsToRefresh(
            totalRows: 6,
            dirtyRows: IndexSet([3]),
            fullRefresh: false,
            previousCursorRow: 3,
            currentCursorRow: 3,
            cursorNeedsRefresh: true
        )

        XCTAssertEqual(rows, IndexSet([3]))
    }

    func testIgnoresCursorRowsWhenCursorDidNotChange() {
        let rows = MetalInstanceUpdatePlanner.rowsToRefresh(
            totalRows: 5,
            dirtyRows: IndexSet([0, 4]),
            fullRefresh: false,
            previousCursorRow: 1,
            currentCursorRow: 2,
            cursorNeedsRefresh: false
        )

        XCTAssertEqual(rows, IndexSet([0, 4]))
    }

    func testClampsOutOfBoundsRows() {
        let rows = MetalInstanceUpdatePlanner.rowsToRefresh(
            totalRows: 3,
            dirtyRows: IndexSet([1, 9]),
            fullRefresh: false,
            previousCursorRow: -3,
            currentCursorRow: 4,
            cursorNeedsRefresh: true
        )

        XCTAssertEqual(rows, IndexSet([1]))
    }
}
