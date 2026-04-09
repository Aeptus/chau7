import Foundation

/// In-memory ring buffer of runtime events for a session.
///
/// Thread-safe via `NSLock` (same pattern as `TelemetryRecorder`).
/// Supports cursor-based reads so orchestrators can poll efficiently.
public final class EventJournal: @unchecked Sendable {

    /// Maximum events retained. Oldest events are evicted when full.
    private let capacity: Int

    /// Ring buffer storage.
    private var buffer: [RuntimeEvent]
    /// Write position in the ring buffer.
    private var writeIndex = 0
    /// Total events ever appended (monotonic). Used as the cursor space.
    private var totalAppended: UInt64 = 0
    /// Whether the buffer has wrapped around at least once.
    private var wrapped = false
    private let lock = NSLock()

    public init(capacity: Int = 1000) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.buffer = []
        buffer.reserveCapacity(capacity)
    }

    /// Append a new event. Returns the created event with its sequence number.
    @discardableResult
    public func append(sessionID: String, turnID: String?, type: String, data: [String: String] = [:]) -> RuntimeEvent {
        lock.lock()
        totalAppended += 1
        let event = RuntimeEvent(
            seq: totalAppended,
            sessionID: sessionID,
            turnID: turnID,
            timestamp: Date(),
            type: type,
            data: data
        )

        if buffer.count < capacity {
            buffer.append(event)
        } else {
            buffer[writeIndex] = event
            wrapped = true
        }
        writeIndex = (writeIndex + 1) % capacity
        lock.unlock()

        return event
    }

    /// Read events after the given cursor (exclusive).
    ///
    /// Returns a tuple of:
    /// - `events`: Events with seq > cursor, up to `limit`.
    /// - `cursor`: The new cursor (seq of the last returned event, or input cursor if none).
    /// - `hasMore`: Whether more events exist beyond the returned batch.
    ///
    /// If the cursor is too old (events evicted), returns events from the oldest available.
    public func events(after cursor: UInt64, limit: Int = 100) -> (events: [RuntimeEvent], cursor: UInt64, hasMore: Bool) {
        lock.lock()
        defer { lock.unlock() }

        guard !buffer.isEmpty else {
            return ([], cursor, false)
        }

        let oldest = oldestSeq
        let newest = totalAppended

        // Nothing new
        guard cursor < newest else {
            return ([], cursor, false)
        }

        // Determine effective start
        let effectiveStart = max(cursor, oldest - 1) // -1 because we want seq > cursor

        var result: [RuntimeEvent] = []
        let count = buffer.count
        result.reserveCapacity(min(limit, count))

        // Iterate through the buffer in chronological order
        let startReadIndex: Int
        if wrapped {
            startReadIndex = writeIndex // oldest element in a wrapped buffer
        } else {
            startReadIndex = 0
        }

        for i in 0 ..< count {
            let idx = (startReadIndex + i) % count
            let event = buffer[idx]
            if event.seq > effectiveStart {
                result.append(event)
                if result.count >= limit {
                    let hasMore = (i + 1) < count
                    let newCursor = result.last?.seq ?? cursor
                    return (result, newCursor, hasMore)
                }
            }
        }

        let newCursor = result.last?.seq ?? cursor
        return (result, newCursor, false)
    }

    /// The sequence number of the most recent event (0 if empty).
    public var latestCursor: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return totalAppended
    }

    /// The oldest available sequence number (1 if not yet wrapped).
    public var oldestAvailableCursor: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return oldestSeq
    }

    /// Current number of events in the buffer.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    // MARK: - Private

    /// Oldest seq in the buffer. Caller must hold lock.
    private var oldestSeq: UInt64 {
        guard !buffer.isEmpty else { return 0 }
        if wrapped {
            return buffer[writeIndex % capacity].seq
        } else {
            return buffer[0].seq
        }
    }
}
