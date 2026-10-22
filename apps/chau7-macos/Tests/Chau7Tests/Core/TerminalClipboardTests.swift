import XCTest
@testable import Chau7Core

final class TerminalClipboardTests: XCTestCase {
    func testNormalCopyPreservesMultilineTextExactly() {
        let text = "  echo hello\r\n    --flag  value\n"
        XCTAssertEqual(TerminalClipboard.copiedText(text, fromTUI: false), text)
        XCTAssertEqual(TerminalClipboard.copiedText(text, fromTUI: true), "echo hello --flag  value")
    }

    func testHardWrappedCommandLosesScreenIndentation() {
        XCTAssertEqual(TerminalClipboard.singleLine("echo hello-world\n    --flag value"), "echo hello-world --flag value")
    }

    func testCRLFAndBlankDisplayRowsBecomeOneSeparator() {
        XCTAssertEqual(TerminalClipboard.singleLine("  git status\r\n\r\n  --short  "), "git status --short")
    }

    func testQuotedAndInteriorWhitespaceIsPreserved() {
        XCTAssertEqual(TerminalClipboard.singleLine("printf 'a  b'\n    --flag  value"), "printf 'a  b' --flag  value")
        XCTAssertEqual(TerminalClipboard.singleLine("echo '\tvalue'"), "echo '\tvalue'")
    }

    func testUnicodeAndEmptySelections() {
        XCTAssertEqual(TerminalClipboard.singleLine("echo café\u{2028}    😀"), "echo café 😀")
        XCTAssertEqual(TerminalClipboard.singleLine("\r\n  \t"), "")
    }

    func testHardWrapInsideLongTokenDoesNotInsertSpace() {
        for separator in ["\n", "\r\n", "\r", "\u{2028}"] {
            XCTAssertEqual(TerminalClipboard.singleLine("cat /tmp/verylongpa" + separator + "th/file.md"), "cat /tmp/verylongpath/file.md")
            XCTAssertEqual(TerminalClipboard.singleLine("curl https://example.com/verylong" + separator + "path"), "curl https://example.com/verylongpath")
        }
    }

    func testWhitespaceAtEitherBoundarySeparatesArguments() {
        XCTAssertEqual(TerminalClipboard.singleLine("echo hello \nworld"), "echo hello world")
        XCTAssertEqual(TerminalClipboard.singleLine("echo hello\n    world"), "echo hello world")
        XCTAssertEqual(TerminalClipboard.singleLine("echo hello\t\nworld"), "echo hello world")
    }

    func testBlankRowsSeparateContentWhileAdjacentTokenRowsJoin() {
        XCTAssertEqual(TerminalClipboard.singleLine("first\n\nsecond"), "first second")
        XCTAssertEqual(TerminalClipboard.singleLine("first\r\nsecond"), "firstsecond")
    }

    func testGridCopyPreservesIndentationAndHardLineBreaks() {
        XCTAssertEqual(TerminalClipboard.gridText(
            rows: ["  echo hi  ", "    next  ", ""],
            softWrappedRows: []
        ), "  echo hi\n    next")
    }

    func testGridCopyJoinsSoftWrapsWithoutLosingArgumentSpaces() {
        XCTAssertEqual(TerminalClipboard.gridText(
            rows: ["echo ", "hello  "],
            softWrappedRows: [1]
        ), "echo hello")
        XCTAssertEqual(TerminalClipboard.gridText(
            rows: ["/tmp/long", "path"],
            softWrappedRows: [1]
        ), "/tmp/longpath")
    }

    func testGridCopyRetainsInteriorBlankLinesAndUnicode() {
        XCTAssertEqual(TerminalClipboard.gridText(
            rows: ["café 😀", "", "  next", "", ""],
            softWrappedRows: []
        ), "café 😀\n\n  next")
        XCTAssertEqual(TerminalClipboard.gridText(rows: [], softWrappedRows: [0, 1]), "")
        XCTAssertEqual(TerminalClipboard.gridText(rows: ["", " "], softWrappedRows: []), "")
    }

    func testGridCopyIgnoresInvalidWrapIndices() {
        XCTAssertEqual(TerminalClipboard.gridText(
            rows: ["one", "two"],
            softWrappedRows: [-1, 0, 100]
        ), "one\ntwo")
    }
}
