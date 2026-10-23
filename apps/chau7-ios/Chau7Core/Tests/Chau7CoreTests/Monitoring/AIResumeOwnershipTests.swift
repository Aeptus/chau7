import XCTest
import Chau7Core

final class AIResumeOwnershipTests: XCTestCase {
    func testSanitizeForPersistenceDropsClaimedSessionForSameProvider() {
        let metadata = AIResumeOwnership.sanitizeForPersistence(
            provider: "claude",
            sessionId: "session-1",
            claimedSessions: [AIResumeOwnership.ClaimedSession(provider: "claude", sessionId: "session-1")]
        )

        XCTAssertEqual(metadata.provider, "claude")
        XCTAssertNil(metadata.sessionId)
    }

    /// Regression for the debug-tab bug: a Codex session UUID that was
    /// mis-routed to a Claude tab upstream used to make the dedup logic
    /// strip the legitimate Codex tab's session id because the key was
    /// `sessionId` alone. Two providers carrying the same UUID must not
    /// collide.
    func testSanitizeForPersistenceKeepsSessionWhenProviderDiffers() {
        let metadata = AIResumeOwnership.sanitizeForPersistence(
            provider: "codex",
            sessionId: "019e0bd8-1367-7e53-97a5-3977e8d37c8a",
            claimedSessions: [
                AIResumeOwnership.ClaimedSession(
                    provider: "claude",
                    sessionId: "019e0bd8-1367-7e53-97a5-3977e8d37c8a"
                )
            ]
        )

        XCTAssertEqual(metadata.provider, "codex")
        XCTAssertEqual(metadata.sessionId, "019e0bd8-1367-7e53-97a5-3977e8d37c8a")
    }

    func testSanitizeForRestoreDropsLaterDuplicateForSameProvider() {
        let sanitized = AIResumeOwnership.sanitizeForRestore(sequence: [
            .init(provider: "claude", sessionId: "session-1"),
            .init(provider: "claude", sessionId: "session-1"),
            .init(provider: "gemini", sessionId: "session-2")
        ])

        XCTAssertEqual(sanitized[0], .init(provider: "claude", sessionId: "session-1"))
        XCTAssertEqual(sanitized[1], .init(provider: "claude", sessionId: nil))
        XCTAssertEqual(sanitized[2], .init(provider: "gemini", sessionId: "session-2"))
    }

    func testSanitizeForRestoreKeepsSameSessionIDAcrossDifferentProviders() {
        let sanitized = AIResumeOwnership.sanitizeForRestore(sequence: [
            .init(provider: "codex", sessionId: "session-1"),
            .init(provider: "claude", sessionId: "session-1"),
            .init(provider: "gemini", sessionId: "session-2")
        ])

        XCTAssertEqual(sanitized[0], .init(provider: "codex", sessionId: "session-1"))
        XCTAssertEqual(sanitized[1], .init(provider: "claude", sessionId: "session-1"))
        XCTAssertEqual(sanitized[2], .init(provider: "gemini", sessionId: "session-2"))
    }
}
