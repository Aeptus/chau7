import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class TerminalNormalizerTests: XCTestCase {

    // MARK: - Full Normalize

    func testNormalizePlainText() {
        XCTAssertEqual(TerminalNormalizer.normalize("hello world"), "hello world")
    }

    func testNormalizeEmpty() {
        XCTAssertEqual(TerminalNormalizer.normalize(""), "")
    }

    func testNormalizeStripsAnsiColors() {
        let input = "\u{1B}[31mred\u{1B}[0m"
        XCTAssertEqual(TerminalNormalizer.normalize(input), "red")
    }

    func testNormalizeStripsAnsiSGR() {
        let input = "\u{1B}[1;4;32mbold underline green\u{1B}[0m"
        XCTAssertEqual(TerminalNormalizer.normalize(input), "bold underline green")
    }

    func testNormalizeStripsCursorMovement() {
        let input = "\u{1B}[10;5H positioned text"
        XCTAssertEqual(TerminalNormalizer.normalize(input), " positioned text")
    }

    // MARK: - Backspace Processing

    func testBackspaceDeletesCharacter() {
        let input = "abc\u{08}d"
        XCTAssertEqual(TerminalNormalizer.normalize(input), "abd")
    }

    func testMultipleBackspaces() {
        let input = "abcde\u{08}\u{08}xy"
        XCTAssertEqual(TerminalNormalizer.normalize(input), "abcxy")
    }

    func testBackspaceAtStart() {
        let input = "\u{08}hello"
        XCTAssertEqual(TerminalNormalizer.normalize(input), "hello")
    }

    func testDeleteCharacter() {
        let input = "abc\u{7F}d"
        XCTAssertEqual(TerminalNormalizer.normalize(input), "abd")
    }

    func testApplyBackspacesOnlyPreservesAnsi() {
        let input = "\u{1B}[31mre\u{08}ed\u{1B}[0m"
        let result = TerminalNormalizer.applyBackspacesOnly(input)
        XCTAssertTrue(result.contains("\u{1B}[31m"), "ANSI codes should be preserved")
        XCTAssertTrue(result.contains("ed"), "Text after backspace should remain")
    }

    // MARK: - Control Character Stripping

    func testStripsBellCharacter() {
        let input = "hello\u{07}world"
        XCTAssertEqual(TerminalNormalizer.normalize(input), "helloworld")
    }

    func testPreservesTab() {
        let input = "col1\tcol2"
        XCTAssertEqual(TerminalNormalizer.normalize(input), "col1\tcol2")
    }

    func testStripsFormFeed() {
        let input = "page1\u{0C}page2"
        XCTAssertEqual(TerminalNormalizer.normalize(input), "page1page2")
    }

    // MARK: - Unicode Handling

    func testNormalizeUnicode() {
        let input = "\u{1B}[32m🎉 Success\u{1B}[0m"
        XCTAssertEqual(TerminalNormalizer.normalize(input), "🎉 Success")
    }

    func testNormalizeCJK() {
        let input = "\u{1B}[34m日本語テスト\u{1B}[0m"
        XCTAssertEqual(TerminalNormalizer.normalize(input), "日本語テスト")
    }

    // MARK: - Combined

    func testNormalizeComplexTerminalOutput() {
        // Typical prompt with ANSI colors, backspaces, and control chars
        let input = "\u{1B}[1;32muser@host\u{1B}[0m:\u{1B}[1;34m~/proj\u{1B}[0m$ tyop\u{08}\u{08}\u{08}\u{08}type"
        let result = TerminalNormalizer.normalize(input)
        XCTAssertTrue(result.contains("user@host"))
        XCTAssertTrue(result.contains("type"))
        XCTAssertFalse(result.contains("\u{1B}"))
    }
}
#endif
