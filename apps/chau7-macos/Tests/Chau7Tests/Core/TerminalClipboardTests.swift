import XCTest
@testable import Chau7Core

final class TerminalClipboardTests: XCTestCase {
    func testNormalCopyPreservesMultilineTextExactly() {
        let text = "  echo hello\r\n    --flag  value\n"
        XCTAssertEqual(TerminalClipboard.copiedText(text, fromTUI: false), text)
        XCTAssertEqual(TerminalClipboard.copiedText(text, fromTUI: true), text)
    }

    func testHardWrappedCommandPreservesExplicitLineBreaks() {
        let text = "echo hello-world\n    --flag value"
        XCTAssertEqual(TerminalClipboard.copiedText(text, fromTUI: true), text)
    }

    func testCRLFAndBlankDisplayRowsArePreserved() {
        let text = "  git status\r\n\r\n  --short  "
        XCTAssertEqual(TerminalClipboard.copiedText(text, fromTUI: true), text)
    }

    func testQuotedAndInteriorWhitespaceIsPreserved() {
        let text = "printf 'a  b'\n    --flag  value"
        XCTAssertEqual(TerminalClipboard.copiedText(text, fromTUI: true), text)
        XCTAssertEqual(TerminalClipboard.copiedText("echo '\tvalue'", fromTUI: true), "echo '\tvalue'")
    }

    func testUnicodeAndEmptySelectionsArePreserved() {
        let text = "echo café\u{2028}    😀"
        XCTAssertEqual(TerminalClipboard.copiedText(text, fromTUI: true), text)
        XCTAssertEqual(TerminalClipboard.copiedText("\r\n  \t", fromTUI: true), "\r\n  \t")
    }

    func testHardWrapInsideLongTokenPreservesSelectionBytes() {
        for separator in ["\n", "\r\n", "\r", "\u{2028}"] {
            let path = "cat /tmp/verylongpa" + separator + "th/file.md"
            let url = "curl https://example.com/verylong" + separator + "path"
            XCTAssertEqual(TerminalClipboard.copiedText(path, fromTUI: true), path)
            XCTAssertEqual(TerminalClipboard.copiedText(url, fromTUI: true), url)
        }
    }

    func testWhitespaceAtEitherBoundaryIsPreserved() {
        for text in ["echo hello \nworld", "echo hello\n    world", "echo hello\t\nworld"] {
            XCTAssertEqual(TerminalClipboard.copiedText(text, fromTUI: true), text)
        }
    }

    func testBlankRowsDoNotJoinAdjacentText() {
        for text in ["first\n\nsecond", "first\r\nsecond"] {
            XCTAssertEqual(TerminalClipboard.copiedText(text, fromTUI: true), text)
        }
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
