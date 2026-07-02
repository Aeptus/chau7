import Foundation

/// The single time-windowed suppression component for notification delivery.
///
/// Owns the four state maps that decide whether an accepted event still gets
/// delivered (they previously lived app-side as `NotificationDeliveryPolicy`,
/// with the pure predicates split across `NotificationDeliverySemantics`):
///
/// * `recentAuthoritativeEvents` — "fallback shadow": a heuristic/fallback
///   event arriving shortly after an authoritative one for the same
///   session/tab/directory is suppressed.
/// * `recentRepeatedAttentionEvents` — repeat suppression for interactive
///   attention (permission / waiting-input / attention-required) the user
///   has already been shown.
/// * `recentClosedSessionEvents` — "post-close": events arriving after the
///   session announced finish/fail stay muted.
/// * `routingRetryCounts` — retry bookkeeping for authoritative events that
///   arrived before their target tab could be resolved.
///
/// All windows are the named `NotificationTimings` constants and every
/// time read goes through the injected clock, so identical event sequences
/// with an identical clock produce identical verdict sequences — the
/// determinism contract `NotificationSuppressionCenterTests` replays.
///
/// Not thread-safe: confine to one actor/queue (the notification manager
/// runs it on the main actor).
public final class NotificationSuppressionCenter {

    /// What the caller should do for a given step.
    public enum Verdict: Equatable, Sendable {
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
    private let now: () -> Date

    public init(
        authoritativeRetryDelays: [TimeInterval] = [0.05, 0.15, 0.5],
        routingRetryCountsCap: Int = 100,
        now: @escaping () -> Date = Date.init
    ) {
        self.authoritativeRetryDelays = authoritativeRetryDelays
        self.routingRetryCountsCap = routingRetryCountsCap
        self.now = now
    }

    public var maxRoutingRetryAttempts: Int {
        authoritativeRetryDelays.count
    }

    // MARK: - Pruning

    /// Drop entries from the three time-windowed maps that are older than
    /// their suppression window, and cap `routingRetryCounts` once it
    /// crosses the cap. Call at the start of every delivery evaluation so
    /// the dicts can't grow unboundedly across a busy burst of events.
    public func pruneExpired() {
        let current = now()
        recentAuthoritativeEvents = recentAuthoritativeEvents.filter {
            current.timeIntervalSince($0.value) <= NotificationTimings.authorityRetention
        }
        recentRepeatedAttentionEvents = recentRepeatedAttentionEvents.filter {
            current.timeIntervalSince($0.value) <= NotificationTimings.repeatedAttentionSuppression
        }
        recentClosedSessionEvents = recentClosedSessionEvents.filter {
            current.timeIntervalSince($0.value) <= NotificationTimings.closedSessionSuppression
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
    public func attemptAuthoritativeRoutingRetry(_ event: AIEvent) -> Verdict {
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
    public func attemptPostCloseSuppression(_ event: AIEvent) -> Verdict {
        if NotificationDeliverySemantics.shouldSuppressAfterClose(
            event,
            recentlyClosedEvents: recentClosedSessionEvents,
            now: now()
        ) {
            routingRetryCounts.removeValue(forKey: event.id)
            return .drop(reason: "Suppressed stale post-close notification for an already-finished session")
        }
        return .pass
    }

    /// Verdict for the fallback-shadow suppression step. Drops fallback /
    /// heuristic events when an authoritative event for the same
    /// session/tab/directory was delivered recently.
    public func attemptFallbackShadowSuppression(_ event: AIEvent) -> Verdict {
        if NotificationDeliverySemantics.shouldSuppressAsFallback(
            event,
            authoritativeEvents: recentAuthoritativeEvents,
            now: now()
        ) {
            return .drop(reason: "Suppressed fallback event shadowed by authoritative delivery")
        }
        return .pass
    }

    /// Verdict for the repeat-suppression step. Drops attention events
    /// for an unchanged session state the user already saw.
    public func attemptRepeatSuppression(_ event: AIEvent) -> Verdict {
        if NotificationDeliverySemantics.shouldSuppressRepeat(
            event,
            recentRepeatEvents: recentRepeatedAttentionEvents,
            now: now()
        ) {
            routingRetryCounts.removeValue(forKey: event.id)
            return .drop(reason: "Suppressed repeated interactive-attention notification for unchanged session state")
        }
        return .pass
    }

    // MARK: - Registrations (write-side)

    public func registerClosedIdentityIfNeeded(_ event: AIEvent) {
        guard NotificationDeliverySemantics.shouldRegisterClosedIdentity(event) else { return }
        let current = now()
        for key in NotificationDeliverySemantics.closedIdentityKeys(for: event) {
            recentClosedSessionEvents[key] = current
        }
    }

    public func registerAuthoritativeEventIfNeeded(_ event: AIEvent) {
        guard event.reliability == .authoritative else { return }
        let current = now()
        for key in NotificationDeliverySemantics.authorityKeys(for: event) {
            recentAuthoritativeEvents[key] = current
        }
        routingRetryCounts.removeValue(forKey: event.id)
    }

    public func registerRepeatSuppressionIfNeeded(_ event: AIEvent) {
        guard let key = NotificationDeliverySemantics.repeatSuppressionKey(for: event) else { return }
        recentRepeatedAttentionEvents[key] = now()
    }

    /// Drop the retry counter for an event that has completed its journey
    /// (delivered, dropped by a non-routing reason, or rate-limited).
    public func forgetRetryCount(_ eventID: UUID) {
        routingRetryCounts.removeValue(forKey: eventID)
    }

    public func reset() {
        recentAuthoritativeEvents.removeAll()
        recentRepeatedAttentionEvents.removeAll()
        recentClosedSessionEvents.removeAll()
        routingRetryCounts.removeAll()
    }
}
