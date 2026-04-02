import Foundation

public enum NotificationProviderAdapterRegistry {
    public enum Decision: Equatable, Sendable {
        case emit(AIEvent, canonical: CanonicalNotificationEvent)
        case drop(reason: String)

        public var event: AIEvent? {
            switch self {
            case .emit(let event, _):
                return event
            case .drop:
                return nil
            }
        }

        public var canonicalEvent: CanonicalNotificationEvent? {
            switch self {
            case .emit(_, let canonical):
                return canonical
            case .drop:
                return nil
            }
        }
    }

    public static func adapt(_ event: AIEvent) -> Decision {
        switch event.source {
        case .claudeCode:
            return adaptClaudeCodeEvent(event)
        case .codex:
            return adaptCodexEvent(event)
        case .runtime, .gemini, .cursor, .windsurf, .copilot, .aider, .cline, .continueAI:
            return adaptGenericAIEvent(event)
        case .historyMonitor, .eventsLog:
            return adaptFallbackAIEvent(event)
        case .terminalSession:
            return adaptTerminalSessionEvent(event)
        case .shell:
            return adaptShellEvent(event)
        case .app:
            return adaptAppEvent(event)
        case .apiProxy:
            return adaptAPIProxyEvent(event)
        case .unknown:
            return adaptUnknownEvent(event)
        default:
            return adaptUnknownEvent(event)
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
        case .deferToFallback(let reason):
            return .drop(reason: reason)
        }
    }

    private static func adaptGenericAIEvent(_ event: AIEvent) -> Decision {
        let providerEvent = NotificationProviderEvent(event: event)
        let kind = NotificationSemanticMapping.kind(
            rawType: providerEvent.rawType,
            notificationType: providerEvent.notificationType
        )
        guard kind != .unknown else {
            return .drop(reason: "Unsupported generic AI raw event \(providerEvent.rawType ?? event.type)")
        }
        return emitCanonicalizedEvent(
            event,
            kind: kind,
            preservedType: event.type,
            rawType: providerEvent.rawType,
            reliability: event.reliability
        )
    }

    private static func adaptCodexEvent(_ event: AIEvent) -> Decision {
        let providerEvent = NotificationProviderEvent(event: event)
        let adapter = CodexNotificationAdapter()
        switch adapter.adapt(providerEvent) {
        case .emit(let canonical):
            return .emit(
                canonical.asAIEvent(source: event.source, producer: event.producer),
                canonical: canonical
            )
        case .drop(let reason):
            return .drop(reason: reason)
        case .deferToFallback(let reason):
            return .drop(reason: reason)
        }
    }

    private static func adaptTerminalSessionEvent(_ event: AIEvent) -> Decision {
        let normalizedType = NotificationSemanticMapping.normalize(event.rawType ?? event.type)
        let kind = NotificationSemanticMapping.kind(
            rawType: normalizedType,
            notificationType: event.notificationType
        )

        if kind == .unknown, normalizedType == "info" {
            return emitCanonicalizedEvent(
                event,
                kind: .informational,
                preservedType: event.type,
                rawType: event.rawType ?? normalizedType,
                reliability: .fallback
            )
        }

        guard kind != .unknown else {
            return .drop(reason: "Unsupported terminal session raw event \(normalizedType)")
        }

        guard event.tabID != nil || event.sessionID != nil else {
            return .drop(reason: "Terminal session event \(normalizedType) missing exact routing identity")
        }

        return emitCanonicalizedEvent(
            event,
            kind: kind,
            preservedType: event.type,
            rawType: event.rawType ?? normalizedType,
            reliability: .fallback
        )
    }

    private static func adaptFallbackAIEvent(_ event: AIEvent) -> Decision {
        let normalizedType = NotificationSemanticMapping.normalize(event.rawType ?? event.type)
        let kind = NotificationSemanticMapping.kind(
            rawType: normalizedType,
            notificationType: event.notificationType
        )

        guard kind != .unknown else {
            return .drop(reason: "Unsupported fallback AI raw event \(normalizedType)")
        }

        guard event.tabID != nil || event.sessionID != nil || event.directory != nil else {
            return .drop(reason: "Fallback AI event \(normalizedType) missing routing identity")
        }

        return emitCanonicalizedEvent(
            event,
            kind: kind,
            preservedType: event.type,
            rawType: event.rawType ?? normalizedType,
            reliability: .fallback
        )
    }

    private static func adaptShellEvent(_ event: AIEvent) -> Decision {
        let normalizedType = NotificationSemanticMapping.normalize(event.rawType ?? event.type)
        let kind: NotificationSemanticKind
        switch normalizedType {
        case "command_finished":
            kind = .taskFinished
        case "command_failed":
            kind = .taskFailed
        case "exit_code_match", "pattern_match", "long_running", "process_started", "process_ended", "directory_changed", "git_branch_changed", "other":
            kind = .informational
        default:
            kind = .unknown
        }

        guard kind != .unknown else {
            return .drop(reason: "Unsupported shell raw event \(normalizedType)")
        }

        return emitCanonicalizedEvent(
            event,
            kind: kind,
            preservedType: event.type,
            rawType: event.rawType ?? normalizedType,
            reliability: event.reliability
        )
    }

    private static func adaptAppEvent(_ event: AIEvent) -> Decision {
        let normalizedType = NotificationSemanticMapping.normalize(event.rawType ?? event.type)
        let kind: NotificationSemanticKind
        switch normalizedType {
        case "update_available", "launch", "tab_opened", "tab_closed", "window_focused", "window_unfocused", "file_modified", "docker_event", "other":
            kind = .informational
        case "file_conflict", "memory_threshold":
            kind = .attentionRequired
        default:
            kind = .unknown
        }

        guard kind != .unknown else {
            return .drop(reason: "Unsupported app raw event \(normalizedType)")
        }

        return emitCanonicalizedEvent(
            event,
            kind: kind,
            preservedType: event.type,
            rawType: event.rawType ?? normalizedType,
            reliability: event.reliability
        )
    }

    private static func adaptAPIProxyEvent(_ event: AIEvent) -> Decision {
        let normalizedType = NotificationSemanticMapping.normalize(event.rawType ?? event.type)
        let kind: NotificationSemanticKind
        switch normalizedType {
        case "api_call":
            kind = .informational
        case "api_error", "error":
            kind = .taskFailed
        default:
            kind = .unknown
        }

        guard kind != .unknown else {
            return .drop(reason: "Unsupported API proxy raw event \(normalizedType)")
        }

        return emitCanonicalizedEvent(
            event,
            kind: kind,
            preservedType: event.type,
            rawType: event.rawType ?? normalizedType,
            reliability: event.reliability
        )
    }

    private static func adaptUnknownEvent(_ event: AIEvent) -> Decision {
        let normalizedType = NotificationSemanticMapping.normalize(event.rawType ?? event.type)
        let kind = NotificationSemanticMapping.kind(
            rawType: normalizedType,
            notificationType: event.notificationType
        )

        guard kind != .unknown else {
            return .drop(reason: "Unsupported unknown-source raw event \(normalizedType)")
        }

        return emitCanonicalizedEvent(
            event,
            kind: kind,
            preservedType: event.type,
            rawType: event.rawType ?? normalizedType,
            reliability: event.reliability
        )
    }

    private static func emitCanonicalizedEvent(
        _ event: AIEvent,
        kind: NotificationSemanticKind,
        preservedType: String,
        rawType: String?,
        reliability: AIEventReliability
    ) -> Decision {
        let providerEvent = NotificationProviderEvent(event: event)
        let canonical = providerEvent.canonicalEvent(kind: kind, reliability: reliability)
        return .emit(
            canonical.asAIEvent(
                source: event.source,
                producer: event.producer,
                sharedTypeOverride: preservedType,
                rawTypeOverride: rawType
            ),
            canonical: canonical
        )
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
            return .drop(reason: "Claude response_complete is state-only; Notification hook owns user-facing delivery")

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

private struct CodexNotificationAdapter: NotificationProviderAdapter {
    let providerID = AIEventSource.codex.rawValue

    func adapt(_ event: NotificationProviderEvent) -> NotificationProviderAdapterResult {
        let rawType = NotificationSemanticMapping.normalize(event.rawType ?? "")

        switch rawType {
        case "agent_turn_complete", "agentturncomplete":
            return .emit(event.canonicalEvent(kind: .taskFinished, reliability: .authoritative))
        case "approval_requested", "approvalrequested":
            return .emit(event.canonicalEvent(kind: .permissionRequired, reliability: .authoritative))
        case "user_input_requested", "userinputrequested":
            return .emit(event.canonicalEvent(kind: .waitingForInput, reliability: .authoritative))
        default:
            let kind = NotificationSemanticMapping.kind(
                rawType: rawType,
                notificationType: event.notificationType
            )
            guard kind != .unknown else {
                return .drop(reason: "Unsupported Codex raw event \(rawType)")
            }
            return .emit(event.canonicalEvent(kind: kind))
        }
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
            reliability: event.reliability,
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

    func asAIEvent(
        source: AIEventSource,
        producer: String?,
        sharedTypeOverride: String? = nil,
        rawTypeOverride: String? = nil
    ) -> AIEvent {
        AIEvent(
            id: id,
            source: source,
            type: sharedTypeOverride ?? sharedTriggerType,
            rawType: rawTypeOverride ?? rawType,
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
