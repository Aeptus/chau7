import XCTest
import AppKit

#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class TerminalRestoreBootstrapTests: XCTestCase {

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

        let settledExpectation = expectation(description: "restore bootstrap settles after resume prefill")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            XCTAssertEqual(
                capturedInputs,
                ["codex resume 019d25d0-d0bd-7501-99ba-1f937c17b29b"]
            )
            XCTAssertEqual(session.restoreBootstrapPhase, .settled)
            XCTAssertFalse(session.isRestoreBootstrapPending)
            settledExpectation.fulfill()
        }
        wait(for: [settledExpectation], timeout: 1.0)
    }
}
#endif
