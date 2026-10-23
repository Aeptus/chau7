import CoreGraphics
import XCTest
@testable import Chau7Core

final class TerminalRenderLayoutParityTests: XCTestCase {
    private struct LayoutSnapshot: Equatable {
        let surfaceFrame: CGRect
        let gridOrigin: CGPoint
        let rows: Int
        let cols: Int
        let cellSize: CGSize
        let mouseCell: TerminalRenderGeometry.CellCoordinate
        let cursorRect: CGRect?
        let remainderPixels: CGSize
    }

    func testCPUAndMetalUseSameGeometryContract() {
        let geometry = TerminalRenderGeometry.resolve(
            bounds: CGRect(x: 0, y: 0, width: 1920, height: 1042),
            inset: 4,
            cellSize: CGSize(width: 7, height: 13)
        )
        let mousePoint = CGPoint(x: geometry.surfaceFrame.minX + 231.5, y: geometry.surfaceFrame.minY + 2)
        let cursor = TerminalRenderGeometry.CellCoordinate(col: 17, row: 24)

        let cpu = makeCPUSnapshot(
            geometry: geometry,
            mousePoint: mousePoint,
            cursor: cursor,
            scale: 2
        )
        let metal = makeMetalSnapshot(
            geometry: geometry,
            mousePoint: mousePoint,
            cursor: cursor,
            scale: 2
        )

        XCTAssertEqual(cpu, metal)
        XCTAssertEqual(cpu.rows, 79)
        XCTAssertEqual(cpu.cols, 273)
        XCTAssertEqual(cpu.remainderPixels.height, 14)
        XCTAssertEqual(cpu.mouseCell, .init(col: 33, row: 78))
    }

    func testParityHoldsAcrossNonIntegralBoundsAndScale() {
        let geometry = TerminalRenderGeometry.resolve(
            bounds: CGRect(x: 12.5, y: 7.25, width: 805.5, height: 601.25),
            inset: 4,
            cellSize: CGSize(width: 7.5, height: 14.25)
        )
        let mousePoint = CGPoint(x: geometry.gridFrame.maxX + 10, y: geometry.gridFrame.minY - 10)
        let cursor = TerminalRenderGeometry.CellCoordinate(col: geometry.cols - 1, row: geometry.rows - 1)

        let cpu = makeCPUSnapshot(
            geometry: geometry,
            mousePoint: mousePoint,
            cursor: cursor,
            scale: 1.5
        )
        let metal = makeMetalSnapshot(
            geometry: geometry,
            mousePoint: mousePoint,
            cursor: cursor,
            scale: 1.5
        )

        XCTAssertEqual(cpu, metal)
        XCTAssertEqual(cpu.mouseCell, cursor)
        XCTAssertEqual(cpu.cursorRect, geometry.cellRect(col: cursor.col, row: cursor.row))
    }

    private func makeCPUSnapshot(
        geometry: TerminalRenderGeometry,
        mousePoint: CGPoint,
        cursor: TerminalRenderGeometry.CellCoordinate,
        scale: CGFloat
    ) -> LayoutSnapshot {
        LayoutSnapshot(
            surfaceFrame: geometry.surfaceFrame,
            gridOrigin: geometry.gridOrigin,
            rows: geometry.rows,
            cols: geometry.cols,
            cellSize: geometry.cellSize,
            mouseCell: geometry.clampedCell(for: mousePoint),
            cursorRect: geometry.cellRect(col: cursor.col, row: cursor.row),
            remainderPixels: geometry.remainderPixels(backingScaleFactor: scale)
        )
    }

    private func makeMetalSnapshot(
        geometry: TerminalRenderGeometry,
        mousePoint: CGPoint,
        cursor: TerminalRenderGeometry.CellCoordinate,
        scale: CGFloat
    ) -> LayoutSnapshot {
        LayoutSnapshot(
            surfaceFrame: geometry.surfaceFrame,
            gridOrigin: geometry.gridOrigin,
            rows: geometry.rows,
            cols: geometry.cols,
            cellSize: geometry.cellSize,
            mouseCell: geometry.clampedCell(for: mousePoint),
            cursorRect: geometry.cellRect(col: cursor.col, row: cursor.row),
            remainderPixels: geometry.remainderPixels(backingScaleFactor: scale)
        )
    }
}
