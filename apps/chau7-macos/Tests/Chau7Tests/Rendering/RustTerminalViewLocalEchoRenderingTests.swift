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
        var cell = RustCellData()
        let byte = UInt8(character.unicodeScalars.first!.value)
        cell.cluster_offset = RustCellLocalEcho.encode(byte: byte)
        cell.cluster_len = 1
        return cell
    }

    func testProcessOutputClearsPostEnterPTYWait() {
        let view = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 160, height: 80))
        view.awaitingPostEnterPTYOutput = true

        _ = view.processOutputForLocalEcho(Data([0x20])) // any byte

        XCTAssertFalse(
            view.awaitingPostEnterPTYOutput,
            "PTY output must end the post-Enter stale-cursor window"
        )
    }

    func testApplyLocalEchoSkipsPaintWhileAwaitingPostEnterPTY() {
        let settings = FeatureSettings.shared
        let previous = settings.isLocalEchoEnabled
        settings.isLocalEchoEnabled = true
        defer { settings.isLocalEchoEnabled = previous }

        let view = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 160, height: 80))
        view.cols = 80
        view.rows = 24
        view.isPtyEchoLikelyEnabled = true
        view.hostsAITUI = false
        view.localEchoCursor = nil
        view.awaitingPostEnterPTYOutput = true

        view.applyLocalEcho(for: [0x61]) // 'a'

        XCTAssertTrue(
            view.localEchoOverlay.isEmpty,
            "Overlay must not be painted while rust.cursorPosition is stale after Enter"
        )
        XCTAssertTrue(
            view.pendingLocalEcho.isEmpty,
            "Suppression queue must not be primed for a paint we didn't make"
        )
    }
}
