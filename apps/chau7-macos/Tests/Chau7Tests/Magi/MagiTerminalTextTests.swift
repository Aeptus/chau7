import XCTest
@testable import Chau7Core

final class MagiTerminalTextTests: XCTestCase {
    func testNormalizedInlineCollapsesWhitespace() {
        XCTAssertEqual(
            MagiTerminalText.normalizedInline("  first\n\nsecond\t third  "),
            "first second third"
        )
    }

    func testWrappedKeepsEveryWordWithoutTruncation() {
        let lines = MagiTerminalText.wrapped(
            "The strongest defensible answer is conditional and requires explicit criteria.",
            width: 24
        )

        XCTAssertEqual(lines, [
            "The strongest defensible",
            "answer is conditional",
            "and requires explicit",
            "criteria."
        ])
    }

    func testWrappedSplitsLongWords() {
        let lines = MagiTerminalText.wrapped("abcdefghij", width: 4)

        XCTAssertEqual(lines, ["abcd", "efgh", "ij"])
    }
}
