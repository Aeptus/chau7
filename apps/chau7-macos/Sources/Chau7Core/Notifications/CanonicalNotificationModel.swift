import Foundation

/// Canonical semantic categories for user-facing AI notification events.
///
/// Provider-specific adapters should translate raw tool events and hook payloads
/// into one of these kinds before the shared notification layer makes delivery
/// decisions.
public enum NotificationSemanticKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case taskFinished = "task_finished"
    case taskFailed = "task_failed"
    case permissionRequired = "permission_required"
    case waitingForInput = "waiting_for_input"
    case attentionRequired = "attention_required"
    case authenticationSucceeded = "authentication_succeeded"
    case idle
    case informational
    case unknown

    public var id: String {
        rawValue
    }

    /// Returns `true` for kinds that should generally be surfaced as active
    /// user attention events in the shared notification layer.
    public var isAttentionSeeking: Bool {
        switch self {
        case .taskFinished, .taskFailed, .permissionRequired, .waitingForInput, .attentionRequired:
            return true
        case .authenticationSucceeded, .idle, .informational, .unknown:
            return false
        }
    }
}

/// Provider-side event payload normalized into a transport-friendly shape.
///
/// Adapters should construct this from raw provider events and then map it into
/// `CanonicalNotificationEvent` or a drop/defer decision.
public struct NotificationProviderEvent: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let providerID: String
    public let providerName: String
    public let rawType: String?
    public let title: String?
    public let message: String
    public let notificationType: String?
    public let sessionID: String?
    public let tabID: UUID?
    public let directory: String?
    public let timestamp: Date
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        providerID: String,
        providerName: String,
        rawType: String? = nil,
        title: String? = nil,
        message: String,
        notificationType: String? = nil,
        sessionID: String? = nil,
        tabID: UUID? = nil,
        directory: String? = nil,
        timestamp: Date = Date(),
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.providerID = providerID
        self.providerName = providerName
        self.rawType = rawType
        self.title = title
        self.message = message
        self.notificationType = notificationType
        self.sessionID = sessionID
        self.tabID = tabID
        self.directory = directory
        self.timestamp = timestamp
        self.metadata = metadata
    }

    public func canonicalEvent(
        kind: NotificationSemanticKind,
        reliability: AIEventReliability = .heuristic
    ) -> CanonicalNotificationEvent {
        CanonicalNotificationEvent(
            id: id,
            kind: kind,
            providerID: providerID,
            providerName: providerName,
            rawType: rawType,
            title: title,
            message: message,
            notificationType: notificationType,
            sessionID: sessionID,
            tabID: tabID,
            directory: directory,
            timestamp: timestamp,
            reliability: reliability,
            metadata: metadata
        )
    }
}

/// Canonical semantic notification event emitted by a provider adapter.
///
/// The shared notification pipeline should consume this model rather than raw
/// provider event types.
public struct CanonicalNotificationEvent: Identifiable, Equatable, Codable, Sendable {
    public let id: UUID
    public let kind: NotificationSemanticKind
    public let providerID: String
    public let providerName: String
    public let rawType: String?
    public let title: String?
    public let message: String
    public let notificationType: String?
    public let sessionID: String?
    public let tabID: UUID?
    public let directory: String?
    public let timestamp: Date
    public let reliability: AIEventReliability
    public let metadata: [String: String]

    public init(
        id: UUID = UUID(),
        kind: NotificationSemanticKind,
        providerID: String,
        providerName: String,
        rawType: String? = nil,
        title: String? = nil,
        message: String,
        notificationType: String? = nil,
        sessionID: String? = nil,
        tabID: UUID? = nil,
        directory: String? = nil,
        timestamp: Date = Date(),
        reliability: AIEventReliability = .heuristic,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.kind = kind
        self.providerID = providerID
        self.providerName = providerName
        self.rawType = rawType
        self.title = title
        self.message = message
        self.notificationType = notificationType
        self.sessionID = sessionID
        self.tabID = tabID
        self.directory = directory
        self.timestamp = timestamp
        self.reliability = reliability
        self.metadata = metadata
    }

    public var isAttentionSeeking: Bool {
        kind.isAttentionSeeking
    }
}

/// Result of translating a provider event into the canonical semantic layer.
public enum NotificationProviderAdapterResult: Equatable, Sendable {
    case emit(CanonicalNotificationEvent)
    case drop(reason: String)
    case deferToFallback(reason: String)

    public var canonicalEvent: CanonicalNotificationEvent? {
        if case let .emit(event) = self {
            return event
        }
        return nil
    }

    public var reason: String? {
        switch self {
        case .emit:
            return nil
        case let .drop(reason), let .deferToFallback(reason):
            return reason
        }
    }
}

/// Adapter contract for provider-specific notification parsing.
public protocol NotificationProviderAdapter {
    var providerID: String { get }

    func adapt(_ event: NotificationProviderEvent) -> NotificationProviderAdapterResult
}
