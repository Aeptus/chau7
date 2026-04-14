import XCTest
@testable import Chau7

final class MCPSessionTests: XCTestCase {
    override func setUp() {
        super.setUp()
        MCPSession.resetSharedToolRateLimiterForTests()
        Chau7ObservabilityService.shared.resetForTests()
    }

    func testRejectsRequestsBeforeInitialization() throws {
        let response = try XCTUnwrap(
            MCPSession(fd: -1).handleRequestObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/list"
            ])
        )

        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32002)
    }

    func testInitializeNegotiatesSupportedVersionAndRequiresInitializedNotification() throws {
        let session = MCPSession(fd: -1)

        let initialize = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": ["protocolVersion": "2025-11-25"]
            ])
        )
        let initializeResult = try XCTUnwrap(initialize["result"] as? [String: Any])
        XCTAssertEqual(initializeResult["protocolVersion"] as? String, "2025-11-25")

        let preReady = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 2,
                "method": "tools/list"
            ])
        )
        let preReadyError = try XCTUnwrap(preReady["error"] as? [String: Any])
        XCTAssertEqual(preReadyError["code"] as? Int, -32002)

        XCTAssertNil(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "method": "notifications/initialized"
            ])
        )

        let toolList = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 3,
                "method": "tools/list"
            ])
        )
        let tools = try XCTUnwrap((toolList["result"] as? [String: Any])?["tools"] as? [[String: Any]])
        let sessionCurrent = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "session_current" }))
        let inputSchema = try XCTUnwrap(sessionCurrent["inputSchema"] as? [String: Any])
        XCTAssertEqual(inputSchema["additionalProperties"] as? Bool, false)

        let runtimeInfo = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "chau7_runtime_info" }))
        XCTAssertTrue((runtimeInfo["description"] as? String)?.contains("build and process identity") == true)

        let runtimeEvents = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "chau7_runtime_events" }))
        XCTAssertTrue((runtimeEvents["description"] as? String)?.contains("observability events") == true)

        let timerInventory = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "chau7_timer_inventory" }))
        XCTAssertTrue((timerInventory["description"] as? String)?.contains("timer and display-link inventory") == true)

        XCTAssertNotNil(tools.first(where: { ($0["name"] as? String) == "chau7_state_snapshot" }))
        XCTAssertNotNil(tools.first(where: { ($0["name"] as? String) == "chau7_subscribe" }))
        XCTAssertNotNil(tools.first(where: { ($0["name"] as? String) == "chau7_unsubscribe" }))

        let sessionList = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "session_list" }))
        XCTAssertTrue((sessionList["description"] as? String)?.contains("telemetry/history") == true)
        XCTAssertTrue((sessionList["description"] as? String)?.contains("tab_list") == true)

        XCTAssertTrue((sessionCurrent["description"] as? String)?.contains("telemetry-backed") == true)
        XCTAssertTrue((sessionCurrent["description"] as? String)?.contains("tab_status") == true)

        let tabList = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "tab_list" }))
        XCTAssertTrue((tabList["description"] as? String)?.contains("primary live discovery API") == true)

        let tabExec = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "tab_exec" }))
        XCTAssertTrue((tabExec["description"] as? String)?.contains("can_accept_exec") == true)

        let tabStatus = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "tab_status" }))
        XCTAssertTrue((tabStatus["description"] as? String)?.contains("can_accept_exec") == true)

        let tabWaitReady = try XCTUnwrap(tools.first(where: { ($0["name"] as? String) == "tab_wait_ready" }))
        XCTAssertTrue((tabWaitReady["description"] as? String)?.contains("can_accept_exec=true") == true)
        XCTAssertFalse(tools.contains(where: { (($0["name"] as? String) ?? "").hasPrefix("runtime_") }))
    }

    func testInitializeRejectsUnsupportedProtocolVersions() throws {
        let response = try XCTUnwrap(
            MCPSession(fd: -1).handleRequestObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": ["protocolVersion": "2023-01-01"]
            ])
        )

        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        let data = try XCTUnwrap(error["data"] as? [String: Any])
        XCTAssertEqual(data["supported"] as? [String], ["2025-11-25", "2024-11-05"])
    }

    func testUnknownToolReturnsProtocolError() throws {
        let session = initializedSession()

        let response = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": "does_not_exist", "arguments": [:]]
            ])
        )

        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
    }

    func testRuntimeToolsAreRejectedByMCP() throws {
        let session = initializedSession()

        let response = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": "runtime_session_list", "arguments": [:]]
            ])
        )

        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertTrue((error["message"] as? String)?.contains("Unknown tool") == true)
    }

    func testMissingRequiredArgumentsReturnProtocolError() throws {
        let session = initializedSession()

        let response = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": "run_get", "arguments": [:]]
            ])
        )

        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32602)
        XCTAssertTrue((error["message"] as? String)?.contains("missing required argument 'run_id'") == true)
    }

    func testToolExecutionFailuresUseIsErrorResult() throws {
        let session = initializedSession()

        let response = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": [
                    "name": "run_get",
                    "arguments": ["run_id": "missing-run"]
                ]
            ])
        )

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let structuredContent = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structuredContent["error"] as? String, "Run not found")
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "Run not found")
    }

    func testObservabilityToolsReturnStructuredResults() throws {
        Chau7ObservabilityService.shared.recordEvent(type: "app_launched", subsystem: "app_lifecycle")
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

        let session = initializedSession()

        let runtimeInfo = try toolStructuredContent(
            session: session,
            name: "chau7_runtime_info",
            arguments: [:]
        )
        XCTAssertEqual(runtimeInfo["observability_schema_version"] as? Int, 1)

        let runtimeEvents = try toolStructuredContent(
            session: session,
            name: "chau7_runtime_events",
            arguments: ["limit": 10]
        )
        let events = try XCTUnwrap(runtimeEvents["events"] as? [[String: Any]])
        XCTAssertEqual(events.first?["type"] as? String, "app_launched")

        let timerInventory = try toolStructuredContent(
            session: session,
            name: "chau7_timer_inventory",
            arguments: [:]
        )
        let timers = try XCTUnwrap(timerInventory["timers"] as? [[String: Any]])
        XCTAssertEqual(timers.first?["id"] as? String, "mcp_health_check")
    }

    func testStateSnapshotReturnsAggregatedState() throws {
        Chau7ObservabilityService.shared.recordEvent(type: "app_launched", subsystem: "app_lifecycle")

        let session = initializedSession()
        let snapshot = try toolStructuredContent(
            session: session,
            name: "chau7_state_snapshot",
            arguments: [:]
        )

        XCTAssertEqual(snapshot["schema_version"] as? Int, 1)
        XCTAssertNotNil(snapshot["latest_seq"])
        XCTAssertNotNil(snapshot["runtime_info"] as? [String: Any])
        XCTAssertNotNil(snapshot["tabs"] as? [[String: Any]])
        XCTAssertNotNil(snapshot["approvals"] as? [[String: Any]])
        XCTAssertNotNil((snapshot["telemetry"] as? [String: Any])?["active_runs"] as? [[String: Any]])
    }

    func testSubscribeEmitsReplayAndNotifications() throws {
        let notificationExpectation = expectation(description: "receives state notification")
        var receivedNotification: [String: Any]?
        let session = initializedSession(notificationSink: { payload in
            if payload["method"] as? String == "notifications/chau7.event" {
                receivedNotification = payload
                notificationExpectation.fulfill()
            }
        })

        Chau7ObservabilityService.shared.recordEvent(type: "app_launched", subsystem: "app_lifecycle")

        let subscribeResponse = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 10,
                "method": "tools/call",
                "params": [
                    "name": "chau7_subscribe",
                    "arguments": [
                        "topics": ["runtime-events"],
                        "cursor": 0,
                        "replay_limit": 10
                    ]
                ]
            ])
        )

        let subscribeResult = try XCTUnwrap(subscribeResponse["result"] as? [String: Any])
        let subscribeStructured = try XCTUnwrap(subscribeResult["structuredContent"] as? [String: Any])
        XCTAssertNotNil(subscribeStructured["subscription_id"] as? String)
        let replay = try XCTUnwrap(subscribeStructured["replay"] as? [[String: Any]])
        XCTAssertEqual(replay.count, 1)
        XCTAssertEqual(replay.first?["type"] as? String, "app_launched")

        Chau7ObservabilityService.shared.recordEvent(type: "tab_created", subsystem: "tabs", detail: ["window_id": 1])

        waitForExpectations(timeout: 1)

        let params = try XCTUnwrap(receivedNotification?["params"] as? [String: Any])
        XCTAssertEqual(params["type"] as? String, "tab_created")
        XCTAssertEqual((params["topics"] as? [String])?.contains("runtime-events"), true)
        XCTAssertNotNil(params["subscription_id"] as? String)
    }

    func testUnsubscribeStopsNotifications() throws {
        let inverted = expectation(description: "no notification after unsubscribe")
        inverted.isInverted = true

        let session = initializedSession(notificationSink: { payload in
            if payload["method"] as? String == "notifications/chau7.event" {
                inverted.fulfill()
            }
        })

        let subscribeStructured = try toolStructuredContent(
            session: session,
            name: "chau7_subscribe",
            arguments: [:]
        )
        let subscriptionID = try XCTUnwrap(subscribeStructured["subscription_id"] as? String)

        _ = try toolStructuredContent(
            session: session,
            name: "chau7_unsubscribe",
            arguments: ["subscription_id": subscriptionID]
        )

        Chau7ObservabilityService.shared.recordEvent(type: "tab_created", subsystem: "tabs")
        waitForExpectations(timeout: 0.2)
    }

    func testSubscribeRejectsExpiredCursorReplay() throws {
        Chau7ObservabilityService.shared.recordEvent(type: "app_launched", subsystem: "app_lifecycle")

        let session = initializedSession(notificationSink: { _ in })
        let response = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 11,
                "method": "tools/call",
                "params": [
                    "name": "chau7_subscribe",
                    "arguments": ["cursor": -1]
                ]
            ])
        )

        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["isError"] as? Bool, true)
        let structured = try XCTUnwrap(result["structuredContent"] as? [String: Any])
        XCTAssertEqual(structured["error"] as? String, "snapshot_required")
        XCTAssertNotNil(structured["latest_seq"] as? Int64 ?? structured["latest_seq"] as? Int)
        XCTAssertNotNil(structured["oldest_available_seq"] as? Int64 ?? structured["oldest_available_seq"] as? Int)
    }

    private func initializedSession() -> MCPSession {
        initializedSession(notificationSink: nil)
    }

    private func initializedSession(notificationSink: (([String: Any]) -> Void)?) -> MCPSession {
        let session = MCPSession(fd: -1, notificationSink: notificationSink)
        _ = session.handleRequestObject([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": ["protocolVersion": "2025-11-25"]
        ])
        _ = session.handleRequestObject([
            "jsonrpc": "2.0",
            "method": "notifications/initialized"
        ])
        return session
    }

    private func toolStructuredContent(session: MCPSession, name: String, arguments: [String: Any]) throws -> [String: Any] {
        let response = try XCTUnwrap(
            session.handleRequestObject([
                "jsonrpc": "2.0",
                "id": 1,
                "method": "tools/call",
                "params": ["name": name, "arguments": arguments]
            ])
        )
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        return try XCTUnwrap(result["structuredContent"] as? [String: Any])
    }
}
