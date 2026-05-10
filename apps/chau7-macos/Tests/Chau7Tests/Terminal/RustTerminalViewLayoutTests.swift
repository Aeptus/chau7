import XCTest
import AppKit
@testable import Chau7

final class RustTerminalViewLayoutTests: XCTestCase {
    func testAlignedRenderSurfaceFramePinsVisibleGridToTop() {
        let insetRect = NSRect(x: 4, y: 4, width: 800, height: 79 * 13 + 7)

        let frame = RustTerminalView.alignedRenderSurfaceFrame(
            insetRect: insetRect,
            rows: 79,
            cellHeight: 13
        )

        XCTAssertEqual(frame.maxY, insetRect.maxY, accuracy: 0.001)
        XCTAssertEqual(frame.height, 79 * 13, accuracy: 0.001)
        XCTAssertEqual(frame.minY - insetRect.minY, 7, accuracy: 0.001)
    }

    func testAlignedRenderSurfaceFrameCollapsesWhenNoRowsFit() {
        let insetRect = NSRect(x: 4, y: 4, width: 800, height: 0)

        let frame = RustTerminalView.alignedRenderSurfaceFrame(
            insetRect: insetRect,
            rows: 0,
            cellHeight: 13
        )

        XCTAssertEqual(frame.origin.x, insetRect.minX, accuracy: 0.001)
        XCTAssertEqual(frame.origin.y, insetRect.minY, accuracy: 0.001)
        XCTAssertEqual(frame.height, 0, accuracy: 0.001)
    }
}
