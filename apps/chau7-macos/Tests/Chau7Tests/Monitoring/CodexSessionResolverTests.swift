#if canImport(AppKit)
import XCTest
@testable import Chau7

final class CodexSessionResolverTests: XCTestCase {
    func testBestMatchingSessionIDChoosesClosestObservedCandidate() {
        let referenceDate = Date(timeIntervalSince1970: 1_000)
        let candidates = [
            CodexSessionResolver.Candidate(
                sessionId: "session-a",
                cwd: "/tmp/project",
                touchedAt: referenceDate.addingTimeInterval(-120)
            ),
            CodexSessionResolver.Candidate(
                sessionId: "session-b",
                cwd: "/tmp/project/src",
                touchedAt: referenceDate.addingTimeInterval(-3)
            ),
            CodexSessionResolver.Candidate(
                sessionId: "session-c",
                cwd: "/tmp/other",
                touchedAt: referenceDate.addingTimeInterval(-1)
            )
        ]

        XCTAssertEqual(
            CodexSessionResolver.bestMatchingSessionID(
                forDirectory: "/tmp/project",
                referenceDate: referenceDate,
                candidates: candidates
            ),
            "session-b"
        )
    }

    func testBestMatchingSessionIDReturnsNilWhenAmbiguousWithoutReferenceDate() {
        let candidates = [
            CodexSessionResolver.Candidate(
                sessionId: "session-a",
                cwd: "/tmp/project",
                touchedAt: Date(timeIntervalSince1970: 100)
            ),
            CodexSessionResolver.Candidate(
                sessionId: "session-b",
                cwd: "/tmp/project",
                touchedAt: Date(timeIntervalSince1970: 200)
            )
        ]

        XCTAssertNil(
            CodexSessionResolver.bestMatchingSessionID(
                forDirectory: "/tmp/project",
                referenceDate: nil,
                candidates: candidates
            )
        )
    }
}
#endif
