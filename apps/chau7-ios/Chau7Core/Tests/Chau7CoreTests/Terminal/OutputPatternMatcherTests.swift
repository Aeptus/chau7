import XCTest
@testable import Chau7Core

final class OutputPatternMatcherTests: XCTestCase {
    func testFirstMatchReturnsFirstMatchingPattern() {
        let patterns = [
            OutputPatternMatcher.Candidate(pattern: "alpha", appName: "Alpha"),
            OutputPatternMatcher.Candidate(pattern: "beta", appName: "Beta")
        ]

        let match = OutputPatternMatcher.firstMatch(in: "prefix beta alpha suffix", patterns: patterns)

        XCTAssertEqual(match, patterns[0])
    }

    func testFirstMatchReturnsNilWhenNothingMatches() {
        let patterns = [
            OutputPatternMatcher.Candidate(pattern: "alpha", appName: "Alpha"),
            OutputPatternMatcher.Candidate(pattern: "beta", appName: "Beta")
        ]

        let match = OutputPatternMatcher.firstMatch(in: "gamma delta", patterns: patterns)

        XCTAssertNil(match)
    }

    func testFirstMatchUsesCandidateMetadata() {
        let patterns = [
            OutputPatternMatcher.Candidate(pattern: "openai codex", appName: "Codex")
        ]

        let match = OutputPatternMatcher.firstMatch(in: "hello openai codex", patterns: patterns)

        XCTAssertEqual(match?.appName, "Codex")
        XCTAssertEqual(match?.pattern, "openai codex")
    }
}
