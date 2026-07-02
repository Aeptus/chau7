import XCTest
@testable import Chau7
import Chau7Core

/// Direct tests for the NotificationSuppressionCenter (previously
/// NotificationDeliveryPolicy). The integration path is covered through
/// NotificationManager by NotificationManagerTimingTests; these tests pin
/// the verdict contract per-step without spinning up a manager, and the
/// clock-driven tests pin window expiry and replay determinism.
@MainActor
final class NotificationSuppressionCenterTests: XCTestCase {

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
        let policy = NotificationSuppressionCenter()
        let event = makeEvent(tabID: UUID()) // already has tabID — no retry needed
        XCTAssertEqual(policy.attemptAuthoritativeRoutingRetry(event), .pass)
    }

    func testRoutingRetryFirstAttemptSchedulesAtFirstDelay() {
        let policy = NotificationSuppressionCenter(authoritativeRetryDelays: [0.05, 0.15, 0.5])
        let event = makeEvent()
        XCTAssertEqual(
            policy.attemptAuthoritativeRoutingRetry(event),
            .scheduleRetry(delaySeconds: 0.05, attempt: 1)
        )
    }

    func testRoutingRetryExhaustsAndDrops() {
        let policy = NotificationSuppressionCenter(authoritativeRetryDelays: [0.05])
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
        let policy = NotificationSuppressionCenter()
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
        let policy = NotificationSuppressionCenter()
        let event = makeEvent(type: "permission")
        XCTAssertEqual(policy.attemptPostCloseSuppression(event), .pass)
    }

    func testPostCloseSuppressionDropsAfterFinishRegistered() {
        let policy = NotificationSuppressionCenter()
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
        let policy = NotificationSuppressionCenter()
        XCTAssertEqual(policy.attemptFallbackShadowSuppression(makeEvent()), .pass)
    }

    func testFallbackShadowSuppressionDropsHeuristicAfterAuthoritative() {
        let policy = NotificationSuppressionCenter()
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
        let policy = NotificationSuppressionCenter()
        let event = makeEvent(type: "permission", tabID: UUID())
        policy.registerRepeatSuppressionIfNeeded(event)
        guard case .drop = policy.attemptRepeatSuppression(event) else {
            XCTFail("Repeated attention event for unchanged session state should be dropped")
            return
        }
    }

    // MARK: - Pruning + reset

    func testResetClearsAllPolicyMaps() {
        let policy = NotificationSuppressionCenter()
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
    // MARK: - Injected clock: window expiry

    func testPostCloseSuppressionExpiresAfterWindowViaInjectedClock() {
        var currentTime = Date(timeIntervalSince1970: 1_000_000)
        let center = NotificationSuppressionCenter(now: { currentTime })
        let session = "thread_windowed"
        center.registerClosedIdentityIfNeeded(makeEvent(type: "finished", sessionID: session))

        let attention = makeEvent(type: "permission", sessionID: session)
        guard case .drop = center.attemptPostCloseSuppression(attention) else {
            XCTFail("inside the window the event must drop")
            return
        }

        currentTime = currentTime.addingTimeInterval(NotificationTimings.closedSessionSuppression + 1)
        XCTAssertEqual(center.attemptPostCloseSuppression(attention), .pass, "window elapsed — must pass")
    }

    func testRepeatSuppressionExpiresAfterWindowViaInjectedClock() {
        var currentTime = Date(timeIntervalSince1970: 1_000_000)
        let center = NotificationSuppressionCenter(now: { currentTime })
        let event = makeEvent(type: "permission", tabID: UUID())
        center.registerRepeatSuppressionIfNeeded(event)
        guard case .drop = center.attemptRepeatSuppression(event) else {
            XCTFail("inside the window the repeat must drop")
            return
        }
        currentTime = currentTime.addingTimeInterval(NotificationTimings.repeatedAttentionSuppression + 1)
        XCTAssertEqual(center.attemptRepeatSuppression(event), .pass)
    }

    func testPruneExpiredUsesInjectedClock() {
        var currentTime = Date(timeIntervalSince1970: 1_000_000)
        let center = NotificationSuppressionCenter(now: { currentTime })
        let auth = makeEvent(type: "finished", tabID: UUID(), reliability: .authoritative)
        center.registerAuthoritativeEventIfNeeded(auth)

        currentTime = currentTime.addingTimeInterval(NotificationTimings.authorityRetention + 1)
        center.pruneExpired()

        let fallback = makeEvent(
            type: "finished", tabID: auth.tabID, sessionID: auth.sessionID, reliability: .fallback
        )
        XCTAssertEqual(center.attemptFallbackShadowSuppression(fallback), .pass, "pruned authority must not shadow")
    }

    // MARK: - Determinism replay

    /// The B4 determinism contract: an identical event sequence evaluated
    /// against an identical clock produces an identical verdict sequence,
    /// every time.
    func testIdenticalEventAndClockSequencesProduceIdenticalVerdicts() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let sharedTab = UUID()
        let events: [(offset: TimeInterval, event: AIEvent)] = [
            (0, makeEvent(type: "permission", tabID: sharedTab, sessionID: "s1")),
            (1, makeEvent(type: "permission", tabID: sharedTab, sessionID: "s1")),
            (2, makeEvent(type: "finished", tabID: sharedTab, sessionID: "s1")),
            (3, makeEvent(type: "waiting_input", tabID: sharedTab, sessionID: "s1", reliability: .fallback)),
            (200, makeEvent(type: "permission", tabID: sharedTab, sessionID: "s1")),
            (200 + NotificationTimings.closedSessionSuppression + 1,
             makeEvent(type: "permission", tabID: sharedTab, sessionID: "s1"))
        ]

        func replay() -> [NotificationSuppressionCenter.Verdict] {
            var currentTime = base
            let center = NotificationSuppressionCenter(now: { currentTime })
            var verdicts: [NotificationSuppressionCenter.Verdict] = []
            for (offset, event) in events {
                currentTime = base.addingTimeInterval(offset)
                center.pruneExpired()
                verdicts.append(center.attemptAuthoritativeRoutingRetry(event))
                verdicts.append(center.attemptPostCloseSuppression(event))
                verdicts.append(center.attemptFallbackShadowSuppression(event))
                verdicts.append(center.attemptRepeatSuppression(event))
                // Same registration flow the manager runs on delivery.
                center.registerClosedIdentityIfNeeded(event)
                center.registerAuthoritativeEventIfNeeded(event)
                center.registerRepeatSuppressionIfNeeded(event)
            }
            return verdicts
        }

        let first = replay()
        let second = replay()
        XCTAssertEqual(first, second, "replay with identical clock must be verdict-identical")
        // And the sequence itself must exercise real suppression (not all passes).
        XCTAssertTrue(first.contains(where: { if case .drop = $0 { return true } else { return false } }))
    }
}
