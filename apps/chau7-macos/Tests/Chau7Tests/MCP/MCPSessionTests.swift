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
        XCTAssertEqual(snapshot["observer_contract_version"] as? Int, 1)
        XCTAssertNotNil(snapshot["latest_seq"])
        XCTAssertNotNil(snapshot["runtime_info"] as? [String: Any])
        XCTAssertNotNil(snapshot["tabs"] as? [[String: Any]])
        XCTAssertNotNil(snapshot["approvals"] as? [[String: Any]])
        XCTAssertNotNil((snapshot["telemetry"] as? [String: Any])?["active_runs"] as? [[String: Any]])
        let observerContract = try XCTUnwrap(snapshot["observer_contract"] as? [String: Any])
        XCTAssertEqual(observerContract["notification_method"] as? String, "notifications/chau7.event")
        XCTAssertEqual(observerContract["delivery_mode"] as? String, "serial")
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
                        "replay_limit": 10,
                        "heartbeat_interval_ms": 1_000
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
        let subscription = try XCTUnwrap(subscribeStructured["subscription"] as? [String: Any])
        XCTAssertEqual(subscription["observer_contract_version"] as? Int, 1)
        let health = try XCTUnwrap(subscription["health"] as? [String: Any])
        XCTAssertEqual(health["delivery_mode"] as? String, "serial")
        XCTAssertEqual(health["heartbeat_interval_ms"] as? Int, 1_000)

        Chau7ObservabilityService.shared.recordEvent(type: "tab_created", subsystem: "tabs", detail: ["window_id": 1])

        waitForExpectations(timeout: 1)

        let params = try XCTUnwrap(receivedNotification?["params"] as? [String: Any])
        XCTAssertEqual(params["type"] as? String, "tab_created")
        XCTAssertEqual((params["topics"] as? [String])?.contains("runtime-events"), true)
        XCTAssertNotNil(params["subscription_id"] as? String)
        XCTAssertEqual(params["observer_contract_version"] as? Int, 1)
        XCTAssertNotNil(params["delivery_seq"] as? Int64 ?? params["delivery_seq"] as? Int)
        let notificationHealth = try XCTUnwrap(params["subscription_health"] as? [String: Any])
        XCTAssertEqual(notificationHealth["delivery_mode"] as? String, "serial")
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
        XCTAssertEqual(structured["observer_contract_version"] as? Int, 1)
    }

    func testSubscriptionHeartbeatUsesStableContractShape() throws {
        let heartbeatExpectation = expectation(description: "receives heartbeat notification")
        var receivedNotification: [String: Any]?
        let session = initializedSession(notificationSink: { payload in
            if payload["method"] as? String == "notifications/chau7.event",
               let params = payload["params"] as? [String: Any],
               params["type"] as? String == "heartbeat" {
                receivedNotification = payload
                heartbeatExpectation.fulfill()
            }
        })

        _ = try toolStructuredContent(
            session: session,
            name: "chau7_subscribe",
            arguments: ["heartbeat_interval_ms": 1_000]
        )

        session.emitSubscriptionHeartbeatForTests()
        waitForExpectations(timeout: 1)

        let params = try XCTUnwrap(receivedNotification?["params"] as? [String: Any])
        XCTAssertEqual(params["type"] as? String, "heartbeat")
        XCTAssertEqual(params["topic"] as? String, "subscription-control")
        XCTAssertEqual(params["observer_contract_version"] as? Int, 1)
        XCTAssertNotNil(params["latest_seq"] as? Int64 ?? params["latest_seq"] as? Int)
    }

    func testStateSnapshotGoldenContractShape() throws {
        Chau7ObservabilityService.shared.recordEvent(type: "app_launched", subsystem: "app_lifecycle")
        let session = initializedSession()
        let snapshot = try toolStructuredContent(
            session: session,
            name: "chau7_state_snapshot",
            arguments: [:]
        )

        let scrubbed = scrubSnapshotContract(snapshot)
        let encoded = try canonicalJSONString(scrubbed)
        XCTAssertEqual(encoded, """
{"approvals":[],"generated_at_millis":"<generated_at_millis>","latest_seq":"<latest_seq>","observer_contract":{"default_heartbeat_interval_ms":15000,"default_replay_limit":200,"delivery_mode":"serial","heartbeat_event_type":"heartbeat","max_heartbeat_interval_ms":60000,"max_replay_limit":500,"min_heartbeat_interval_ms":1000,"notification_method":"notifications\\/chau7.event","snapshot_tool":"chau7_state_snapshot","subscribe_tool":"chau7_subscribe","supported_topics":["approval-state","repo-events","runtime-events","session-state","tab-state","telemetry-runs","timer-inventory"],"unsubscribe_tool":"chau7_unsubscribe","version":1},"observer_contract_version":1,"repo_events":[],"runtime_info":{"app_version":"<app_version>","build_channel":"<build_channel>","build_number":"<build_number>","build_sha":"<build_sha>","build_timestamp":"<build_timestamp>","bundle_id":"<bundle_id>","launch_time":"<launch_time>","mcp_protocol_version":"2025-11-25","observability_schema_version":1,"process_id":"<process_id>","session_started_at":"<session_started_at>"},"schema_version":1,"tabs":[],"telemetry":{"active_runs":[],"active_sessions":[]},"timers":[]}
""")
    }

    func testSubscriptionNotificationGoldenContractShape() throws {
        let expectation = expectation(description: "receives golden contract notification")
        var paramsPayload: [String: Any]?
        let session = initializedSession(notificationSink: { payload in
            guard payload["method"] as? String == "notifications/chau7.event",
                  let params = payload["params"] as? [String: Any],
                  params["type"] as? String == "tab_created" else { return }
            paramsPayload = params
            expectation.fulfill()
        })

        _ = try toolStructuredContent(
            session: session,
            name: "chau7_subscribe",
            arguments: ["topics": ["tab-state"], "heartbeat_interval_ms": 1_000]
        )

        Chau7ObservabilityService.shared.recordEvent(type: "tab_created", subsystem: "tabs", detail: ["window_id": 1])
        waitForExpectations(timeout: 1)

        let scrubbed = try scrubNotificationContract(try XCTUnwrap(paramsPayload))
        let encoded = try canonicalJSONString(scrubbed)
        XCTAssertEqual(encoded, """
{"delivery_seq":"<delivery_seq>","observer_contract_version":1,"payload":{"detail":{"window_id":1},"id":"<event_id>","seq":"<event_seq>","subsystem":"tabs","timestamp_millis":"<event_timestamp_millis>","type":"tab_created"},"seq":"<event_seq>","subscription_health":{"buffer_depth":0,"created_at_millis":"<created_at_millis>","delivery_mode":"serial","dropped_notification_count":0,"heartbeat_interval_ms":1000,"lag_state":"healthy","last_notification_at_millis":"<last_notification_at_millis>","notifications_emitted_count":1},"subscription_id":"<subscription_id>","subsystem":"tabs","timestamp_millis":"<event_timestamp_millis>","topics":["runtime-events","tab-state"],"type":"tab_created"}
""")
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

    private func scrubSnapshotContract(_ payload: [String: Any]) -> [String: Any] {
        var snapshot = payload
        snapshot["generated_at_millis"] = "<generated_at_millis>"
        snapshot["latest_seq"] = "<latest_seq>"
        if var runtimeInfo = snapshot["runtime_info"] as? [String: Any] {
            runtimeInfo["app_version"] = "<app_version>"
            runtimeInfo["build_channel"] = "<build_channel>"
            runtimeInfo["build_number"] = "<build_number>"
            runtimeInfo["build_sha"] = "<build_sha>"
            runtimeInfo["build_timestamp"] = "<build_timestamp>"
            runtimeInfo["bundle_id"] = "<bundle_id>"
            runtimeInfo["launch_time"] = "<launch_time>"
            runtimeInfo["process_id"] = "<process_id>"
            runtimeInfo["session_started_at"] = "<session_started_at>"
            snapshot["runtime_info"] = runtimeInfo
        }
        return snapshot
    }

    private func scrubNotificationContract(_ payload: [String: Any]) throws -> [String: Any] {
        var notification = payload
        notification["delivery_seq"] = "<delivery_seq>"
        notification["subscription_id"] = "<subscription_id>"
        notification["seq"] = "<event_seq>"
        notification["timestamp_millis"] = "<event_timestamp_millis>"
        if var eventPayload = notification["payload"] as? [String: Any] {
            eventPayload["id"] = "<event_id>"
            eventPayload["seq"] = "<event_seq>"
            eventPayload["timestamp_millis"] = "<event_timestamp_millis>"
            notification["payload"] = eventPayload
        }
        if var health = notification["subscription_health"] as? [String: Any] {
            health["created_at_millis"] = "<created_at_millis>"
            health["last_notification_at_millis"] = "<last_notification_at_millis>"
            notification["subscription_health"] = health
        }
        return notification
    }

    private func canonicalJSONString(_ object: [String: Any]) throws -> String {
        let data = try XCTUnwrap(try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
