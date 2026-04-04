import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class RuntimeControlServiceTests: XCTestCase {
    private var appModel: AppModel!
    private var overlayModel: OverlayTabsModel!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        FeatureSettings.shared.mcpPermissionMode = .allowAll
        appModel = AppModel()
        overlayModel = OverlayTabsModel(appModel: appModel, restoreState: false)
        TerminalControlService.shared.register(overlayModel)
    }

    override func tearDown() {
        if let selectedTabID = overlayModel?.selectedTabID,
           let session = RuntimeSessionManager.shared.sessionForTab(selectedTabID) {
            _ = RuntimeSessionManager.shared.stopSession(id: session.id)
        }
        if let overlayModel {
            TerminalControlService.shared.unregister(overlayModel)
        }
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        overlayModel = nil
        appModel = nil
        super.tearDown()
    }

    func testRuntimeTurnSendAcceptsAdoptedSession() throws {
        let adoptedSession = RuntimeSessionManager.shared.adoptSession(
            tabID: overlayModel.selectedTabID,
            backend: ClaudeCodeBackend(),
            cwd: "/tmp/runtime-control-\(UUID().uuidString)"
        )

        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_turn_send",
            arguments: [
                "session_id": adoptedSession.id,
                "prompt": "status"
            ]
        )

        let json = try XCTUnwrap(parseJSONObject(response))
        XCTAssertEqual(json["status"] as? String, "accepted")
        XCTAssertEqual(json["turn_id"] as? String, adoptedSession.currentTurnID)
        XCTAssertEqual(adoptedSession.state, .busy)
    }

    func testRuntimeSessionCreateStartsReadySession() throws {
        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": "shell",
                "directory": "/tmp/runtime-create-\(UUID().uuidString)"
            ]
        )

        let json = try XCTUnwrap(parseJSONObject(response))
        let sessionID = try XCTUnwrap(json["session_id"] as? String)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))

        XCTAssertEqual(json["state"] as? String, "ready")
        XCTAssertEqual(session.state, .ready)
    }

    func testRuntimeSessionCreateWithAttachTabStartsReadySession() throws {
        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": "shell",
                "directory": "/tmp/runtime-attach-\(UUID().uuidString)",
                "attach_tab_id": overlayModel.selectedTabID.uuidString
            ]
        )

        let json = try XCTUnwrap(parseJSONObject(response))
        let sessionID = try XCTUnwrap(json["session_id"] as? String)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))

        XCTAssertEqual(json["state"] as? String, "ready")
        XCTAssertEqual(session.state, .ready)
    }

    func testRuntimeSessionCreatePersistsDelegationMetadata() throws {
        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": "shell",
                "directory": "/tmp/runtime-delegation-\(UUID().uuidString)",
                "purpose": "code_review",
                "parent_session_id": "rs_parent123",
                "parent_run_id": "run_parent123",
                "delegation_depth": 1,
                "task_metadata": [
                    "review_scope": "commits",
                    "audience": "main-agent"
                ]
            ]
        )

        let json = try XCTUnwrap(parseJSONObject(response))
        let sessionID = try XCTUnwrap(json["session_id"] as? String)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))
        let taskMetadata = try XCTUnwrap(json["task_metadata"] as? [String: Any])

        XCTAssertEqual(json["purpose"] as? String, "code_review")
        XCTAssertEqual(json["parent_session_id"] as? String, "rs_parent123")
        XCTAssertEqual(json["parent_run_id"] as? String, "run_parent123")
        XCTAssertEqual(json["delegation_depth"] as? Int, 1)
        XCTAssertEqual(taskMetadata["review_scope"] as? String, "commits")
        XCTAssertEqual(taskMetadata["audience"] as? String, "main-agent")

        XCTAssertEqual(session.config.purpose, "code_review")
        XCTAssertEqual(session.config.parentSessionID, "rs_parent123")
        XCTAssertEqual(session.config.parentRunID, "run_parent123")
        XCTAssertEqual(session.config.delegationDepth, 1)
        XCTAssertEqual(session.config.taskMetadata["review_scope"], "commits")
    }

    func testRuntimeTurnResultReturnsCapturedStructuredPayload() throws {
        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": "shell",
                "directory": "/tmp/runtime-result-\(UUID().uuidString)",
                "result_schema": [
                    "type": "object",
                    "required": ["summary", "findings"],
                    "properties": [
                        "summary": ["type": "string"],
                        "findings": [
                            "type": "array",
                            "items": [
                                "type": "object",
                                "required": ["severity", "message"],
                                "properties": [
                                    "severity": ["type": "string"],
                                    "message": ["type": "string"]
                                ]
                            ]
                        ]
                    ]
                ]
            ]
        )

        let json = try XCTUnwrap(parseJSONObject(response))
        let sessionID = try XCTUnwrap(json["session_id"] as? String)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))

        let sendResponse = RuntimeControlService.shared.handleToolCall(
            name: "runtime_turn_send",
            arguments: [
                "session_id": sessionID,
                "prompt": "review the change"
            ]
        )
        let sendJSON = try XCTUnwrap(parseJSONObject(sendResponse))
        let turnID = try XCTUnwrap(sendJSON["turn_id"] as? String)

        _ = session.completeTurn(
            summary: """
            ```json
            {"summary":"Looks good overall","findings":[{"severity":"medium","message":"Missing regression test"}]}
            ```
            """,
            terminalOutput: nil
        )

        let resultResponse = RuntimeControlService.shared.handleToolCall(
            name: "runtime_turn_result",
            arguments: [
                "session_id": sessionID,
                "turn_id": turnID
            ]
        )

        let resultJSON = try XCTUnwrap(parseJSONObject(resultResponse))
        XCTAssertEqual(resultJSON["status"] as? String, "available")
        let value = try XCTUnwrap(resultJSON["value"] as? [String: Any])
        XCTAssertEqual(value["summary"] as? String, "Looks good overall")
        let findings = try XCTUnwrap(value["findings"] as? [[String: Any]])
        XCTAssertEqual(findings.first?["severity"] as? String, "medium")
    }

    func testRuntimeSessionCreateRejectsChildWhenParentPolicyDisallowsDelegation() throws {
        let parentResponse = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": "shell",
                "directory": "/tmp/runtime-parent-\(UUID().uuidString)",
                "policy": [
                    "allow_child_delegation": false,
                    "max_delegation_depth": 0
                ]
            ]
        )
        let parentJSON = try XCTUnwrap(parseJSONObject(parentResponse))
        let parentSessionID = try XCTUnwrap(parentJSON["session_id"] as? String)

        let childResponse = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": "shell",
                "directory": "/tmp/runtime-child-\(UUID().uuidString)",
                "parent_session_id": parentSessionID,
                "delegation_depth": 1
            ]
        )

        let childJSON = try XCTUnwrap(parseJSONObject(childResponse))
        XCTAssertEqual(childJSON["error"] as? String, "Session policy disallows child delegation.")
    }

    func testRuntimeSessionChildrenListsDescendants() throws {
        let parentResponse = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": "shell",
                "directory": "/tmp/runtime-tree-\(UUID().uuidString)"
            ]
        )
        let parentJSON = try XCTUnwrap(parseJSONObject(parentResponse))
        let parentSessionID = try XCTUnwrap(parentJSON["session_id"] as? String)

        let childResponse = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": "shell",
                "directory": "/tmp/runtime-tree-child-\(UUID().uuidString)",
                "parent_session_id": parentSessionID,
                "delegation_depth": 1
            ]
        )
        let childJSON = try XCTUnwrap(parseJSONObject(childResponse))
        let childSessionID = try XCTUnwrap(childJSON["session_id"] as? String)

        let descendantsResponse = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_children",
            arguments: [
                "session_id": parentSessionID,
                "recursive": true
            ]
        )

        let descendants = try XCTUnwrap(parseJSONArray(descendantsResponse))
        XCTAssertTrue(descendants.contains { ($0["session_id"] as? String) == childSessionID })
    }

    private func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func parseJSONArray(_ text: String) -> [[String: Any]]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        return json
    }
}
#endif
