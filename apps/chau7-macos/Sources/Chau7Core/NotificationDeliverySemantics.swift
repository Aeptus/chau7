import Foundation

public enum NotificationDeliverySemantics {
    public static let authoritativeRoutingTypes: Set = [
        "finished", "failed", "permission", "waiting_input", "attention_required"
    ]
    public static let authorityRetentionSeconds: TimeInterval = 180

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

        let normalizedTool = event.tool
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var identities: [String] = []
        if let sessionID = event.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            identities.append("session:\(sessionID.lowercased())")
        }
        if let tabID = event.tabID {
            identities.append("tab:\(tabID.uuidString.lowercased())")
        }
        if let directory = event.directory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !directory.isEmpty {
            identities.append("dir:\(URL(fileURLWithPath: directory).standardized.path.lowercased())")
        }
        if identities.isEmpty {
            identities.append(MonitoringSchedule.notificationIdentityKey(for: event))
        }
        return identities.map { "\(event.normalizedType)|\(normalizedTool)|\($0)" }
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
}
