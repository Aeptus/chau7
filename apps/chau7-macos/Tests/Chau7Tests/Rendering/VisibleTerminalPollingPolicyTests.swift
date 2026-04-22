import XCTest
@testable import Chau7Core

final class VisibleTerminalPollingPolicyTests: XCTestCase {
    func testFocusedVisibleTabUsesEventDrain() {
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
            .eventDrain
        )
    }

    func testVisibleNonInteractiveTabUsesBackgroundDrain() {
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
            .backgroundDrain
        )
    }

    func testShellBootstrapKeepsEventDrainEvenWithoutInteraction() {
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
            .eventDrain
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
