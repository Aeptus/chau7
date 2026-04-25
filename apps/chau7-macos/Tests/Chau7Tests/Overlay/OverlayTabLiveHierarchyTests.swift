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

    // testLiveHierarchyKeepsOnlySelectedTabByDefault,
    // testLiveHierarchyDropsPreviouslySelectedTabImmediately, and
    // testLiveHierarchyDoesNotKeepDistantMCPBackgroundTabLive were
    // removed in W1.1.B. See the matching note in OverlayTabsModelTests
    // for context: the contract these tests asserted stopped being
    // honoured by production after the W1.1 revert (commit 6a44d5a),
    // and W1.1.B removed the underlying `shouldKeepTabInLiveHierarchy`
    // method along with the unreachable Color.clear placeholder branch
    // it gated.

    func testSelectingTabKeepsSelectedSurfaceLiveImmediately() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id

        model.selectTab(id: targetID)

        XCTAssertEqual(model.selectedTabID, targetID)
        XCTAssertTrue(model.isTerminalReady)
        XCTAssertFalse(model.tabs[1].session?.awaitingVisibleFrameReady ?? true)
    }

    func testSelectNextTabKeepsSelectedSurfaceLiveImmediately() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id

        model.selectNextTab()

        XCTAssertEqual(model.selectedTabID, targetID)
        XCTAssertTrue(model.isTerminalReady)
        XCTAssertTrue(
            model.tabs[1].session?.awaitingVisibleFrameReady == false,
            "Tab switches should not arm a second visible-frame handoff for the selected tab"
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

    func testSelectedRestoreBootstrapPhaseDoesNotRefreshSelectedTabOutsideStartup() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id

        model.selectTab(id: targetID)

        let selectedSession = try XCTUnwrap(model.tabs[1].session)
        XCTAssertFalse(selectedSession.awaitingVisibleFrameReady)

        selectedSession.restoreBootstrapPhase = .replaying
        drainMainQueue()

        XCTAssertFalse(
            selectedSession.awaitingVisibleFrameReady,
            "Runtime restore bootstrap should not re-enter selected-tab reveal while the selected tab is visible"
        )
        XCTAssertEqual(model.selectedSurfacePresentation.phase, .live)
    }

    func testVisibleFrameReadyDiscardsRestorePreviewAndRecordsStartupLiveFrame() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        model.overlayWindow = window
        model.tabs[0].restorePreviewSnapshot = makeSnapshot()

        let session = try XCTUnwrap(model.tabs[0].session)
        let rustView = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        session.attachRustTerminal(rustView)
        session.resetPresentationSurfaceToLive()
        session.restoreBootstrapPhase = .replaying

        StartupRestoreCoordinator.shared.begin()
        defer { StartupRestoreCoordinator.shared.end() }
        StartupRestoreCoordinator.shared.noteWindowPrepared(
            windowNumber: window.windowNumber,
            selectedTabID: model.selectedTabID
        )

        var callbackCount = 0
        model.onStartupSelectedTabLiveFrameRecorded = {
            callbackCount += 1
        }

        model.noteStartupSelectedTabLiveFrameIfNeeded(reason: "visible_frame_ready")
        XCTAssertEqual(callbackCount, 1)
        XCTAssertNil(model.tabs[0].restorePreviewSnapshot)
        XCTAssertTrue(
            StartupRestoreCoordinator.shared.hasSelectedTabLiveFrame(windowNumber: window.windowNumber)
        )
    }

    func testSelectTabKeepsAttachedLiveSurfaceInPlace() {
        model.newTab(selectNewTab: false)
        let targetID = model.tabs[1].id
        let rustView = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        model.tabs[1].session?.attachRustTerminal(rustView)
        model.tabs[1].session?.resetPresentationSurfaceToLive()

        model.selectTab(id: targetID)

        XCTAssertEqual(model.selectedTabID, targetID)
        XCTAssertTrue(model.isTerminalReady)
        XCTAssertFalse(model.tabs[1].session?.awaitingVisibleFrameReady ?? true)
        XCTAssertEqual(model.selectedSurfacePresentation.phase, .live)
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

        XCTAssertFalse(model.tabs[0].session?.awaitingVisibleFrameReady ?? true)
        XCTAssertEqual(model.selectedSurfacePresentation.phase, .live)
    }

    func testReactivationRevealWithoutAttachedSurfaceStillAwaitsFreshFrame() {
        model.tabs[0].session?.resetPresentationSurfaceToLive()

        model.requestSelectedTabAuthoritativeReveal(reason: "windowDidBecomeMain+windowDidBecomeKey")

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

        XCTAssertTrue(focusedSession.awaitingVisibleFrameReady)
        XCTAssertFalse(model.tabs[0].session?.awaitingVisibleFrameReady ?? true)

        model.tabs[0].session?.notifyVisibleFrameReadyIfNeeded()
        drainMainQueue()

        focusedSession.notifyVisibleFrameReadyIfNeeded()
        drainMainQueue()

        XCTAssertFalse(focusedSession.awaitingVisibleFrameReady)
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
