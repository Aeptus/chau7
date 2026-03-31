import XCTest
@testable import Chau7Core

final class HistorySessionLifecycleTests: XCTestCase {
    func testClosedSessionCanReactivate() {
        let decision = HistorySessionLifecycle.evaluate(
            previousState: .closed,
            nextState: .active,
            lastActivityKind: .prompt
        )

        XCTAssertTrue(decision.shouldPersistState)
        XCTAssertTrue(decision.isReactivation)
        XCTAssertFalse(decision.emitsFinishedEvent)
    }

    func testActiveToIdleFromPromptDoesNotEmitFinishedEvent() {
        let decision = HistorySessionLifecycle.evaluate(
            previousState: .active,
            nextState: .idle,
            lastActivityKind: .prompt
        )

        XCTAssertTrue(decision.shouldPersistState)
        XCTAssertFalse(decision.isReactivation)
        XCTAssertFalse(decision.emitsFinishedEvent)
    }

    func testActiveToIdleFromResponseEmitsFinishedEvent() {
        let decision = HistorySessionLifecycle.evaluate(
            previousState: .active,
            nextState: .idle,
            lastActivityKind: .response
        )

        XCTAssertTrue(decision.shouldPersistState)
        XCTAssertFalse(decision.isReactivation)
        XCTAssertTrue(decision.emitsFinishedEvent)
    }

    func testNewlyObservedClosedPromptSessionDoesNotEmitFinishedEvent() {
        let decision = HistorySessionLifecycle.evaluate(
            previousState: nil,
            nextState: .closed,
            lastActivityKind: .prompt
        )

        XCTAssertTrue(decision.shouldPersistState)
        XCTAssertFalse(decision.isReactivation)
        XCTAssertFalse(decision.emitsFinishedEvent)
    }

    func testNewlyObservedClosedResponseSessionEmitsFinishedEvent() {
        let decision = HistorySessionLifecycle.evaluate(
            previousState: nil,
            nextState: .closed,
            lastActivityKind: .response
        )

        XCTAssertTrue(decision.shouldPersistState)
        XCTAssertFalse(decision.isReactivation)
        XCTAssertTrue(decision.emitsFinishedEvent)
    }
}
