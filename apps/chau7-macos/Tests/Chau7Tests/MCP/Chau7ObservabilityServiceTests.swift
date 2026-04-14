import XCTest
import Chau7Core
@testable import Chau7

final class Chau7ObservabilityServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        Chau7ObservabilityService.shared.resetForTests()
    }

    func testRuntimeInfoIncludesStableIdentityFields() throws {
        let payload = try decodeObject(Chau7ObservabilityService.shared.runtimeInfoJSON())

        XCTAssertNotNil(payload["app_version"] as? String)
        XCTAssertNotNil(payload["build_number"] as? String)
        XCTAssertNotNil(payload["build_sha"] as? String)
        XCTAssertNotNil(payload["process_id"] as? Int)
        XCTAssertEqual(payload["mcp_protocol_version"] as? String, "2025-11-25")
        XCTAssertEqual(payload["observability_schema_version"] as? Int, 1)
    }

    func testRuntimeEventsReturnLatestEventsWithControlPlaneTabIDs() throws {
        let nativeTabID = UUID()
        Chau7ObservabilityService.shared.recordEvent(
            type: "tab_created",
            subsystem: "tabs",
            nativeTabID: nativeTabID,
            detail: ["window_id": 7]
        )
        Chau7ObservabilityService.shared.recordEvent(
            type: "approval_waiting",
            subsystem: "mcp_approvals",
            sessionID: "req_1",
            detail: ["kind": "command_request"]
        )

        let payload = try decodeObject(Chau7ObservabilityService.shared.runtimeEventsJSON(sinceMillis: nil, limit: 10))
        let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0]["type"] as? String, "tab_created")
        XCTAssertEqual(events[0]["tab_id"] as? String, TerminalControlService.shared.controlPlaneTabID(for: nativeTabID))
        XCTAssertEqual((events[0]["detail"] as? [String: Any])?["window_id"] as? Int, 7)
        XCTAssertEqual(events[1]["type"] as? String, "approval_waiting")
        XCTAssertEqual(events[1]["session_id"] as? String, "req_1")
    }

    func testRecordAIEventProducesObservableAIEventEntry() throws {
        let nativeTabID = UUID()
        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "Done",
            ts: DateFormatters.nowISO8601(),
            repoPath: "/tmp/repo",
            tabID: nativeTabID,
            sessionID: "sess_1",
            producer: "test"
        )

        Chau7ObservabilityService.shared.recordAIEvent(event)

        let payload = try decodeObject(Chau7ObservabilityService.shared.runtimeEventsJSON(sinceMillis: nil, limit: 10))
        let events = try XCTUnwrap(payload["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0]["type"] as? String, "ai_event")
        XCTAssertEqual(events[0]["subsystem"] as? String, "codex")
        XCTAssertEqual(events[0]["repo_path"] as? String, "/tmp/repo")
        let detail = try XCTUnwrap(events[0]["detail"] as? [String: Any])
        XCTAssertEqual(detail["event_type"] as? String, "finished")
        XCTAssertEqual(detail["tool"] as? String, "Codex")
    }

    func testTimerInventoryIncludesActiveAndInactiveTimers() throws {
        Chau7ObservabilityService.shared.registerTimer(
            id: "mcp_health_check",
            kind: "dispatch_source_timer",
            label: "mcp-health-check",
            subsystem: "mcp_server",
            queueLabel: "com.chau7.mcp.server",
            intervalMs: 15_000,
            leewayMs: 3_000,
            active: true
        )
        Chau7ObservabilityService.shared.setTimerActive("mcp_health_check", active: false)

        let payload = try decodeObject(Chau7ObservabilityService.shared.timerInventoryJSON())
        let timers = try XCTUnwrap(payload["timers"] as? [[String: Any]])
        XCTAssertEqual(timers.count, 1)
        XCTAssertEqual(timers[0]["id"] as? String, "mcp_health_check")
        XCTAssertEqual(timers[0]["active"] as? Bool, false)
    }

    private func decodeObject(_ json: String) throws -> [String: Any] {
        let data = try XCTUnwrap(json.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
