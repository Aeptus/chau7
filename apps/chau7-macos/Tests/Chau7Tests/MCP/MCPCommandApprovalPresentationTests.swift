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

    func testRemoteApprovalForwardsTheCapturedTargetTab() async {
        let service = TerminalControlService()
        let targetTabID = UUID()
        let forwarded = expectation(description: "approval forwarded with target")
        let forwarder = RecordingApprovalForwarder { requestID, _, tabID in
            XCTAssertEqual(tabID, targetTabID)
            forwarded.fulfill()
            service.resolveApproval(requestID: requestID, approved: false)
        }
        service.approvalForwarder = forwarder
        service.commandApprovalPresenter = { _, _ in true }
        let permissions = ResolvedPermissions(mode: .allowlist, allowedCommands: [], blockedCommands: [], matchedProfile: nil)
        let worker = Task.detached {
            service.requestCommandApproval(
                command: "echo test", flaggedCommand: "echo", reason: "test",
                permissions: permissions, targetTabID: targetTabID
            )
        }
        await fulfillment(of: [forwarded], timeout: 2)
        let decision = await worker.value
        XCTAssertEqual(decision, .denied)
    }

    func testFirstApprovalPayloadContainsTargetContextAndPreservesSeverity() {
        let context = PendingRemoteApprovalContext(
            requestID: "request-b", tabID: 2, tabTitle: "Background build",
            toolName: "Codex", projectName: "Chau7", branchName: "fix/build",
            currentDirectory: "/work/build", recentCommand: "cargo build",
            contextNote: "Explicit background target", sessionID: "session-b",
            command: "rm -rf build", flaggedCommand: "rm", requestedAt: Date()
        )
        let original = ApprovalRequestPayload(
            requestID: "request-b", command: "rm -rf build", flaggedCommand: "rm",
            timestamp: "2026-10-15T08:00:00Z", tabTitle: nil, toolName: nil,
            projectName: nil, branchName: nil, currentDirectory: nil,
            recentCommand: nil, contextNote: nil, sessionID: nil
        ).withSeverity(.destructive)
        let enriched = context.enriching(original).withComposedPushText()
        XCTAssertEqual(enriched.tabTitle, "Background build")
        XCTAssertEqual(enriched.currentDirectory, "/work/build")
        XCTAssertEqual(enriched.branchName, "fix/build")
        XCTAssertEqual(enriched.sessionID, "session-b")
        XCTAssertEqual(enriched.command, original.command)
        XCTAssertEqual(enriched.timestamp, original.timestamp)
        XCTAssertEqual(enriched.severity, original.severity)
        XCTAssertNotNil(enriched.pushSubtitle)
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

@MainActor
private final class RecordingApprovalForwarder: MCPApprovalForwarding {
    private let handler: (String, ApprovalRequestPayload, UUID?) -> Void

    init(handler: @escaping (String, ApprovalRequestPayload, UUID?) -> Void) {
        self.handler = handler
    }

    func sendApprovalRequest(requestID: String, payload: ApprovalRequestPayload, targetTabID: UUID?) {
        handler(requestID, payload, targetTabID)
    }
}
