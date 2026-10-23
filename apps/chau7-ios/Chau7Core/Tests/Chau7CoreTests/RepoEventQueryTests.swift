import XCTest
import Chau7Core

final class RepoEventQueryTests: XCTestCase {
    private let event = AIEvent(type: "waiting_input", tool: "Codex", message: "input", ts: "timestamp", tabID: UUID(), sessionID: "Session", producer: "runtime_session_manager")

    func testFiltersNormalizeProviderFieldsButPreserveSessionCaseAndAliases() {
        let query = RepoEventQuery(limit: 10, tabID: " tab_1 ", eventTypes: ["WAITING_INPUT", ""], tool: " CODEX ", producer: " RUNTIME_SESSION_MANAGER ", sessionID: " Session ")
        XCTAssertTrue(query.matches(event, resolvedTabID: "tab_1"))
        XCTAssertFalse(query.matches(event, resolvedTabID: "tab_2"))
        XCTAssertFalse(RepoEventQuery(limit: 10, sessionID: "session").matches(event, resolvedTabID: nil))
        XCTAssertFalse(RepoEventQuery(limit: 10, producer: "other").matches(event, resolvedTabID: nil))
        XCTAssertFalse(RepoEventQuery(limit: 10, eventTypes: ["finished"]).matches(event, resolvedTabID: nil))
        XCTAssertFalse(RepoEventQuery(limit: 10, tool: "Claude").matches(event, resolvedTabID: nil))
    }

    func testCapsLimitsAndRequiresTabIdentityWhenFiltering() {
        XCTAssertEqual(RepoEventQuery(limit: -1).limit, 1)
        XCTAssertEqual(RepoEventQuery(limit: 1000).limit, 50)
        XCTAssertTrue(RepoEventQuery(limit: 10).matches(event, resolvedTabID: nil))
        let unbound = AIEvent(type: "waiting_input", tool: "Codex", message: "input", ts: "timestamp")
        XCTAssertFalse(RepoEventQuery(limit: 10, tabID: "tab_1").matches(unbound, resolvedTabID: "tab_1"))
    }
}
