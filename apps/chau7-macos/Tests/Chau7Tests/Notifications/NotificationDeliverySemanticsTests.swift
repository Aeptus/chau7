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

    func testDropsUnresolvedAuthoritativeEventAfterRetryExhaustion() {
        let event = AIEvent(
            source: .claudeCode,
            type: "finished",
            tool: "Claude",
            message: "done",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            reliability: .authoritative
        )

        XCTAssertTrue(NotificationDeliverySemantics.shouldDropAfterRoutingFailure(
            event,
            retryAttempts: 3,
            maxRetryAttempts: 3
        ))
    }

    func testDropsAuthoritativeEventMissingExactIdentity() {
        let event = AIEvent(
            source: .claudeCode,
            type: "permission",
            tool: "Claude",
            message: "approve",
            ts: "2026-04-01T00:00:00Z",
            reliability: .authoritative
        )

        XCTAssertTrue(NotificationDeliverySemantics.shouldDropAfterRoutingFailure(
            event,
            retryAttempts: 0,
            maxRetryAttempts: 3
        ))
        XCTAssertEqual(
            NotificationDeliverySemantics.unresolvedRoutingDropReason(
                for: event,
                retryAttempts: 0,
                maxRetryAttempts: 3
            ),
            "Authoritative permission event missing exact routing identity"
        )
    }

    func testSuppressesRepeatedInteractiveAttentionWithinCooldown() {
        let event = AIEvent(
            source: .claudeCode,
            type: "waiting_input",
            tool: "Claude",
            message: "Ready for your input",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            reliability: .authoritative
        )

        let key = NotificationDeliverySemantics.repeatSuppressionKey(for: event)
        XCTAssertNotNil(key)
        XCTAssertTrue(
            NotificationDeliverySemantics.shouldSuppressRepeat(
                event,
                recentRepeatEvents: [key!: Date()]
            )
        )
    }

    func testRepeatSuppressionCoalescesAttentionFamilyAcrossTypes() {
        let permission = AIEvent(
            source: .claudeCode,
            type: "permission",
            tool: "Claude",
            message: "Need approval",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            reliability: .authoritative
        )
        let waiting = AIEvent(
            source: .claudeCode,
            type: "waiting_input",
            tool: "Claude",
            message: "Need approval",
            ts: "2026-04-01T00:00:00Z",
            sessionID: "session-1",
            reliability: .authoritative
        )

        XCTAssertEqual(
            NotificationDeliverySemantics.repeatSuppressionKey(for: permission),
            NotificationDeliverySemantics.repeatSuppressionKey(for: waiting)
        )
    }
}
