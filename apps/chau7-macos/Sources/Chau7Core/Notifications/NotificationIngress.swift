import Foundation

public enum NotificationIngress {
    public struct AcceptedEvent: Equatable, Sendable {
        public let sharedEvent: AIEvent
        public let canonicalEvent: CanonicalNotificationEvent?

        public init(sharedEvent: AIEvent, canonicalEvent: CanonicalNotificationEvent?) {
            self.sharedEvent = sharedEvent
            self.canonicalEvent = canonicalEvent
        }
    }

    public enum Decision: Equatable, Sendable {
        case accept(AcceptedEvent)
        case drop(reason: String)
    }

    public static func ingest(_ event: AIEvent) -> Decision {
        switch NotificationProviderAdapterRegistry.adapt(event) {
        case .drop(let reason):
            return .drop(reason: reason)
        case .passThrough(let adapted):
            return .accept(AcceptedEvent(sharedEvent: adapted, canonicalEvent: nil))
        case .emit(let adapted, let canonical):
            return .accept(AcceptedEvent(sharedEvent: adapted, canonicalEvent: canonical))
        }
    }
}
