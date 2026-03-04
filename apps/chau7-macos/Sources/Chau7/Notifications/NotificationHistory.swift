import Foundation
import Chau7Core

/// In-memory ring buffer of fired notification events for audit/debugging.
/// All access is `@MainActor`-isolated since the notification pipeline runs on main.
@MainActor
final class NotificationHistory {

    struct Entry: Identifiable, Codable, Sendable {
        let id: UUID
        let triggerId: String
        let source: String
        let type: String
        let tool: String
        let message: String
        let timestamp: Date
        let actionsExecuted: [String]
        let wasRateLimited: Bool
    }

    private var entries: [Entry] = []
    private let maxEntries: Int

    init(maxEntries: Int = 100) {
        self.maxEntries = maxEntries
    }

    /// Record a notification event. Drops the oldest entry when full.
    func record(_ entry: Entry) {
        if entries.count >= maxEntries {
            entries.removeFirst()
        }
        entries.append(entry)
    }

    /// Convenience: record from an AIEvent and metadata.
    func record(
        event: AIEvent,
        triggerId: String,
        actionsExecuted: [String],
        wasRateLimited: Bool
    ) {
        let entry = Entry(
            id: event.id,
            triggerId: triggerId,
            source: event.source.rawValue,
            type: event.type,
            tool: event.tool,
            message: event.message,
            timestamp: Date(),
            actionsExecuted: actionsExecuted,
            wasRateLimited: wasRateLimited
        )
        record(entry)
    }

    /// Return the most recent entries (newest first).
    func recent(limit: Int = 50) -> [Entry] {
        Array(entries.suffix(limit).reversed())
    }

    /// Clear all history.
    func clear() {
        entries.removeAll()
    }

    /// Total entries currently held.
    var count: Int { entries.count }
}
