import XCTest
import AppKit

#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class OverlayTabLiveHierarchyTests: XCTestCase {
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

    func testLiveHierarchyKeepsOnlySelectedTabByDefault() {
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)

        let selectedID = model.selectedTabID

        for (index, tab) in model.tabs.enumerated() {
            XCTAssertEqual(
                model.shouldKeepTabInLiveHierarchy(tab: tab, index: index),
                tab.id == selectedID,
                "Only the selected tab should stay live by default"
            )
        }
    }

    func testLiveHierarchyKeepsPreviouslySelectedTabDuringShortHandoff() {
        model.newTab()
        model.newTab()

        let originalSelectedID = model.tabs[2].id
        XCTAssertEqual(model.selectedTabID, originalSelectedID)

        model.selectTab(id: model.tabs[1].id)

        XCTAssertEqual(model.previousLiveHierarchyTabID, originalSelectedID)
        XCTAssertTrue(
            model.shouldKeepTabInLiveHierarchy(tab: model.tabs[2], index: 2),
            "The previously selected tab should stay live during the handoff window"
        )
    }

    func testLiveHierarchyReleasesPreviouslySelectedTabAfterHandoffWindow() {
        model.newTab()
        model.newTab()

        let originalSelectedID = model.tabs[2].id
        model.selectTab(id: model.tabs[1].id)

        RunLoop.main.run(
            until: Date().addingTimeInterval(
                OverlayTabsModel.previousLiveHierarchyKeepAliveInterval + 0.1
            )
        )

        XCTAssertNil(model.previousLiveHierarchyTabID)
        XCTAssertFalse(
            model.shouldKeepTabInLiveHierarchy(tab: model.tabs[2], index: 2),
            "The previous tab should drop out of the live hierarchy after the handoff window"
        )
        XCTAssertNotEqual(model.selectedTabID, originalSelectedID)
    }

    func testLiveHierarchyKeepsDistantMCPBackgroundTabUntilTerminalBootstraps() {
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)

        let distantIndex = 3
        model.tabs[distantIndex].isMCPControlled = true

        XCTAssertTrue(
            model.shouldKeepTabInLiveHierarchy(tab: model.tabs[distantIndex], index: distantIndex),
            "Fresh MCP background tabs should stay in the hierarchy so their shell can start"
        )

        let terminalView = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        model.tabs[distantIndex].session?.attachRustTerminal(terminalView)

        XCTAssertFalse(
            model.shouldKeepTabInLiveHierarchy(tab: model.tabs[distantIndex], index: distantIndex),
            "Once a terminal view has attached, distant MCP tabs can fall back to placeholder rendering"
        )
    }

    func testVisibleSnapshotFallsBackToSessionRetainedFrame() {
        let snapshot = makeSnapshot()
        model.tabs[0].session?.lastRenderedSnapshot = snapshot

        XCTAssertNotNil(model.tabs[0].visibleSnapshot)
        XCTAssertEqual(model.tabs[0].visibleSnapshot?.size.width, snapshot.size.width)
        XCTAssertEqual(model.tabs[0].visibleSnapshot?.size.height, snapshot.size.height)
    }

    func testSelectingTabUsesSessionRetainedFrameWhenTabCacheIsEmpty() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id
        model.tabs[1].session?.lastRenderedSnapshot = makeSnapshot()
        model.tabs[1].cachedSnapshot = nil

        model.selectTab(id: targetID)

        XCTAssertEqual(model.selectedTabID, targetID)
        XCTAssertFalse(
            model.isTerminalReady,
            "Selecting a tab with only a session-retained frame should still use the snapshot-first handoff"
        )
    }
}
#endif
