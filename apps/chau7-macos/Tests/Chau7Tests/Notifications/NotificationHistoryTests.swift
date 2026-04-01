import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7
import Chau7Core

@MainActor
final class NotificationHistoryTests: XCTestCase {
    func testHistoryTracksDeliveryLifecycle() {
        let history = NotificationHistory(maxEntries: 10)
        let event = AIEvent(
            source: .runtime,
            type: "finished",
            tool: "Claude",
            message: "done",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            producer: "runtime_session_manager",
            reliability: .authoritative
        )

        history.begin(event: event)
        history.markPrepared(event: event, resolutionMethod: "explicit_tab")
        history.markActionsExecuted(
            eventID: event.id,
            triggerId: "runtime.finished",
            actionsExecuted: ["showNotification", "styleTab"],
            didDispatchBanner: true,
            didStyleTab: true
        )
        history.markCompleted(eventID: event.id)

        let entry = try XCTUnwrap(history.recent(limit: 1).first)
        XCTAssertEqual(entry.id, event.id)
        XCTAssertEqual(entry.deliveryState, NotificationHistory.DeliveryState.completed.rawValue)
        XCTAssertEqual(entry.triggerId, "runtime.finished")
        XCTAssertEqual(entry.actionsExecuted, ["showNotification", "styleTab"])
        XCTAssertTrue(entry.didDispatchBanner)
        XCTAssertTrue(entry.didStyleTab)
        XCTAssertEqual(entry.reliability, AIEventReliability.authoritative.rawValue)
    }
}
#endif
