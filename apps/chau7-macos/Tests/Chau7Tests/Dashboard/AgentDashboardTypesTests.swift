import XCTest
@testable import Chau7

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
}
