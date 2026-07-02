import Foundation

public enum NotificationDeliverySemantics {
    public static let authoritativeRoutingTypes: Set = [
        "finished", "failed", "permission", "waiting_input", "attention_required"
    ]
    public static let authorityRetentionSeconds: TimeInterval = NotificationTimings.authorityRetention
    public static let repeatedAttentionSuppressionSeconds: TimeInterval = NotificationTimings.repeatedAttentionSuppression
    public static let closedSessionSuppressionSeconds: TimeInterval = NotificationTimings.closedSessionSuppression

    public static func requiresAuthoritativeRouting(_ event: AIEvent) -> Bool {
        event.reliability == .authoritative
            && authoritativeRoutingTypes.contains(event.normalizedType)
            && event.tabID == nil
    }

    public static func shouldDropAfterRoutingFailure(
        _ event: AIEvent,
        retryAttempts: Int,
        maxRetryAttempts: Int
    ) -> Bool {
        requiresAuthoritativeRouting(event)
            && (
                retryAttempts >= maxRetryAttempts
                    || (event.sessionID == nil && event.directory == nil)
            )
    }

    public static func unresolvedRoutingDropReason(
        for event: AIEvent,
        retryAttempts: Int,
        maxRetryAttempts: Int
    ) -> String {
        if event.sessionID == nil, event.directory == nil {
            return "Authoritative \(event.normalizedType) event missing exact routing identity"
        }
        return "Authoritative \(event.normalizedType) event unresolved after \(retryAttempts)/\(maxRetryAttempts) routing attempts"
    }

    public static func authorityKeys(for event: AIEvent) -> [String] {
        guard authoritativeRoutingTypes.contains(event.normalizedType) else {
            return []
        }
        return NotificationIdentity(for: event).authorityKeys
    }

    public static func authorityKey(for event: AIEvent) -> String? {
        authorityKeys(for: event).first
    }

    public static func shouldSuppressAsFallback(
        _ event: AIEvent,
        authoritativeEvents: [String: Date],
        now: Date = Date(),
        retentionSeconds: TimeInterval = authorityRetentionSeconds
    ) -> Bool {
        guard event.reliability != .authoritative,
              !authorityKeys(for: event).isEmpty else {
            return false
        }
        return authorityKeys(for: event).contains { key in
            guard let seenAt = authoritativeEvents[key] else { return false }
            return now.timeIntervalSince(seenAt) <= retentionSeconds
        }
    }

    public static func repeatSuppressionKey(for event: AIEvent) -> String? {
        guard let family = repeatSuppressionFamily(for: event) else { return nil }
        return NotificationIdentity(for: event).repeatSuppressionKey(family: family)
    }

    public static func shouldSuppressRepeat(
        _ event: AIEvent,
        recentRepeatEvents: [String: Date],
        now: Date = Date(),
        suppressionSeconds: TimeInterval = repeatedAttentionSuppressionSeconds
    ) -> Bool {
        guard let key = repeatSuppressionKey(for: event),
              let seenAt = recentRepeatEvents[key] else {
            return false
        }
        return now.timeIntervalSince(seenAt) <= suppressionSeconds
    }

    public static func closedIdentityKey(for event: AIEvent) -> String {
        let identity = NotificationIdentity(for: event)
        return "\(identity.normalizedTool)|\(identity.scopedKey)"
    }

    public static func closedIdentityKeys(for event: AIEvent) -> [String] {
        NotificationIdentity(for: event).closedIdentityKeys
    }

    public static func shouldRegisterClosedIdentity(_ event: AIEvent) -> Bool {
        switch event.normalizedType {
        case "finished", "failed":
            return true
        default:
            return false
        }
    }

    public static func shouldSuppressAfterClose(
        _ event: AIEvent,
        recentlyClosedEvents: [String: Date],
        now: Date = Date(),
        suppressionSeconds: TimeInterval = closedSessionSuppressionSeconds
    ) -> Bool {
        guard repeatSuppressionFamily(for: event) != nil else {
            return false
        }

        for key in closedIdentityKeys(for: event) {
            guard let seenAt = recentlyClosedEvents[key] else { continue }
            if now.timeIntervalSince(seenAt) <= suppressionSeconds {
                return true
            }
        }
        return false
    }

    public static func shouldClearPersistentAttentionStyle(
        event: AIEvent,
        semanticKind: NotificationSemanticKind
    ) -> Bool {
        guard event.reliability == .authoritative else {
            return false
        }

        switch semanticKind {
        case .permissionRequired, .waitingForInput, .attentionRequired:
            return false
        case .idle:
            return !NotificationSemanticMapping.isInputPromptLike(
                title: event.title,
                message: event.message,
                notificationType: event.notificationType
            )
        case .taskFinished, .taskFailed, .authenticationSucceeded, .informational, .unknown:
            return true
        }
    }

    private static func repeatSuppressionFamily(for event: AIEvent) -> String? {
        switch event.normalizedType {
        case "permission", "waiting_input", "attention_required", "idle", "elicitation":
            return "interactive_attention"
        default:
            return nil
        }
    }
}
