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

    func testVisibleNonInteractiveTabUsesEventDrain() {
        // Selected tab in an unfocused window is still visible on multi-monitor
        // setups — it should get event drain for smooth updates.
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
            .eventDrain
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
