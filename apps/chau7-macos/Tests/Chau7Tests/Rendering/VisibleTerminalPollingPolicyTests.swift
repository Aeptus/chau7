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
                    isWindowMiniaturized: false
                )
            ),
            .eventDrain
        )
    }

    func testLiveTabStaysOnEventDrainRegardlessOfOcclusion() {
        // Regression guard, structural edition: occlusion is no longer even
        // an input to the policy (macOS flaps it spuriously on multi-display
        // fullscreen setups, and demoting on it batched the selected tab's
        // output into 1-8s walls). A live visible tab is event-driven, full
        // stop.
        XCTAssertEqual(
            VisibleTerminalPollingPolicy.mode(
                for: VisibleTerminalPollingContext(
                    isTerminalStarted: true,
                    notifyUpdateChanges: true,
                    isShellBootstrapPending: false,
                    allowsLivePresentation: true,
                    isHidden: false,
                    hasVisibleWindow: true,
                    isWindowMiniaturized: false
                )
            ),
            .eventDrain
        )
    }

    func testShellBootstrapForcesEventDrain() {
        // First-output detection must stay fast even mid-bootstrap.
        XCTAssertEqual(
            VisibleTerminalPollingPolicy.mode(
                for: VisibleTerminalPollingContext(
                    isTerminalStarted: true,
                    notifyUpdateChanges: true,
                    isShellBootstrapPending: true,
                    allowsLivePresentation: true,
                    isHidden: false,
                    hasVisibleWindow: true,
                    isWindowMiniaturized: false
                )
            ),
            .eventDrain
        )
    }

    func testVisibleNonInteractiveTabAlsoUsesEventDrain() {
        // A selected tab on a visible-but-not-key window (the dual-monitor
        // case where the user is working on screen A while Chau7 streams
        // on screen B) gets event-driven polling. Pre-fix, this dropped
        // to backgroundDrain (1 Hz) and updates appeared frozen. The
        // lifecycle phase is already `.active` for visible windows
        // (allowsLivePresentation == true here); polling must match.
        XCTAssertEqual(
            VisibleTerminalPollingPolicy.mode(
                for: VisibleTerminalPollingContext(
                    isTerminalStarted: true,
                    notifyUpdateChanges: true,
                    isShellBootstrapPending: false,
                    allowsLivePresentation: true,
                    isHidden: false,
                    hasVisibleWindow: true,
                    isWindowMiniaturized: false
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
                    isWindowMiniaturized: false
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
                    isWindowMiniaturized: false
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
                    isWindowMiniaturized: false
                )
            ),
            .backgroundDrain
        )
    }
}
