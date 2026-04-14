import XCTest
import AppKit
@testable import Chau7

@MainActor
final class OverlayTabSnapshotRetentionTests: XCTestCase {
    private var model: OverlayTabsModel!
    private var appModel: AppModel!

    private func makeSnapshot(size: NSSize = NSSize(width: 80, height: 40)) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }

    override func setUp() {
        super.setUp()
        OverlayTabsModel.clearPersistedWindowState()
        OverlayTabsModel.sessionFinders = [:]
        appModel = AppModel()
        model = OverlayTabsModel(appModel: appModel, restoreState: false)
    }

    override func tearDown() {
        model = nil
        appModel = nil
        OverlayTabsModel.sessionFinders = [:]
        OverlayTabsModel.clearPersistedWindowState()
        super.tearDown()
    }

    func testCleanupDistantSnapshotsClearsOnlySessionRetainedFrames() {
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)

        for index in model.tabs.indices {
            let snapshot = makeSnapshot(size: NSSize(width: CGFloat(80 + index), height: CGFloat(40 + index)))
            model.tabs[index].cachedSnapshot = snapshot
            model.tabs[index].session?.lastRenderedSnapshot = snapshot
        }

        model.cleanupDistantSnapshots(currentIndex: 2)

        XCTAssertNotNil(model.tabs[0].cachedSnapshot)
        XCTAssertNil(model.tabs[0].session?.lastRenderedSnapshot)
        XCTAssertNotNil(model.tabs[1].cachedSnapshot)
        XCTAssertNotNil(model.tabs[1].session?.lastRenderedSnapshot)
        XCTAssertNotNil(model.tabs[4].cachedSnapshot)
        XCTAssertNil(model.tabs[4].session?.lastRenderedSnapshot)
    }

    func testCloseTabClearsSessionRetainedSnapshotBeforeSessionShutdown() throws {
        model.newTab(selectNewTab: false)
        let closingTabID = model.tabs[1].id
        let closingSession = try XCTUnwrap(model.tabs[1].session)
        let snapshot = makeSnapshot(size: NSSize(width: 120, height: 60))
        model.tabs[1].cachedSnapshot = snapshot
        closingSession.lastRenderedSnapshot = snapshot

        model.closeTab(id: closingTabID, skipWarning: true)

        XCTAssertNil(closingSession.lastRenderedSnapshot)
    }
}
