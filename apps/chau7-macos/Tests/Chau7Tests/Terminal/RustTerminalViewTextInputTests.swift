import XCTest
import AppKit
import Carbon.HIToolbox
@testable import Chau7

@MainActor
final class RustTerminalViewTextInputTests: XCTestCase {

    func testPendingApprovalDoesNotForwardPaste() {
        let view = RustTerminalView(frame: .zero)
        var inputs: [String] = []
        view.onInput = { inputs.append($0) }
        view.shouldAcceptUserText = { _, _ in false }
        view.pasteText("rm -rf /tmp/example\n")
        XCTAssertTrue(inputs.isEmpty)
    }

    func testDeferredInputCannotResumeWithoutOriginalBackend() {
        let view = RustTerminalView(frame: .zero)
        var inputs: [String] = []
        var decision: (() -> Void)?
        view.onInput = { inputs.append($0) }
        view.shouldAcceptUserText = { _, resume in decision = resume
            return false
        }
        view.pasteText("test\n")
        decision?()
        XCTAssertTrue(inputs.isEmpty)
    }

    func testImmediatelyAllowedPasteStillForwardsExactlyOnce() {
        let view = RustTerminalView(frame: .zero)
        var inputs: [String] = []
        view.onInput = { inputs.append($0) }
        view.shouldAcceptUserText = { _, _ in true }
        view.pasteText("hello\n")
        XCTAssertEqual(inputs, ["hello\n"])
    }

    func testTerminalDoesNotAdvertiseMacOSServicesPasteboardTypes() {
        let view = RustTerminalView(frame: .zero)

        XCTAssertNil(view.validRequestor(forSendType: .string, returnType: nil))
        XCTAssertNil(view.validRequestor(forSendType: nil, returnType: .string))
    }

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

    func testGenerateSpecialKeySequenceTreatsKeypadEnterAsReturn() {
        let view = RustTerminalView(frame: .zero)

        XCTAssertEqual(
            view.generateSpecialKeySequence(keyCode: UInt16(kVK_Return), modifiers: []),
            [0x0D],
            "Main Return should send carriage return"
        )
        XCTAssertEqual(
            view.generateSpecialKeySequence(keyCode: UInt16(kVK_ANSI_KeypadEnter), modifiers: []),
            [0x0D],
            "Numeric keypad Enter should send carriage return"
        )
    }

    func testShouldKeepStartupPollingWhileWaitingForFirstPTYBytes() {
        XCTAssertTrue(
            RustTerminalView.shouldKeepStartupPolling(
                isTerminalStarted: true,
                hasObservedInitialPTYActivity: false,
                awaitingInitialPTYOutput: true
            )
        )
    }

    func testShouldStopStartupPollingAfterFirstPTYBytes() {
        XCTAssertFalse(
            RustTerminalView.shouldKeepStartupPolling(
                isTerminalStarted: true,
                hasObservedInitialPTYActivity: true,
                awaitingInitialPTYOutput: true
            )
        )
    }

    func testShouldStopStartupPollingAfterBootstrapSettles() {
        XCTAssertFalse(
            RustTerminalView.shouldKeepStartupPolling(
                isTerminalStarted: true,
                hasObservedInitialPTYActivity: false,
                awaitingInitialPTYOutput: false
            )
        )
    }

    func testMetadataOnlyPollCountsAsPTYStartupActivity() {
        XCTAssertTrue(RustTerminalView.containsPTYActivity(.metadataChanged))
        XCTAssertTrue(RustTerminalView.containsPTYActivity(.gridChanged))
        XCTAssertFalse(RustTerminalView.containsPTYActivity([]))
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
        // The polling policy is occlusion-aware: in a headless test host the
        // window is typically reported occluded, so the promoted mode depends
        // on the live window state. Assert the reconciliation matches the
        // policy rather than hard-coding eventDrain. (Pure policy semantics —
        // including occlusion and the visible-but-noninteractive case — are
        // covered by VisibleTerminalPollingPolicyTests.)
        XCTAssertEqual(
            view.livePollingActiveForProfiling,
            view.desiredPollingMode() == .eventDrain,
            "applyRenderPhase must reconcile live polling with the policy's desired mode"
        )

        view.applyRenderPhase(.warm, isInteractive: false, reason: "test")

        XCTAssertFalse(
            view.livePollingActiveForProfiling,
            "Demoting a tab out of the active phase should drop it out of the active polling loop immediately"
        )
        XCTAssertEqual(view.currentRenderLoopMode, "background_drain")
    }

    func testCopyJoinsTUILinesThroughBothSelectionPaths() {
        let view = RustTerminalView(frame: .zero)
        let backend = FakeTerminalBackend()
        backend.selectionText = "echo hello\n    --flag value"
        view.rustTerminal = backend
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }

        for alternateScreen in [false, true] {
            view.hostsTUIApp = !alternateScreen
            backend.alternateScreenActive = alternateScreen
            XCTAssertEqual(view.getSelectedText(), "echo hello --flag value")
            XCTAssertTrue(view.writeSelectionToPasteboard(pasteboard, types: [.string]))
            XCTAssertEqual(pasteboard.string(forType: .string), "echo hello --flag value")
        }

        view.hostsTUIApp = false
        backend.alternateScreenActive = false
        XCTAssertEqual(view.getSelectedText(), backend.selectionText)
        XCTAssertTrue(view.writeSelectionToPasteboard(pasteboard, types: [.string]))
        XCTAssertEqual(pasteboard.string(forType: .string), backend.selectionText)
    }

    func testWhitespaceTUISelectionStillCountsAsSelection() {
        let view = RustTerminalView(frame: .zero)
        let backend = FakeTerminalBackend()
        backend.selectionText = "  \n  "
        view.rustTerminal = backend
        view.hostsTUIApp = true
        XCTAssertTrue(view.hasSelection)
        XCTAssertEqual(view.getSelectedText(), "")
    }

    func testBusyTUIClickUsesApplicationCursorMode() throws {
        let view = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let backend = FakeTerminalBackend()
        view.rustTerminal = backend
        view.hostsTUIApp = true
        view.isAtPrompt = { false }
        view.setApplicationCursorMode(true)
        let rect = try XCTUnwrap(view.currentRenderGeometry.cellRect(col: 3, row: 0))
        XCTAssertTrue(view.handleClickToPosition(at: NSPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(backend.sentText, [String(repeating: "\u{1b}OC", count: 3)])
    }

    func testClickRejectsOutputRowsAndScrollback() throws {
        let view = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let backend = FakeTerminalBackend()
        view.rustTerminal = backend
        view.hostsTUIApp = true
        view.isAtPrompt = { true }
        let output = try XCTUnwrap(view.currentRenderGeometry.cellRect(col: 3, row: 1))
        XCTAssertFalse(view.handleClickToPosition(at: NSPoint(x: output.midX, y: output.midY)))
        backend.displayOffset = 1
        let input = try XCTUnwrap(view.currentRenderGeometry.cellRect(col: 3, row: 0))
        XCTAssertFalse(view.handleClickToPosition(at: NSPoint(x: input.midX, y: input.midY)))
        XCTAssertTrue(backend.sentText.isEmpty)
    }

    func testClickAcrossSoftWrapSendsOnlyHorizontalCharacterMovement() throws {
        let view = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let backend = FakeTerminalBackend()
        backend.cursorPosition = (4, 1)
        backend.logicalLineHitProvider = { row, _ in
            RustTerminalFFI.LogicalLineHit(text: "abcdefghijklmnop", startRow: 0, clickedUTF16Offset: row == 1 ? 15 : 5)
        }
        view.rustTerminal = backend
        view.hostsTUIApp = true
        view.setApplicationCursorMode(true)
        let rect = try XCTUnwrap(view.currentRenderGeometry.cellRect(col: 5, row: 0))
        XCTAssertTrue(view.handleClickToPosition(at: NSPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(backend.sentText, [String(repeating: "\u{1b}OD", count: 10)])
    }

    func testClickCountsUnicodeCharactersInsteadOfCellsOrUTF16() throws {
        let view = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let backend = FakeTerminalBackend()
        backend.cursorPosition = (4, 0)
        backend.logicalLineHitProvider = { _, column in
            RustTerminalFFI.LogicalLineHit(text: "a😀bz", startRow: 0, clickedUTF16Offset: column == 4 ? 4 : 1)
        }
        view.rustTerminal = backend
        view.isAtPrompt = { true }
        let rect = try XCTUnwrap(view.currentRenderGeometry.cellRect(col: 1, row: 0))
        XCTAssertTrue(view.handleClickToPosition(at: NSPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(backend.sentText, [String(repeating: "\u{1b}[D", count: 2)])
    }

    func testOptionClickUsesApplicationCursorMode() throws {
        let view = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let backend = FakeTerminalBackend()
        view.rustTerminal = backend
        view.setApplicationCursorMode(true)
        let rect = try XCTUnwrap(view.currentRenderGeometry.cellRect(col: 2, row: 1))
        XCTAssertTrue(view.handleOptionClick(at: NSPoint(x: rect.midX, y: rect.midY)))
        XCTAssertEqual(backend.sentText, ["\u{1b}OB\u{1b}OC\u{1b}OC"])
    }

}
