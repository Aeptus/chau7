import XCTest
@testable import Chau7Core

final class NotificationDeliverySemanticsTests: XCTestCase {
    func testRequiresAuthoritativeRoutingForCoreEventWithoutTabID() {
        let event = AIEvent(
            source: .runtime,
            type: "finished",
            tool: "Claude",
            message: "done",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            reliability: .authoritative
        )

        XCTAssertTrue(NotificationDeliverySemantics.requiresAuthoritativeRouting(event))
    }

    func testDoesNotRequireAuthoritativeRoutingForFallbackEvent() {
        let event = AIEvent(
            source: .historyMonitor,
            type: "finished",
            tool: "Claude",
            message: "done",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            reliability: .fallback
        )

        XCTAssertFalse(NotificationDeliverySemantics.requiresAuthoritativeRouting(event))
    }

    func testSuppressesFallbackWhenRecentAuthoritativeEventExists() {
        let event = AIEvent(
            source: .historyMonitor,
            type: "finished",
            tool: "Claude",
            message: "done",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            reliability: .fallback
        )
        let key = NotificationDeliverySemantics.authorityKey(for:
            AIEvent(
                source: .runtime,
                type: "finished",
                tool: "Claude",
                message: "done",
                ts: "2026-04-01T00:00:00Z",
                sessionID: "session-1",
                reliability: .authoritative
            )
        )!

        XCTAssertTrue(NotificationDeliverySemantics.shouldSuppressAsFallback(
            event,
            authoritativeEvents: [key: Date()]
        ))
    }
}
