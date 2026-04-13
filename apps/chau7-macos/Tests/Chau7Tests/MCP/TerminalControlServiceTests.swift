import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class TerminalControlServiceTests: XCTestCase {
    private var appModel: AppModel!
    private var overlayModel: OverlayTabsModel!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        FeatureSettings.shared.mcpPermissionMode = .allowAll
        FeatureSettings.shared.mcpRequiresApproval = false
        FeatureSettings.shared.mcpEnabled = true
        appModel = AppModel()
        overlayModel = OverlayTabsModel(appModel: appModel, restoreState: false)
        TerminalControlService.shared.register(overlayModel)
    }

    override func tearDown() {
        if let overlayModel {
            TerminalControlService.shared.unregister(overlayModel)
        }
        TerminalControlService.shared.activeOverlayModelProvider = nil
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        overlayModel = nil
        appModel = nil
        super.tearDown()
    }

    func testTabStatusUsesEffectiveStateForAutomation() throws {
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.status = .running
        session.isAtPrompt = false
        session.restoreAIMetadata(provider: "claude", sessionId: "session-123")
        appModel.sessionStatuses = [
            SessionStatus(
                id: "Claude-session-123",
                sessionId: "session-123",
                tool: "Claude",
                state: .idle,
                lastSeen: Date()
            )
        ]

        let response = TerminalControlService.shared.tabStatus(tabID: overlayModel.selectedTabID.uuidString)
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["status"] as? String, CommandStatus.idle.rawValue)
        XCTAssertEqual(json["is_at_prompt"] as? Bool, true)
        XCTAssertEqual(json["active_app"] as? String, "Claude")
        XCTAssertEqual(json["ai_provider"] as? String, "claude")
        XCTAssertEqual(json["ai_session_id"] as? String, "session-123")

        XCTAssertEqual(json["raw_status"] as? String, CommandStatus.running.rawValue)
        XCTAssertEqual(json["raw_is_at_prompt"] as? Bool, false)
    }

    func testBackgroundTabCreationDisablesAutoFocusOnAttach() {
        overlayModel.newTab(selectNewTab: false)
        let backgroundSession = overlayModel.tabs.last?.session

        XCTAssertEqual(overlayModel.selectedTabID, overlayModel.tabs.first?.id)
        XCTAssertEqual(backgroundSession?.autoFocusOnAttachEnabled, false)

        overlayModel.newTab()
        let selectedSession = overlayModel.tabs.last?.session
        XCTAssertEqual(selectedSession?.autoFocusOnAttachEnabled, true)
    }

    func testCloseTabRejectsApprovalRequiredStatusWithoutForce() throws {
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.status = .approvalRequired

        let response = TerminalControlService.shared.closeTab(
            tabID: overlayModel.selectedTabID.uuidString,
            force: false
        )
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["error"] as? String, "Tab has a running process (status: approvalRequired). Use force=true to close anyway.")
    }

    func testListTabsReturnsDeterministicControlPlaneIDs() throws {
        let response = TerminalControlService.shared.listTabs()
        let json = try XCTUnwrap(parseJSONArray(response))
        let first = try XCTUnwrap(json.first)

        XCTAssertEqual(first["tab_id"] as? String, "tab_1")
    }

    func testControlPlaneIDsAreReusedAfterTabClose() throws {
        overlayModel.newTab(selectNewTab: false)
        let createdID = try XCTUnwrap(overlayModel.tabs.last?.id)
        XCTAssertEqual(TerminalControlService.shared.controlPlaneTabID(for: createdID), "tab_2")

        _ = TerminalControlService.shared.closeTab(tabID: "tab_2", force: true)

        overlayModel.newTab(selectNewTab: false)
        let recreatedID = try XCTUnwrap(overlayModel.tabs.last?.id)
        XCTAssertEqual(TerminalControlService.shared.controlPlaneTabID(for: recreatedID), "tab_2")
    }

    func testCreateTabDefaultsToActiveOverlayWindow() throws {
        let secondAppModel = AppModel()
        let secondOverlayModel = OverlayTabsModel(appModel: secondAppModel, restoreState: false)
        TerminalControlService.shared.register(secondOverlayModel)
        defer { TerminalControlService.shared.unregister(secondOverlayModel) }

        TerminalControlService.shared.activeOverlayModelProvider = { secondOverlayModel }

        let firstWindowCount = overlayModel.tabs.count
        let secondWindowCount = secondOverlayModel.tabs.count

        let response = TerminalControlService.shared.createTab(directory: nil, windowID: nil)
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["window_id"] as? Int, 1)
        XCTAssertEqual(overlayModel.tabs.count, firstWindowCount)
        XCTAssertEqual(secondOverlayModel.tabs.count, secondWindowCount + 1)
        XCTAssertEqual(secondOverlayModel.selectedTabID, secondOverlayModel.tabs.first?.id)
    }

    func testIsToolAtPromptCanBeScopedToSessionID() throws {
        let promptSession = try XCTUnwrap(overlayModel.tabs.first?.session)
        promptSession.activeAppName = "Codex"
        promptSession.isAtPrompt = true
        promptSession.restoreAIMetadata(provider: "codex", sessionId: "session-prompt")

        overlayModel.newTab(selectNewTab: false)
        let activeSession = try XCTUnwrap(overlayModel.tabs.last?.session)
        activeSession.activeAppName = "Codex"
        activeSession.isAtPrompt = false
        activeSession.restoreAIMetadata(provider: "codex", sessionId: "session-active")

        XCTAssertTrue(TerminalControlService.shared.isToolAtPrompt(toolName: "Codex"))
        XCTAssertTrue(TerminalControlService.shared.isToolAtPrompt(toolName: "Codex", sessionID: "session-prompt"))
        XCTAssertFalse(TerminalControlService.shared.isToolAtPrompt(toolName: "Codex", sessionID: "session-active"))
    }

    func testRunCommandPrearmsAILoggingForKnownToolWithoutLaunchableLookup() throws {
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let tabID = TerminalControlService.shared.controlPlaneTabID(for: tab.id)
        let session = try XCTUnwrap(tab.session)
        session.currentDirectory = "/tmp"

        let response = TerminalControlService.shared.execInTab(
            tabID: tabID,
            command: "codex --model gpt-5.3-codex"
        )
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(session.activeAppName, "Codex")
        XCTAssertNotNil(session.currentPTYLogPath())
    }

    func testSubmitPromptIssuesSecondEnterWhenCodexDraftPersists() throws {
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let tabID = TerminalControlService.shared.controlPlaneTabID(for: tab.id)
        let session = try XCTUnwrap(tab.session)
        session.activeAppName = "Codex"
        session.status = .running
        session.isAtPrompt = true
        session.cachedRemoteOutputText = "› Audit Chau7 MCP and report back with bugs and fixes"

        let response = TerminalControlService.shared.submitPrompt(tabID: tabID)
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["enter_count"] as? Int, 2)
        XCTAssertEqual(json["resolved_intermediate_prompt"] as? Bool, true)
    }

    func testTabOutputPTYLogReadsActiveSessionOutputBeforeClose() throws {
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let session = try XCTUnwrap(tab.session)
        session.startAILoggingIfNeeded(toolName: "Codex", commandLine: "codex --model gpt-5.3-codex")
        session.aiLogSession?.recordOutput(Data("\u{1B}[32mWorking...\u{1B}[0m\n{\"summary\":\"ok\",\"findings\":[],\"recommendations\":[],\"confidence\":\"high\"}\n".utf8))

        let response = TerminalControlService.shared.tabOutput(
            tabID: TerminalControlService.shared.controlPlaneTabID(for: tab.id),
            lines: 50,
            source: "pty_log"
        )
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["source"] as? String, "pty_log")
        XCTAssertTrue((json["output"] as? String)?.contains("Working...") == true)
        XCTAssertTrue((json["output"] as? String)?.contains("\"summary\":\"ok\"") == true)
    }

    func testTabOutputPTYLogSupportsStablePolling() throws {
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let session = try XCTUnwrap(tab.session)
        session.startAILoggingIfNeeded(toolName: "Codex", commandLine: "codex --model gpt-5.3-codex")
        session.aiLogSession?.recordOutput(
            Data(
                "line one\n__CHAU7_REVIEW_JSON_BEGIN__\n{\"summary\":\"ok\",\"findings\":[],\"recommendations\":[],\"confidence\":\"high\"}\n__CHAU7_REVIEW_JSON_END__\n".utf8
            )
        )

        let response = TerminalControlService.shared.tabOutput(
            tabID: TerminalControlService.shared.controlPlaneTabID(for: tab.id),
            lines: 50,
            waitForStableMs: 300,
            source: "pty_log"
        )
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["source"] as? String, "pty_log")
        XCTAssertTrue((json["output"] as? String)?.contains("__CHAU7_REVIEW_JSON_END__") == true)
    }

    func testRepoGetEventsSupportsFilteringAndFullMessages() throws {
        let repoPath = "/tmp/chau7-review-repo"
        let selectedTabID = try XCTUnwrap(overlayModel.tabs.first?.id)
        let otherTabID = UUID()
        let longMessage = "Review complete\n__CHAU7_REVIEW_JSON_BEGIN__\n"
            + "{\"summary\":\"ok\",\"findings\":[],\"recommendations\":[\"none\"],\"confidence\":\"high\"}\n"
            + "__CHAU7_REVIEW_JSON_END__\n"
            + String(repeating: "x", count: 300)

        appModel.eventsByRepo[repoPath] = [
            AIEvent(
                source: .runtime,
                type: "waiting_input",
                tool: "Codex",
                message: longMessage,
                ts: DateFormatters.nowISO8601(),
                repoPath: repoPath,
                tabID: selectedTabID,
                producer: "runtime_session_manager",
                reliability: .authoritative
            ),
            AIEvent(
                source: .runtime,
                type: "finished",
                tool: "Codex",
                message: "other tab",
                ts: DateFormatters.nowISO8601(),
                repoPath: repoPath,
                tabID: otherTabID,
                producer: "runtime_session_manager",
                reliability: .authoritative
            )
        ]

        let response = TerminalControlService.shared.repoGetEvents(
            repoPath: repoPath,
            limit: 10,
            tabID: "tab_1",
            eventTypes: ["waiting_input"],
            tool: "Codex",
            producer: "runtime_session_manager",
            truncateMessages: false
        )
        let json = try XCTUnwrap(parseJSONObject(response))
        let events = try XCTUnwrap(json["events"] as? [[String: Any]])
        let first = try XCTUnwrap(events.first)

        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(first["tab_id"] as? String, "tab_1")
        XCTAssertEqual(first["type"] as? String, "waiting_input")
        XCTAssertEqual(first["producer"] as? String, "runtime_session_manager")
        XCTAssertEqual(first["reliability"] as? String, AIEventReliability.authoritative.rawValue)
        XCTAssertEqual(first["message"] as? String, longMessage)
    }

    func testRenameTabPropagatesToAllSplitSessions() throws {
        overlayModel.splitCurrentTabHorizontally()
        let tab = try XCTUnwrap(overlayModel.tabs.first)
        let sessions = tab.splitController.terminalSessions.map(\.1)
        XCTAssertEqual(sessions.count, 2)

        let response = TerminalControlService.shared.renameTab(
            tabID: tab.id.uuidString,
            title: "Split Tab"
        )
        let json = try XCTUnwrap(parseJSONObject(response))

        XCTAssertEqual(json["title"] as? String, "Split Tab")
        XCTAssertTrue(sessions.allSatisfy { $0.tabTitleOverride == "Split Tab" })
    }

    func testApplyNotificationStyleAcrossWindowsFindsTabInLaterWindow() throws {
        let secondAppModel = AppModel()
        let secondOverlayModel = OverlayTabsModel(appModel: secondAppModel, restoreState: false)
        TerminalControlService.shared.register(secondOverlayModel)
        defer { TerminalControlService.shared.unregister(secondOverlayModel) }

        let secondTabID = try XCTUnwrap(secondOverlayModel.tabs.first?.id)
        let resolvedTabID = TerminalControlService.shared.applyNotificationStyleAcrossWindows(
            to: secondTabID,
            stylePreset: "attention",
            config: [:]
        )

        XCTAssertEqual(resolvedTabID, secondTabID)
        XCTAssertNil(overlayModel.tabs.first?.notificationStyle)
        XCTAssertEqual(secondOverlayModel.tabs.first?.notificationStyle, .attention)
    }

    func testApplyNotificationStyleAcrossWindowsTreatsUnchangedStyleAsSuccess() throws {
        let tabID = try XCTUnwrap(overlayModel.tabs.first?.id)
        overlayModel.tabs[0].notificationStyle = .attention

        let resolvedTabID = TerminalControlService.shared.applyNotificationStyleAcrossWindows(
            to: tabID,
            stylePreset: "attention",
            config: [:]
        )

        XCTAssertEqual(resolvedTabID, tabID)
        XCTAssertEqual(overlayModel.tabs.first?.notificationStyle, .attention)
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
