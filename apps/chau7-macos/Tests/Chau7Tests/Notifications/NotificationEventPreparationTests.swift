import XCTest
@testable import Chau7Core

final class NotificationEventPreparationTests: XCTestCase {
    func testPrepareDropsDisabledTriggerWithoutResolvingTab() {
        let event = AIEvent(
            source: .claudeCode,
            type: "finished",
            tool: "Claude",
            message: "done",
            ts: "2026-04-01T00:00:00Z"
        )
        var triggerState = NotificationTriggerState()
        let trigger = NotificationTriggerCatalog.trigger(for: event)
        XCTAssertNotNil(trigger)
        triggerState.setEnabled(false, for: trigger!)

        var resolverCallCount = 0
        let decision = NotificationEventPreparation.prepare(event, triggerState: triggerState) { _ in
            resolverCallCount += 1
            return UUID()
        }

        XCTAssertEqual(resolverCallCount, 0)
        XCTAssertEqual(decision, .drop(reason: "Trigger claude_code.finished disabled"))
    }

    func testPrepareResolvesTabForEnabledTrigger() {
        let expectedTabID = UUID()
        let event = AIEvent(
            source: .claudeCode,
            type: "finished",
            tool: "Claude",
            message: "done",
            ts: "2026-04-01T00:00:00Z",
            directory: "/tmp/chau7",
            sessionID: "claude-session-1"
        )

        let decision = NotificationEventPreparation.prepare(event, triggerState: NotificationTriggerState()) { target in
            XCTAssertEqual(
                target,
                TabTarget(
                    tool: "Claude",
                    directory: "/tmp/chau7",
                    tabID: nil,
                    sessionID: "claude-session-1"
                )
            )
            return expectedTabID
        }

        if case .proceed(let resolvedEvent) = decision {
            XCTAssertEqual(resolvedEvent.tabID, expectedTabID)
        } else {
            XCTFail("Expected enabled event to proceed")
        }
    }

    func testPrepareKeepsExplicitTabIDWithoutResolvingAgain() {
        let explicitTabID = UUID()
        let event = AIEvent(
            source: .claudeCode,
            type: "finished",
            tool: "Claude",
            message: "done",
            ts: "2026-04-01T00:00:00Z",
            tabID: explicitTabID
        )

        var resolverCallCount = 0
        let decision = NotificationEventPreparation.prepare(event, triggerState: NotificationTriggerState()) { _ in
            resolverCallCount += 1
            return UUID()
        }

        XCTAssertEqual(resolverCallCount, 0)
        if case .proceed(let preparedEvent) = decision {
            XCTAssertEqual(preparedEvent.tabID, explicitTabID)
        } else {
            XCTFail("Expected explicit-tab event to proceed")
        }
    }
}
