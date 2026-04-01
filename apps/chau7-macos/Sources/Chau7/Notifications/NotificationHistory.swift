import Foundation
import Chau7Core

/// In-memory delivery ledger for notification events.
/// Tracks ingestion, routing, decision, and output execution so failures are explainable.
@MainActor
final class NotificationHistory {

    enum DeliveryState: String, Codable {
        case ingested
        case coalesced
        case retryScheduled
        case prepared
        case dropped
        case rateLimited
        case actionsExecuted
        case completed
    }

    struct Entry: Identifiable, Codable {
        let id: UUID
        let source: String
        let type: String
        let rawType: String?
        var semanticKind: String?
        let tool: String
        let message: String
        let notificationType: String?
        let timestamp: Date
        let reliability: String
        let producer: String?
        var triggerId: String?
        var actionsExecuted: [String]
        var wasRateLimited: Bool
        var deliveryState: String
        var dropReason: String?
        var resolutionMethod: String?
        var resolvedTabID: String?
        var didDispatchBanner: Bool
        var didStyleTab: Bool
        var notes: [String]
    }

    private var entriesByID: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private let maxEntries: Int

    init(maxEntries: Int = 100) {
        self.maxEntries = maxEntries
    }

    func begin(
        event: AIEvent,
        semanticKind: String? = nil,
        rawType: String? = nil,
        notificationType: String? = nil
    ) {
        let effectiveRawType = rawType ?? event.rawType
        var notes: [String] = []
        if let effectiveRawType, effectiveRawType != event.type {
            notes.append("rawType:\(effectiveRawType)")
        }
        if let notificationType {
            notes.append("notificationType:\(notificationType)")
        }
        let entry = Entry(
            id: event.id,
            source: event.source.rawValue,
            type: event.type,
            rawType: effectiveRawType,
            semanticKind: semanticKind,
            tool: event.tool,
            message: event.message,
            notificationType: event.notificationType,
            timestamp: Date(),
            reliability: event.reliability.rawValue,
            producer: event.producer,
            triggerId: nil,
            actionsExecuted: [],
            wasRateLimited: false,
            deliveryState: DeliveryState.ingested.rawValue,
            dropReason: nil,
            resolutionMethod: nil,
            resolvedTabID: event.tabID?.uuidString,
            didDispatchBanner: false,
            didStyleTab: false,
            notes: notes
        )
        store(entry)
    }

    func markCanonicalized(eventID: UUID, semanticKind: String, rawType: String?, notificationType: String?) {
        update(eventID) { entry in
            entry.semanticKind = semanticKind
            if let rawType {
                entry.notes.append("rawType:\(rawType)")
            }
            if let notificationType {
                entry.notes.append("notificationType:\(notificationType)")
            }
        }
    }

    func markCoalesced(eventID: UUID, key: String) {
        update(eventID) { entry in
            entry.deliveryState = DeliveryState.coalesced.rawValue
            entry.notes.append("coalesced:\(key)")
        }
    }

    func markRetryScheduled(eventID: UUID, attempt: Int, reason: String) {
        update(eventID) { entry in
            entry.deliveryState = DeliveryState.retryScheduled.rawValue
            entry.dropReason = nil
            entry.notes.append("retry#\(attempt):\(reason)")
        }
    }

    func markPrepared(event: AIEvent, resolutionMethod: String) {
        update(event.id) { entry in
            entry.deliveryState = DeliveryState.prepared.rawValue
            entry.resolutionMethod = resolutionMethod
            entry.resolvedTabID = event.tabID?.uuidString
        }
    }

    func markDropped(eventID: UUID, triggerId: String? = nil, reason: String) {
        update(eventID) { entry in
            entry.deliveryState = DeliveryState.dropped.rawValue
            entry.triggerId = triggerId ?? entry.triggerId
            entry.dropReason = reason
        }
    }

    func markRateLimited(eventID: UUID, triggerId: String) {
        update(eventID) { entry in
            entry.deliveryState = DeliveryState.rateLimited.rawValue
            entry.triggerId = triggerId
            entry.wasRateLimited = true
        }
    }

    func markActionsExecuted(
        eventID: UUID,
        triggerId: String?,
        actionsExecuted: [String],
        didDispatchBanner: Bool,
        didStyleTab: Bool
    ) {
        update(eventID) { entry in
            entry.deliveryState = DeliveryState.actionsExecuted.rawValue
            entry.triggerId = triggerId ?? entry.triggerId
            entry.actionsExecuted = actionsExecuted
            entry.didDispatchBanner = entry.didDispatchBanner || didDispatchBanner
            entry.didStyleTab = entry.didStyleTab || didStyleTab
            entry.dropReason = nil
        }
    }

    func markCompleted(eventID: UUID) {
        update(eventID) { entry in
            entry.deliveryState = DeliveryState.completed.rawValue
        }
    }

    func appendNote(eventID: UUID, note: String) {
        update(eventID) { entry in
            entry.notes.append(note)
        }
    }

    func recent(limit: Int = 50) -> [Entry] {
        Array(order.suffix(limit).reversed()).compactMap { entriesByID[$0] }
    }

    func clear() {
        entriesByID.removeAll()
        order.removeAll()
    }

    var count: Int {
        entriesByID.count
    }

    private func store(_ entry: Entry) {
        if entriesByID[entry.id] == nil {
            if order.count >= maxEntries, let oldest = order.first {
                order.removeFirst()
                entriesByID.removeValue(forKey: oldest)
            }
            order.append(entry.id)
        }
        entriesByID[entry.id] = entry
    }

    private func update(_ eventID: UUID, mutate: (inout Entry) -> Void) {
        guard var entry = entriesByID[eventID] else {
            return
        }
        mutate(&entry)
        entriesByID[eventID] = entry
    }
}
