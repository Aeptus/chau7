import CoreGraphics
import XCTest
@testable import Chau7Core

final class TerminalRenderGeometryTests: XCTestCase {
    func testSurfaceFillsAvailableBoundsWhileGridUsesWholeRows() {
        let geometry = TerminalRenderGeometry.resolve(
            bounds: CGRect(x: 0, y: 0, width: 808, height: 79 * 13 + 15),
            inset: 4,
            cellSize: CGSize(width: 8, height: 13)
        )

        XCTAssertEqual(geometry.contentBounds, CGRect(x: 4, y: 4, width: 800, height: 79 * 13 + 7))
        XCTAssertEqual(geometry.surfaceFrame, geometry.contentBounds)
        XCTAssertEqual(geometry.rows, 79)
        XCTAssertEqual(geometry.gridFrame.maxY, geometry.surfaceFrame.maxY, accuracy: 0.001)
        XCTAssertEqual(geometry.gridFrame.height, 79 * 13, accuracy: 0.001)
        XCTAssertEqual(geometry.verticalRemainder, 7, accuracy: 0.001)
    }

    func testNoFractionalRowsAreAllocated() {
        let geometry = TerminalRenderGeometry.resolve(
            bounds: CGRect(x: 0, y: 0, width: 100, height: 49),
            inset: 0,
            cellSize: CGSize(width: 10, height: 13)
        )

        XCTAssertEqual(geometry.rows, 3)
        XCTAssertEqual(geometry.gridFrame.height, 39)
        XCTAssertEqual(geometry.verticalRemainder, 10)
    }

    func testInsetGeometryExcludesPaddingFromAllocatedGridCells() {
        let geometry = TerminalRenderGeometry.resolve(
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1042),
            inset: 4,
            cellSize: CGSize(width: 7, height: 13)
        )

        XCTAssertEqual(geometry.contentBounds, CGRect(x: 4, y: 4, width: 1912, height: 1034))
        XCTAssertEqual(geometry.cols, 273)
        XCTAssertEqual(geometry.rows, 79)
        XCTAssertEqual(Int(1920 / 7), 274)
        XCTAssertEqual(Int(1042 / 13), 80)
    }

    func testMousePointInBottomRemainderClampsToLastWholeRow() {
        let geometry = TerminalRenderGeometry.resolve(
            bounds: CGRect(x: 0, y: 0, width: 80, height: 49),
            inset: 0,
            cellSize: CGSize(width: 8, height: 13)
        )

        XCTAssertEqual(geometry.rows, 3)
        XCTAssertEqual(geometry.clampedCell(for: CGPoint(x: 12, y: 2)), .init(col: 1, row: 2))
    }

    func testDegenerateHeightCollapsesSurface() {
        let geometry = TerminalRenderGeometry.resolve(
            bounds: CGRect(x: 0, y: 0, width: 80, height: 10),
            inset: 0,
            cellSize: CGSize(width: 8, height: 13)
        )

        XCTAssertEqual(geometry.rows, 0)
        XCTAssertEqual(geometry.surfaceFrame.height, 0)
        XCTAssertFalse(geometry.canResizePTY)
    }

    func testAbsurdInputsClampResizeTarget() {
        let geometry = TerminalRenderGeometry.resolve(
            bounds: CGRect(x: 0, y: 0, width: 30000, height: 20000),
            inset: 0,
            cellSize: CGSize(width: 8, height: 13)
        )

        XCTAssertTrue(geometry.isClamped)
        XCTAssertEqual(geometry.cols, TerminalRenderGeometry.defaultMaxColumns)
        XCTAssertEqual(geometry.rows, TerminalRenderGeometry.defaultMaxRows)
        XCTAssertTrue(geometry.canResizePTY)
    }
}
