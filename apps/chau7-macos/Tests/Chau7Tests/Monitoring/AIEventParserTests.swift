import XCTest
import Chau7Core

final class AIEventParserIdentifierTests: XCTestCase {
    func testParsePreservesSessionAndTabIdentifiers() throws {
        let tabID = UUID()
        let line = """
        {"source":"codex","type":"idle","tool":"Codex","message":"Waiting","ts":"2026-03-25T16:25:55Z","cwd":"/tmp/project","session_id":"session-42","tab_id":"\(tabID.uuidString)"}
        """

        let event = try AIEventParser.parse(line: line)

        XCTAssertEqual(event.source, .codex)
        XCTAssertEqual(event.directory, "/tmp/project")
        XCTAssertEqual(event.sessionID, "session-42")
        XCTAssertEqual(event.tabID, tabID)
    }

    func testParseDropsInvalidSessionIdentifier() throws {
        let line = """
        {"source":"codex","type":"idle","tool":"Codex","message":"Waiting","ts":"2026-03-25T16:25:55Z","sessionId":"bad session id"}
        """

        let event = try AIEventParser.parse(line: line)

        XCTAssertNil(event.sessionID)
    }
}
