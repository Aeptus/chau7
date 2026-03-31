import XCTest
@testable import Chau7Core

final class HistorySessionLifecycleTests: XCTestCase {
    func testClosedSessionCanReactivate() {
        let decision = HistorySessionLifecycle.evaluate(
            previousState: .closed,
            nextState: .active
        )

        XCTAssertTrue(decision.shouldPersistState)
        XCTAssertTrue(decision.isReactivation)
        XCTAssertFalse(decision.emitsFinishedEvent)
    }

    func testActiveToIdleEmitsFinishedEvent() {
        let decision = HistorySessionLifecycle.evaluate(
            previousState: .active,
            nextState: .idle
        )

        XCTAssertTrue(decision.shouldPersistState)
        XCTAssertFalse(decision.isReactivation)
        XCTAssertTrue(decision.emitsFinishedEvent)
    }

    func testNewlyObservedClosedSessionEmitsFinishedEvent() {
        let decision = HistorySessionLifecycle.evaluate(
            previousState: nil,
            nextState: .closed
        )

        XCTAssertTrue(decision.shouldPersistState)
        XCTAssertFalse(decision.isReactivation)
        XCTAssertTrue(decision.emitsFinishedEvent)
    }
}
