import XCTest
import Chau7Core

final class AIResumeOwnershipTests: XCTestCase {
    func testSanitizeForPersistenceDropsClaimedSessionIDButKeepsProvider() {
        let metadata = AIResumeOwnership.sanitizeForPersistence(
            provider: "claude",
            sessionId: "session-1",
            claimedSessionIds: ["session-1"]
        )

        XCTAssertEqual(metadata.provider, "claude")
        XCTAssertNil(metadata.sessionId)
    }

    func testSanitizeForRestoreDropsLaterDuplicateSessionIDs() {
        let sanitized = AIResumeOwnership.sanitizeForRestore(sequence: [
            .init(provider: "codex", sessionId: "session-1"),
            .init(provider: "claude", sessionId: "session-1"),
            .init(provider: "gemini", sessionId: "session-2")
        ])

        XCTAssertEqual(sanitized[0], .init(provider: "codex", sessionId: "session-1"))
        XCTAssertEqual(sanitized[1], .init(provider: "claude", sessionId: nil))
        XCTAssertEqual(sanitized[2], .init(provider: "gemini", sessionId: "session-2"))
    }
}
