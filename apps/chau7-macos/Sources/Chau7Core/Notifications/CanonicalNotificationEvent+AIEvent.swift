import Foundation

public extension NotificationSemanticKind {
    var aiEventType: String {
        switch self {
        case .taskFinished:
            return "finished"
        case .taskFailed:
            return "failed"
        case .permissionRequired:
            return "permission"
        case .waitingForInput:
            return "waiting_input"
        case .attentionRequired:
            return "attention_required"
        case .authenticationSucceeded:
            return "authentication_succeeded"
        case .idle:
            return "idle"
        case .informational:
            return "informational"
        case .unknown:
            return "unknown"
        }
    }
}

public extension CanonicalNotificationEvent {
    func aiEvent(
        source: AIEventSource,
        toolName: String? = nil,
        producer: String? = nil
    ) -> AIEvent {
        AIEvent(
            id: id,
            source: source,
            type: kind.aiEventType,
            tool: toolName ?? providerName,
            message: message,
            ts: DateFormatters.iso8601.string(from: timestamp),
            directory: directory,
            tabID: tabID,
            sessionID: sessionID,
            producer: producer,
            reliability: reliability
        )
    }
}
