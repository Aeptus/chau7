import AppKit
import XCTest
@testable import Chau7

@MainActor
final class RustTerminalViewLocalEchoRenderingTests: XCTestCase {
    func testLocalEchoOverlayRequestsMetalSyncWhenMetalRenderingIsActive() {
        let view = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 160, height: 80))
        view.isMetalRenderingActive = true
        var syncRequestCount = 0
        view.onDisplaySyncNeeded = {
            syncRequestCount += 1
        }

        view.localEchoOverlay = [0: makeCell("x")]
        view.updateLocalEchoOverlay()

        XCTAssertTrue(view.needsGridSync)
        XCTAssertEqual(syncRequestCount, 1)
    }

    func testLocalEchoOverlayDoesNotRequestMetalSyncWhenCPURenderingIsActive() {
        let view = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 160, height: 80))
        view.isMetalRenderingActive = false
        var syncRequestCount = 0
        view.onDisplaySyncNeeded = {
            syncRequestCount += 1
        }

        view.localEchoOverlay = [0: makeCell("x")]
        view.updateLocalEchoOverlay()

        XCTAssertFalse(view.needsGridSync)
        XCTAssertEqual(syncRequestCount, 0)
    }

    func testClearingLocalEchoOverlayRequestsMetalSyncWhenMetalRenderingIsActive() {
        let view = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 160, height: 80))
        view.isMetalRenderingActive = true
        view.localEchoOverlay = [0: makeCell("x")]
        var syncRequestCount = 0
        view.onDisplaySyncNeeded = {
            syncRequestCount += 1
        }

        view.clearLocalEchoOverlay()

        XCTAssertTrue(view.localEchoOverlay.isEmpty)
        XCTAssertTrue(view.needsGridSync)
        XCTAssertEqual(syncRequestCount, 1)
    }

    private func makeCell(_ character: String) -> RustCellData {
        RustCellData(
            character: UInt32(character.unicodeScalars.first!.value),
            fg_r: 255,
            fg_g: 255,
            fg_b: 255,
            bg_r: 0,
            bg_g: 0,
            bg_b: 0,
            flags: 0,
            _pad: 0,
            link_id: 0
        )
    }
}
