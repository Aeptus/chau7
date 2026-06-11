import Foundation
import Chau7Core

/// Owns the four time-windowed delivery-policy maps that used to live as
/// loose `private var` dictionaries on `NotificationManager`:
///
/// * `recentAuthoritativeEvents` — drives "fallback shadow" suppression
///   when a heuristic/fallback event arrives shortly after an
///   authoritative one for the same session/tab/directory.
/// * `recentRepeatedAttentionEvents` — drives repeat suppression for
///   permission / waiting-input / attention-required attention events
///   the user has already been shown.
/// * `recentClosedSessionEvents` — drives "post-close" suppression for
///   events that arrive after the session has already announced finish
///   or fail.
/// * `routingRetryCounts` — keyed by event id, holds the retry attempt
///   for authoritative events that arrived before their target tab was
///   ready to be routed to.
///
/// The policy returns `Verdict` values so the manager can pattern-match
/// on intent (pass / drop / scheduleRetry) without having to know which
/// of the four maps got read. The manager still owns the actual side
/// effects (history accounting, DispatchQueue dispatches, enqueueEvent
/// re-entry) because those depend on manager-only state.
@MainActor
final class NotificationDeliveryPolicy {

    /// What the manager should do for a given step.
    enum Verdict: Equatable {
        case pass
        case drop(reason: String)
        case scheduleRetry(delaySeconds: TimeInterval, attempt: Int)
    }

    // MARK: - State

    private var recentAuthoritativeEvents: [String: Date] = [:]
    private var recentRepeatedAttentionEvents: [String: Date] = [:]
    private var recentClosedSessionEvents: [String: Date] = [:]
    private var routingRetryCounts: [UUID: Int] = [:]

    private let authoritativeRetryDelays: [TimeInterval]
    private let routingRetryCountsCap: Int

    init(
        authoritativeRetryDelays: [TimeInterval] = [0.05, 0.15, 0.5],
        routingRetryCountsCap: Int = 100
    ) {
        self.authoritativeRetryDelays = authoritativeRetryDelays
        self.routingRetryCountsCap = routingRetryCountsCap
    }

    var maxRoutingRetryAttempts: Int { authoritativeRetryDelays.count }

    // MARK: - Pruning

    /// Drop entries from the three time-windowed maps that are older than
    /// their suppression window, and cap `routingRetryCounts` once it
    /// crosses the cap. Called by the manager at the start of every
    /// processEvent so the dicts can't grow unboundedly across a busy
    /// burst of events.
    func pruneExpired(now: Date = Date()) {
        recentAuthoritativeEvents = recentAuthoritativeEvents.filter {
            now.timeIntervalSince($0.value) <= NotificationDeliverySemantics.authorityRetentionSeconds
        }
        recentRepeatedAttentionEvents = recentRepeatedAttentionEvents.filter {
            now.timeIntervalSince($0.value) <= NotificationDeliverySemantics.repeatedAttentionSuppressionSeconds
        }
        recentClosedSessionEvents = recentClosedSessionEvents.filter {
            now.timeIntervalSince($0.value) <= NotificationDeliverySemantics.closedSessionSuppressionSeconds
        }
        if routingRetryCounts.count > routingRetryCountsCap {
            routingRetryCounts = routingRetryCounts.filter { $0.value < authoritativeRetryDelays.count }
        }
    }

    // MARK: - Suppression verdicts (read-side)

    /// Verdict for the authoritative-routing retry path. Returns
    /// `scheduleRetry(delay:attempt:)` when a retry slot is available and
    /// the event carries enough identity to retry; `drop` when retries
    /// are exhausted or identity is missing; `pass` when the event
    /// doesn't require authoritative routing at all.
    func attemptAuthoritativeRoutingRetry(_ event: AIEvent) -> Verdict {
        guard NotificationDeliverySemantics.requiresAuthoritativeRouting(event),
              event.tabID == nil else {
            return .pass
        }

        let attempts = routingRetryCounts[event.id] ?? 0
        let hasIdentity = event.sessionID != nil || event.directory != nil
        if attempts < authoritativeRetryDelays.count, hasIdentity {
            let nextAttempt = attempts + 1
            routingRetryCounts[event.id] = nextAttempt
            return .scheduleRetry(
                delaySeconds: authoritativeRetryDelays[attempts],
                attempt: nextAttempt
            )
        }

        let recordedAttempts = routingRetryCounts[event.id] ?? authoritativeRetryDelays.count
        guard NotificationDeliverySemantics.shouldDropAfterRoutingFailure(
            event,
            retryAttempts: recordedAttempts,
            maxRetryAttempts: authoritativeRetryDelays.count
        ) else {
            return .pass
        }
        let reason = NotificationDeliverySemantics.unresolvedRoutingDropReason(
            for: event,
            retryAttempts: recordedAttempts,
            maxRetryAttempts: authoritativeRetryDelays.count
        )
        routingRetryCounts.removeValue(forKey: event.id)
        return .drop(reason: reason)
    }

    /// Verdict for the post-close suppression step. Drops events that
    /// arrive for a session that has already announced finish/fail
    /// within the suppression window.
    func attemptPostCloseSuppression(_ event: AIEvent) -> Verdict {
        if NotificationDeliverySemantics.shouldSuppressAfterClose(
            event,
            recentlyClosedEvents: recentClosedSessionEvents
        ) {
            routingRetryCounts.removeValue(forKey: event.id)
            return .drop(reason: "Suppressed stale post-close notification for an already-finished session")
        }
        return .pass
    }

    /// Verdict for the fallback-shadow suppression step. Drops fallback /
    /// heuristic events when an authoritative event for the same
    /// session/tab/directory was delivered recently.
    func attemptFallbackShadowSuppression(_ event: AIEvent) -> Verdict {
        if NotificationDeliverySemantics.shouldSuppressAsFallback(
            event,
            authoritativeEvents: recentAuthoritativeEvents
        ) {
            return .drop(reason: "Suppressed fallback event shadowed by authoritative delivery")
        }
        return .pass
    }

    /// Verdict for the repeat-suppression step. Drops attention events
    /// for an unchanged session state the user already saw.
    func attemptRepeatSuppression(_ event: AIEvent) -> Verdict {
        if NotificationDeliverySemantics.shouldSuppressRepeat(
            event,
            recentRepeatEvents: recentRepeatedAttentionEvents
        ) {
            routingRetryCounts.removeValue(forKey: event.id)
            return .drop(reason: "Suppressed repeated interactive-attention notification for unchanged session state")
        }
        return .pass
    }

    // MARK: - Registrations (write-side)

    func registerClosedIdentityIfNeeded(_ event: AIEvent, now: Date = Date()) {
        guard NotificationDeliverySemantics.shouldRegisterClosedIdentity(event) else { return }
        for key in NotificationDeliverySemantics.closedIdentityKeys(for: event) {
            recentClosedSessionEvents[key] = now
        }
    }

    func registerAuthoritativeEventIfNeeded(_ event: AIEvent, now: Date = Date()) {
        guard event.reliability == .authoritative else { return }
        for key in NotificationDeliverySemantics.authorityKeys(for: event) {
            recentAuthoritativeEvents[key] = now
        }
        routingRetryCounts.removeValue(forKey: event.id)
    }

    func registerRepeatSuppressionIfNeeded(_ event: AIEvent, now: Date = Date()) {
        guard let key = NotificationDeliverySemantics.repeatSuppressionKey(for: event) else { return }
        recentRepeatedAttentionEvents[key] = now
    }

    /// Drop the retry counter for an event that has completed its journey
    /// (delivered, dropped by a non-routing reason, or rate-limited).
    func forgetRetryCount(_ eventID: UUID) {
        routingRetryCounts.removeValue(forKey: eventID)
    }

    func reset() {
        recentAuthoritativeEvents.removeAll()
        recentRepeatedAttentionEvents.removeAll()
        recentClosedSessionEvents.removeAll()
        routingRetryCounts.removeAll()
    }
}
