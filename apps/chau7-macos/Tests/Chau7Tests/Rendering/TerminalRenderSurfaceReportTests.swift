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
        var coalescer = TerminalRenderRequestCoalescer(needsSync: false, needsPresent: false)
        coalescer.requestSync()
        coalescer.requestSync()
        var retryState = TerminalRenderRetryState()
        retryState.recordFailure(reason: .noDrawable)
        retryState.recordFailure(reason: .noDrawable)
        retryState.recordFailure(reason: .noDrawable)
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
            lastPresentedFrameAgeMs: 42,
            coordinatorDiagnostics: .init(
                renderRequests: coalescer.diagnostics,
                retry: retryState.snapshot
            )
        )

        let formatted = report.formatted()

        XCTAssertTrue(formatted.contains("windowContentSize: 1920.0x1042.0"))
        XCTAssertTrue(formatted.contains("surfaceFrame: (x:4.0 y:4.0 800.0x1042.0)"))
        XCTAssertTrue(formatted.contains("gridFrame: (x:4.0 y:6.0 798.0x1040.0)"))
        XCTAssertTrue(formatted.contains("gridOrigin: (x:4.0 y:6.0)"))
        XCTAssertTrue(formatted.contains("raw cols × rows: 114 × 80"))
        XCTAssertTrue(formatted.contains("cols × rows: 114 × 80"))
        XCTAssertTrue(formatted.contains("max cols × rows: 2000 × 500"))
        XCTAssertTrue(formatted.contains("remainderX × remainderY: 2.0 × 2.0"))
        XCTAssertTrue(formatted.contains("remainderPixels: 4.0x4.0"))
        XCTAssertTrue(formatted.contains("metalActive: true"))
        XCTAssertTrue(formatted.contains("metalDrawableSize: 1600.0x2084.0"))
        XCTAssertTrue(formatted.contains("lastPresentedFrameAgeMs: 42"))
        XCTAssertTrue(
            formatted.contains(
                "renderRequests: pending(sync:true present:true count:2) requested(sync:2 present:2)"
            )
        )
        XCTAssertTrue(formatted.contains("coalesced(sync:1 present:1 total:2)"))
        XCTAssertTrue(formatted.contains("retry: reason:noDrawable consecutiveFailures:3"))
    }

    func testCompactReportIncludesBugTriageFields() {
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

        let compact = report.compact(reason: "fullscreen-enter", viewID: 7)

        XCTAssertTrue(compact.contains("Render surface reason=fullscreen-enter view=7"))
        XCTAssertTrue(compact.contains("windowContent=1920.0x1042.0"))
        XCTAssertTrue(compact.contains("surface=(x:4.0 y:4.0 800.0x1042.0)"))
        XCTAssertTrue(compact.contains("gridOrigin=(x:4.0 y:6.0)"))
        XCTAssertTrue(compact.contains("colsRows=114x80"))
        XCTAssertTrue(compact.contains("cell=7.0x13.0"))
        XCTAssertTrue(compact.contains("remainder=2.0x2.0"))
        XCTAssertTrue(compact.contains("drawable=1600.0x2084.0"))
        XCTAssertTrue(compact.contains("lastFrameAgeMs=42"))
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
        XCTAssertTrue(formatted.contains("windowContentSize: <nil>"))
        XCTAssertTrue(formatted.contains("metalViewBounds: <nil>"))
        XCTAssertTrue(formatted.contains("backingScaleFactor: <nil>"))
        XCTAssertTrue(formatted.contains("remainderPixels: <nil>"))
        XCTAssertTrue(formatted.contains("lastPresentedFrameAgeMs: <nil>"))
        XCTAssertTrue(formatted.contains("renderRequests: <nil>"))
        XCTAssertTrue(formatted.contains("retry: <nil>"))
    }
}
