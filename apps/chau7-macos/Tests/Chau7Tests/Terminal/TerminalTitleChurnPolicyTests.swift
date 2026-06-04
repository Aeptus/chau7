import XCTest
@testable import Chau7Core

final class TerminalTitleChurnPolicyTests: XCTestCase {
    func testBrailleSpinnerPrefixIsRemovedFromStableDisplayTitle() {
        XCTAssertEqual(
            TerminalTitleChurnPolicy.stableDisplayTitle(from: "⠦ Mockup"),
            "Mockup"
        )
        XCTAssertEqual(
            TerminalTitleChurnPolicy.stableDisplayTitle(from: "⠐ Audit database"),
            "Audit database"
        )
    }

    func testAsciiSpinnerPrefixIsRemovedOnlyWhenItIsAToken() {
        XCTAssertEqual(
            TerminalTitleChurnPolicy.stableDisplayTitle(from: "| Mockup"),
            "Mockup"
        )
        XCTAssertEqual(
            TerminalTitleChurnPolicy.stableDisplayTitle(from: "Mockup"),
            "Mockup"
        )
        XCTAssertEqual(
            TerminalTitleChurnPolicy.stableDisplayTitle(from: "/Users/me/Mockup"),
            "/Users/me/Mockup"
        )
    }

    func testSpinnerOnlyTitleFallsBackToRawTitle() {
        XCTAssertEqual(
            TerminalTitleChurnPolicy.stableDisplayTitle(from: "⠦"),
            "⠦"
        )
    }

    func testDeliveryUsesStableTitleToSuppressSpinnerChurn() {
        XCTAssertFalse(
            TerminalTitleChurnPolicy.shouldDeliverTitle("⠧ Mockup", lastDeliveredTitle: "Mockup")
        )
        XCTAssertTrue(
            TerminalTitleChurnPolicy.shouldDeliverTitle("⠧ Build finished", lastDeliveredTitle: "Mockup")
        )
    }
}
