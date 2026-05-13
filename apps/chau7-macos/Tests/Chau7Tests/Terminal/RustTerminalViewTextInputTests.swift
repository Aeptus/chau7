import XCTest
import AppKit
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class RustTerminalViewTextInputTests: XCTestCase {

    func testShouldSuppressRawTextFallbackWhenInputContextHandled() {
        let view = RustTerminalView(frame: .zero)

        XCTAssertTrue(
            view.shouldSuppressRawTextFallback(afterInputContextHandled: true),
            "Committed input from NSTextInputContext should never fall through to raw character fallback"
        )
    }

    func testShouldSuppressRawTextFallbackWhenMarkedTextExists() {
        let view = RustTerminalView(frame: .zero)

        view.setMarkedText("^", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))

        XCTAssertTrue(view.hasMarkedText(), "Dead-key composition should register marked text")
        XCTAssertTrue(
            view.shouldSuppressRawTextFallback(afterInputContextHandled: false),
            "Pending dead-key composition must suppress raw fallback to avoid injecting literal accent characters"
        )
    }

    func testShouldNotSuppressRawTextFallbackWithoutHandledInputOrMarkedText() {
        let view = RustTerminalView(frame: .zero)

        XCTAssertFalse(
            view.shouldSuppressRawTextFallback(afterInputContextHandled: false),
            "Plain text keys still need the fallback path when NSTextInputContext does not consume the event"
        )
    }

    func testShouldReconcilePollingModeWhenLoopIsStillRunningWhileMarkedInactive() {
        XCTAssertTrue(
            RustTerminalView.shouldReconcilePollingMode(
                desiredLive: false,
                markedLive: false,
                actuallyRunning: true
            )
        )
    }

    func testShouldNotReconcilePollingModeWhenMarkedStateMatchesReality() {
        XCTAssertFalse(
            RustTerminalView.shouldReconcilePollingMode(
                desiredLive: true,
                markedLive: true,
                actuallyRunning: true
            )
        )
    }

    func testShouldKeepStartupPollingWhileWaitingForFirstPTYBytes() {
        XCTAssertTrue(
            RustTerminalView.shouldKeepStartupPolling(
                isTerminalStarted: true,
                startupBytesLogged: 0,
                awaitingInitialPTYOutput: true
            )
        )
    }

    func testShouldStopStartupPollingAfterFirstPTYBytes() {
        XCTAssertFalse(
            RustTerminalView.shouldKeepStartupPolling(
                isTerminalStarted: true,
                startupBytesLogged: 1,
                awaitingInitialPTYOutput: true
            )
        )
    }

    func testShouldStopStartupPollingAfterBootstrapSettles() {
        XCTAssertFalse(
            RustTerminalView.shouldKeepStartupPolling(
                isTerminalStarted: true,
                startupBytesLogged: 0,
                awaitingInitialPTYOutput: false
            )
        )
    }

    func testShouldRefreshVisibleTerminalFromPumpOnlyForVisibleChangingTabs() {
        XCTAssertTrue(
            RustTerminalView.shouldRefreshVisibleTerminalFromPump(
                changed: true,
                notifyUpdateChanges: true,
                isHidden: false,
                hasVisibleWindow: true
            )
        )

        XCTAssertFalse(
            RustTerminalView.shouldRefreshVisibleTerminalFromPump(
                changed: false,
                notifyUpdateChanges: true,
                isHidden: false,
                hasVisibleWindow: true
            )
        )

        XCTAssertFalse(
            RustTerminalView.shouldRefreshVisibleTerminalFromPump(
                changed: true,
                notifyUpdateChanges: false,
                isHidden: false,
                hasVisibleWindow: true
            )
        )

        XCTAssertFalse(
            RustTerminalView.shouldRefreshVisibleTerminalFromPump(
                changed: true,
                notifyUpdateChanges: true,
                isHidden: true,
                hasVisibleWindow: true
            )
        )
    }

    func testApplyRenderPhaseDemotionReconcilesPollingMode() {
        let view = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let container = NSView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = container
        container.addSubview(view)
        window.makeKeyAndOrderFront(nil)
        defer {
            view.stopPollingLoop()
            window.orderOut(nil)
        }

        view.isTerminalStarted = true
        view.applyRenderPhase(.active, isInteractive: true, reason: "test")
        XCTAssertTrue(view.livePollingActiveForProfiling)

        view.applyRenderPhase(.active, isInteractive: false, reason: "test")

        XCTAssertFalse(
            view.livePollingActiveForProfiling,
            "Demoting a visible tab to noninteractive should drop it out of the active polling loop immediately"
        )
        XCTAssertEqual(view.currentRenderLoopMode, "background_drain")
    }

    func testApplyRenderPhaseClearsLocalEchoWhenViewBecomesNonInteractive() {
        let view = RustTerminalView(frame: .zero)
        view.localEchoOverlay = [0: makeCell("g")]
        view.isInteractive = true

        view.applyRenderPhase(.active, isInteractive: false, reason: "test")

        XCTAssertTrue(view.localEchoOverlay.isEmpty)
    }

    func testApplyRenderPhaseClearsLocalEchoWhenViewStopsLivePresentation() {
        let view = RustTerminalView(frame: .zero)
        view.localEchoOverlay = [0: makeCell("g")]

        view.applyRenderPhase(.hidden, isInteractive: false, reason: "test")

        XCTAssertTrue(view.localEchoOverlay.isEmpty)
    }

    func testProcessOutputForLocalEchoSuppressesPlainEchoBytes() {
        let view = RustTerminalView(frame: .zero)
        view.pendingLocalEcho = Array("git".utf8)
        view.localEchoOverlay = [0: makeCell("g")]

        let filtered = view.processOutputForLocalEcho(Data("git".utf8))

        XCTAssertTrue(filtered.isEmpty)
        XCTAssertTrue(view.pendingLocalEcho.isEmpty)
        XCTAssertTrue(view.localEchoOverlay.isEmpty)
    }

    func testProcessOutputForLocalEchoBypassesSuppressionWhenOutputContainsEscapeSequence() {
        let view = RustTerminalView(frame: .zero)
        view.pendingLocalEcho = Array("git".utf8)
        view.localEchoOverlay = [0: makeCell("g")]

        let output = Data([0x1B, 0x5B, 0x32, 0x4B] + Array("git".utf8))
        let filtered = view.processOutputForLocalEcho(output)

        XCTAssertEqual(filtered, output)
        XCTAssertTrue(view.pendingLocalEcho.isEmpty)
        XCTAssertTrue(view.localEchoOverlay.isEmpty)
    }

    func testProcessOutputForLocalEchoBypassesSuppressionWhenOutputContainsCarriageReturn() {
        let view = RustTerminalView(frame: .zero)
        view.pendingLocalEcho = Array("git".utf8)
        view.localEchoOverlay = [0: makeCell("g")]

        let output = Data([0x0D] + Array("git".utf8))
        let filtered = view.processOutputForLocalEcho(output)

        XCTAssertEqual(filtered, output)
        XCTAssertTrue(view.pendingLocalEcho.isEmpty)
        XCTAssertTrue(view.localEchoOverlay.isEmpty)
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
#endif
