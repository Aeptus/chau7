import Foundation

public enum NotificationIngress {
    public enum Decision: Equatable, Sendable {
        case accept(EnrichedEvent)
        case drop(reason: String)
    }

    public static func ingest(_ event: AIEvent) -> Decision {
        switch NotificationProviderAdapterRegistry.adapt(event) {
        case .drop(let reason):
            return .drop(reason: reason)
        case .emit(let enriched):
            return .accept(enriched)
        }
    }
}
