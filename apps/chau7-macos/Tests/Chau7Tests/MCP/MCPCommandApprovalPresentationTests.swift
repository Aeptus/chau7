import AppKit
import XCTest
import Chau7Core
@testable import Chau7

@MainActor
final class MCPCommandApprovalPresentationTests: XCTestCase {
    func testFirstDecisionWinsAndLaterAllowCannotOverrideDenial() {
        var decisions: [MCPApprovalResult] = []
        let presentation = MCPCommandApprovalPresentation(alert: NSAlert()) { decisions.append($0) }
        presentation.resolve(.denied)
        presentation.resolve(.alwaysAllow)
        XCTAssertEqual(decisions, [.denied])
    }

    func testRemoteDecisionWinsOverLaterSheetCancellation() {
        var decisions: [MCPApprovalResult] = []
        let presentation = MCPCommandApprovalPresentation(alert: NSAlert()) { decisions.append($0) }
        presentation.resolve(.allowedOnce)
        presentation.resolve(.denied)
        XCTAssertEqual(decisions, [.allowedOnce])
    }

    func testMissingWindowFailsClosedWithoutEnteringModalLoop() {
        var decision: MCPApprovalResult?
        let presentation = MCPCommandApprovalPresentation(alert: NSAlert()) { decision = $0 }
        XCTAssertFalse(presentation.present(in: nil))
        XCTAssertEqual(decision, .denied)
    }

    func testApprovalWaitLeavesMainFreeAndRemoteDecisionCompletesWorker() async {
        let service = TerminalControlService()
        let presented = expectation(description: "approval presented on main")
        var requestID: String?
        service.commandApprovalPresenter = { id, _ in
            XCTAssertTrue(Thread.isMainThread)
            requestID = id
            presented.fulfill()
            return true
        }
        let permissions = ResolvedPermissions(mode: .allowlist, allowedCommands: [], blockedCommands: [], matchedProfile: nil)
        let worker = Task.detached {
            service.requestCommandApproval(command: "echo test", flaggedCommand: "echo", reason: "test", permissions: permissions)
        }
        await fulfillment(of: [presented], timeout: 2)
        XCTAssertNotNil(requestID)
        if let requestID { service.resolveApproval(requestID: requestID, approved: true) }
        let decision = await worker.value
        XCTAssertEqual(decision, .allowedOnce)
    }

    func testTimedOutApprovalRejectsLatePermissionAndRemovesPendingState() async {
        let service = TerminalControlService()
        service.commandApprovalTimeout = 0.05
        var lateResponse: ((MCPApprovalResult) -> Void)?
        service.commandApprovalPresenter = { _, reply in lateResponse = reply
            return true
        }
        let permissions = ResolvedPermissions(mode: .allowlist, allowedCommands: [], blockedCommands: [], matchedProfile: nil)
        let worker = Task.detached {
            service.requestCommandApproval(command: "echo test", flaggedCommand: "echo", reason: "test", permissions: permissions)
        }
        let decision = await worker.value
        XCTAssertEqual(decision, .denied)
        let drained = expectation(description: "timeout cleanup")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        lateResponse?(.alwaysAllow)
        XCTAssertTrue(service.pendingApprovalSummaries().isEmpty)
    }

    func testSharedSheetOwnerFailsClosedWithoutWindowAndIgnoresLateClose() {
        var decisions: [NSApplication.ModalResponse] = []
        let presentation = ConfirmationSheetPresentation(alert: NSAlert()) { decisions.append($0) }
        XCTAssertFalse(presentation.present(in: nil))
        presentation.resolve(.alertFirstButtonReturn)
        XCTAssertEqual(decisions, [.abort])
    }

}
