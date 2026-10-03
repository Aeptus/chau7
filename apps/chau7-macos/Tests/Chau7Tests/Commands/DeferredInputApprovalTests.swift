import XCTest
@testable import Chau7Core

final class DeferredInputApprovalTests: XCTestCase {
    func testPendingLocalApprovalBlocksExecEvenAtPromptOrDuringShellLoading() {
        for loading in [false, true] {
            let readiness = TabExecutionReadiness.evaluate(snapshot: .init(shellLoading: loading, isAtPrompt: true, hasView: true, status: "command_approval_pending"))
            XCTAssertFalse(readiness.canAcceptExec)
            XCTAssertFalse(readiness.isReady)
            XCTAssertEqual(readiness.reason, .commandApprovalPending)
        }
    }

    private func context(
        terminalID: UInt64 = 1,
        shellPID: Int32 = 2,
        directory: String = "/repo",
        prefix: String = "rm",
        date: Date = Date(timeIntervalSince1970: 0)
    ) -> DeferredInputApproval.Context {
        .init(terminalID: terminalID, shellPID: shellPID, directory: directory, inputPrefix: prefix, lastInputAt: date)
    }

    func testApprovalIsExplicitAndConsumedOnce() throws {
        var state = DeferredInputApproval()
        let request = try XCTUnwrap(state.begin(context: context()))
        XCTAssertNil(state.begin(context: context()))
        XCTAssertTrue(state.resolve(token: request, current: context(), approved: true))
        XCTAssertFalse(state.resolve(token: request, current: context(), approved: true))
        XCTAssertNil(state.pendingToken)
    }

    func testCancellationAndMissingTerminalNeverResume() throws {
        var state = DeferredInputApproval()
        let request = try XCTUnwrap(state.begin(context: context()))
        XCTAssertFalse(state.resolve(token: request, current: context(), approved: false))
        let next = try XCTUnwrap(state.begin(context: context()))
        XCTAssertFalse(state.resolve(token: next, current: nil, approved: true))
    }

    func testChangedPanePTYDirectoryAndInputInvalidateConsent() throws {
        for changed in [
            context(terminalID: 3),
            context(shellPID: 4),
            context(directory: "/other"),
            context(prefix: "different"),
            context(date: Date(timeIntervalSince1970: 1))
        ] {
            var state = DeferredInputApproval()
            let request = try XCTUnwrap(state.begin(context: context()))
            XCTAssertFalse(state.resolve(token: request, current: changed, approved: true))
            XCTAssertNil(state.pendingToken)
        }
    }

    func testOldDecisionCannotConsumeNewRequest() throws {
        var state = DeferredInputApproval()
        let old = try XCTUnwrap(state.begin(context: context()))
        XCTAssertFalse(state.resolve(token: old, current: context(), approved: false))
        let next = try XCTUnwrap(state.begin(context: context()))
        XCTAssertFalse(state.resolve(token: old, current: context(), approved: true))
        XCTAssertEqual(state.pendingToken, next)
        XCTAssertTrue(state.resolve(token: next, current: context(), approved: true))
    }
}
