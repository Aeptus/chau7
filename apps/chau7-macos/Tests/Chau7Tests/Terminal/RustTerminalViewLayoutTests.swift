import XCTest
import AppKit
@testable import Chau7

final class RustTerminalViewLayoutTests: XCTestCase {
    func testRenderGeometryFillsAvailableInsetRect() {
        let geometry = RustTerminalView.renderGeometry(
            bounds: NSRect(x: 0, y: 0, width: 808, height: 79 * 13 + 15),
            cellSize: CGSize(width: 8, height: 13)
        )

        XCTAssertEqual(geometry.surfaceFrame, NSRect(x: 4, y: 4, width: 800, height: 79 * 13 + 7))
        XCTAssertEqual(geometry.rows, 79)
        XCTAssertEqual(geometry.verticalRemainder, 7, accuracy: 0.001)
    }

    func testRenderGeometryCollapsesWhenNoRowsFit() {
        let geometry = RustTerminalView.renderGeometry(
            bounds: NSRect(x: 0, y: 0, width: 808, height: 8),
            cellSize: CGSize(width: 8, height: 13)
        )

        XCTAssertEqual(geometry.surfaceFrame.origin.x, RustTerminalView.terminalInset, accuracy: 0.001)
        XCTAssertEqual(geometry.surfaceFrame.origin.y, RustTerminalView.terminalInset, accuracy: 0.001)
        XCTAssertEqual(geometry.surfaceFrame.height, 0, accuracy: 0.001)
    }
}
