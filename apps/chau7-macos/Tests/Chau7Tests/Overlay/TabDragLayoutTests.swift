import XCTest
@testable import Chau7Core

final class TabDragLayoutTests: XCTestCase {
    func testDestinationIndexWaitsForCenterCrossingWithEqualWidths() {
        let widths: [CGFloat] = [100, 100, 100]

        XCTAssertEqual(
            TabDragLayout.destinationIndex(for: 107, homeIndex: 0, tabWidths: widths, spacing: 8),
            0
        )
        XCTAssertEqual(
            TabDragLayout.destinationIndex(for: 109, homeIndex: 0, tabWidths: widths, spacing: 8),
            1
        )
    }

    func testDestinationIndexIncludesDraggedWidthWhenMovingRight() {
        let widths: [CGFloat] = [100, 200, 150]

        XCTAssertEqual(
            TabDragLayout.destinationIndex(for: 157, homeIndex: 0, tabWidths: widths, spacing: 8),
            0
        )
        XCTAssertEqual(
            TabDragLayout.destinationIndex(for: 159, homeIndex: 0, tabWidths: widths, spacing: 8),
            1
        )
    }

    func testDestinationIndexAccumulatesCenterDistancesAcrossMultipleTabs() {
        let widths: [CGFloat] = [100, 200, 150]

        XCTAssertEqual(
            TabDragLayout.destinationIndex(for: 340, homeIndex: 0, tabWidths: widths, spacing: 8),
            1
        )
        XCTAssertEqual(
            TabDragLayout.destinationIndex(for: 342, homeIndex: 0, tabWidths: widths, spacing: 8),
            2
        )
    }

    func testDestinationIndexIncludesDraggedWidthWhenMovingLeft() {
        let widths: [CGFloat] = [100, 140, 80]

        XCTAssertEqual(
            TabDragLayout.destinationIndex(for: -117, homeIndex: 2, tabWidths: widths, spacing: 8),
            2
        )
        XCTAssertEqual(
            TabDragLayout.destinationIndex(for: -119, homeIndex: 2, tabWidths: widths, spacing: 8),
            1
        )
        XCTAssertEqual(
            TabDragLayout.destinationIndex(for: -247, homeIndex: 2, tabWidths: widths, spacing: 8),
            0
        )
    }
}
