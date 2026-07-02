import Foundation

/// Canonical semantic categories for user-facing AI notification events.
///
/// Provider-specific adapters translate raw tool events and hook payloads
/// into one of these kinds before the shared notification layer makes
/// delivery decisions.
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

/// The shared trigger type an emitted semantic kind maps to, used to match
/// events against `NotificationTriggerCatalog` entries.
///
/// This enum is the compile-time bridge between the adapter layer and the
/// trigger catalog: adding a `NotificationSemanticKind` case fails to compile
/// here until the mapping is decided, and `NotificationTriggerCatalogTests`
/// asserts every reachable (source, trigger-type) pair has a deliberate
/// catalog entry (or an explicit wildcard allowlisting).
public enum SemanticTriggerType: String, CaseIterable, Sendable {
    case finished
    case failed
    case permission
    case waitingInput = "waiting_input"
    case attentionRequired = "attention_required"
    case authenticationSucceeded = "authentication_succeeded"
    case info
    case idle

    /// Nil for `.unknown` — adapters never emit unknown kinds (they drop).
    public init?(kind: NotificationSemanticKind) {
        switch kind {
        case .taskFinished:
            self = .finished
        case .taskFailed:
            self = .failed
        case .permissionRequired:
            self = .permission
        case .waitingForInput:
            self = .waitingInput
        case .attentionRequired:
            self = .attentionRequired
        case .authenticationSucceeded:
            self = .authenticationSucceeded
        case .informational:
            self = .info
        case .idle:
            self = .idle
        case .unknown:
            return nil
        }
    }
}

/// An `AIEvent` annotated with its semantic kind by the adapter layer.
///
/// This replaces the previous three-shape chain
/// (AIEvent → NotificationProviderEvent → CanonicalNotificationEvent → AIEvent)
/// with zero conversions: adapters normalize the event in place (type/raw-type
/// rewrite, reliability adjustment) and attach the derived kind alongside.
/// The kind travels separately from the event because it is derived, not
/// producer-supplied — producers cannot lie about semantics.
public struct EnrichedEvent: Equatable, Sendable {
    public let event: AIEvent
    public let kind: NotificationSemanticKind

    public init(event: AIEvent, kind: NotificationSemanticKind) {
        self.event = event
        self.kind = kind
    }

    public var isAttentionSeeking: Bool {
        kind.isAttentionSeeking
    }
}
