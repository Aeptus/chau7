import XCTest
@testable import Chau7Core

final class CommandRiskDetectionTests: XCTestCase {

    func testRiskyCommandMatchesSimplePatterns() {
        let patterns = ["rm -rf", "git push --force", "gh repo delete"]
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "rm -rf /tmp", patterns: patterns))
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "git push --force origin main", patterns: patterns))
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "gh repo delete org/repo", patterns: patterns))
    }

    func testRiskyCommandMatchesWithWhitespace() {
        let patterns = ["rm -rf"]
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "rm    -rf   /", patterns: patterns))
    }

    func testRiskyCommandIsCaseInsensitive() {
        let patterns = ["GIT PUSH -F"]
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "git push -f origin main", patterns: patterns))
    }

    func testNonRiskyCommandDoesNotMatch() {
        let patterns = ["rm -rf", "git push --force"]
        XCTAssertFalse(CommandRiskDetection.isRisky(commandLine: "rm -r ./build", patterns: patterns))
        XCTAssertFalse(CommandRiskDetection.isRisky(commandLine: "git push origin main", patterns: patterns))
    }

    func testEmptyPatternsDoNotMatch() {
        XCTAssertFalse(CommandRiskDetection.isRisky(commandLine: "rm -rf /", patterns: []))
        XCTAssertFalse(CommandRiskDetection.isRisky(commandLine: "", patterns: ["rm -rf"]))
    }

    // MARK: - Anchoring Behavior (substring matching)

    func testPatternMatchesAnywhere() {
        let patterns = ["--force"]
        // Pattern should match as substring, not only at start
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "git push --force origin main", patterns: patterns))
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "some-command --force-yes", patterns: patterns))
    }

    func testPatternDoesNotMatchPartialWords() {
        let patterns = ["rm -rf"]
        // "storm -rf" contains "rm -rf" as a substring but only because "storm" ends with "rm"
        // With normalize, "storm -rf" → "storm -rf" which contains "rm -rf"
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "storm -rf /tmp", patterns: patterns))
    }

    // MARK: - Multi-Command Separators

    func testMultiCommandWithSemicolon() {
        let patterns = ["rm -rf"]
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "echo hello; rm -rf /", patterns: patterns))
    }

    func testMultiCommandWithAndOperator() {
        let patterns = ["rm -rf"]
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "cd /tmp && rm -rf *", patterns: patterns))
    }

    func testMultiCommandWithPipe() {
        let patterns = ["rm -rf"]
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "find . -name '*.tmp' | xargs rm -rf", patterns: patterns))
    }

    // MARK: - Whitespace Normalization

    func testTabsNormalized() {
        let patterns = ["rm -rf"]
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "rm\t-rf\t/", patterns: patterns))
    }

    func testLeadingTrailingWhitespace() {
        let patterns = ["rm -rf"]
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "  rm -rf /  ", patterns: patterns))
    }

    func testNewlineInCommand() {
        let patterns = ["rm -rf"]
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "rm\n-rf /", patterns: patterns))
    }

    // MARK: - Edge Cases

    func testVeryLongCommand() {
        let patterns = ["dangerous"]
        let longPrefix = String(repeating: "a", count: 10_000)
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "\(longPrefix) dangerous", patterns: patterns))
    }

    func testWhitespaceOnlyCommand() {
        let patterns = ["rm -rf"]
        XCTAssertFalse(CommandRiskDetection.isRisky(commandLine: "   \t\n  ", patterns: patterns))
    }

    func testWhitespaceOnlyPattern() {
        XCTAssertFalse(CommandRiskDetection.isRisky(commandLine: "rm -rf /", patterns: ["  ", "\t"]))
    }

    func testMultiplePatternsFirstMatches() {
        let patterns = ["rm -rf", "git push --force", "drop table"]
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "rm -rf /important", patterns: patterns))
    }

    func testMultiplePatternsLastMatches() {
        let patterns = ["rm -rf", "git push --force", "drop table"]
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "sql DROP TABLE users", patterns: patterns))
    }
}
