import XCTest
@testable import Chau7Core

final class TabGroupDragStateTests: XCTestCase {
    func testRejectsInvalidGeometry() {
        XCTAssertNil(TabGroupDragState(homeRange: 0 ..< 0, tabWidths: [100], spacing: 8))
        XCTAssertNil(TabGroupDragState(homeRange: 1 ..< 2, tabWidths: [100], spacing: 8))
        XCTAssertNil(TabGroupDragState(homeRange: 0 ..< 1, tabWidths: [0], spacing: 8))
        XCTAssertNil(TabGroupDragState(homeRange: 0 ..< 1, tabWidths: [100], spacing: -1))
    }

    func testCombinesPointerAndScrollIntoOneDestination() throws {
        var state = try XCTUnwrap(
            TabGroupDragState(homeRange: 1 ..< 3, tabWidths: [100, 80, 120, 90], spacing: 8)
        )

        state.updatePointerTranslation(100)
        XCTAssertEqual(state.destinationIndex, 1)

        state.applyScrollCompensation(100)
        XCTAssertEqual(state.effectiveTranslation, 200)
        XCTAssertEqual(state.destinationIndex, 2)
    }

    func testComputesStablePlaceholderDisplacementsToTheRight() throws {
        var state = try XCTUnwrap(
            TabGroupDragState(
                homeRange: 1 ..< 3,
                tabWidths: [60, 80, 120, 90, 70],
                spacing: 8,
                leadingAccessoryWidth: 40
            )
        )
        state.updatePointerTranslation(250)

        XCTAssertEqual(state.groupWidth, 256)
        XCTAssertEqual(state.displacement(forTabAt: 1), 0)
        XCTAssertEqual(state.displacement(forTabAt: 2), 0)
        XCTAssertEqual(state.displacement(forTabAt: 3), -264)
        XCTAssertEqual(state.displacement(forTabAt: 4), 0)
    }

    func testComputesStablePlaceholderDisplacementsToTheLeft() throws {
        var state = try XCTUnwrap(
            TabGroupDragState(homeRange: 2 ..< 4, tabWidths: [60, 70, 80, 120], spacing: 8)
        )
        state.updatePointerTranslation(-300)

        XCTAssertEqual(state.destinationIndex, 0)
        XCTAssertEqual(state.displacement(forTabAt: 0), 216)
        XCTAssertEqual(state.displacement(forTabAt: 1), 216)
        XCTAssertEqual(state.displacement(forTabAt: 2), 0)
        XCTAssertEqual(state.displacement(forTabAt: 3), 0)
    }
}
