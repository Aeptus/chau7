import XCTest
import Chau7Core

final class AIResumeParserTests: XCTestCase {

    // MARK: - extractMetadata

    func testExtractMetadataFromClaudeResume() {
        let result = AIResumeParser.extractMetadata(from: "claude --resume abc123")
        XCTAssertEqual(result, AIResumeParser.ResumeMetadata(provider: "claude", sessionId: "abc123"))
    }

    func testExtractMetadataFromCodexResume() {
        let result = AIResumeParser.extractMetadata(from: "codex resume my-session-42")
        XCTAssertEqual(result, AIResumeParser.ResumeMetadata(provider: "codex", sessionId: "my-session-42"))
    }

    func testExtractMetadataReturnsNilForPlainCommand() {
        XCTAssertNil(AIResumeParser.extractMetadata(from: "claude"))
        XCTAssertNil(AIResumeParser.extractMetadata(from: "ls -la"))
        XCTAssertNil(AIResumeParser.extractMetadata(from: ""))
        XCTAssertNil(AIResumeParser.extractMetadata(from: "   "))
    }

    func testExtractMetadataRejectsInvalidSessionId() {
        // Shell metacharacters should be rejected
        XCTAssertNil(AIResumeParser.extractMetadata(from: "claude --resume $(whoami)"))
        // Too few tokens (just "claude --resume")
        XCTAssertNil(AIResumeParser.extractMetadata(from: "claude --resume"))
    }

    func testExtractMetadataIsCaseInsensitive() {
        let result = AIResumeParser.extractMetadata(from: "Claude --resume ABC123")
        XCTAssertEqual(result?.provider, "claude")
        XCTAssertEqual(result?.sessionId, "abc123")
    }

    // MARK: - detectProvider

    func testDetectProviderFromClaudeCommand() {
        XCTAssertEqual(AIResumeParser.detectProvider(from: "claude chat"), "claude")
    }

    func testDetectProviderFromCodexCommand() {
        XCTAssertEqual(AIResumeParser.detectProvider(from: "codex start"), "codex")
    }

    func testDetectProviderReturnsNilForUnknown() {
        XCTAssertNil(AIResumeParser.detectProvider(from: "vim file.txt"))
        XCTAssertNil(AIResumeParser.detectProvider(from: ""))
    }

    // MARK: - normalizeProviderName

    func testNormalizeProviderName() {
        XCTAssertEqual(AIResumeParser.normalizeProviderName("Claude Code"), "claude")
        XCTAssertEqual(AIResumeParser.normalizeProviderName("codex"), "codex")
        XCTAssertEqual(AIResumeParser.normalizeProviderName("  CLAUDE  "), "claude")
        XCTAssertNil(AIResumeParser.normalizeProviderName("vim"))
        XCTAssertNil(AIResumeParser.normalizeProviderName(""))
    }

    // MARK: - isValidSessionId

    func testIsValidSessionId() {
        XCTAssertTrue(AIResumeParser.isValidSessionId("abc123"))
        XCTAssertTrue(AIResumeParser.isValidSessionId("my-session_42"))
        XCTAssertFalse(AIResumeParser.isValidSessionId(""))
        XCTAssertFalse(AIResumeParser.isValidSessionId("../../etc"))
        XCTAssertFalse(AIResumeParser.isValidSessionId("$(whoami)"))
        XCTAssertFalse(AIResumeParser.isValidSessionId("a b c"))
    }

    // MARK: - bestSessionMatch

    func testBestSessionMatchReturnsSingleCandidate() {
        let candidates = [
            (sessionId: "only-one", touchedAt: Date())
        ]
        XCTAssertEqual(AIResumeParser.bestSessionMatch(candidates: candidates, referenceDate: nil), "only-one")
    }

    func testBestSessionMatchReturnsNilForEmptyCandidates() {
        let candidates: [(sessionId: String, touchedAt: Date)] = []
        XCTAssertNil(AIResumeParser.bestSessionMatch(candidates: candidates, referenceDate: nil))
    }

    func testBestSessionMatchReturnsNilForMultipleWithoutReference() {
        let now = Date()
        let candidates = [
            (sessionId: "a", touchedAt: now),
            (sessionId: "b", touchedAt: now.addingTimeInterval(-10))
        ]
        XCTAssertNil(AIResumeParser.bestSessionMatch(candidates: candidates, referenceDate: nil))
    }

    func testBestSessionMatchPicksClosestToReference() {
        let ref = Date()
        let candidates = [
            (sessionId: "far", touchedAt: ref.addingTimeInterval(-100)),
            (sessionId: "close", touchedAt: ref.addingTimeInterval(-5)),
            (sessionId: "medium", touchedAt: ref.addingTimeInterval(-30))
        ]
        XCTAssertEqual(AIResumeParser.bestSessionMatch(candidates: candidates, referenceDate: ref), "close")
    }

    func testBestSessionMatchPrefersMoreRecentOnTie() {
        let ref = Date()
        // Both are equidistant (10s away) but on opposite sides
        let candidates = [
            (sessionId: "older", touchedAt: ref.addingTimeInterval(-10)),
            (sessionId: "newer", touchedAt: ref.addingTimeInterval(10))
        ]
        XCTAssertEqual(AIResumeParser.bestSessionMatch(candidates: candidates, referenceDate: ref), "newer")
    }
}
