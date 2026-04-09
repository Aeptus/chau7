import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7
@testable import Chau7Core

@MainActor
final class ScriptingAPITests: XCTestCase {

    private var api: ScriptingAPI!
    private var createdSessionIDs: [String] = []
    private var defaultsSuiteName: String!
    private var isolatedDefaults: UserDefaults!

    override func setUp() async throws {
        try await super.setUp()
        api = ScriptingAPI.shared
        defaultsSuiteName = "ScriptingAPITests-\(UUID().uuidString)"
        isolatedDefaults = UserDefaults(suiteName: defaultsSuiteName)
        isolatedDefaults.removePersistentDomain(forName: defaultsSuiteName)
    }

    override func tearDown() async throws {
        for sessionID in createdSessionIDs {
            _ = RuntimeSessionManager.shared.stopSession(id: sessionID)
        }
        createdSessionIDs.removeAll()
        if let defaultsSuiteName {
            isolatedDefaults?.removePersistentDomain(forName: defaultsSuiteName)
        }
        isolatedDefaults = nil
        defaultsSuiteName = nil
        api = nil
        try await super.tearDown()
    }

    // MARK: - Request Parsing

    func testMissingMethodReturnsError() async {
        let request: [String: Any] = ["params": ["key": "value"]]
        let response = await api.handleRequest(request)
        XCTAssertNotNil(response["error"] as? String)
        XCTAssertEqual(response["error"] as? String, "missing method")
    }

    func testEmptyRequestReturnsError() async {
        let request: [String: Any] = [:]
        let response = await api.handleRequest(request)
        XCTAssertNotNil(response["error"] as? String)
        XCTAssertEqual(response["error"] as? String, "missing method")
    }

    func testValidMethodWithNoParams() async {
        let request: [String: Any] = ["method": "get_status"]
        let response = await api.handleRequest(request)
        XCTAssertNil(response["error"])
        XCTAssertNotNil(response["result"])
    }

    // MARK: - Unknown Method

    func testUnknownMethodReturnsError() async {
        let request: [String: Any] = ["method": "nonexistent_method"]
        let response = await api.handleRequest(request)
        let error = response["error"] as? String
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("unknown method") ?? false)
        XCTAssertTrue(error?.contains("nonexistent_method") ?? false)
    }

    func testAnotherUnknownMethod() async {
        let request: [String: Any] = ["method": "delete_everything"]
        let response = await api.handleRequest(request)
        let error = response["error"] as? String
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("unknown method") ?? false)
    }

    // MARK: - list_tabs Response Format

    func testListTabsReturnsArray() async {
        let request: [String: Any] = ["method": "list_tabs"]
        let response = await api.handleRequest(request)
        XCTAssertNil(response["error"])
        // result should be an array (possibly empty)
        let result = response["result"]
        XCTAssertNotNil(result)
        XCTAssertTrue(result is [[String: Any]])
    }

    // MARK: - get_status Response

    func testGetStatusResponseFormat() async {
        let request: [String: Any] = ["method": "get_status"]
        let response = await api.handleRequest(request)
        XCTAssertNil(response["error"])

        guard let result = response["result"] as? [String: Any] else {
            XCTFail("get_status result should be a dictionary")
            return
        }

        // Verify expected keys exist
        XCTAssertNotNil(result["version"])
        XCTAssertNotNil(result["build"])
        XCTAssertNotNil(result["uptime_seconds"])
        XCTAssertNotNil(result["connected_clients"])
        XCTAssertNotNil(result["server_running"])
        XCTAssertNotNil(result["history_count"])
        XCTAssertNotNil(result["api_version"])
        XCTAssertNotNil(result["supported_methods"])

        // Verify types
        XCTAssertTrue(result["version"] is String)
        XCTAssertTrue(result["build"] is String)
        XCTAssertTrue(result["uptime_seconds"] is Int)
        XCTAssertTrue(result["connected_clients"] is Int)
        XCTAssertTrue(result["server_running"] is Bool)
        XCTAssertTrue(result["history_count"] is Int)
        XCTAssertTrue(result["api_version"] is Int)
        XCTAssertTrue(result["supported_methods"] is [String])
    }

    func testGetStatusIncludesUnifiedInteractiveMethods() async throws {
        let response = await api.handleRequest(["method": "get_status"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        let methods = try XCTUnwrap(result["supported_methods"] as? [String])

        XCTAssertTrue(methods.contains("send_input"))
        XCTAssertTrue(methods.contains("press_key"))
        XCTAssertTrue(methods.contains("submit_prompt"))
    }

    // MARK: - get_history

    func testGetHistoryReturnsArray() async {
        let request: [String: Any] = ["method": "get_history", "params": ["limit": 10]]
        let response = await api.handleRequest(request)
        XCTAssertNil(response["error"])
        let result = response["result"]
        XCTAssertNotNil(result)
        XCTAssertTrue(result is [[String: Any]])
    }

    // MARK: - get_settings

    func testGetSettingsReturnsDict() async {
        let request: [String: Any] = ["method": "get_settings"]
        let response = await api.handleRequest(request)
        XCTAssertNil(response["error"])
        XCTAssertTrue(response["result"] is [String: Any])
    }

    func testInitialEnabledDefaultsToTrueWhenUnset() {
        let defaults = isolatedDefaults!

        XCTAssertNil(defaults.object(forKey: ScriptingAPI.featureFlagKey))
        XCTAssertTrue(ScriptingAPI.initialEnabled(defaults: defaults))
        XCTAssertEqual(defaults.object(forKey: ScriptingAPI.featureFlagKey) as? Bool, true)
    }

    func testInitialEnabledRespectsPersistedFalse() {
        let defaults = isolatedDefaults!
        defaults.set(false, forKey: ScriptingAPI.featureFlagKey)

        XCTAssertFalse(ScriptingAPI.initialEnabled(defaults: defaults))
    }

    func testInitialEnabledRespectsPersistedTrue() {
        let defaults = isolatedDefaults!
        defaults.set(true, forKey: ScriptingAPI.featureFlagKey)

        XCTAssertTrue(ScriptingAPI.initialEnabled(defaults: defaults))
    }

    // MARK: - set_setting Validation

    func testSetSettingMissingKey() async {
        let request: [String: Any] = ["method": "set_setting", "params": ["value": true]]
        let response = await api.handleRequest(request)
        XCTAssertEqual(response["error"] as? String, "missing param: key")
    }

    func testSetSettingMissingValue() async {
        let request: [String: Any] = ["method": "set_setting", "params": ["key": "feature.scriptingAPI"]]
        let response = await api.handleRequest(request)
        XCTAssertEqual(response["error"] as? String, "missing param: value")
    }

    func testSetSettingDisallowedKey() async {
        let request: [String: Any] = [
            "method": "set_setting",
            "params": ["key": "some.private.setting", "value": true]
        ]
        let response = await api.handleRequest(request)
        let error = response["error"] as? String
        XCTAssertNotNil(error)
        XCTAssertTrue(error?.contains("disallowed") ?? false)
    }

    // MARK: - Parameter Validation

    func testRunCommandMissingTabID() async {
        let request: [String: Any] = ["method": "run_command", "params": ["command": "ls"]]
        let response = await api.handleRequest(request)
        XCTAssertEqual(response["error"] as? String, "missing param: tab_id")
    }

    func testRunCommandMissingCommand() async {
        let request: [String: Any] = ["method": "run_command", "params": ["tab_id": "t1"]]
        let response = await api.handleRequest(request)
        XCTAssertEqual(response["error"] as? String, "missing param: command")
    }

    func testSendInputMissingTabID() async {
        let response = await api.handleRequest(["method": "send_input", "params": ["input": "hello"]])
        XCTAssertEqual(response["error"] as? String, "missing param: tab_id")
    }

    func testSubmitPromptMissingTabID() async {
        let response = await api.handleRequest(["method": "submit_prompt", "params": [:]])
        XCTAssertEqual(response["error"] as? String, "missing param: tab_id")
    }

    func testGetOutputMissingTabID() async {
        let request: [String: Any] = ["method": "get_output", "params": [:]]
        let response = await api.handleRequest(request)
        XCTAssertEqual(response["error"] as? String, "missing param: tab_id")
    }

    func testCloseTabMissingID() async {
        let request: [String: Any] = ["method": "close_tab", "params": [:]]
        let response = await api.handleRequest(request)
        XCTAssertEqual(response["error"] as? String, "missing param: id")
    }

    // MARK: - list_snippets

    func testListSnippetsReturnsArray() async {
        let request: [String: Any] = ["method": "list_snippets"]
        let response = await api.handleRequest(request)
        XCTAssertNil(response["error"])
        XCTAssertTrue(response["result"] is [[String: Any]])
    }

    // MARK: - Delegated Sessions

    func testCreateSessionRequiresDirectory() async {
        let response = await api.handleRequest([
            "method": "create_session",
            "params": [
                "mode": "staged_diff",
                "staged_diff": "diff --git a/file.swift b/file.swift"
            ]
        ])

        XCTAssertEqual(response["error"] as? String, "missing param: directory")
    }

    func testCreateSessionRejectsUnsupportedMode() async {
        let response = await api.handleRequest([
            "method": "create_session",
            "params": [
                "directory": "/tmp/review-\(UUID().uuidString)",
                "mode": "mystery"
            ]
        ])

        XCTAssertEqual(response["error"] as? String, "unsupported review mode: mystery")
    }

    func testCreateSessionCreatesDelegatedCodeReviewSession() async throws {
        let response = await api.handleRequest([
            "method": "create_session",
            "params": [
                "backend": "shell",
                "directory": "/tmp/review-\(UUID().uuidString)",
                "mode": "staged_diff",
                "staged_files": ["Sources/App.swift", "Tests/AppTests.swift"],
                "staged_diff": """
                diff --git a/Sources/App.swift b/Sources/App.swift
                @@ -1 +1 @@
                -old
                +new
                """
            ]
        ])

        let sessionID = try XCTUnwrap(response["session_id"] as? String)
        createdSessionIDs.append(sessionID)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))

        XCTAssertEqual(response["purpose"] as? String, "code_review")
        XCTAssertEqual(session.config.purpose, "code_review")
        XCTAssertEqual(session.config.taskMetadata["review_mode"], "staged_diff")
        XCTAssertEqual(session.config.taskMetadata["session_binding"], "isolated")
        XCTAssertEqual(session.config.policy.maxTurns, 1)
        XCTAssertFalse(session.config.policy.allowChildDelegation)
    }

    func testCreateReviewSessionDoesNotStartTurnBeforePromptIsSent() async throws {
        let response = await api.handleRequest([
            "method": "create_session",
            "params": [
                "backend": "shell",
                "directory": "/tmp/review-\(UUID().uuidString)",
                "mode": "staged_diff",
                "staged_diff": "diff --git a/file.swift b/file.swift"
            ]
        ])

        let sessionID = try XCTUnwrap(response["session_id"] as? String)
        createdSessionIDs.append(sessionID)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))

        XCTAssertEqual(response["phase"] as? String, "created")
        XCTAssertEqual(response["prompt_sent"] as? Bool, false)
        XCTAssertNil(session.currentTurnID)
    }

    func testGetSessionEventsReturnsReadyEventForImmediateBackend() async throws {
        let createResponse = await api.handleRequest([
            "method": "create_session",
            "params": [
                "backend": "shell",
                "directory": "/tmp/review-\(UUID().uuidString)",
                "mode": "staged_diff",
                "staged_diff": "diff --git a/file.swift b/file.swift"
            ]
        ])

        let sessionID = try XCTUnwrap(createResponse["session_id"] as? String)
        createdSessionIDs.append(sessionID)

        let eventsResponse = await api.handleRequest([
            "method": "get_session_events",
            "params": [
                "session_id": sessionID,
                "cursor": 0
            ]
        ])

        XCTAssertEqual(eventsResponse["session_id"] as? String, sessionID)
        let events = try XCTUnwrap(eventsResponse["events"] as? [[String: Any]])
        XCTAssertTrue(events.contains(where: { $0["type"] as? String == RuntimeEventType.sessionReady.rawValue }))
    }

    func testGetSessionEventsPreservesRuntimeCursorWhenFilterRemovesEvents() async throws {
        let createResponse = await api.handleRequest([
            "method": "create_session",
            "params": [
                "backend": "shell",
                "directory": "/tmp/review-\(UUID().uuidString)",
                "mode": "staged_diff",
                "staged_diff": "diff --git a/file.swift b/file.swift"
            ]
        ])

        let sessionID = try XCTUnwrap(createResponse["session_id"] as? String)
        createdSessionIDs.append(sessionID)

        let unfilteredResponse = await api.handleRequest([
            "method": "get_session_events",
            "params": [
                "session_id": sessionID,
                "cursor": 0
            ]
        ])
        let unfilteredCursor = try XCTUnwrap(unfilteredResponse["cursor"])

        let filteredResponse = await api.handleRequest([
            "method": "get_session_events",
            "params": [
                "session_id": sessionID,
                "cursor": 0,
                "event_types": ["definitely_not_a_real_event_type"]
            ]
        ])

        XCTAssertEqual(filteredResponse["session_id"] as? String, sessionID)
        let filteredEvents = try XCTUnwrap(filteredResponse["events"] as? [[String: Any]])
        XCTAssertTrue(filteredEvents.isEmpty)
        XCTAssertEqual(String(describing: filteredResponse["cursor"]), String(describing: unfilteredCursor))
    }

    func testSubmitSessionTurnStartsTurnForPreparedSession() async throws {
        let createResponse = await api.handleRequest([
            "method": "create_session",
            "params": [
                "backend": "shell",
                "directory": "/tmp/review-\(UUID().uuidString)",
                "mode": "staged_diff",
                "staged_diff": "diff --git a/file.swift b/file.swift"
            ]
        ])

        let sessionID = try XCTUnwrap(createResponse["session_id"] as? String)
        createdSessionIDs.append(sessionID)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))

        let sendResponse = await api.handleRequest([
            "method": "submit_session_turn",
            "params": ["session_id": sessionID]
        ])

        XCTAssertEqual(sendResponse["phase"] as? String, "prompt_sent")
        XCTAssertEqual(sendResponse["prompt_sent"] as? Bool, true)
        XCTAssertEqual(sendResponse["status"] as? String, "accepted")
        XCTAssertNotNil(sendResponse["turn_id"] as? String)
        XCTAssertNotNil(session.currentTurnID)
        XCTAssertNil(sendResponse["result_schema"])
    }

    func testGetSessionEventsReturnsTurnResultAfterCompletion() async throws {
        let response = await api.handleRequest([
            "method": "create_session",
            "params": [
                "backend": "shell",
                "directory": "/tmp/review-\(UUID().uuidString)",
                "mode": "staged_diff",
                "staged_diff": "diff --git a/file.swift b/file.swift"
            ]
        ])

        let sessionID = try XCTUnwrap(response["session_id"] as? String)
        createdSessionIDs.append(sessionID)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))
        _ = await api.handleRequest([
            "method": "submit_session_turn",
            "params": ["session_id": sessionID]
        ])
        try await waitForTurnStart(session)
        _ = session.completeTurn(
            summary: """
            ```json
            {"summary":"done","findings":[],"recommendations":[],"confidence":"high"}
            ```
            """,
            terminalOutput: nil
        )

        let eventsResponse = await api.handleRequest([
            "method": "get_session_events",
            "params": [
                "session_id": sessionID,
                "cursor": 0,
                "event_types": [RuntimeEventType.turnResult.rawValue]
            ]
        ])

        XCTAssertEqual(eventsResponse["session_id"] as? String, sessionID)
        let events = try XCTUnwrap(eventsResponse["events"] as? [[String: Any]])
        XCTAssertTrue(events.contains(where: { $0["type"] as? String == RuntimeEventType.turnResult.rawValue }))
    }

    func testGetSessionResultReturnsStructuredPayload() async throws {
        let response = await api.handleRequest([
            "method": "create_session",
            "params": [
                "backend": "shell",
                "directory": "/tmp/review-\(UUID().uuidString)",
                "mode": "commit_range",
                "base_commit": "abc123",
                "head_commit": "def456"
            ]
        ])

        let sessionID = try XCTUnwrap(response["session_id"] as? String)
        createdSessionIDs.append(sessionID)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))
        _ = await api.handleRequest([
            "method": "submit_session_turn",
            "params": ["session_id": sessionID]
        ])
        try await waitForTurnStart(session)
        _ = session.completeTurn(
            summary: """
            ```json
            {"summary":"ready","findings":[{"severity":"medium","file":"App.swift","message":"Missing test"}],"recommendations":["Add a regression test"],"confidence":"high"}
            ```
            """,
            terminalOutput: nil
        )

        let resultResponse = await api.handleRequest([
            "method": "get_session_result",
            "params": ["session_id": sessionID]
        ])

        XCTAssertEqual(resultResponse["status"] as? String, "available")
        let value = try XCTUnwrap(resultResponse["value"] as? [String: Any])
        XCTAssertEqual(value["summary"] as? String, "ready")
    }

    func testStopSessionStopsSessionAndClosesTab() async throws {
        let response = await api.handleRequest([
            "method": "create_session",
            "params": [
                "backend": "shell",
                "directory": "/tmp/review-\(UUID().uuidString)",
                "mode": "staged_diff",
                "staged_diff": "diff --git a/file.swift b/file.swift"
            ]
        ])

        let sessionID = try XCTUnwrap(response["session_id"] as? String)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))
        createdSessionIDs.append(sessionID)

        let stopResponse = await api.handleRequest([
            "method": "stop_session",
            "params": [
                "session_id": sessionID,
                "force": true
            ]
        ])

        XCTAssertEqual(stopResponse["ok"] as? Bool, true)
        XCTAssertEqual(stopResponse["session_id"] as? String, sessionID)
        XCTAssertEqual(session.state, .stopped)
    }

    private func waitForTurnStart(_ session: RuntimeSession, timeoutNs: UInt64 = 2_000_000_000) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + timeoutNs
        while session.currentTurnID == nil {
            if DispatchTime.now().uptimeNanoseconds >= deadline {
                XCTFail("Timed out waiting for initial review turn to start")
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
#endif
