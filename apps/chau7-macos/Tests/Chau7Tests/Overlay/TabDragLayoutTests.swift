import XCTest
@testable import Chau7Core

final class TabDragLayoutTests: XCTestCase {
    func testEdgeAutoScrollIsInactiveInViewportCenter() {
        XCTAssertEqual(
            TabDragLayout.edgeAutoScrollDelta(
                pointer: CGPoint(x: 150, y: 15),
                viewport: CGRect(x: 0, y: 0, width: 300, height: 30)
            ),
            0
        )
    }

    func testEdgeAutoScrollDirectionAndSpeedFollowEdgePenetration() {
        let viewport = CGRect(x: 100, y: 20, width: 400, height: 30)
        let nearLeft = TabDragLayout.edgeAutoScrollDelta(
            pointer: CGPoint(x: 135, y: 35),
            viewport: viewport
        )
        let outsideLeft = TabDragLayout.edgeAutoScrollDelta(
            pointer: CGPoint(x: 80, y: 35),
            viewport: viewport
        )
        let nearRight = TabDragLayout.edgeAutoScrollDelta(
            pointer: CGPoint(x: 465, y: 35),
            viewport: viewport
        )
        let outsideRight = TabDragLayout.edgeAutoScrollDelta(
            pointer: CGPoint(x: 520, y: 35),
            viewport: viewport
        )

        XCTAssertLessThan(nearLeft, 0)
        XCTAssertEqual(outsideLeft, -22)
        XCTAssertGreaterThan(nearRight, 0)
        XCTAssertEqual(outsideRight, 22)
        XCTAssertLessThan(abs(nearLeft), abs(outsideLeft))
        XCTAssertLessThan(abs(nearRight), abs(outsideRight))
    }

    func testEdgeAutoScrollRequiresPointerNearTabBarVertically() {
        XCTAssertEqual(
            TabDragLayout.edgeAutoScrollDelta(
                pointer: CGPoint(x: 295, y: 100),
                viewport: CGRect(x: 0, y: 0, width: 300, height: 30)
            ),
            0
        )
    }

    func testAutoScrollDeltaClampsAtBothContentBounds() {
        XCTAssertEqual(
            TabDragLayout.clampedAutoScrollDelta(
                requestedDelta: -20,
                currentOrigin: 5,
                contentWidth: 800,
                viewportWidth: 300
            ),
            -5
        )
        XCTAssertEqual(
            TabDragLayout.clampedAutoScrollDelta(
                requestedDelta: 30,
                currentOrigin: 490,
                contentWidth: 800,
                viewportWidth: 300
            ),
            10
        )
    }

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
