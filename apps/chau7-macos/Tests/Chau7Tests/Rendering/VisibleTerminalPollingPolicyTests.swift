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

    func testOccludedWindowDropsToBackgroundDrain() {
        // isVisible stays true for fully covered windows; rendering up to
        // ~15fps for pixels nobody sees burns CPU/battery for nothing.
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
                    isWindowOccluded: true,
                    isInteractive: true
                )
            ),
            .backgroundDrain
        )
    }

    func testShellBootstrapOverridesOcclusion() {
        // First-output detection must stay fast even if the window is covered.
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
                    isWindowOccluded: true,
                    isInteractive: true
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
