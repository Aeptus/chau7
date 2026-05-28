import XCTest
import Chau7Core
@testable import Chau7

@MainActor
final class HistorySessionAdoptionTests: XCTestCase {
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

    func testAdoptHistorySessionUpdatesResolvedCodexTabIdentity() throws {
        let tabID = overlayModel.selectedTabID
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.currentDirectory = "/tmp/Aethyme"
        session.restoreAIMetadata(
            provider: "codex",
            sessionId: "019d86d9-2396-72d0-85af-71dce6106541",
            sessionIdSource: .explicit
        )

        let request = try XCTUnwrap(HistorySessionAdoptionRequest(
            toolName: "Codex",
            sessionId: "019daf30-9809-7893-afc9-9b9a5b1fbe23",
            directory: "/tmp/Aethyme",
            tabID: tabID,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: .active,
            reason: .stateChange
        ))

        XCTAssertTrue(TerminalControlService.shared.adoptHistorySession(request))
        XCTAssertEqual(session.lastAIProvider, "codex")
        XCTAssertEqual(session.lastAISessionId, "019daf30-9809-7893-afc9-9b9a5b1fbe23")
        XCTAssertEqual(session.lastAISessionIdentitySource, .observed)
        XCTAssertEqual(session.lastDetectedAppName, "Codex")
        XCTAssertEqual(session.activeAppName, "Codex")
        XCTAssertTrue(session.isAIRunning)
        XCTAssertEqual(session.lastAgentLaunchCommand, "codex resume 019daf30-9809-7893-afc9-9b9a5b1fbe23")
    }

    func testAdoptHistorySessionRefusesDifferentProviderTab() throws {
        let tabID = overlayModel.selectedTabID
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.currentDirectory = "/tmp/Aethyme"
        session.restoreAIMetadata(
            provider: "claude",
            sessionId: "claude-existing",
            sessionIdSource: .explicit
        )

        let request = try XCTUnwrap(HistorySessionAdoptionRequest(
            toolName: "Codex",
            sessionId: "019daf30-9809-7893-afc9-9b9a5b1fbe23",
            directory: "/tmp/Aethyme",
            tabID: tabID,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: .active,
            reason: .stateChange
        ))

        XCTAssertFalse(TerminalControlService.shared.adoptHistorySession(request))
        XCTAssertEqual(session.lastAIProvider, "claude")
        XCTAssertEqual(session.lastAISessionId, "claude-existing")
        XCTAssertEqual(session.lastAISessionIdentitySource, .explicit)
    }

    func testAdoptHistorySessionRefusesDifferentLiveProviderTab() throws {
        let tabID = overlayModel.selectedTabID
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.currentDirectory = "/tmp/Aethyme"
        session.overrideLiveAgentNameForTesting("Claude")

        let request = try XCTUnwrap(HistorySessionAdoptionRequest(
            toolName: "Codex",
            sessionId: "019daf30-9809-7893-afc9-9b9a5b1fbe23",
            directory: "/tmp/Aethyme",
            tabID: tabID,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: .active,
            reason: .stateChange
        ))

        XCTAssertFalse(TerminalControlService.shared.adoptHistorySession(request))
        XCTAssertEqual(session.aiDisplayAppName, "Claude")
        XCTAssertNil(session.lastAIProvider)
        XCTAssertNil(session.lastAISessionId)
    }

    func testAdoptHistorySessionRequiresDirectoryWhenReplacingExplicitSession() throws {
        let tabID = overlayModel.selectedTabID
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.restoreAIMetadata(
            provider: "codex",
            sessionId: "019d86d9-2396-72d0-85af-71dce6106541",
            sessionIdSource: .explicit
        )

        let request = try XCTUnwrap(HistorySessionAdoptionRequest(
            toolName: "Codex",
            sessionId: "019daf30-9809-7893-afc9-9b9a5b1fbe23",
            directory: nil,
            tabID: tabID,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: .active,
            reason: .stateChange
        ))

        XCTAssertFalse(TerminalControlService.shared.adoptHistorySession(request))
        XCTAssertEqual(session.lastAISessionId, "019d86d9-2396-72d0-85af-71dce6106541")
        XCTAssertEqual(session.lastAISessionIdentitySource, .explicit)
    }

    func testAdoptHistorySessionUsesExplicitTabIDWithoutDirectoryForEmptyIdentity() throws {
        let tabID = overlayModel.selectedTabID
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.currentDirectory = "/tmp/Mockup"

        let request = try XCTUnwrap(HistorySessionAdoptionRequest(
            toolName: "Codex",
            sessionId: "019eaaab-1111-7222-8333-444455556666",
            directory: nil,
            tabID: tabID,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: nil,
            reason: .historyEntry
        ))

        XCTAssertTrue(TerminalControlService.shared.adoptHistorySession(request))
        XCTAssertEqual(session.lastAIProvider, "codex")
        XCTAssertEqual(session.lastAISessionId, "019eaaab-1111-7222-8333-444455556666")
        XCTAssertEqual(session.lastAISessionIdentitySource, .observed)
        XCTAssertEqual(session.lastAgentLaunchCommand, "codex resume 019eaaab-1111-7222-8333-444455556666")
    }

    func testUnifiedEventWithExplicitTabIDAdoptsResumeIdentity() throws {
        let tabID = overlayModel.selectedTabID
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.currentDirectory = "/tmp/Mockup"
        appModel.historySessionAdopter = { request in
            TerminalControlService.shared.adoptHistorySession(request)
        }

        let event = AIEvent(
            source: .codex,
            type: "finished",
            tool: "Codex",
            message: "Codex finished",
            ts: DateFormatters.nowISO8601(),
            tabID: tabID,
            sessionID: "019eaaac-1111-7222-8333-444455556666",
            producer: "test",
            reliability: .authoritative
        )

        XCTAssertTrue(appModel.adoptUnifiedEventSessionIdentityIfNeeded(event))
        XCTAssertEqual(session.lastAIProvider, "codex")
        XCTAssertEqual(session.lastAISessionId, "019eaaac-1111-7222-8333-444455556666")
        XCTAssertEqual(session.lastAISessionIdentitySource, .observed)
        XCTAssertEqual(session.lastAgentLaunchCommand, "codex resume 019eaaac-1111-7222-8333-444455556666")
    }

    func testInactiveHistoryDoesNotReplaceNewerObservedSession() throws {
        let tabID = overlayModel.selectedTabID
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.currentDirectory = "/tmp/Aethyme"

        let newActiveRequest = try XCTUnwrap(HistorySessionAdoptionRequest(
            toolName: "Codex",
            sessionId: "019daf30-9809-7893-afc9-9b9a5b1fbe23",
            directory: "/tmp/Aethyme",
            tabID: tabID,
            observedAt: Date(timeIntervalSince1970: 1_700_000_100),
            state: .active,
            reason: .stateChange
        ))
        XCTAssertTrue(TerminalControlService.shared.adoptHistorySession(newActiveRequest))

        for staleState in [HistorySessionState.idle, .closed] {
            let oldInactiveRequest = try XCTUnwrap(HistorySessionAdoptionRequest(
                toolName: "Codex",
                sessionId: "019d86d9-2396-72d0-85af-71dce6106541",
                directory: "/tmp/Aethyme",
                tabID: tabID,
                observedAt: Date(timeIntervalSince1970: 1_700_000_000),
                state: staleState,
                reason: .stateChange
            ))

            XCTAssertFalse(TerminalControlService.shared.adoptHistorySession(oldInactiveRequest))
            XCTAssertEqual(session.lastAISessionId, "019daf30-9809-7893-afc9-9b9a5b1fbe23")
            XCTAssertEqual(session.lastAISessionIdentitySource, .observed)
            XCTAssertEqual(session.activeAppName, "Codex")
            XCTAssertTrue(session.isAIRunning)
        }
    }

    func testOlderHistoryEntryDoesNotReplaceNewerObservedSession() throws {
        let tabID = overlayModel.selectedTabID
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.currentDirectory = "/tmp/Aethyme"

        let newActiveRequest = try XCTUnwrap(HistorySessionAdoptionRequest(
            toolName: "Codex",
            sessionId: "019daf30-9809-7893-afc9-9b9a5b1fbe23",
            directory: "/tmp/Aethyme",
            tabID: tabID,
            observedAt: Date(timeIntervalSince1970: 1_700_000_100),
            state: .active,
            reason: .stateChange
        ))
        let olderHistoryEntryRequest = try XCTUnwrap(HistorySessionAdoptionRequest(
            toolName: "Codex",
            sessionId: "019d86d9-2396-72d0-85af-71dce6106541",
            directory: "/tmp/Aethyme",
            tabID: tabID,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: nil,
            reason: .historyEntry
        ))

        XCTAssertTrue(TerminalControlService.shared.adoptHistorySession(newActiveRequest))
        XCTAssertFalse(TerminalControlService.shared.adoptHistorySession(olderHistoryEntryRequest))
        XCTAssertEqual(session.lastAISessionId, "019daf30-9809-7893-afc9-9b9a5b1fbe23")
        XCTAssertEqual(session.lastAISessionIdentitySource, .observed)
        XCTAssertEqual(session.activeAppName, "Codex")
        XCTAssertTrue(session.isAIRunning)
    }

    func testIdleHistoryClearsRunningStateForCurrentObservedSession() throws {
        let tabID = overlayModel.selectedTabID
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.currentDirectory = "/tmp/Aethyme"

        let activeRequest = try XCTUnwrap(HistorySessionAdoptionRequest(
            toolName: "Codex",
            sessionId: "019daf30-9809-7893-afc9-9b9a5b1fbe23",
            directory: "/tmp/Aethyme",
            tabID: tabID,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: .active,
            reason: .stateChange
        ))
        let idleRequest = try XCTUnwrap(HistorySessionAdoptionRequest(
            toolName: "Codex",
            sessionId: "019daf30-9809-7893-afc9-9b9a5b1fbe23",
            directory: "/tmp/Aethyme",
            tabID: tabID,
            observedAt: Date(timeIntervalSince1970: 1_700_000_100),
            state: .idle,
            reason: .stateChange
        ))

        XCTAssertTrue(TerminalControlService.shared.adoptHistorySession(activeRequest))
        XCTAssertTrue(session.isAIRunning)

        XCTAssertTrue(TerminalControlService.shared.adoptHistorySession(idleRequest))
        XCTAssertEqual(session.lastAISessionId, "019daf30-9809-7893-afc9-9b9a5b1fbe23")
        XCTAssertEqual(session.lastAISessionIdentitySource, .observed)
        XCTAssertNil(session.activeAppName)
        XCTAssertFalse(session.isAIRunning)
    }

    func testClosedHistoryClearsRunningStateForCurrentObservedSession() throws {
        let tabID = overlayModel.selectedTabID
        let session = try XCTUnwrap(overlayModel.tabs.first?.session)
        session.currentDirectory = "/tmp/Aethyme"

        let activeRequest = try XCTUnwrap(HistorySessionAdoptionRequest(
            toolName: "Codex",
            sessionId: "019daf30-9809-7893-afc9-9b9a5b1fbe23",
            directory: "/tmp/Aethyme",
            tabID: tabID,
            observedAt: Date(timeIntervalSince1970: 1_700_000_000),
            state: .active,
            reason: .stateChange
        ))
        let closedRequest = try XCTUnwrap(HistorySessionAdoptionRequest(
            toolName: "Codex",
            sessionId: "019daf30-9809-7893-afc9-9b9a5b1fbe23",
            directory: "/tmp/Aethyme",
            tabID: tabID,
            observedAt: Date(timeIntervalSince1970: 1_700_000_100),
            state: .closed,
            reason: .stateChange
        ))

        XCTAssertTrue(TerminalControlService.shared.adoptHistorySession(activeRequest))
        XCTAssertTrue(session.isAIRunning)

        XCTAssertTrue(TerminalControlService.shared.adoptHistorySession(closedRequest))
        XCTAssertEqual(session.lastAISessionId, "019daf30-9809-7893-afc9-9b9a5b1fbe23")
        XCTAssertEqual(session.lastAISessionIdentitySource, .observed)
        XCTAssertNil(session.activeAppName)
        XCTAssertFalse(session.isAIRunning)
    }
}
