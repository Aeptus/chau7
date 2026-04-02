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

    func testParsePreservesRichProviderFields() throws {
        let tabID = UUID()
        let line = """
        {"source":"codex","type":"agent-turn-complete","rawType":"agent-turn-complete","tool":"Codex","title":"Codex finished","message":"Done","notificationType":"idle_prompt","ts":"2026-04-02T10:00:00Z","cwd":"/tmp/project","session_id":"thread_123","tab_id":"\(tabID.uuidString)","producer":"codex_notify_hook","reliability":"authoritative"}
        """

        let event = try AIEventParser.parse(line: line)

        XCTAssertEqual(event.rawType, "agent-turn-complete")
        XCTAssertEqual(event.title, "Codex finished")
        XCTAssertEqual(event.notificationType, "idle_prompt")
        XCTAssertEqual(event.producer, "codex_notify_hook")
        XCTAssertEqual(event.reliability, .authoritative)
        XCTAssertEqual(event.tabID, tabID)
    }
}
