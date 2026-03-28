import XCTest
@testable import Chau7Core

final class HistoryEventContextResolverTests: XCTestCase {
    func testDirectoryUsesClaudeProviderLookup() {
        let directory = HistoryEventContextResolver.directory(
            forToolName: "Claude",
            sessionID: "b026411b-4e80-4228-b824-3fb1826aa0c9",
            claudeDirectoryProvider: { sessionID in
                XCTAssertEqual(sessionID, "b026411b-4e80-4228-b824-3fb1826aa0c9")
                return "/tmp/sp42"
            },
            codexDirectoryProvider: { _ in
                XCTFail("Codex lookup should not be used for Claude")
                return nil
            }
        )

        XCTAssertEqual(directory, "/tmp/sp42")
    }

    func testDirectoryUsesCodexProviderLookup() {
        let directory = HistoryEventContextResolver.directory(
            forToolName: "Codex",
            sessionID: "019d25d0-d0bd-7501-99ba-1f937c17b29b",
            claudeDirectoryProvider: { _ in
                XCTFail("Claude lookup should not be used for Codex")
                return nil
            },
            codexDirectoryProvider: { sessionID in
                XCTAssertEqual(sessionID, "019d25d0-d0bd-7501-99ba-1f937c17b29b")
                return "/tmp/chau7"
            }
        )

        XCTAssertEqual(directory, "/tmp/chau7")
    }

    func testDirectoryReturnsNilForUnknownProvider() {
        let directory = HistoryEventContextResolver.directory(
            forToolName: "Aider",
            sessionID: "session",
            claudeDirectoryProvider: { _ in
                XCTFail("Claude lookup should not be used")
                return nil
            },
            codexDirectoryProvider: { _ in
                XCTFail("Codex lookup should not be used")
                return nil
            }
        )

        XCTAssertNil(directory)
    }

    func testDirectoryReturnsNilForInvalidSessionID() {
        let directory = HistoryEventContextResolver.directory(
            forToolName: "Codex",
            sessionID: "invalid session id with spaces",
            claudeDirectoryProvider: { _ in
                XCTFail("Provider lookup should not be used")
                return nil
            },
            codexDirectoryProvider: { _ in
                XCTFail("Provider lookup should not be used")
                return nil
            }
        )

        XCTAssertNil(directory)
    }
}
