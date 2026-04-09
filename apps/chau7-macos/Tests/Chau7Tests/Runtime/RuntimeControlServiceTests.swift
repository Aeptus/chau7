import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

private struct MockInteractiveBackend: AgentBackend {
    let name: String

    func launchCommand(config: SessionConfig) -> String {
        "printf ''"
    }

    func formatPromptInput(_ prompt: String, context: String?) -> String {
        if let context, !context.isEmpty {
            return "CTX:\(context)\nPROMPT:\(prompt)\n"
        }
        return "PROMPT:\(prompt)\n"
    }

    var resumeProviderKey: String? {
        nil
    }

    var launchReadinessStrategy: AgentLaunchReadinessStrategy {
        .interactiveAgent
    }
}

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
        RuntimeControlService.shared.launchReadinessProbe = nil
        for session in RuntimeSessionManager.shared.allSessions(includeStopped: false) {
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
        let attachTabID = TerminalControlService.shared.controlPlaneTabID(for: overlayModel.selectedTabID)
        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": "shell",
                "directory": "/tmp/runtime-attach-\(UUID().uuidString)",
                "attach_tab_id": attachTabID
            ]
        )

        let json = try XCTUnwrap(parseJSONObject(response))
        let sessionID = try XCTUnwrap(json["session_id"] as? String)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))

        XCTAssertEqual(json["state"] as? String, "ready")
        XCTAssertEqual(json["tab_id"] as? String, attachTabID)
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

    func testInteractiveBackendSessionStartsInStartingStateUntilLaunchReady() throws {
        let backendName = "mock-interactive-start-\(UUID().uuidString)"
        RuntimeControlService.registerBackend(name: backendName) { MockInteractiveBackend(name: backendName) }
        RuntimeControlService.shared.launchReadinessProbe = { _ in
            RuntimeLaunchReadinessSnapshot(
                shellLoading: true,
                isAtPrompt: true,
                effectiveStatus: "idle",
                rawStatus: "idle",
                activeApp: nil,
                rawActiveApp: nil,
                aiProvider: nil,
                activeRunProvider: nil,
                processNames: []
            )
        }

        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": backendName,
                "directory": "/tmp/runtime-starting-\(UUID().uuidString)"
            ]
        )

        let json = try XCTUnwrap(parseJSONObject(response))
        let sessionID = try XCTUnwrap(json["session_id"] as? String)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))

        XCTAssertEqual(json["state"] as? String, "starting")
        XCTAssertEqual(session.state, .starting)
    }

    func testRuntimeTurnSendPromotesInteractiveSessionOnceLaunchProbeIsReady() throws {
        let backendName = "mock-interactive-send-\(UUID().uuidString)"
        RuntimeControlService.registerBackend(name: backendName) { MockInteractiveBackend(name: backendName) }
        RuntimeControlService.shared.launchReadinessProbe = { _ in
            RuntimeLaunchReadinessSnapshot(
                shellLoading: false,
                isAtPrompt: true,
                effectiveStatus: "idle",
                rawStatus: "idle",
                activeApp: "MockInteractive",
                rawActiveApp: "MockInteractive",
                aiProvider: backendName,
                activeRunProvider: backendName,
                processNames: [backendName]
            )
        }

        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": backendName,
                "directory": "/tmp/runtime-promote-\(UUID().uuidString)"
            ]
        )

        let json = try XCTUnwrap(parseJSONObject(response))
        let sessionID = try XCTUnwrap(json["session_id"] as? String)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))
        XCTAssertEqual(session.state, .starting)

        let sendResponse = RuntimeControlService.shared.handleToolCall(
            name: "runtime_turn_send",
            arguments: [
                "session_id": sessionID,
                "prompt": "status"
            ]
        )

        let sendJSON = try XCTUnwrap(parseJSONObject(sendResponse))
        XCTAssertEqual(sendJSON["status"] as? String, "accepted")
        XCTAssertEqual(session.state, .busy)
    }

    func testInitialPromptWaitsUntilInteractiveLaunchProbeBecomesReady() throws {
        let backendName = "mock-interactive-prompt-\(UUID().uuidString)"
        RuntimeControlService.registerBackend(name: backendName) { MockInteractiveBackend(name: backendName) }

        var isReady = false
        RuntimeControlService.shared.launchReadinessProbe = { _ in
            if !isReady {
                return RuntimeLaunchReadinessSnapshot(
                    shellLoading: true,
                    isAtPrompt: true,
                    effectiveStatus: "idle",
                    rawStatus: "idle",
                    activeApp: nil,
                    rawActiveApp: nil,
                    aiProvider: nil,
                    activeRunProvider: nil,
                    processNames: []
                )
            }
            return RuntimeLaunchReadinessSnapshot(
                shellLoading: false,
                isAtPrompt: true,
                effectiveStatus: "idle",
                rawStatus: "idle",
                activeApp: "MockInteractive",
                rawActiveApp: "MockInteractive",
                aiProvider: backendName,
                activeRunProvider: backendName,
                processNames: [backendName]
            )
        }

        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": backendName,
                "directory": "/tmp/runtime-initial-\(UUID().uuidString)",
                "initial_prompt": "review this change"
            ]
        )

        let json = try XCTUnwrap(parseJSONObject(response))
        let sessionID = try XCTUnwrap(json["session_id"] as? String)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))
        let terminalSession = try XCTUnwrap(tabSession(for: session))

        XCTAssertEqual(session.turnCount, 0)
        isReady = true
        terminalSession.isShellLoading = false
        terminalSession.activeAppName = "MockInteractive"

        XCTAssertTrue(waitUntil(timeout: 3.0) { session.turnCount == 1 && session.state == .busy })
    }

    func testCodeReviewInitialPromptDispatchesWhileInteractiveShellStillReportsLoading() throws {
        let backendName = "mock-interactive-code-review-\(UUID().uuidString)"
        RuntimeControlService.registerBackend(name: backendName) { MockInteractiveBackend(name: backendName) }
        RuntimeControlService.shared.launchReadinessProbe = { session in
            RuntimeLaunchReadinessSnapshot(
                shellLoading: true,
                isAtPrompt: false,
                effectiveStatus: "running",
                rawStatus: "running",
                activeApp: "MockInteractive",
                rawActiveApp: "MockInteractive",
                aiProvider: session.config.purpose == "code_review" ? backendName : nil,
                activeRunProvider: backendName,
                processNames: [backendName]
            )
        }

        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": backendName,
                "directory": "/tmp/runtime-code-review-\(UUID().uuidString)",
                "purpose": "code_review",
                "initial_prompt": "review this staged diff"
            ]
        )

        let json = try XCTUnwrap(parseJSONObject(response))
        let sessionID = try XCTUnwrap(json["session_id"] as? String)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))

        XCTAssertTrue(waitUntil(timeout: 1.5) { session.turnCount == 1 && session.state == .busy })
        XCTAssertNil(session.pendingInitialPrompt)
    }

    func testRuntimeTurnWaitDoesNotFinishWhileInteractiveSessionIsStillStarting() throws {
        let backendName = "mock-interactive-wait-\(UUID().uuidString)"
        RuntimeControlService.registerBackend(name: backendName) { MockInteractiveBackend(name: backendName) }
        RuntimeControlService.shared.launchReadinessProbe = { _ in
            RuntimeLaunchReadinessSnapshot(
                shellLoading: true,
                isAtPrompt: true,
                effectiveStatus: "idle",
                rawStatus: "idle",
                activeApp: nil,
                rawActiveApp: nil,
                aiProvider: nil,
                activeRunProvider: nil,
                processNames: []
            )
        }

        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": backendName,
                "directory": "/tmp/runtime-wait-\(UUID().uuidString)",
                "initial_prompt": "review this change"
            ]
        )

        let json = try XCTUnwrap(parseJSONObject(response))
        let sessionID = try XCTUnwrap(json["session_id"] as? String)

        let waitResponse = RuntimeControlService.shared.handleToolCall(
            name: "runtime_turn_wait",
            arguments: [
                "session_id": sessionID,
                "timeout_ms": 150
            ]
        )

        let waitJSON = try XCTUnwrap(parseJSONObject(waitResponse))
        XCTAssertEqual(waitJSON["state"] as? String, "starting")
        XCTAssertEqual(waitJSON["timed_out"] as? Bool, true)
    }

    func testRuntimeTurnWaitDispatchesDeferredInitialPromptOnceInteractiveBackendBecomesReady() throws {
        let backendName = "mock-interactive-recover-\(UUID().uuidString)"
        RuntimeControlService.registerBackend(name: backendName) { MockInteractiveBackend(name: backendName) }

        var probeAttempts = 0
        RuntimeControlService.shared.launchReadinessProbe = { _ in
            probeAttempts += 1
            if probeAttempts < 4 {
                return RuntimeLaunchReadinessSnapshot(
                    shellLoading: true,
                    isAtPrompt: true,
                    effectiveStatus: "idle",
                    rawStatus: "idle",
                    activeApp: nil,
                    rawActiveApp: nil,
                    aiProvider: nil,
                    activeRunProvider: nil,
                    processNames: []
                )
            }
            return RuntimeLaunchReadinessSnapshot(
                shellLoading: false,
                isAtPrompt: true,
                effectiveStatus: "idle",
                rawStatus: "idle",
                activeApp: "MockInteractive",
                rawActiveApp: "MockInteractive",
                aiProvider: backendName,
                activeRunProvider: backendName,
                processNames: [backendName]
            )
        }

        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": backendName,
                "directory": "/tmp/runtime-recover-\(UUID().uuidString)",
                "initial_prompt": "review this change"
            ]
        )

        let json = try XCTUnwrap(parseJSONObject(response))
        let sessionID = try XCTUnwrap(json["session_id"] as? String)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))

        let waitResponse = RuntimeControlService.shared.handleToolCall(
            name: "runtime_turn_wait",
            arguments: [
                "session_id": sessionID,
                "timeout_ms": 1200
            ]
        )
        let waitJSON = try XCTUnwrap(parseJSONObject(waitResponse))

        XCTAssertEqual(waitJSON["timed_out"] as? Bool, true)
        XCTAssertEqual(waitJSON["state"] as? String, "busy")
        XCTAssertEqual(session.turnCount, 1)
        XCTAssertEqual(session.state, .busy)
        XCTAssertNil(session.pendingInitialPrompt)
        XCTAssertGreaterThanOrEqual(probeAttempts, 4)
    }

    func testRuntimeTurnWaitDispatchesDeferredInitialPromptAfterLegacyTimeoutWindow() throws {
        let backendName = "mock-interactive-slow-recover-\(UUID().uuidString)"
        RuntimeControlService.registerBackend(name: backendName) { MockInteractiveBackend(name: backendName) }

        var probeAttempts = 0
        RuntimeControlService.shared.launchReadinessProbe = { _ in
            probeAttempts += 1
            if probeAttempts < 17 {
                return RuntimeLaunchReadinessSnapshot(
                    shellLoading: true,
                    isAtPrompt: true,
                    effectiveStatus: "idle",
                    rawStatus: "idle",
                    activeApp: nil,
                    rawActiveApp: nil,
                    aiProvider: nil,
                    activeRunProvider: nil,
                    processNames: []
                )
            }
            return RuntimeLaunchReadinessSnapshot(
                shellLoading: false,
                isAtPrompt: true,
                effectiveStatus: "idle",
                rawStatus: "idle",
                activeApp: "MockInteractive",
                rawActiveApp: "MockInteractive",
                aiProvider: backendName,
                activeRunProvider: backendName,
                processNames: [backendName]
            )
        }

        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": backendName,
                "directory": "/tmp/runtime-slow-recover-\(UUID().uuidString)",
                "initial_prompt": "review this change"
            ]
        )

        let json = try XCTUnwrap(parseJSONObject(response))
        let sessionID = try XCTUnwrap(json["session_id"] as? String)
        let session = try XCTUnwrap(RuntimeSessionManager.shared.session(id: sessionID))

        XCTAssertTrue(waitUntil(timeout: 10.0) { session.turnCount == 1 && session.state == .busy })
        XCTAssertNil(session.pendingInitialPrompt)
        XCTAssertGreaterThanOrEqual(probeAttempts, 17)
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

    func testRuntimeSessionStopQueuesTabCloseAsynchronously() throws {
        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: [
                "backend": "shell",
                "directory": "/tmp/runtime-stop-close-\(UUID().uuidString)"
            ]
        )

        let json = try XCTUnwrap(parseJSONObject(response))
        let sessionID = try XCTUnwrap(json["session_id"] as? String)
        let tabID = try XCTUnwrap(json["tab_id"] as? String)

        let stopResponse = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_stop",
            arguments: [
                "session_id": sessionID,
                "close_tab": true
            ]
        )

        let stopJSON = try XCTUnwrap(parseJSONObject(stopResponse))
        XCTAssertEqual(stopJSON["ok"] as? Bool, true)
        XCTAssertEqual(stopJSON["close_queued"] as? Bool, true)
        XCTAssertTrue(waitUntil(timeout: 1.0) {
            !self.overlayModel.tabs.contains(where: { $0.id.uuidString == tabID })
        })
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

    private func tabSession(for runtimeSession: RuntimeSession) -> TerminalSessionModel? {
        overlayModel.tabs.first(where: { $0.id == runtimeSession.tabID })?.session
    }

    private func waitUntil(timeout: TimeInterval, condition: @escaping () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() {
                return true
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        return condition()
    }
}
#endif
