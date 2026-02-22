import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class PasteEscaperTests: XCTestCase {

    // MARK: - Basic Escape Sequences

    func testEscapeBackslash() {
        let result = PasteEscaper.escape("path\\to\\file")
        XCTAssertEqual(result, "path\\\\to\\\\file",
            "Backslashes should be doubled")
    }

    func testEscapeSingleQuote() {
        let result = PasteEscaper.escape("it's")
        XCTAssertEqual(result, "it\\'s",
            "Single quotes should be escaped")
    }

    func testEscapeDoubleQuote() {
        let result = PasteEscaper.escape("say \"hello\"")
        XCTAssertEqual(result, "say \\\"hello\\\"",
            "Double quotes should be escaped")
    }

    func testEscapeDollarSign() {
        let result = PasteEscaper.escape("$HOME")
        XCTAssertEqual(result, "\\$HOME",
            "Dollar signs should be escaped")
    }

    func testEscapeBacktick() {
        let result = PasteEscaper.escape("`whoami`")
        XCTAssertEqual(result, "\\`whoami\\`",
            "Backticks should be escaped")
    }

    func testEscapeExclamationMark() {
        let result = PasteEscaper.escape("hello!")
        XCTAssertEqual(result, "hello\\!",
            "Exclamation marks should be escaped")
    }

    // MARK: - Multiline Text

    func testMultilineText() {
        let input = "line1\nline2\nline3"
        let result = PasteEscaper.escape(input)
        // Newlines are not escaped by PasteEscaper
        XCTAssertTrue(result.contains("\n"),
            "Newlines should be preserved")
    }

    func testMultilineWithSpecialChars() {
        let input = "echo $VAR\n`cmd`\npath\\dir"
        let result = PasteEscaper.escape(input)
        XCTAssertTrue(result.contains("\\$VAR"),
            "Dollar sign in multiline should be escaped")
        XCTAssertTrue(result.contains("\\`cmd\\`"),
            "Backticks in multiline should be escaped")
        XCTAssertTrue(result.contains("path\\\\dir"),
            "Backslashes in multiline should be escaped")
    }

    // MARK: - Special Characters Combined

    func testAllSpecialCharactersTogether() {
        let input = "\\\"'$`!"
        let result = PasteEscaper.escape(input)
        XCTAssertEqual(result, "\\\\\\\"\\'\\$\\`\\!",
            "All special characters should be escaped together")
    }

    // MARK: - Empty Input

    func testEmptyInput() {
        let result = PasteEscaper.escape("")
        XCTAssertEqual(result, "",
            "Empty input should return empty string")
    }

    // MARK: - Unicode Handling

    func testUnicodePassedThrough() {
        let input = "Hello, world!"
        let result = PasteEscaper.escape(input)
        // Only the '!' should be escaped; emoji should pass through
        XCTAssertTrue(result.contains("Hello, world"),
            "Emoji and unicode should not be altered")
        XCTAssertTrue(result.hasSuffix("\\!"),
            "Exclamation after unicode should still be escaped")
    }

    func testJapaneseText() {
        let result = PasteEscaper.escape("echo 'Hello'")
        // The single quotes should be escaped, Japanese should pass through
        XCTAssertTrue(result.contains("echo"),
            "Non-ASCII text should pass through unchanged")
        XCTAssertTrue(result.contains("\\'"),
            "Single quotes among unicode should be escaped")
    }

    func testPlainASCII() {
        let result = PasteEscaper.escape("hello world 123")
        XCTAssertEqual(result, "hello world 123",
            "Plain ASCII text with no special chars should be unchanged")
    }

    // MARK: - Real-World Paste Scenarios

    func testPasteShellCommand() {
        let input = "echo \"$HOME\" && ls `pwd`"
        let result = PasteEscaper.escape(input)
        XCTAssertFalse(result.contains("$HOME") && !result.contains("\\$HOME"),
            "Variable expansion should be neutralized")
        XCTAssertFalse(result.contains("`pwd`") && !result.contains("\\`pwd\\`"),
            "Command substitution should be neutralized")
    }

    func testPasteURLWithSpecialChars() {
        let input = "https://example.com/path?q=hello&name=world"
        let result = PasteEscaper.escape(input)
        // URLs typically don't contain characters that PasteEscaper escapes
        XCTAssertEqual(result, input,
            "URL without shell-special chars should be unchanged")
    }
}
#endif
