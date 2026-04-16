import XCTest
import AppKit

#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class OverlayTabLiveHierarchyTests: XCTestCase {
    private var model: OverlayTabsModel!
    private var appModel: AppModel!

    private func drainMainQueue(_ seconds: TimeInterval = 0.05) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

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

    func testSelectingTabIgnoresSessionRetainedFrameAndAwaitsLiveReveal() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id
        model.tabs[1].session?.lastRenderedSnapshot = makeSnapshot()
        model.tabs[1].cachedSnapshot = nil

        model.selectTab(id: targetID)

        XCTAssertEqual(model.selectedTabID, targetID)
        XCTAssertFalse(
            model.isTerminalReady,
            "Selecting a tab should wait for a fresh live frame instead of presenting a retained snapshot"
        )
        XCTAssertEqual(model.selectedSurfacePresentation.phase, .awaitingLiveFrame)
    }

    func testSelectingTabArmsVisibleFrameReadyHandoffForTargetSession() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id
        model.tabs[1].session?.lastRenderedSnapshot = makeSnapshot()

        model.selectTab(id: targetID)

        XCTAssertTrue(
            model.tabs[1].session?.awaitingVisibleFrameReady == true,
            "Selected tab switches should wait for the selected session's first live frame"
        )
    }

    func testSelectedSessionVisibleFrameReadyRevealsTerminal() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id
        model.tabs[1].session?.lastRenderedSnapshot = makeSnapshot()

        model.selectTab(id: targetID)
        XCTAssertFalse(model.isTerminalReady)

        model.tabs[1].session?.notifyVisibleFrameReadyIfNeeded()
        XCTAssertFalse(
            model.isTerminalReady,
            "The repaint cover should stay visible for one compositor pass after the first frame is presented"
        )
        drainMainQueue()

        XCTAssertTrue(
            model.isTerminalReady,
            "The selected terminal should become visible only after its first live frame arrives"
        )
        XCTAssertFalse(model.tabs[1].session?.awaitingVisibleFrameReady ?? true)
    }

    func testSelectedSessionVisibleFrameReadyClearsTransientSnapshots() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id
        let snapshot = makeSnapshot()
        model.tabs[1].cachedSnapshot = snapshot
        model.tabs[1].session?.lastRenderedSnapshot = snapshot

        model.selectTab(id: targetID)
        model.tabs[1].session?.notifyVisibleFrameReadyIfNeeded()
        drainMainQueue()

        XCTAssertTrue(model.isTerminalReady)
        XCTAssertNil(model.tabs[1].cachedSnapshot)
        XCTAssertNil(model.tabs[1].session?.lastRenderedSnapshot)
    }

    func testSelectNextTabUsesLiveRevealHandoffPath() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id
        model.tabs[1].session?.lastRenderedSnapshot = makeSnapshot()

        model.selectNextTab()

        XCTAssertEqual(model.selectedTabID, targetID)
        XCTAssertFalse(model.isTerminalReady)
        XCTAssertTrue(model.tabs[1].session?.awaitingVisibleFrameReady == true)
    }

    func testSelectingColdTabDoesNotPresentRetainedSessionSnapshotDuringHandoff() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id
        model.tabs[1].cachedSnapshot = nil
        model.tabs[1].session?.lastRenderedSnapshot = makeSnapshot()

        model.selectTab(id: targetID)

        XCTAssertNotNil(
            model.tabs[1].visibleSnapshot,
            "Retained snapshots may still exist for persistence, but the selected surface should not present them during handoff"
        )
        XCTAssertFalse(model.isTerminalReady)
        XCTAssertEqual(model.selectedSurfacePresentation.phase, .awaitingLiveFrame)
    }

    func testVisibleSnapshotPrefersFocusedDisplaySessionFrame() {
        model.splitCurrentTabHorizontally()
        let splitSessions = model.tabs[0].splitController.terminalSessions
        let focusedPaneID = splitSessions[1].0
        let focusedSession = splitSessions[1].1
        model.tabs[0].splitController.setFocusedPane(focusedPaneID)

        model.tabs[0].session?.lastRenderedSnapshot = nil
        focusedSession.lastRenderedSnapshot = makeSnapshot(size: NSSize(width: 120, height: 60))

        XCTAssertEqual(model.tabs[0].visibleSnapshot?.size, NSSize(width: 120, height: 60))
    }

    func testVisibleSnapshotDoesNotFallBackToPrimarySessionWhenFocusedDisplaySessionDiffers() {
        model.splitCurrentTabHorizontally()
        let splitSessions = model.tabs[0].splitController.terminalSessions
        let focusedPaneID = splitSessions[1].0
        let focusedSession = splitSessions[1].1
        model.tabs[0].splitController.setFocusedPane(focusedPaneID)

        model.tabs[0].cachedSnapshot = nil
        model.tabs[0].restorePreviewSnapshot = nil
        model.tabs[0].session?.lastRenderedSnapshot = makeSnapshot(size: NSSize(width: 90, height: 50))
        focusedSession.lastRenderedSnapshot = nil

        XCTAssertNil(
            model.tabs[0].visibleSnapshot,
            "The selected surface snapshot must come from the focused display session, not the tab's primary session"
        )
    }

    func testRequestSelectedTabAuthoritativeRevealTargetsFocusedDisplaySession() {
        model.splitCurrentTabHorizontally()
        let splitSessions = model.tabs[0].splitController.terminalSessions
        let focusedPaneID = splitSessions[1].0
        let focusedSession = splitSessions[1].1
        model.tabs[0].splitController.setFocusedPane(focusedPaneID)

        model.tabs[0].cachedSnapshot = nil
        model.tabs[0].restorePreviewSnapshot = makeSnapshot()
        focusedSession.cancelVisibleFrameReadyHandoff()
        model.tabs[0].session?.cancelVisibleFrameReadyHandoff()

        model.requestSelectedTabAuthoritativeReveal(reason: "test_split_focus")

        XCTAssertTrue(
            focusedSession.awaitingVisibleFrameReady,
            "The focused display session should own the selected reveal handoff"
        )
        XCTAssertFalse(
            model.tabs[0].session?.awaitingVisibleFrameReady ?? true,
            "The primary session must not be armed when a different focused display session is visible"
        )
    }

    func testVisibleFrameReadyIgnoresPrimarySessionWhenFocusedDisplaySessionIsSelectedSurface() {
        model.splitCurrentTabHorizontally()
        let splitSessions = model.tabs[0].splitController.terminalSessions
        let focusedPaneID = splitSessions[1].0
        let focusedSession = splitSessions[1].1
        model.tabs[0].splitController.setFocusedPane(focusedPaneID)

        let snapshot = makeSnapshot()
        model.tabs[0].cachedSnapshot = nil
        model.tabs[0].restorePreviewSnapshot = nil
        model.tabs[0].session?.lastRenderedSnapshot = nil
        focusedSession.lastRenderedSnapshot = snapshot

        model.requestSelectedTabAuthoritativeReveal(reason: "test_split_visible_frame")

        XCTAssertFalse(model.isTerminalReady)
        XCTAssertTrue(focusedSession.awaitingVisibleFrameReady)
        XCTAssertFalse(model.tabs[0].session?.awaitingVisibleFrameReady ?? true)

        model.tabs[0].session?.notifyVisibleFrameReadyIfNeeded()
        drainMainQueue()

        XCTAssertFalse(
            model.isTerminalReady,
            "A non-visible primary session must not complete the selected surface reveal"
        )

        focusedSession.notifyVisibleFrameReadyIfNeeded()
        drainMainQueue()

        XCTAssertTrue(
            model.isTerminalReady,
            "The focused display session should be the only session that can complete the selected reveal"
        )
    }

    func testCleanupDistantSnapshotsEvictsDistantTabPreviewAndSessionFrames() {
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)

        for index in model.tabs.indices {
            let snapshot = makeSnapshot(size: NSSize(width: CGFloat(80 + index), height: CGFloat(40 + index)))
            model.tabs[index].cachedSnapshot = snapshot
            model.tabs[index].session?.lastRenderedSnapshot = snapshot
        }

        model.cleanupDistantSnapshots(currentIndex: 3)

        XCTAssertNotNil(model.tabs[1].cachedSnapshot)
        XCTAssertNotNil(model.tabs[1].session?.lastRenderedSnapshot)
        XCTAssertNil(model.tabs[0].cachedSnapshot)
        XCTAssertNil(model.tabs[0].session?.lastRenderedSnapshot)
        XCTAssertNotNil(model.tabs[5].cachedSnapshot)
        XCTAssertNotNil(model.tabs[5].session?.lastRenderedSnapshot)
        XCTAssertNil(model.tabs[6].cachedSnapshot)
        XCTAssertNil(model.tabs[6].session?.lastRenderedSnapshot)
    }

    func testCaptureSnapshotSkipsHiddenFreshRetainedView() {
        let rustView = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        rustView.isHidden = true

        XCTAssertNil(
            OverlayTabsModel.captureSnapshotImage(from: rustView),
            "A hidden terminal view without any rendered frame should not yield a retained snapshot"
        )
    }
}
#endif
