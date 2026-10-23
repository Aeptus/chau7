import XCTest
@testable import Chau7Core

final class ExitClassifierTests: XCTestCase {

    // MARK: - Default Path

    func testSuccess_defaultPath() {
        let reason = ExitClassifier.classify(
            sessionState: .ready,
            lastDenied: false,
            terminalOutput: nil,
            wasInterrupted: false
        )
        XCTAssertEqual(reason, .success)
    }

    func testSuccess_withNormalOutput() {
        let reason = ExitClassifier.classify(
            sessionState: .ready,
            lastDenied: false,
            terminalOutput: "Task completed successfully.",
            wasInterrupted: false
        )
        XCTAssertEqual(reason, .success)
    }

    // MARK: - Interrupted

    func testInterrupted() {
        let reason = ExitClassifier.classify(
            sessionState: .busy,
            lastDenied: false,
            terminalOutput: nil,
            wasInterrupted: true
        )
        XCTAssertEqual(reason, .interrupted)
    }

    // MARK: - Approval Denied

    func testApprovalDenied() {
        let reason = ExitClassifier.classify(
            sessionState: .ready,
            lastDenied: true,
            terminalOutput: nil,
            wasInterrupted: false
        )
        XCTAssertEqual(reason, .approvalDenied)
    }

    // MARK: - Error (failed state)

    func testError_fromFailedState() {
        let reason = ExitClassifier.classify(
            sessionState: .failed,
            lastDenied: false,
            terminalOutput: nil,
            wasInterrupted: false
        )
        XCTAssertEqual(reason, .error)
    }

    // MARK: - Context Limit

    func testContextLimit_contextWindow() {
        let reason = ExitClassifier.classify(
            sessionState: .ready,
            lastDenied: false,
            terminalOutput: "Warning: context window exceeded, please start a new conversation.",
            wasInterrupted: false
        )
        XCTAssertEqual(reason, .contextLimit)
    }

    func testContextLimit_tokenLimit() {
        let reason = ExitClassifier.classify(
            sessionState: .ready,
            lastDenied: false,
            terminalOutput: "Reached token limit for this session",
            wasInterrupted: false
        )
        XCTAssertEqual(reason, .contextLimit)
    }

    // MARK: - Error Patterns in Output

    func testError_fromOutputPattern() {
        let reason = ExitClassifier.classify(
            sessionState: .ready,
            lastDenied: false,
            terminalOutput: "fatal: unable to read tree object",
            wasInterrupted: false
        )
        XCTAssertEqual(reason, .error)
    }

    // MARK: - Priority Order

    func testPriority_interruptedBeatsAll() {
        // Even with denied + failed + error output, interrupted wins
        let reason = ExitClassifier.classify(
            sessionState: .failed,
            lastDenied: true,
            terminalOutput: "fatal: crash\ncontext window exceeded",
            wasInterrupted: true
        )
        XCTAssertEqual(reason, .interrupted)
    }

    func testPriority_deniedBeatsError() {
        let reason = ExitClassifier.classify(
            sessionState: .failed,
            lastDenied: true,
            terminalOutput: "error: something went wrong",
            wasInterrupted: false
        )
        XCTAssertEqual(reason, .approvalDenied)
    }

    func testPriority_failedStateBeatsContextLimit() {
        let reason = ExitClassifier.classify(
            sessionState: .failed,
            lastDenied: false,
            terminalOutput: "context window exceeded",
            wasInterrupted: false
        )
        XCTAssertEqual(reason, .error)
    }
}
