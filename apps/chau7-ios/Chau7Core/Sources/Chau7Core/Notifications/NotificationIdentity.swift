import Foundation

/// Every time window in the notification pipeline, named in one place.
///
/// Historically these lived as scattered literals (MonitoringSchedule,
/// NotificationDeliverySemantics, AISessionEventReconciler, the app-side
/// rate limiter), which made "don't repeat" behavior impossible to reason
/// about as a whole. Consumers must reference these by name.
public enum NotificationTimings {
    /// Last-wins merge window for near-simultaneous events with the same
    /// coalescing key (NotificationManager enqueue buffer).
    public static let coalescingWindow: TimeInterval = 0.25
    /// Reconciler window during which a repeated terminal state for the same
    /// session is treated as a duplicate, not a new transition.
    public static let terminalRepeatWindow: TimeInterval = 10
    /// How long an interactive-attention notification suppresses repeats for
    /// the same identity.
    public static let repeatedAttentionSuppression: TimeInterval = 90
    /// How long an authoritative event shadows fallback events with the same
    /// authority key.
    public static let authorityRetention: TimeInterval = 180
    /// How long after a session closes its identities stay muted.
    public static let closedSessionSuppression: TimeInterval = 180
    /// Per-trigger rate limiter cooldown between deliveries.
    public static let rateLimitCooldown: TimeInterval = 10
}

/// The single derivation of "which user-facing thing is this notification
/// about", shared by coalescing, rate limiting, authority shadowing, repeat
/// suppression, and post-close muting.
///
/// Scope resolution order (best available wins): AI session ID > tab UUID >
/// working directory > event UUID. The derivations delegate to
/// `AIObservation` (scoped identity) and reproduce the exact key formats the
/// pipeline shipped with — `NotificationIdentityTests` pins byte-equality
/// against the legacy helpers.
public struct NotificationIdentity: Equatable, Sendable {
    /// Normalized provider ("claude", "codex", source raw value fallback).
    public let providerKey: String
    /// Best-scope identity, e.g. "session:abc123" / "tab:<uuid>" /
    /// "dir:/path" / "event:<uuid>".
    public let scopedKey: String
    /// Event type, trimmed + lowercased.
    public let normalizedType: String
    /// Tool name, trimmed + lowercased.
    public let normalizedTool: String
    /// All exact routing identities present on the event (session, tab,
    /// directory — in that order), formatted per the authority-key rules.
    /// Empty when the event has no exact routing identity.
    public let routingIdentities: [String]
    /// "session:<id>" when a session ID is present (used by post-close keys).
    public let sessionKey: String?

    public init(for event: AIEvent) {
        self.providerKey = AIObservation.providerKey(for: event)
        self.scopedKey = AIObservation.identityKey(for: event)
        self.normalizedType = event.normalizedType
        self.normalizedTool = event.tool
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        var identities: [String] = []
        var sessionKey: String?
        if let sessionID = event.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            let key = "session:\(sessionID.lowercased())"
            identities.append(key)
            sessionKey = key
        }
        if let tabID = event.tabID {
            identities.append("tab:\(tabID.uuidString.lowercased())")
        }
        if let directory = event.directory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            identities.append("dir:\(URL(fileURLWithPath: directory).standardized.path.lowercased())")
        }
        self.routingIdentities = identities
        self.sessionKey = sessionKey
    }

    // MARK: - Key derivations

    /// Coalescing key: events with the same key within
    /// `NotificationTimings.coalescingWindow` merge (last wins).
    public var coalescingKey: String {
        "\(providerKey)|\(normalizedType)|\(scopedKey)"
    }

    /// Rate-limit bucket key, scoped by both trigger and identity so one
    /// noisy tab cannot starve the same trigger on another tab.
    public func rateLimitKey(triggerID: String) -> String {
        "\(triggerID)|\(scopedKey)"
    }

    /// Authority keys: one per exact routing identity (falling back to the
    /// best-scope identity when none exist). An authoritative event registers
    /// these; fallback events matching any of them are shadowed.
    public var authorityKeys: [String] {
        let identities = routingIdentities.isEmpty ? [scopedKey] : routingIdentities
        return identities.map { "\(normalizedType)|\(normalizedTool)|\($0)" }
    }

    /// Repeat-suppression key within a semantic family (e.g.
    /// "interactive_attention").
    public func repeatSuppressionKey(family: String) -> String {
        "\(family)|\(normalizedTool)|\(scopedKey)"
    }

    /// Post-close mute keys: the session identity (when known) plus the
    /// tool-scoped best identity.
    public var closedIdentityKeys: [String] {
        let toolScoped = "\(normalizedTool)|\(scopedKey)"
        if let sessionKey {
            return [sessionKey, toolScoped]
        }
        return [toolScoped]
    }
}
