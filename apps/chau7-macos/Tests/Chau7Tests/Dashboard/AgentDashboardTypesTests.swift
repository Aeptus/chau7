import XCTest
@testable import Chau7
import Chau7Core

final class AgentDashboardTypesTests: XCTestCase {
    func testCommandStatusApprovalRequiredMapsToAwaitingApproval() {
        XCTAssertEqual(
            DashboardAgentState(commandStatus: .approvalRequired, isAtPrompt: false),
            .awaitingApproval
        )
    }

    func testCommandStatusWaitingForInputMapsToWaitingInput() {
        XCTAssertEqual(
            DashboardAgentState(commandStatus: .waitingForInput, isAtPrompt: true),
            .waitingInput
        )
    }

    func testCommandStatusIdleAtPromptMapsToReady() {
        XCTAssertEqual(
            DashboardAgentState(commandStatus: .idle, isAtPrompt: true),
            .ready
        )
    }

    func testCommandStatusDoneAwayFromPromptMapsToBusy() {
        XCTAssertEqual(
            DashboardAgentState(commandStatus: .done, isAtPrompt: false),
            .busy
        )
    }

    func testCommandStatusExitedMapsToStopped() {
        XCTAssertEqual(
            DashboardAgentState(commandStatus: .exited, isAtPrompt: false),
            .stopped
        )
    }

    func testSnapshotIndexKeepsNewestSnapshotForDuplicateTabIDs() {
        let tabID = UUID()
        let older = makeSnapshot(id: "older", tabID: tabID, createdAt: Date(timeIntervalSince1970: 1))
        let newer = makeSnapshot(id: "newer", tabID: tabID, createdAt: Date(timeIntervalSince1970: 2))

        let indexed = DashboardSessionSnapshot.indexByTabID([older, newer])

        XCTAssertEqual(indexed.count, 1)
        XCTAssertEqual(indexed[tabID]?.id, "newer")
    }

    func testLiveTabIsAgentTabWhenAnyAgentSignalIsPresent() {
        XCTAssertFalse(makeLiveTab(aiProvider: nil, aiSessionId: nil).isAgentTab(activeRun: nil))
        XCTAssertTrue(makeLiveTab(aiProvider: "claude", aiSessionId: nil).isAgentTab(activeRun: nil))
        XCTAssertTrue(makeLiveTab(aiProvider: nil, aiSessionId: "abc").isAgentTab(activeRun: nil))
    }

    func testFallbackSnapshotMapsLiveTabState() {
        let liveTab = makeLiveTab(aiProvider: "claude", status: .approvalRequired, isAtPrompt: false)

        let snapshot = DashboardSessionSnapshot.fallback(id: "tab:x", liveTab: liveTab, activeRun: nil)

        XCTAssertEqual(snapshot.id, "tab:x")
        XCTAssertEqual(snapshot.tabID, liveTab.tabID)
        XCTAssertEqual(snapshot.backendName, "claude")
        XCTAssertEqual(snapshot.directory, "/repo")
        XCTAssertEqual(snapshot.state, .awaitingApproval)
        XCTAssertTrue(snapshot.requiresApproval)
    }

    func testMergingLiveTabTakesDirectoryAndApprovalFromLiveTab() {
        let liveTab = makeLiveTab(aiProvider: "codex", status: .approvalRequired)
        let runtime = makeSnapshot(id: "runtime", tabID: liveTab.tabID, createdAt: Date())

        let merged = runtime.mergingLiveTab(liveTab, activeRun: nil)

        XCTAssertEqual(merged.id, "runtime")
        XCTAssertEqual(merged.directory, "/repo")
        XCTAssertTrue(merged.requiresApproval)
    }

    /// Regression: the dashboard refresh runs on a background queue and used to
    /// read `TerminalSessionModel.effectiveStatus` there, which trapped in
    /// `MainActor.assumeIsolated` for tabs carrying an AI provider + session id.
    /// Capture must happen on main; building snapshots off-main must be safe.
    @MainActor
    func testLiveTabCapturedOnMainBuildsSnapshotsOffMain() async {
        let session = TerminalSessionModel(appModel: AppModel())
        session.applyAgentIdentity(AgentIdentityRecord(
            provider: "claude",
            sessionId: UUID().uuidString.lowercased(),
            source: .explicit
        ))
        let liveTab = DashboardLiveTabState(tabID: UUID(), session: session)
        XCTAssertNotNil(liveTab.aiProvider)
        XCTAssertNotNil(liveTab.aiSessionId)

        let runtime = makeSnapshot(id: "runtime", tabID: liveTab.tabID, createdAt: Date())
        let built = expectation(description: "snapshots built on background queue")
        DispatchQueue(label: "test.agent-dashboard.refresh").async {
            XCTAssertFalse(Thread.isMainThread)
            _ = runtime.mergingLiveTab(liveTab, activeRun: nil)
            _ = DashboardSessionSnapshot.fallback(id: "tab:x", liveTab: liveTab, activeRun: nil)
            built.fulfill()
        }
        await fulfillment(of: [built], timeout: 5)
    }

    private func makeLiveTab(
        aiProvider: String?,
        aiSessionId: String? = nil,
        status: CommandStatus = .idle,
        isAtPrompt: Bool = true
    ) -> DashboardLiveTabState {
        DashboardLiveTabState(
            tabID: UUID(),
            tabIdentifier: UUID().uuidString,
            aiProvider: aiProvider,
            aiSessionId: aiSessionId,
            activeAppName: nil,
            directory: "/repo",
            status: status,
            isAtPrompt: isAtPrompt
        )
    }

    private func makeSnapshot(id: String, tabID: UUID, createdAt: Date) -> DashboardSessionSnapshot {
        DashboardSessionSnapshot(
            id: id,
            tabID: tabID,
            backendName: "Claude",
            directory: "/tmp",
            purpose: nil,
            parentSessionID: nil,
            delegationDepth: 0,
            state: .ready,
            turnCount: 0,
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            requiresApproval: false,
            latestResult: nil,
            createdAt: createdAt,
            costUSD: 0,
            journal: EventJournal()
        )
    }
}
