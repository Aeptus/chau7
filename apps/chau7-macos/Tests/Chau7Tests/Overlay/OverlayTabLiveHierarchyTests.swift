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

    func testSelectingTabIgnoresSessionRetainedFrameAndAwaitsLiveReveal() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id

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

        model.selectTab(id: targetID)

        XCTAssertTrue(
            model.tabs[1].session?.awaitingVisibleFrameReady == true,
            "Selected tab switches should wait for the selected session's first live frame"
        )
    }

    func testBackgroundRestoreBootstrapPhaseDoesNotRefreshSelectedTab() {
        model.newTab(selectNewTab: false)

        let selectedSession = try XCTUnwrap(model.tabs[0].session)
        let backgroundSession = try XCTUnwrap(model.tabs[1].session)

        XCTAssertFalse(selectedSession.awaitingVisibleFrameReady)

        backgroundSession.restoreBootstrapPhase = .replaying
        drainMainQueue()

        XCTAssertFalse(
            selectedSession.awaitingVisibleFrameReady,
            "Background restore transitions should not force the currently selected tab back through reveal"
        )
    }

    func testSelectedSessionVisibleFrameReadyRevealsTerminal() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id

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

    func testSelectedSessionVisibleFrameReadyClearsRestorePreviewSnapshot() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id
        model.tabs[1].restorePreviewSnapshot = makeSnapshot()

        model.selectTab(id: targetID)
        model.tabs[1].session?.notifyVisibleFrameReadyIfNeeded()
        drainMainQueue()

        XCTAssertTrue(model.isTerminalReady)
        XCTAssertNil(model.tabs[1].restorePreviewSnapshot)
    }

    func testSelectedTabRevealTimeoutForcesLivePresentation() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id

        model.selectTab(id: targetID)
        XCTAssertFalse(model.isTerminalReady)

        drainMainQueue(OverlayTabsModel.selectedTerminalRevealTimeout + 0.1)

        XCTAssertTrue(
            model.isTerminalReady,
            "A missed visible-frame callback should not strand the selected tab behind the repaint cover"
        )
        XCTAssertFalse(model.tabs[1].session?.awaitingVisibleFrameReady ?? true)
    }

    func testOlderRevealTimeoutCannotCompleteNewerSelection() {
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)

        let firstTargetID = model.tabs[1].id
        let secondTargetID = model.tabs[2].id

        model.selectTab(id: firstTargetID)
        drainMainQueue(0.2)
        model.selectTab(id: secondTargetID)

        drainMainQueue(OverlayTabsModel.selectedTerminalRevealTimeout - 0.1)

        XCTAssertEqual(model.selectedTabID, secondTargetID)
        XCTAssertFalse(
            model.isTerminalReady,
            "An older reveal timeout must not complete a newer selected tab before its own timeout or live frame"
        )
        XCTAssertTrue(model.tabs[2].session?.awaitingVisibleFrameReady ?? false)
    }

    func testSelectNextTabUsesLiveRevealHandoffPath() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id

        model.selectNextTab()

        XCTAssertEqual(model.selectedTabID, targetID)
        XCTAssertFalse(model.isTerminalReady)
        XCTAssertTrue(model.tabs[1].session?.awaitingVisibleFrameReady == true)
    }

    func testRequestSelectedTabAuthoritativeRevealDiscardsSettledRestorePreview() {
        model.tabs[0].restorePreviewSnapshot = makeSnapshot()
        model.tabs[0].session?.markRestoreBootstrapReady(source: "test")

        model.requestSelectedTabAuthoritativeReveal(reason: "test_restore_preview_discard")

        XCTAssertNil(
            model.tabs[0].restorePreviewSnapshot,
            "Restore previews should be discarded once bootstrap has settled, even though selected-tab reveal no longer presents snapshots"
        )
    }

    func testRequestSelectedTabAuthoritativeRevealTargetsFocusedDisplaySession() {
        model.splitCurrentTabHorizontally()
        let splitSessions = model.tabs[0].splitController.terminalSessions
        let focusedPaneID = splitSessions[1].0
        let focusedSession = splitSessions[1].1
        model.tabs[0].splitController.setFocusedPane(focusedPaneID)

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

    func testReactivationRevealKeepsAttachedSelectedSurfaceLive() {
        let rustView = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        model.tabs[0].session?.attachRustTerminal(rustView)
        model.tabs[0].session?.resetPresentationSurfaceToLive()

        model.requestSelectedTabAuthoritativeReveal(reason: "windowDidBecomeMain+windowDidBecomeKey")

        XCTAssertTrue(
            model.isTerminalReady,
            "Reactivating an already-live selected tab should keep the current surface visible"
        )
        XCTAssertFalse(model.tabs[0].session?.awaitingVisibleFrameReady ?? true)
        XCTAssertEqual(model.selectedSurfacePresentation.phase, .live)
    }

    func testReactivationRevealWithoutAttachedSurfaceStillAwaitsFreshFrame() {
        model.tabs[0].session?.resetPresentationSurfaceToLive()

        model.requestSelectedTabAuthoritativeReveal(reason: "windowDidBecomeMain+windowDidBecomeKey")

        XCTAssertFalse(
            model.isTerminalReady,
            "A reactivation without an attached renderer still needs a blocking handoff"
        )
        XCTAssertTrue(model.tabs[0].session?.awaitingVisibleFrameReady ?? false)
        XCTAssertEqual(model.selectedSurfacePresentation.phase, .awaitingLiveFrame)
    }

    func testVisibleFrameReadyIgnoresPrimarySessionWhenFocusedDisplaySessionIsSelectedSurface() {
        model.splitCurrentTabHorizontally()
        let splitSessions = model.tabs[0].splitController.terminalSessions
        let focusedPaneID = splitSessions[1].0
        let focusedSession = splitSessions[1].1
        model.tabs[0].splitController.setFocusedPane(focusedPaneID)

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
