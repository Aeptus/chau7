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
