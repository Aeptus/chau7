import Chau7Core
import XCTest

final class RemoteTerminalScrollPolicyTests: XCTestCase {
    func testWideHistoryIsReachableAcrossEntireScrollRange() {
        // 1,000 source rows occupy 3,000 phone rows, with a 400pt viewport.
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            XCTAssertEqual(RemoteTerminalScrollPolicy.normalizedOffset(
                contentHeight: 60400, viewportHeight: 400,
                contentOffsetY: 60000 * (1 - fraction),
                cellHeight: 20, scrollbackRows: 1000, chunksPerRow: 3
            ), fraction, accuracy: 0.000001)
        }
    }

    func testScrollKeepsSubRowPrecisionUntilEngineResolvesHistory() {
        XCTAssertEqual(RemoteTerminalScrollPolicy.normalizedOffset(
            contentHeight: 60400, viewportHeight: 400, contentOffsetY: 59970,
            cellHeight: 20, scrollbackRows: 1000, chunksPerRow: 3
        ), 0.0005, accuracy: 0.000001)
    }

    func testBounceClampsAtBothHistoryEndpoints() {
        for (offset, expected) in [(61000.0, 0.0), (-1000.0, 1.0)] {
            XCTAssertEqual(RemoteTerminalScrollPolicy.normalizedOffset(
                contentHeight: 60400, viewportHeight: 400, contentOffsetY: offset,
                cellHeight: 20, scrollbackRows: 1000, chunksPerRow: 3
            ), expected)
        }
    }

    func testEmptyHistoryAndInvalidGeometryReturnLiveBottom() {
        XCTAssertEqual(RemoteTerminalScrollPolicy.normalizedOffset(
            contentHeight: 400, viewportHeight: 400, contentOffsetY: 0,
            cellHeight: 20, scrollbackRows: 0
        ), 0)
        for cellHeight in [0.0, -1, Double.nan, .infinity] {
            XCTAssertEqual(RemoteTerminalScrollPolicy.normalizedOffset(
                contentHeight: 1000, viewportHeight: 400, contentOffsetY: 0,
                cellHeight: cellHeight, scrollbackRows: 100
            ), 0)
        }
    }

    func testRendererCannotOverrideTrackingDraggingOrDeceleration() {
        for (tracking, dragging, decelerating) in [(true, false, false), (false, true, false), (false, false, true)] {
            XCTAssertFalse(RemoteTerminalScrollPolicy.shouldSynchronizePosition(
                force: false, isTracking: tracking, isDragging: dragging, isDecelerating: decelerating
            ))
        }
    }

    func testIdleRendererAndExplicitModeResetCanSynchronize() {
        XCTAssertTrue(RemoteTerminalScrollPolicy.shouldSynchronizePosition(
            force: false, isTracking: false, isDragging: false, isDecelerating: false
        ))
        XCTAssertTrue(RemoteTerminalScrollPolicy.shouldSynchronizePosition(
            force: true, isTracking: true, isDragging: true, isDecelerating: true
        ))
    }

    func testWrappedCanvasVisitsOnlyVisibleRows() {
        XCTAssertEqual(RemoteTerminalScrollPolicy.visibleRows(
            totalRows: 120, cellHeight: 20, minY: 0, maxY: 400
        ), 0 ..< 20)
    }

    func testPannedTUICanvasVisitsSourceRowsAtItsOffset() {
        XCTAssertEqual(RemoteTerminalScrollPolicy.visibleRows(
            totalRows: 120, cellHeight: 20, minY: 1000, maxY: 1400
        ), 50 ..< 70)
    }

    func testPartiallyVisibleRowsAndDirtyRectEdgesAreIncluded() {
        XCTAssertEqual(RemoteTerminalScrollPolicy.visibleRows(
            totalRows: 120, cellHeight: 20, minY: 19, maxY: 401
        ), 0 ..< 21)
    }

    func testVisibleRowsClampToGridDuringBounce() {
        XCTAssertEqual(RemoteTerminalScrollPolicy.visibleRows(
            totalRows: 3, cellHeight: 20, minY: -20, maxY: 40
        ), 0 ..< 2)
        XCTAssertEqual(RemoteTerminalScrollPolicy.visibleRows(
            totalRows: 3, cellHeight: 20, minY: 40, maxY: 100
        ), 2 ..< 3)
        XCTAssertTrue(RemoteTerminalScrollPolicy.visibleRows(
            totalRows: 3, cellHeight: 20, minY: 60, maxY: 100
        ).isEmpty)
    }

    func testInvalidVisibleAreaDoesNoDrawingWork() {
        for (height, minY, maxY) in [(0.0, 0.0, 100.0), (20.0, 20.0, 20.0), (20.0, Double.nan, 100.0)] {
            XCTAssertTrue(RemoteTerminalScrollPolicy.visibleRows(
                totalRows: 120, cellHeight: height, minY: minY, maxY: maxY
            ).isEmpty)
        }
    }
}

final class RemoteTerminalScrollRequestsTests: XCTestCase {
    func testGestureBurstBecomesOneLatestDestination() {
        var requests = RemoteTerminalScrollRequests()
        for index in 0 ... 1000 {
            requests.request(tabID: 7, fraction: Double(index) / 1000)
        }
        let request = requests.take(for: 7)
        XCTAssertEqual(request?.tabID, 7)
        XCTAssertEqual(request?.fraction, 1)
        XCTAssertNil(requests.take(for: 7))
    }

    func testNextRefreshCanConsumeAnUpdatedDestination() {
        var requests = RemoteTerminalScrollRequests()
        requests.request(tabID: 7, fraction: 0.25)
        XCTAssertEqual(requests.take(for: 7)?.fraction, 0.25)
        requests.request(tabID: 7, fraction: 0.75)
        XCTAssertEqual(requests.take(for: 7)?.fraction, 0.75)
    }

    func testTabSwitchDoesNotRetargetOldGesture() {
        var requests = RemoteTerminalScrollRequests()
        requests.request(tabID: 7, fraction: 0.5)
        XCTAssertNil(requests.take(for: 8))
        XCTAssertNil(requests.take(for: 7))
    }

    func testResetDiscardsPendingScroll() {
        var requests = RemoteTerminalScrollRequests()
        requests.request(tabID: 7, fraction: 0.5)
        requests.discard()
        XCTAssertNil(requests.take(for: 7))
    }

    func testInvalidRequestsDoNotReplacePendingDestination() {
        var requests = RemoteTerminalScrollRequests()
        requests.request(tabID: 7, fraction: 0.5)
        requests.request(tabID: 0, fraction: 0.25)
        requests.request(tabID: 7, fraction: .nan)
        XCTAssertEqual(requests.take(for: 7)?.fraction, 0.5)
    }

    func testPendingRequestClampsToHistoryBounds() {
        var requests = RemoteTerminalScrollRequests()
        for (fraction, expected) in [(-1.0, 0.0), (2.0, 1.0)] {
            requests.request(tabID: 7, fraction: fraction)
            XCTAssertEqual(requests.take(for: 7)?.fraction, expected)
        }
    }
}
