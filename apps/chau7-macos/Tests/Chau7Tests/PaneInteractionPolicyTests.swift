import Chau7Core
import XCTest

final class PaneInteractionPolicyTests: XCTestCase {
    func testOnlyFocusedPaneOfInteractiveTabIsInteractive() {
        XCTAssertTrue(
            PaneInteractionPolicy.isInteractive(
                isFocused: true,
                tabIsInteractive: true
            )
        )
        XCTAssertFalse(
            PaneInteractionPolicy.isInteractive(
                isFocused: false,
                tabIsInteractive: true
            )
        )
    }

    func testInactiveTabHasNoInteractivePane() {
        XCTAssertFalse(
            PaneInteractionPolicy.isInteractive(
                isFocused: true,
                tabIsInteractive: false
            )
        )
        XCTAssertFalse(
            PaneInteractionPolicy.isInteractive(
                isFocused: false,
                tabIsInteractive: false
            )
        )
    }
}
