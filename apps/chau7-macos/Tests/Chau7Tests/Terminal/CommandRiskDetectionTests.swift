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
}
