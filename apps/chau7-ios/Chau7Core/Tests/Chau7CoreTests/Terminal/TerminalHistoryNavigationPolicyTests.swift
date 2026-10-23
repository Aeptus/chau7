import Chau7Core
import XCTest

final class TerminalHistoryNavigationPolicyTests: XCTestCase {
    func testInterceptsArrowAtPlainShellPrompt() {
        XCTAssertTrue(
            TerminalHistoryNavigationPolicy.shouldInterceptArrowKey(
                isAtPrompt: true,
                hostsTUIApp: false,
                isAlternateScreenActive: false
            )
        )
    }

    func testDoesNotInterceptWhenPromptMarkerIsStaleDuringKnownTUI() {
        XCTAssertFalse(
            TerminalHistoryNavigationPolicy.shouldInterceptArrowKey(
                isAtPrompt: true,
                hostsTUIApp: true,
                isAlternateScreenActive: false
            )
        )
    }

    func testDoesNotInterceptGenericAlternateScreenApplication() {
        XCTAssertFalse(
            TerminalHistoryNavigationPolicy.shouldInterceptArrowKey(
                isAtPrompt: true,
                hostsTUIApp: false,
                isAlternateScreenActive: true
            )
        )
    }

    func testDoesNotInterceptAwayFromPrompt() {
        XCTAssertFalse(
            TerminalHistoryNavigationPolicy.shouldInterceptArrowKey(
                isAtPrompt: false,
                hostsTUIApp: false,
                isAlternateScreenActive: false
            )
        )
    }
}
