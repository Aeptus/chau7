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
}
