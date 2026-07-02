import Foundation

public enum NotificationProviderAdapterRegistry {
    public enum Decision: Equatable, Sendable {
        case emit(EnrichedEvent)
        case drop(reason: String)

        public var event: AIEvent? {
            switch self {
            case .emit(let enriched):
                return enriched.event
            case .drop:
                return nil
            }
        }

        public var enrichedEvent: EnrichedEvent? {
            switch self {
            case .emit(let enriched):
                return enriched
            case .drop:
                return nil
            }
        }
    }

    public static func adapt(_ event: AIEvent) -> Decision {
        // Dedicated-adapter sources first — each has provider-specific
        // event shape handling (Claude permission payloads, Codex turn-
        // complete wire format, etc.).
        switch event.source {
        case .claudeCode:
            return adaptClaudeCodeEvent(event)
        case .codex:
            return adaptCodexEvent(event)
        case .historyMonitor, .eventsLog:
            return adaptMappedSourceEvent(event, policy: .fallbackAI)
        case .terminalSession:
            return adaptMappedSourceEvent(event, policy: .terminalSession)
        case .shell:
            return adaptMappedSourceEvent(event, policy: .shell)
        case .app:
            return adaptMappedSourceEvent(event, policy: .app)
        case .apiProxy:
            return adaptMappedSourceEvent(event, policy: .apiProxy)
        default:
            // Generic AI sources (15 tool-level sources that share the
            // semantic-mapping path) route via the set declared on
            // `AIEventSource` so adding a new tool only touches that file.
            // Any source that's neither dedicated nor in the generic set
            // falls through to the unknown-source adapter.
            if AIEventSource.genericAIAdapterSources.contains(event.source) {
                return adaptMappedSourceEvent(event, policy: .genericAI)
            }
            return adaptMappedSourceEvent(event, policy: .unknown)
        }
    }

    // MARK: - Emission

    /// Build the enriched event: the original AIEvent normalized in place
    /// (semantic `type` rewrite for dedicated adapters, raw-type and
    /// reliability adjustments) with the derived kind attached. Identity,
    /// timestamp, routing fields, and `repoPath` are all preserved — the
    /// previous three-shape round-trip minted nothing but also dropped
    /// `repoPath` and re-formatted `ts`.
    private static func emitEnriched(
        _ event: AIEvent,
        kind: NotificationSemanticKind,
        type: String? = nil,
        rawType: String?,
        reliability: AIEventReliability
    ) -> Decision {
        let triggerType = SemanticTriggerType(kind: kind)?.rawValue ?? event.type
        let normalized = AIEvent(
            id: event.id,
            source: event.source,
            type: type ?? triggerType,
            rawType: rawType,
            tool: event.tool,
            title: event.title,
            message: event.message,
            notificationType: event.notificationType,
            ts: event.ts,
            directory: event.directory,
            repoPath: event.repoPath,
            tabID: event.tabID,
            sessionID: event.sessionID,
            producer: event.producer,
            reliability: reliability
        )
        return .emit(EnrichedEvent(event: normalized, kind: kind))
    }

    // MARK: - Claude Code

    private static func adaptClaudeCodeEvent(_ event: AIEvent) -> Decision {
        let rawType = NotificationSemanticMapping.normalize(event.rawType ?? event.type)
        let originalRawType = event.rawType ?? event.type

        switch rawType {
        case "notification":
            let inferredType = event.notificationType ?? inferClaudeNotificationType(from: event)
            let kind = NotificationSemanticMapping.kind(rawType: nil, notificationType: inferredType)
            guard kind != .unknown else {
                return .drop(reason: "Unsupported Claude notification payload")
            }
            return emitEnriched(event, kind: kind, rawType: originalRawType, reliability: .authoritative)

        case "permission_request", "permissionrequest":
            return emitEnriched(event, kind: .permissionRequired, rawType: originalRawType, reliability: .authoritative)

        case "tool_failed", "toolfailed", "response_failed", "responsefailed":
            return emitEnriched(event, kind: .taskFailed, rawType: originalRawType, reliability: .authoritative)

        case "elicitation":
            return emitEnriched(event, kind: .attentionRequired, rawType: originalRawType, reliability: .authoritative)

        case "idle":
            let kind: NotificationSemanticKind = NotificationSemanticMapping.isInputPromptLike(
                title: event.title,
                message: event.message,
                notificationType: event.notificationType
            ) ? .waitingForInput : .idle
            return emitEnriched(event, kind: kind, rawType: originalRawType, reliability: event.reliability)

        case "response_complete", "responsecomplete":
            return .drop(reason: "Claude response_complete is state-only; Notification hook owns user-facing delivery")

        case "user_prompt", "userprompt", "session_start", "sessionstart",
             "tool_start", "toolstart", "tool_complete", "toolcomplete",
             "session_end", "sessionend":
            return .drop(reason: "Claude raw event \(rawType) is not user-facing")

        default:
            let kind = NotificationSemanticMapping.kind(rawType: rawType)
            guard kind != .unknown else {
                return .drop(reason: "Unsupported Claude raw event \(rawType)")
            }
            return emitEnriched(event, kind: kind, rawType: originalRawType, reliability: event.reliability)
        }
    }

    private static func inferClaudeNotificationType(from event: AIEvent) -> String? {
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

    // MARK: - Codex

    private static func adaptCodexEvent(_ event: AIEvent) -> Decision {
        let rawType = NotificationSemanticMapping.normalize(event.rawType ?? event.type)
        let originalRawType = event.rawType ?? event.type

        switch rawType {
        case "agent_turn_complete", "agentturncomplete":
            return emitEnriched(event, kind: .taskFinished, rawType: originalRawType, reliability: .authoritative)
        case "approval_requested", "approvalrequested":
            return emitEnriched(event, kind: .permissionRequired, rawType: originalRawType, reliability: .authoritative)
        case "user_input_requested", "userinputrequested":
            return emitEnriched(event, kind: .waitingForInput, rawType: originalRawType, reliability: .authoritative)
        default:
            let kind = NotificationSemanticMapping.kind(
                rawType: rawType,
                notificationType: event.notificationType
            )
            guard kind != .unknown else {
                return .drop(reason: "Unsupported Codex raw event \(rawType)")
            }
            return emitEnriched(event, kind: kind, rawType: originalRawType, reliability: event.reliability)
        }
    }

    // MARK: - Mapped sources

    private static func adaptMappedSourceEvent(
        _ event: AIEvent,
        policy: MappedSourceAdapterPolicy
    ) -> Decision {
        let normalizedType = NotificationSemanticMapping.normalize(event.rawType ?? event.type)
        let kind = policy.kind(for: normalizedType, notificationType: event.notificationType)

        guard kind != .unknown else {
            return .drop(reason: policy.unsupportedReason(for: normalizedType))
        }

        if let reason = policy.missingRoutingReason(for: event, normalizedType: normalizedType) {
            return .drop(reason: reason)
        }

        return emitEnriched(
            event,
            kind: kind,
            type: event.type,
            rawType: policy.emittedRawType(for: event, normalizedType: normalizedType),
            reliability: policy.reliability(for: event)
        )
    }
}

private enum MappedSourceAdapterPolicy {
    case genericAI
    case terminalSession
    case fallbackAI
    case shell
    case app
    case apiProxy
    case unknown

    func kind(for normalizedType: String, notificationType: String?) -> NotificationSemanticKind {
        switch self {
        case .genericAI, .terminalSession, .fallbackAI, .unknown:
            return NotificationSemanticMapping.kind(
                rawType: normalizedType,
                notificationType: notificationType
            )

        case .shell:
            switch normalizedType {
            case "command_finished":
                return .taskFinished
            case "command_failed":
                return .taskFailed
            case "exit_code_match", "pattern_match", "long_running", "process_started", "process_ended",
                 "directory_changed", "git_branch_changed", "other":
                return .informational
            default:
                return .unknown
            }

        case .app:
            switch normalizedType {
            case "update_available", "launch", "tab_opened", "tab_closed", "window_focused",
                 "window_unfocused", "file_modified", "docker_event", "other":
                return .informational
            case "file_conflict", "memory_threshold":
                return .attentionRequired
            default:
                return .unknown
            }

        case .apiProxy:
            switch normalizedType {
            case "api_call":
                return .informational
            case "api_error", "error":
                return .taskFailed
            default:
                return .unknown
            }
        }
    }

    func missingRoutingReason(for event: AIEvent, normalizedType: String) -> String? {
        switch self {
        case .terminalSession:
            guard event.tabID != nil || event.sessionID != nil else {
                return "Terminal session event \(normalizedType) missing exact routing identity"
            }
            return nil
        case .fallbackAI:
            guard event.tabID != nil || event.sessionID != nil || event.directory != nil else {
                return "Fallback AI event \(normalizedType) missing routing identity"
            }
            return nil
        case .genericAI, .shell, .app, .apiProxy, .unknown:
            return nil
        }
    }

    func emittedRawType(for event: AIEvent, normalizedType: String) -> String? {
        switch self {
        case .genericAI:
            return event.rawType ?? event.type
        case .terminalSession, .fallbackAI, .shell, .app, .apiProxy, .unknown:
            return event.rawType ?? normalizedType
        }
    }

    func reliability(for event: AIEvent) -> AIEventReliability {
        switch self {
        case .terminalSession, .fallbackAI:
            return .fallback
        case .genericAI, .shell, .app, .apiProxy, .unknown:
            return event.reliability
        }
    }

    func unsupportedReason(for normalizedType: String) -> String {
        "Unsupported \(unsupportedRawEventLabel) raw event \(normalizedType)"
    }

    private var unsupportedRawEventLabel: String {
        switch self {
        case .genericAI:
            return "generic AI"
        case .terminalSession:
            return "terminal session"
        case .fallbackAI:
            return "fallback AI"
        case .shell:
            return "shell"
        case .app:
            return "app"
        case .apiProxy:
            return "API proxy"
        case .unknown:
            return "unknown-source"
        }
    }
}
