import XCTest
import AppKit
@testable import Chau7

@MainActor
final class OverlayRestorePreviewTests: XCTestCase {

    private func makePreviewImage(size: NSSize = NSSize(width: 80, height: 40)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    func testExportTabStatesDoesNotRepersistHydratedRestorePreviewSnapshot() {
        let model = OverlayTabsModel(appModel: AppModel(), restoreState: false)
        model.tabs[0].restorePreviewSnapshot = makePreviewImage()

        let states = model.exportTabStates()
        XCTAssertNil(
            states.first?.previewSnapshotPNGData,
            "Restore previews loaded from previous launches should not be persisted again"
        )
    }

    func testRestoreSavedTabsHydratesPersistedPreviewSnapshot() throws {
        let previewData = try XCTUnwrap(OverlayTabsModel.pngData(from: makePreviewImage()))
        // A persisted restore preview only outlives the selected tab's init
        // reveal while the session is still in its restore-bootstrap
        // `.replaying` phase — `requestSelectedTabAuthoritativeReveal` runs
        // synchronously during init and `discardSettledRestorePreviews`
        // drops previews for any tab whose session is not replaying. The
        // bootstrap phase is only entered for tabs that expect a resume
        // prefill, so give this tab AI resume metadata to mirror the real
        // resumable-tab scenario these snapshots accompany. Codex provider +
        // session id survives restore sanitization without an on-disk
        // transcript (unlike Claude UUIDs), keeping the test hermetic.
        let codexSessionID = "preview-restore-codex"
        let state = SavedTabState(
            customTitle: "Preview Restore",
            color: TabColor.blue.rawValue,
            directory: "/tmp/preview-restore",
            selectedIndex: 0,
            tokenOptOverride: nil,
            scrollbackContent: nil,
            aiResumeCommand: "codex resume \(codexSessionID)",
            aiProvider: "codex",
            aiSessionId: codexSessionID,
            aiSessionIdSource: .explicit,
            splitLayout: nil,
            focusedPaneID: nil,
            paneStates: nil,
            previewSnapshotPNGData: previewData
        )

        let restoredModel = OverlayTabsModel(
            appModel: AppModel(),
            restoreState: false,
            restoringStates: [state]
        )

        let restoredTab = try XCTUnwrap(restoredModel.tabs.first)
        XCTAssertNotNil(restoredTab.restorePreviewSnapshot)

        // Once the bootstrap settles, the next authoritative reveal discards
        // the now-settled preview. The reveal trigger is environment-gated
        // (startup-restore-active / key window), so drive the discard pass
        // directly to assert the settled-preview cleanup deterministically.
        restoredTab.session?.markRestoreBootstrapReady(source: "test")
        restoredModel.discardSettledRestorePreviews(reason: "test")

        XCTAssertNil(restoredModel.tabs[0].restorePreviewSnapshot)
    }
}
