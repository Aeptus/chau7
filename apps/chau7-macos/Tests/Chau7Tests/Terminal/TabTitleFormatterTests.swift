import XCTest
import Chau7Core

final class TabTitleFormatterTests: XCTestCase {
    func testActiveAINameSurfacesAlongsideCustomTitle() {
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: "Aethyme tooling",
                aiDisplayAppName: "Codex",
                devServerName: nil,
                customTitleOnly: false
            ),
            "Codex - Aethyme tooling"
        )
    }

    func testCustomTitleOnlyPreservesExactCustomTitle() {
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: "Aethyme tooling",
                aiDisplayAppName: "Codex",
                devServerName: nil,
                customTitleOnly: true
            ),
            "Aethyme tooling"
        )
    }

    func testCustomTitleThatAlreadyContainsAINameIsNotDuplicated() {
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: "Codex - Aethyme tooling",
                aiDisplayAppName: "Codex",
                devServerName: nil,
                customTitleOnly: false
            ),
            "Codex - Aethyme tooling"
        )
    }

    func testAINameSubstringInLongerWordDoesNotSkipPrefix() {
        // "codex" is a substring of "codexport" but not a whole-word match.
        // The prefix must still be applied so the user sees "Codex - codexport".
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: "codexport",
                aiDisplayAppName: "Codex",
                devServerName: nil,
                customTitleOnly: false
            ),
            "Codex - codexport"
        )
    }

    func testAINameMatchIsCaseInsensitive() {
        // Word-boundary match preserved case insensitivity.
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: "my codex session",
                aiDisplayAppName: "Codex",
                devServerName: nil,
                customTitleOnly: false
            ),
            "my codex session"
        )
    }

    func testShortAINameDoesNotFalseMatchUnrelatedSubstring() {
        // A hypothetical short tool name "Co" would substring-match
        // "Command deploy" — the word-boundary check must reject that
        // and still prefix.
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: "Command deploy",
                aiDisplayAppName: "Co",
                devServerName: nil,
                customTitleOnly: false
            ),
            "Co - Command deploy"
        )
    }

    func testFallsBackToViteAndShell() {
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: nil,
                aiDisplayAppName: nil,
                devServerName: "Vite",
                customTitleOnly: false
            ),
            "Vite"
        )
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: nil,
                aiDisplayAppName: nil,
                devServerName: nil,
                customTitleOnly: false
            ),
            "Shell"
        )
    }

    func testUsesCallerProvidedShellFallback() {
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: nil,
                aiDisplayAppName: nil,
                devServerName: nil,
                customTitleOnly: false,
                shellFallback: "Terminal"
            ),
            "Terminal"
        )
    }
}
