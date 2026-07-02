import Foundation

public enum AIObservationState: String, Codable, Sendable, CaseIterable {
    case unknown
    case running
    case idle
    case waitingForInput
    case attentionRequired
    case permissionRequired
    case finished
    case failed

    public var isTerminal: Bool {
        self == .finished || self == .failed
    }

    public var isInteractiveAttention: Bool {
        switch self {
        case .waitingForInput, .attentionRequired, .permissionRequired:
            return true
        case .unknown, .running, .idle, .finished, .failed:
            return false
        }
    }

    public var interactiveSpecificity: Int {
        switch self {
        case .permissionRequired:
            return 3
        case .attentionRequired:
            return 2
        case .waitingForInput:
            return 1
        case .unknown, .running, .idle, .finished, .failed:
            return 0
        }
    }
}

public enum AIObservationSourceClass: String, Codable, Sendable, CaseIterable {
    case providerHook
    case runtime
    case terminalStructured
    case shellLifecycle
    case providerFallback
    case historyFallback
    case terminalTextHeuristic
    case app
    case generic
    case unknown

    public var precedence: Int {
        switch self {
        case .runtime:
            return 600
        case .providerHook:
            return 500
        case .terminalStructured:
            return 350
        case .shellLifecycle:
            return 250
        case .providerFallback:
            return 190
        case .historyFallback:
            return 160
        case .terminalTextHeuristic:
            return 80
        case .app:
            return 70
        case .generic:
            return 60
        case .unknown:
            return 0
        }
    }
}

public enum AIObservationIdentityScope: Int, Codable, Sendable, CaseIterable, Comparable {
    case session = 0
    case tab = 1
    case directory = 2
    case event = 3

    public static func < (lhs: AIObservationIdentityScope, rhs: AIObservationIdentityScope) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct AIObservationIdentityAlias: Hashable, Codable, Sendable {
    public let providerKey: String
    public let scope: AIObservationIdentityScope
    public let value: String

    public init(providerKey: String, scope: AIObservationIdentityScope, value: String) {
        self.providerKey = providerKey
        self.scope = scope
        self.value = value
    }

    public var key: String {
        "\(providerKey)|\(scopedKey)"
    }

    public var scopedKey: String {
        "\(scopeLabel):\(value)"
    }

    private var scopeLabel: String {
        switch scope {
        case .session:
            return "session"
        case .tab:
            return "tab"
        case .directory:
            return "dir"
        case .event:
            return "event"
        }
    }
}

public struct AIObservation: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let eventID: UUID
    public let state: AIObservationState?
    public let sourceClass: AIObservationSourceClass
    public let providerKey: String
    public let aliases: [AIObservationIdentityAlias]
    public let reliability: AIEventReliability
    public let timestamp: Date
    public let eventType: String
    public let producer: String?

    public init(
        id: UUID = UUID(),
        eventID: UUID,
        state: AIObservationState?,
        sourceClass: AIObservationSourceClass,
        providerKey: String,
        aliases: [AIObservationIdentityAlias],
        reliability: AIEventReliability,
        timestamp: Date,
        eventType: String,
        producer: String?
    ) {
        self.id = id
        self.eventID = eventID
        self.state = state
        self.sourceClass = sourceClass
        self.providerKey = providerKey
        self.aliases = AIObservation.orderedUniqueAliases(aliases)
        self.reliability = reliability
        self.timestamp = timestamp
        self.eventType = eventType
        self.producer = producer
    }

    public var strength: Int {
        sourceClass.precedence + reliabilityAdjustment
    }

    public var primaryIdentityKey: String {
        AIObservation.preferredPrimaryKey(aliases: aliases, providerKey: providerKey)
    }

    public static func notificationObservation(
        from enriched: EnrichedEvent,
        now: Date = Date()
    ) -> AIObservation? {
        guard let state = state(for: enriched.kind) else {
            return nil
        }
        return AIObservation(event: enriched.event, state: state, now: now)
    }

    public static func rawLifecycleObservation(from event: AIEvent, now: Date = Date()) -> AIObservation? {
        let normalized = NotificationSemanticMapping.normalize(event.rawType ?? event.type)
        let state: AIObservationState
        switch normalized {
        case "session_start", "sessionstart", "user_prompt", "userprompt",
             "tool_start", "toolstart", "process_started", "processstarted",
             "command_started", "commandstarted":
            state = .running
        default:
            return nil
        }
        return AIObservation(event: event, state: state, now: now)
    }

    public static func providerKey(for event: AIEvent) -> String {
        switch event.source {
        case .claudeCode:
            return "claude"
        case .codex:
            return "codex"
        default:
            break
        }

        if let key = AIToolRegistry.resumeProviderKey(for: event.tool) {
            return key
        }

        let sourceKey = event.source.rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return sourceKey.isEmpty ? "unknown" : sourceKey
    }

    public static func identityAliases(for event: AIEvent) -> [AIObservationIdentityAlias] {
        let provider = providerKey(for: event)
        var aliases: [AIObservationIdentityAlias] = []

        if let sessionID = normalizedIdentityComponent(event.sessionID) {
            aliases.append(AIObservationIdentityAlias(providerKey: provider, scope: .session, value: sessionID))
        }
        if let tabID = event.tabID {
            aliases.append(AIObservationIdentityAlias(providerKey: provider, scope: .tab, value: tabID.uuidString.lowercased()))
        }
        if let directory = normalizedDirectory(event.directory) {
            aliases.append(AIObservationIdentityAlias(providerKey: provider, scope: .directory, value: directory))
        }

        if aliases.isEmpty {
            aliases.append(AIObservationIdentityAlias(providerKey: provider, scope: .event, value: event.id.uuidString.lowercased()))
        }
        return orderedUniqueAliases(aliases)
    }

    public static func preferredPrimaryKey(
        aliases: some Sequence<AIObservationIdentityAlias>,
        providerKey: String
    ) -> String {
        orderedUniqueAliases(Array(aliases)).first?.key
            ?? "\(providerKey)|event:unknown"
    }

    public static func identityKey(for event: AIEvent) -> String {
        identityAliases(for: event).first?.scopedKey
            ?? "event:\(event.id.uuidString.lowercased())"
    }

    public static func orderedUniqueAliases(
        _ aliases: [AIObservationIdentityAlias]
    ) -> [AIObservationIdentityAlias] {
        var seen: Set<String> = []
        return aliases
            .sorted(by: aliasSort)
            .filter { alias in
                if seen.contains(alias.key) {
                    return false
                }
                seen.insert(alias.key)
                return true
            }
    }

    public static func aliasSort(
        _ lhs: AIObservationIdentityAlias,
        _ rhs: AIObservationIdentityAlias
    ) -> Bool {
        if lhs.scope != rhs.scope {
            return lhs.scope < rhs.scope
        }
        if lhs.providerKey != rhs.providerKey {
            return lhs.providerKey < rhs.providerKey
        }
        return lhs.value < rhs.value
    }

    private init(event: AIEvent, state: AIObservationState, now: Date) {
        self.init(
            eventID: event.id,
            state: state,
            sourceClass: Self.sourceClass(for: event),
            providerKey: Self.providerKey(for: event),
            aliases: Self.identityAliases(for: event),
            reliability: event.reliability,
            timestamp: now,
            eventType: event.normalizedType,
            producer: event.producer
        )
    }

    private var reliabilityAdjustment: Int {
        switch reliability {
        case .authoritative:
            return 40
        case .fallback:
            return 20
        case .heuristic:
            return 0
        }
    }

    private static func state(for kind: NotificationSemanticKind) -> AIObservationState? {
        switch kind {
        case .taskFinished:
            return .finished
        case .taskFailed:
            return .failed
        case .permissionRequired:
            return .permissionRequired
        case .waitingForInput:
            return .waitingForInput
        case .attentionRequired:
            return .attentionRequired
        case .idle:
            return .idle
        case .authenticationSucceeded, .informational, .unknown:
            return nil
        }
    }

    private static func sourceClass(for event: AIEvent) -> AIObservationSourceClass {
        switch event.source {
        case .runtime:
            return .runtime
        case .shell:
            return .shellLifecycle
        case .historyMonitor, .eventsLog:
            return .historyFallback
        case .terminalSession:
            return event.reliability == .heuristic ? .terminalTextHeuristic : .terminalStructured
        case .app:
            return .app
        case .claudeCode, .codex:
            if event.reliability == .heuristic {
                return .terminalTextHeuristic
            }
            if event.reliability == .fallback {
                return .providerFallback
            }
            if isTerminalStructuredProducer(event.producer) {
                return .terminalStructured
            }
            return .providerHook
        default:
            if AIEventSource.genericAIAdapterSources.contains(event.source) {
                return event.reliability == .fallback ? .providerFallback : .generic
            }
            return .unknown
        }
    }

    private static func isTerminalStructuredProducer(_ producer: String?) -> Bool {
        let normalized = producer?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
        return normalized == "terminal_osc9"
    }

    private static func normalizedIdentityComponent(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed.lowercased()
    }

    private static func normalizedDirectory(_ rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardized.path.lowercased()
    }
}
