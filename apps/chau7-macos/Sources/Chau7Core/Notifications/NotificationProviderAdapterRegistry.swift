import Foundation

public enum NotificationProviderAdapterRegistry {
    public enum Decision: Equatable, Sendable {
        case emit(AIEvent, canonical: CanonicalNotificationEvent)
        case passThrough(AIEvent)
        case drop(reason: String)

        public var event: AIEvent? {
            switch self {
            case .emit(let event, _), .passThrough(let event):
                return event
            case .drop:
                return nil
            }
        }
    }

    public static func adapt(_ event: AIEvent) -> Decision {
        switch event.source {
        case .claudeCode:
            return adaptClaudeCodeEvent(event)
        case .runtime, .codex, .cursor, .windsurf, .copilot, .aider, .cline, .continueAI:
            return adaptGenericAIEvent(event)
        default:
            return .passThrough(event)
        }
    }

    private static func adaptClaudeCodeEvent(_ event: AIEvent) -> Decision {
        let providerEvent = NotificationProviderEvent(event: event)
        let adapter = ClaudeCodeNotificationAdapter()
        switch adapter.adapt(providerEvent) {
        case .emit(let canonical):
            return .emit(canonical.asAIEvent(source: event.source, producer: event.producer), canonical: canonical)
        case .drop(let reason):
            return .drop(reason: reason)
        case .deferToFallback:
            return .passThrough(event)
        }
    }

    private static func adaptGenericAIEvent(_ event: AIEvent) -> Decision {
        let providerEvent = NotificationProviderEvent(event: event)
        let kind = NotificationSemanticMapping.kind(
            rawType: providerEvent.rawType,
            notificationType: providerEvent.notificationType
        )
        guard kind != .unknown else {
            return .passThrough(event)
        }
        let canonical = providerEvent.canonicalEvent(kind: kind, reliability: event.reliability)
        return .emit(canonical.asAIEvent(source: event.source, producer: event.producer), canonical: canonical)
    }
}

private struct ClaudeCodeNotificationAdapter: NotificationProviderAdapter {
    let providerID = AIEventSource.claudeCode.rawValue

    func adapt(_ event: NotificationProviderEvent) -> NotificationProviderAdapterResult {
        let rawType = NotificationSemanticMapping.normalize(event.rawType ?? "")

        switch rawType {
        case "notification":
            let inferredType = event.notificationType ?? inferNotificationType(from: event)
            let kind = NotificationSemanticMapping.kind(rawType: nil, notificationType: inferredType)
            guard kind != .unknown else {
                return .drop(reason: "Unsupported Claude notification payload")
            }
            return .emit(event.canonicalEvent(kind: kind, reliability: .authoritative))

        case "permission_request", "permissionrequest":
            return .emit(event.canonicalEvent(kind: .permissionRequired, reliability: .authoritative))

        case "response_complete", "responsecomplete":
            return .emit(
                event.canonicalEvent(
                    kind: .waitingForInput,
                    reliability: .fallback
                )
            )

        case "user_prompt", "userprompt", "tool_start", "toolstart", "tool_complete", "toolcomplete", "session_end", "sessionend":
            return .drop(reason: "Claude raw event \(rawType) is not user-facing")

        default:
            let kind = NotificationSemanticMapping.kind(rawType: rawType)
            guard kind != .unknown else {
                return .drop(reason: "Unsupported Claude raw event \(rawType)")
            }
            return .emit(event.canonicalEvent(kind: kind, reliability: .authoritative))
        }
    }

    private func inferNotificationType(from event: NotificationProviderEvent) -> String? {
        let haystack = [event.title, event.message]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .joined(separator: " ")

        if haystack.contains("waiting for your input") || haystack.contains("needs your input") {
            return "idle_prompt"
        }
        if haystack.contains("needs your approval") || haystack.contains("needs your permission") {
            return "permission_prompt"
        }
        if haystack.contains("needs your attention") {
            return "elicitation_dialog"
        }
        if haystack.contains("authenticated") || haystack.contains("signed in") || haystack.contains("login successful") {
            return "auth_success"
        }
        return nil
    }
}

private extension NotificationProviderEvent {
    init(event: AIEvent) {
        let timestamp = DateFormatters.iso8601.date(from: event.ts) ?? Date()
        var metadata: [String: String] = [:]
        if let producer = event.producer, !producer.isEmpty {
            metadata["producer"] = producer
        }
        self.init(
            id: event.id,
            providerID: event.source.rawValue,
            providerName: event.tool,
            rawType: event.rawType ?? event.type,
            title: event.title,
            message: event.message,
            notificationType: event.notificationType,
            sessionID: event.sessionID,
            tabID: event.tabID,
            directory: event.directory,
            timestamp: timestamp,
            metadata: metadata
        )
    }
}

private extension CanonicalNotificationEvent {
    var sharedTriggerType: String {
        switch kind {
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
        case .informational:
            return "info"
        case .idle:
            return "idle"
        case .unknown:
            return rawType ?? "unknown"
        }
    }

    func asAIEvent(source: AIEventSource, producer: String?) -> AIEvent {
        AIEvent(
            id: id,
            source: source,
            type: sharedTriggerType,
            rawType: rawType,
            tool: providerName,
            title: title,
            message: message,
            notificationType: notificationType,
            ts: DateFormatters.iso8601.string(from: timestamp),
            directory: directory,
            tabID: tabID,
            sessionID: sessionID,
            producer: producer,
            reliability: reliability
        )
    }
}
