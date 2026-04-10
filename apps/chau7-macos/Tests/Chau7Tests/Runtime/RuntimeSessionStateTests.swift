import XCTest
@testable import Chau7Core

final class RuntimeSessionStateTests: XCTestCase {

    // MARK: - Initial State

    func testInitialState() {
        let sm = RuntimeSessionStateMachine()
        XCTAssertEqual(sm.state, .starting)
        XCTAssertFalse(sm.isTerminal)
        XCTAssertFalse(sm.canAcceptTurn)
    }

    // MARK: - Starting Transitions

    func testStartingToReady() {
        var sm = RuntimeSessionStateMachine()
        XCTAssertTrue(sm.handle(.backendReady))
        XCTAssertEqual(sm.state, .ready)
        XCTAssertTrue(sm.canAcceptTurn)
    }

    func testStartingToFailed_launchTimeout() {
        var sm = RuntimeSessionStateMachine()
        XCTAssertTrue(sm.handle(.launchTimeout))
        XCTAssertEqual(sm.state, .failed)
        XCTAssertTrue(sm.isTerminal)
    }

    func testStartingToFailed_processCrashed() {
        var sm = RuntimeSessionStateMachine()
        XCTAssertTrue(sm.handle(.processCrashed("SIGSEGV")))
        XCTAssertEqual(sm.state, .failed)
    }

    func testStartingToStopped_tabClosed() {
        var sm = RuntimeSessionStateMachine()
        XCTAssertTrue(sm.handle(.tabClosed))
        XCTAssertEqual(sm.state, .stopped)
        XCTAssertTrue(sm.isTerminal)
    }

    func testStartingRejectsInvalidTriggers() {
        var sm = RuntimeSessionStateMachine()
        XCTAssertFalse(sm.handle(.turnSubmitted))
        XCTAssertEqual(sm.state, .starting)
        XCTAssertFalse(sm.handle(.turnCompleted))
        XCTAssertFalse(sm.handle(.approvalNeeded))
        XCTAssertFalse(sm.handle(.inputProvided))
    }

    // MARK: - Ready Transitions

    func testReadyToBusy() {
        var sm = makeReady()
        XCTAssertTrue(sm.handle(.turnSubmitted))
        XCTAssertEqual(sm.state, .busy)
        XCTAssertFalse(sm.canAcceptTurn)
    }

    func testReadyToStopped() {
        var sm = makeReady()
        XCTAssertTrue(sm.handle(.tabClosed))
        XCTAssertEqual(sm.state, .stopped)
    }

    func testReadyRejectsInvalidTriggers() {
        var sm = makeReady()
        XCTAssertFalse(sm.handle(.turnCompleted))
        XCTAssertEqual(sm.state, .ready)
        XCTAssertFalse(sm.handle(.backendReady))
    }

    // MARK: - Busy Transitions

    func testBusyToReady() {
        var sm = makeBusy()
        XCTAssertTrue(sm.handle(.turnCompleted))
        XCTAssertEqual(sm.state, .ready)
    }

    func testBusyToAwaitingApproval() {
        var sm = makeBusy()
        XCTAssertTrue(sm.handle(.approvalNeeded))
        XCTAssertEqual(sm.state, .awaitingApproval)
    }

    func testBusyToWaitingInput() {
        var sm = makeBusy()
        XCTAssertTrue(sm.handle(.inputRequested))
        XCTAssertEqual(sm.state, .waitingInput)
    }

    func testBusyToInterrupted() {
        var sm = makeBusy()
        XCTAssertTrue(sm.handle(.interrupted))
        XCTAssertEqual(sm.state, .interrupted)
    }

    func testBusyToFailed() {
        var sm = makeBusy()
        XCTAssertTrue(sm.handle(.processCrashed("exit 1")))
        XCTAssertEqual(sm.state, .failed)
    }

    func testBusyToStopped() {
        var sm = makeBusy()
        XCTAssertTrue(sm.handle(.tabClosed))
        XCTAssertEqual(sm.state, .stopped)
    }

    // MARK: - AwaitingApproval Transitions

    func testApprovalResolvedReturnsToBusy() {
        var sm = makeBusy()
        sm.handle(.approvalNeeded)
        XCTAssertTrue(sm.handle(.approvalResolved))
        XCTAssertEqual(sm.state, .busy)
    }

    func testAwaitingApprovalToInterrupted() {
        var sm = makeBusy()
        sm.handle(.approvalNeeded)
        XCTAssertTrue(sm.handle(.interrupted))
        XCTAssertEqual(sm.state, .interrupted)
    }

    func testAwaitingApprovalToStopped() {
        var sm = makeBusy()
        sm.handle(.approvalNeeded)
        XCTAssertTrue(sm.handle(.tabClosed))
        XCTAssertEqual(sm.state, .stopped)
    }

    func testAwaitingApprovalToFailed() {
        var sm = makeBusy()
        sm.handle(.approvalNeeded)
        XCTAssertTrue(sm.handle(.processCrashed("approval_timeout_stuck")))
        XCTAssertEqual(sm.state, .failed)
    }

    // MARK: - WaitingInput Transitions

    func testInputProvidedReturnsToBusy() {
        var sm = makeBusy()
        sm.handle(.inputRequested)
        XCTAssertTrue(sm.handle(.inputProvided))
        XCTAssertEqual(sm.state, .busy)
    }

    func testWaitingInputToStopped() {
        var sm = makeBusy()
        sm.handle(.inputRequested)
        XCTAssertTrue(sm.handle(.tabClosed))
        XCTAssertEqual(sm.state, .stopped)
    }

    func testWaitingInputToFailed() {
        var sm = makeBusy()
        sm.handle(.inputRequested)
        XCTAssertTrue(sm.handle(.processCrashed("backend_crash")))
        XCTAssertEqual(sm.state, .failed)
    }

    // MARK: - Interrupted Transitions

    func testInterruptedToReady() {
        var sm = makeBusy()
        sm.handle(.interrupted)
        XCTAssertTrue(sm.handle(.backendReady))
        XCTAssertEqual(sm.state, .ready)
    }

    func testInterruptedToFailed() {
        var sm = makeBusy()
        sm.handle(.interrupted)
        XCTAssertTrue(sm.handle(.processCrashed("crash")))
        XCTAssertEqual(sm.state, .failed)
    }

    func testInterruptedToStopped() {
        var sm = makeBusy()
        sm.handle(.interrupted)
        XCTAssertTrue(sm.handle(.tabClosed))
        XCTAssertEqual(sm.state, .stopped)
    }

    // MARK: - Terminal States

    func testFailedRejectsAllTriggers() {
        var sm = RuntimeSessionStateMachine()
        sm.handle(.launchTimeout)
        XCTAssertFalse(sm.handle(.backendReady))
        XCTAssertFalse(sm.handle(.tabClosed))
        XCTAssertFalse(sm.handle(.turnSubmitted))
        XCTAssertEqual(sm.state, .failed)
    }

    func testStoppedRejectsAllTriggers() {
        var sm = RuntimeSessionStateMachine()
        sm.handle(.tabClosed)
        XCTAssertFalse(sm.handle(.backendReady))
        XCTAssertFalse(sm.handle(.turnSubmitted))
        XCTAssertFalse(sm.handle(.processCrashed("x")))
        XCTAssertEqual(sm.state, .stopped)
    }

    // MARK: - Full Lifecycle

    func testFullTurnCycle() {
        var sm = RuntimeSessionStateMachine()
        sm.handle(.backendReady) // starting → ready
        sm.handle(.turnSubmitted) // ready → busy
        sm.handle(.approvalNeeded) // busy → awaitingApproval
        sm.handle(.approvalResolved) // awaitingApproval → busy
        sm.handle(.turnCompleted) // busy → ready
        XCTAssertEqual(sm.state, .ready)
        XCTAssertTrue(sm.canAcceptTurn)
    }

    func testInterruptRecoveryCycle() {
        var sm = RuntimeSessionStateMachine()
        sm.handle(.backendReady)
        sm.handle(.turnSubmitted)
        sm.handle(.interrupted) // busy → interrupted
        sm.handle(.backendReady) // interrupted → ready
        sm.handle(.turnSubmitted) // ready → busy
        sm.handle(.turnCompleted) // busy → ready
        XCTAssertEqual(sm.state, .ready)
    }

    // MARK: - Helpers

    private func makeReady() -> RuntimeSessionStateMachine {
        var sm = RuntimeSessionStateMachine()
        sm.handle(.backendReady)
        return sm
    }

    private func makeBusy() -> RuntimeSessionStateMachine {
        var sm = makeReady()
        sm.handle(.turnSubmitted)
        return sm
    }
}
