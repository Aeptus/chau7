import XCTest
@testable import Chau7Core

final class TerminalFocusRequestPolicyTests: XCTestCase {
    private func action(
        current: Bool = true,
        owner: Bool = true,
        editing: Bool = false,
        interactive: Bool = true,
        active: Bool = true,
        key: Bool = true,
        space: Bool = true,
        attached: Bool = true,
        attempt: Int = 0
    ) -> TerminalFocusRequestPolicy.Action {
        TerminalFocusRequestPolicy.action(
            isCurrentRequest: current,
            ownsFocus: owner,
            responderChangedToEditor: editing,
            isInteractive: interactive,
            appIsActive: active,
            isKeyWindow: key,
            isOnActiveSpace: space,
            viewIsAttached: attached,
            attempt: attempt
        )
    }

    func testReadySelectedTerminalCanReceiveInput() {
        XCTAssertEqual(action(), .focus)
    }

    func testStartupWaitsForAttachmentActivationAndRenderOwnership() {
        XCTAssertEqual(action(attached: false), .retry)
        XCTAssertEqual(action(active: false), .retry)
        XCTAssertEqual(action(key: false), .retry)
        XCTAssertEqual(action(space: false), .retry)
        XCTAssertEqual(action(interactive: false), .retry)
    }

    func testDeselectedPaneAndSupersededRequestsNeverStealFocus() {
        XCTAssertEqual(action(owner: false), .cancel)
        XCTAssertEqual(action(current: false), .cancel)
        XCTAssertEqual(action(owner: false, attached: false), .cancel)
    }

    func testTypingInEditorCancelsDelayedTerminalFocus() {
        XCTAssertEqual(action(editing: true), .cancel)
    }

    func testRetryBudgetIsBoundedButLastReadyAttemptCanSucceed() {
        XCTAssertEqual(action(attached: false, attempt: TerminalFocusRequestPolicy.retryLimit - 1), .retry)
        XCTAssertEqual(action(attached: false, attempt: TerminalFocusRequestPolicy.retryLimit), .cancel)
        XCTAssertEqual(action(attempt: TerminalFocusRequestPolicy.retryLimit), .focus)
    }
}
