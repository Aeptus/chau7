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

    private func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
#endif
