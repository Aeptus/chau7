import XCTest
import Chau7Core

final class TabTitleFormatterTests: XCTestCase {
    /// A non-empty custom title is always returned verbatim — the AI tool
    /// name is never prepended. The tab chip's logo carries the tool
    /// identity visually, so prepending "Codex - " to the user's chosen
    /// title would be redundant chrome. This test pins the contract so a
    /// future regression that re-introduces the AI prefix is caught.
    func testCustomTitleAlwaysWinsOverAINamePrefix() {
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: "Aethyme tooling",
                aiDisplayAppName: "Codex",
                devServerName: nil,
                customTitleOnly: false
            ),
            "Aethyme tooling",
            "Custom title must NOT be prefixed with the AI tool name; the chip logo handles tool identity."
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

    /// Custom title that happens to contain the AI tool name as a substring
    /// (without word boundary) still returns just the custom title. Pre-fix,
    /// the formatter prefixed "Codex - " to disambiguate; the new contract
    /// trusts the user's chosen title verbatim and lets the chip logo carry
    /// the tool identity.
    func testCustomTitleWithAISubstringStillReturnsCustomOnly() {
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: "codexport",
                aiDisplayAppName: "Codex",
                devServerName: nil,
                customTitleOnly: false
            ),
            "codexport"
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

    /// Custom title with an unrelated AI tool name passed in still returns
    /// just the custom title. The previous formatter went to lengths to
    /// avoid false-positive substring matches; the new contract sidesteps
    /// the question entirely by never composing prefixes onto custom titles.
    func testCustomTitleWithUnrelatedAINameStillReturnsCustomOnly() {
        XCTAssertEqual(
            TabTitleFormatter.resolvedTitle(
                customTitle: "Command deploy",
                aiDisplayAppName: "Co",
                devServerName: nil,
                customTitleOnly: false
            ),
            "Command deploy"
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
