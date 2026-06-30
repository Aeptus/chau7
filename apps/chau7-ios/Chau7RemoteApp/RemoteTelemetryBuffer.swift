import Foundation
import Chau7Core

/// Bounded FIFO buffer for telemetry events recorded before the encrypted
/// session is ready.
///
/// Extracted from `RemoteClient` so the capacity/eviction policy lives in one
/// testable value type. The client owns the actual send; this type only retains
/// events until they can be flushed.
struct RemoteTelemetryBuffer {
    private var events: [RemoteClientTelemetryEvent] = []
    private let maxEvents: Int

    init(maxEvents: Int) {
        self.maxEvents = maxEvents
    }

    var isEmpty: Bool {
        events.isEmpty
    }

    mutating func append(_ event: RemoteClientTelemetryEvent) {
        events.append(event)
        if events.count > maxEvents {
            events.removeFirst(events.count - maxEvents)
        }
    }

    /// Returns the buffered events and clears the buffer.
    mutating func drain() -> [RemoteClientTelemetryEvent] {
        defer { events.removeAll(keepingCapacity: true) }
        return events
    }

    mutating func removeAll() {
        events.removeAll(keepingCapacity: true)
    }
}
