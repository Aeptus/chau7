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

    // MARK: - Command Context Matching

    func testPatternMatchesAtCommandStart() {
        let patterns = ["git push --force"]
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "git push --force origin main", patterns: patterns))
    }

    func testCommandMatcherAllowsOptionOnlyCustomPattern() {
        let patterns = ["--force"]
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "git push --force origin main", patterns: patterns))
        XCTAssertFalse(CommandRiskDetection.isRisky(commandLine: "git push --force-with-lease origin main", patterns: patterns))
    }

    func testPatternMatchesAfterPromptOrMarkdownPrefix() {
        let patterns = ["rm -rf", "git push --force"]
        XCTAssertTrue(CommandRiskDetection.isRiskyOutputLine("$ rm -rf /tmp", patterns: patterns))
        XCTAssertTrue(CommandRiskDetection.isRiskyOutputLine("- `git push --force origin main`", patterns: patterns))
    }

    func testPatternDoesNotMatchPartialWords() {
        let patterns = ["rm -rf"]
        XCTAssertFalse(CommandRiskDetection.isRisky(commandLine: "storm -rf /tmp", patterns: patterns))
    }

    func testPatternDoesNotMatchProseMentions() {
        let patterns = ["rm -rf", "delete from", "drop table"]
        XCTAssertFalse(CommandRiskDetection.isRiskyOutputLine("Do not run rm -rf /tmp.", patterns: patterns))
        XCTAssertFalse(CommandRiskDetection.isRiskyOutputLine("Security note: delete from statements need review.", patterns: patterns))
        XCTAssertFalse(CommandRiskDetection.isRiskyOutputLine("The audit mentions DROP TABLE in the migration notes.", patterns: patterns))
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

    func testWrapperCommandsMatch() {
        let patterns = ["rm -rf", "drop table"]
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "sudo rm -rf /tmp", patterns: patterns))
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "env FOO=bar rm -rf /tmp", patterns: patterns))
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "bash -lc 'rm -rf /tmp'", patterns: patterns))
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "sql DROP TABLE users", patterns: patterns))
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
        let longSuffix = String(repeating: " --flag", count: 10000)
        XCTAssertTrue(CommandRiskDetection.isRisky(commandLine: "dangerous\(longSuffix)", patterns: patterns))
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
