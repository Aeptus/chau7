import Chau7Core
import XCTest

final class PresentationPaneFocusPolicyTests: XCTestCase {
    func testFocusedTerminalWins() {
        XCTAssertEqual(
            PresentationPaneFocusPolicy.selectedTerminalPaneID(
                focusedPaneID: "secondary",
                terminalPaneIDs: ["primary", "secondary"],
                previousPresentationPaneID: "primary"
            ),
            "secondary"
        )
    }

    func testPreviousTerminalSurvivesNonTerminalFocus() {
        XCTAssertEqual(
            PresentationPaneFocusPolicy.selectedTerminalPaneID(
                focusedPaneID: "editor",
                terminalPaneIDs: ["primary", "secondary"],
                previousPresentationPaneID: "secondary"
            ),
            "secondary"
        )
    }

    func testFallsBackToFirstTerminalWhenPreviousTerminalIsGone() {
        XCTAssertEqual(
            PresentationPaneFocusPolicy.selectedTerminalPaneID(
                focusedPaneID: "editor",
                terminalPaneIDs: ["primary"],
                previousPresentationPaneID: "secondary"
            ),
            "primary"
        )
    }

    func testReturnsNilWithoutTerminals() {
        XCTAssertNil(
            PresentationPaneFocusPolicy.selectedTerminalPaneID(
                focusedPaneID: "editor",
                terminalPaneIDs: [],
                previousPresentationPaneID: "secondary"
            )
        )
    }
}
