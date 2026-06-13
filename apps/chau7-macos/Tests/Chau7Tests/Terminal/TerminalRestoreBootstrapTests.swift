import XCTest
import AppKit
@testable import Chau7

@MainActor
final class TerminalRestoreBootstrapTests: XCTestCase {

    /// Polls the main run loop until `condition` holds (or the timeout
    /// elapses) so the test does not depend on a fixed asyncAfter delay.
    private func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () -> Bool
    ) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    func testRestoreBootstrapSettlesOnFirstRenderedBufferWhenNoResumePrefillIsExpected() {
        let session = TerminalSessionModel(appModel: AppModel())

        session.beginRestoreBootstrap(expectsResumePrefill: false)
        XCTAssertTrue(session.isRestoreBootstrapPending)

        session.noteRestoreBootstrapBufferChanged()

        XCTAssertEqual(session.restoreBootstrapPhase, .settled)
        XCTAssertFalse(session.isRestoreBootstrapPending)
    }

    func testRestoreBootstrapWaitsForResumePrefillBeforeSettling() {
        let session = TerminalSessionModel(appModel: AppModel())
        session.isShellLoading = false
        session.isAtPrompt = true
        session.status = .idle

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { capturedInputs.append($0) }
        session.attachRustTerminal(terminalView)

        session.beginRestoreBootstrap(expectsResumePrefill: true)
        session.noteRestoreBootstrapBufferChanged()

        XCTAssertTrue(session.isRestoreBootstrapPending)

        session.prefillInput("codex resume 019d25d0-d0bd-7501-99ba-1f937c17b29b")

        waitUntil {
            session.restoreBootstrapPhase == .settled && !capturedInputs.isEmpty
        }
        XCTAssertEqual(
            capturedInputs,
            ["codex resume 019d25d0-d0bd-7501-99ba-1f937c17b29b"]
        )
        XCTAssertEqual(session.restoreBootstrapPhase, .settled)
        XCTAssertFalse(session.isRestoreBootstrapPending)
    }
}
