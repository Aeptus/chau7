import XCTest
@testable import Chau7
import Chau7Core

/// Direct tests for the extracted NotificationDeliveryPolicy. The
/// integration path is covered through NotificationManager by
/// NotificationManagerTimingTests; these tests pin the policy's verdict
/// contract per-step without spinning up a manager.
@MainActor
final class NotificationDeliveryPolicyTests: XCTestCase {

    private func makeEvent(
        type: String = "finished",
        tabID: UUID? = nil,
        sessionID: String? = "session-1",
        directory: String? = "/tmp/chau7",
        reliability: AIEventReliability = .authoritative
    ) -> AIEvent {
        AIEvent(
            source: .codex,
            type: type,
            tool: "Codex",
            message: "test",
            ts: "2026-04-03T09:00:00Z",
            directory: directory,
            tabID: tabID,
            sessionID: sessionID,
            reliability: reliability
        )
    }

    // MARK: - Authoritative routing retry

    func testRoutingRetryPassesWhenEventDoesNotRequireAuthoritativeRouting() {
        let policy = NotificationDeliveryPolicy()
        let event = makeEvent(tabID: UUID()) // already has tabID — no retry needed
        XCTAssertEqual(policy.attemptAuthoritativeRoutingRetry(event), .pass)
    }

    func testRoutingRetryFirstAttemptSchedulesAtFirstDelay() {
        let policy = NotificationDeliveryPolicy(authoritativeRetryDelays: [0.05, 0.15, 0.5])
        let event = makeEvent()
        XCTAssertEqual(
            policy.attemptAuthoritativeRoutingRetry(event),
            .scheduleRetry(delaySeconds: 0.05, attempt: 1)
        )
    }

    func testRoutingRetryExhaustsAndDrops() {
        let policy = NotificationDeliveryPolicy(authoritativeRetryDelays: [0.05])
        let event = makeEvent()
        // First call consumes the only slot
        XCTAssertEqual(
            policy.attemptAuthoritativeRoutingRetry(event),
            .scheduleRetry(delaySeconds: 0.05, attempt: 1)
        )
        // Second call: no slots left, identity exists, so policy drops
        guard case .drop = policy.attemptAuthoritativeRoutingRetry(event) else {
            XCTFail("Expected drop after retries exhausted")
            return
        }
    }

    func testRoutingRetryDropsWhenNoIdentity() {
        let policy = NotificationDeliveryPolicy()
        // No session, no directory — policy has no way to retry routing
        // even though the event requires authoritative routing.
        let event = makeEvent(sessionID: nil, directory: nil)
        let verdict = policy.attemptAuthoritativeRoutingRetry(event)
        guard case .drop = verdict else {
            XCTFail("Expected drop without identity, got \(verdict)")
            return
        }
    }

    // MARK: - Post-close suppression

    func testPostCloseSuppressionPassesByDefault() {
        let policy = NotificationDeliveryPolicy()
        let event = makeEvent(type: "permission")
        XCTAssertEqual(policy.attemptPostCloseSuppression(event), .pass)
    }

    func testPostCloseSuppressionDropsAfterFinishRegistered() {
        let policy = NotificationDeliveryPolicy()
        let session = "thread_abc"
        // Step 1: register the "finished" event so the session is marked closed.
        let finished = makeEvent(type: "finished", sessionID: session)
        policy.registerClosedIdentityIfNeeded(finished)

        // Step 2: a later attention event for the same session must drop.
        let attention = makeEvent(type: "permission", sessionID: session)
        guard case .drop = policy.attemptPostCloseSuppression(attention) else {
            XCTFail("Post-close suppression should drop attention events for a closed session")
            return
        }
    }

    // MARK: - Fallback shadow suppression

    func testFallbackShadowSuppressionPassesByDefault() {
        let policy = NotificationDeliveryPolicy()
        XCTAssertEqual(policy.attemptFallbackShadowSuppression(makeEvent()), .pass)
    }

    func testFallbackShadowSuppressionDropsHeuristicAfterAuthoritative() {
        let policy = NotificationDeliveryPolicy()
        let auth = makeEvent(type: "finished", tabID: UUID(), reliability: .authoritative)
        policy.registerAuthoritativeEventIfNeeded(auth)
        let fallback = makeEvent(
            type: "finished",
            tabID: auth.tabID,
            sessionID: auth.sessionID,
            reliability: .fallback
        )
        guard case .drop = policy.attemptFallbackShadowSuppression(fallback) else {
            XCTFail("Fallback event should be shadowed by recent authoritative one")
            return
        }
    }

    // MARK: - Repeat suppression

    func testRepeatSuppressionDropsAfterRegistration() {
        let policy = NotificationDeliveryPolicy()
        let event = makeEvent(type: "permission", tabID: UUID())
        policy.registerRepeatSuppressionIfNeeded(event)
        guard case .drop = policy.attemptRepeatSuppression(event) else {
            XCTFail("Repeated attention event for unchanged session state should be dropped")
            return
        }
    }

    // MARK: - Pruning + reset

    func testResetClearsAllPolicyMaps() {
        let policy = NotificationDeliveryPolicy()
        let event = makeEvent(type: "finished", tabID: UUID())
        policy.registerClosedIdentityIfNeeded(event)
        policy.registerAuthoritativeEventIfNeeded(event)
        policy.registerRepeatSuppressionIfNeeded(makeEvent(type: "permission", tabID: UUID()))
        _ = policy.attemptAuthoritativeRoutingRetry(makeEvent()) // bumps a retry counter

        policy.reset()

        // After reset, none of the suppression paths should match.
        XCTAssertEqual(policy.attemptPostCloseSuppression(event), .pass)
        XCTAssertEqual(policy.attemptFallbackShadowSuppression(event), .pass)
        // The retry counter is gone; the next attempt should re-issue attempt 1.
        guard case .scheduleRetry(_, let attempt) = policy.attemptAuthoritativeRoutingRetry(makeEvent()) else {
            XCTFail("Expected fresh scheduleRetry after reset")
            return
        }
        XCTAssertEqual(attempt, 1)
    }
}
