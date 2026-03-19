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
        FeatureSettings.shared.mcpPermissionMode = .allowAll
        FeatureSettings.shared.mcpRequiresApproval = false
        FeatureSettings.shared.mcpEnabled = true
        appModel = AppModel()
        overlayModel = OverlayTabsModel(appModel: appModel)
        TerminalControlService.shared.register(overlayModel)
    }

    override func tearDown() {
        if let overlayModel {
            TerminalControlService.shared.unregister(overlayModel)
        }
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
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

    private func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
#endif
