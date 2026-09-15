import XCTest
@testable import Chau7Core

final class TerminalClickResolutionTests: XCTestCase {
    func testRepositoryFallbackChoosesOnlyUniqueMatch() {
        XCTAssertEqual(
            TerminalClickResolution.repositoryFallback(from: ["/repo/docs/README.md"]),
            .unique("/repo/docs/README.md")
        )
    }

    func testRepositoryFallbackRejectsAmbiguousMatchesDeterministically() {
        XCTAssertEqual(
            TerminalClickResolution.repositoryFallback(from: [
                "/repo/z/README.md",
                "/repo/a/README.md",
                "/repo/a/README.md"
            ]),
            .ambiguous(["/repo/a/README.md", "/repo/z/README.md"])
        )
    }

    func testRepositoryFallbackReportsNoMatch() {
        XCTAssertEqual(
            TerminalClickResolution.repositoryFallback(from: []),
            .noMatch
        )
    }

    func testURLTrimmingRemovesUnmatchedClosingParenthesis() {
        XCTAssertEqual(
            TerminalClickResolution.trimmedURLToken("https://example.com/docs)"),
            "https://example.com/docs"
        )
    }

    func testURLTrimmingPreservesBalancedParentheses() {
        XCTAssertEqual(
            TerminalClickResolution.trimmedURLToken("https://example.com/docs_(v2)"),
            "https://example.com/docs_(v2)"
        )
    }

    func testURLTrimmingRemovesOnlySurplusClosingParenthesesAndProse() {
        XCTAssertEqual(
            TerminalClickResolution.trimmedURLToken("https://example.com/docs_(v2))."),
            "https://example.com/docs_(v2)"
        )
    }
}
