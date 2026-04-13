import XCTest
import AppKit

#if !SWIFT_PACKAGE
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

    func testExportTabStatesPersistsSelectedRestorePreviewSnapshot() throws {
        let model = OverlayTabsModel(appModel: AppModel(), restoreState: false)
        model.tabs[0].restorePreviewSnapshot = makePreviewImage()

        let states = model.exportTabStates()
        let persistedData = try XCTUnwrap(states.first?.previewSnapshotPNGData)
        let preview = try XCTUnwrap(OverlayTabsModel.restorePreviewImage(from: persistedData))

        XCTAssertEqual(preview.size.width, 80)
        XCTAssertEqual(preview.size.height, 40)
    }

    func testRestoreSavedTabsHydratesPersistedPreviewSnapshot() throws {
        let previewData = try XCTUnwrap(OverlayTabsModel.pngData(from: makePreviewImage()))
        let state = SavedTabState(
            customTitle: "Preview Restore",
            color: TabColor.blue.rawValue,
            directory: "/tmp/preview-restore",
            selectedIndex: 0,
            tokenOptOverride: nil,
            scrollbackContent: nil,
            aiResumeCommand: nil,
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
        XCTAssertFalse(
            restoredModel.isTerminalReady,
            "Selected restored tab should keep the passive preview visible until live restore settles"
        )

        restoredTab.session?.markRestoreBootstrapReady(source: "test")

        XCTAssertNil(restoredModel.tabs[0].restorePreviewSnapshot)
        XCTAssertTrue(
            restoredModel.isTerminalReady,
            "Passive preview should be discarded once restore bootstrap settles"
        )
    }
}
#endif
