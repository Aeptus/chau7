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

    private func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
#endif
