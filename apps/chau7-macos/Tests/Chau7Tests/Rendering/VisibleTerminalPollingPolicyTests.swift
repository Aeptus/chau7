import XCTest
@testable import Chau7Core

final class VisibleTerminalPollingPolicyTests: XCTestCase {
    func testFocusedVisibleTabUsesDisplayLink() {
        XCTAssertEqual(
            VisibleTerminalPollingPolicy.mode(
                for: VisibleTerminalPollingContext(
                    isTerminalStarted: true,
                    notifyUpdateChanges: true,
                    isShellBootstrapPending: false,
                    allowsLivePresentation: true,
                    isHidden: false,
                    hasVisibleWindow: true,
                    isWindowMiniaturized: false,
                    isInteractive: true
                )
            ),
            .displayLink
        )
    }

    func testVisibleNonInteractiveTabUsesTimer() {
        XCTAssertEqual(
            VisibleTerminalPollingPolicy.mode(
                for: VisibleTerminalPollingContext(
                    isTerminalStarted: true,
                    notifyUpdateChanges: true,
                    isShellBootstrapPending: false,
                    allowsLivePresentation: true,
                    isHidden: false,
                    hasVisibleWindow: true,
                    isWindowMiniaturized: false,
                    isInteractive: false
                )
            ),
            .timer
        )
    }

    func testShellBootstrapKeepsDisplayLinkEvenWithoutInteraction() {
        XCTAssertEqual(
            VisibleTerminalPollingPolicy.mode(
                for: VisibleTerminalPollingContext(
                    isTerminalStarted: true,
                    notifyUpdateChanges: true,
                    isShellBootstrapPending: true,
                    allowsLivePresentation: true,
                    isHidden: false,
                    hasVisibleWindow: true,
                    isWindowMiniaturized: false,
                    isInteractive: false
                )
            ),
            .displayLink
        )
    }

    func testHiddenOrInactiveCasesUseBackgroundDrain() {
        XCTAssertEqual(
            VisibleTerminalPollingPolicy.mode(
                for: VisibleTerminalPollingContext(
                    isTerminalStarted: true,
                    notifyUpdateChanges: true,
                    isShellBootstrapPending: false,
                    allowsLivePresentation: true,
                    isHidden: true,
                    hasVisibleWindow: true,
                    isWindowMiniaturized: false,
                    isInteractive: true
                )
            ),
            .backgroundDrain
        )
        XCTAssertEqual(
            VisibleTerminalPollingPolicy.mode(
                for: VisibleTerminalPollingContext(
                    isTerminalStarted: false,
                    notifyUpdateChanges: true,
                    isShellBootstrapPending: false,
                    allowsLivePresentation: true,
                    isHidden: false,
                    hasVisibleWindow: true,
                    isWindowMiniaturized: false,
                    isInteractive: true
                )
            ),
            .backgroundDrain
        )
    }
}
