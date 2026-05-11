import CoreGraphics
import XCTest
@testable import Chau7Core

final class TerminalRenderSurfaceReportTests: XCTestCase {
    func testFormattedReportIncludesGeometryAndMetalState() {
        let geometry = TerminalRenderGeometry.resolve(
            bounds: CGRect(x: 0, y: 0, width: 808, height: 1050),
            inset: 4,
            cellSize: CGSize(width: 7, height: 13)
        )
        let report = TerminalRenderSurfaceReport(
            windowFrame: CGRect(x: 10, y: 20, width: 1920, height: 1080),
            contentLayoutRect: CGRect(x: 0, y: 0, width: 1920, height: 1042),
            contentViewBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            terminalBounds: CGRect(x: 0, y: 0, width: 808, height: 1050),
            geometry: geometry,
            backingScaleFactor: 2,
            metalActive: true,
            metalViewFrame: geometry.surfaceFrame,
            metalViewBounds: CGRect(origin: .zero, size: geometry.surfaceFrame.size),
            metalDrawableSize: CGSize(width: 1600, height: 2084),
            lastPresentedFrameAgeMs: 42
        )

        let formatted = report.formatted()

        XCTAssertTrue(formatted.contains("surfaceFrame: (x:4.0 y:4.0 800.0x1042.0)"))
        XCTAssertTrue(formatted.contains("gridFrame: (x:4.0 y:6.0 798.0x1040.0)"))
        XCTAssertTrue(formatted.contains("cols × rows: 114 × 80"))
        XCTAssertTrue(formatted.contains("remainderX × remainderY: 2.0 × 2.0"))
        XCTAssertTrue(formatted.contains("metalActive: true"))
        XCTAssertTrue(formatted.contains("metalDrawableSize: 1600.0x2084.0"))
        XCTAssertTrue(formatted.contains("lastPresentedFrameAgeMs: 42"))
    }

    func testFormattedReportHandlesMissingWindowAndMetalFields() {
        let geometry = TerminalRenderGeometry.resolve(
            bounds: CGRect(x: 0, y: 0, width: 80, height: 10),
            inset: 0,
            cellSize: CGSize(width: 8, height: 13)
        )
        let report = TerminalRenderSurfaceReport(
            windowFrame: nil,
            contentLayoutRect: nil,
            contentViewBounds: nil,
            terminalBounds: CGRect(x: 0, y: 0, width: 80, height: 10),
            geometry: geometry,
            backingScaleFactor: nil,
            metalActive: false,
            metalViewFrame: nil,
            metalViewBounds: nil,
            metalDrawableSize: nil,
            lastPresentedFrameAgeMs: nil
        )

        let formatted = report.formatted()

        XCTAssertTrue(formatted.contains("windowFrame: <nil>"))
        XCTAssertTrue(formatted.contains("metalViewBounds: <nil>"))
        XCTAssertTrue(formatted.contains("backingScaleFactor: <nil>"))
        XCTAssertTrue(formatted.contains("lastPresentedFrameAgeMs: <nil>"))
    }
}
