import Foundation

/// In-memory ring buffer of runtime events for a session.
///
/// A thin per-session wrapper over `RingJournal`, which owns the ring/cursor
/// mechanics (monotonic seq surviving eviction, cursor-based reads). The
/// sequence space is **per-journal** (i.e. per-session); the global spine
/// sequence lives in `GlobalEventJournal`.
public final class EventJournal: @unchecked Sendable {

    private let ring: RingJournal<RuntimeEvent>

    public init(capacity: Int = 1000) {
        self.ring = RingJournal(capacity: capacity)
    }

    /// Append a new event. Returns the created event with its sequence number.
    @discardableResult
    public func append(
        sessionID: String,
        turnID: String?,
        type: String,
        correlationID: String? = nil,
        data: [String: String] = [:]
    ) -> RuntimeEvent {
        ring.append { seq in
            RuntimeEvent(
                seq: seq,
                sessionID: sessionID,
                turnID: turnID,
                correlationID: correlationID,
                timestamp: Date(),
                type: type,
                data: data
            )
        }
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
        let result = ring.entries(after: cursor, limit: limit)
        return (result.elements, result.cursor, result.hasMore)
    }

    /// The sequence number of the most recent event (0 if empty).
    public var latestCursor: UInt64 {
        ring.latestCursor
    }

    /// The oldest available sequence number (1 if not yet wrapped).
    public var oldestAvailableCursor: UInt64 {
        ring.oldestAvailableCursor
    }

    /// Current number of events in the buffer.
    public var count: Int {
        ring.count
    }

    /// Returns all currently retained events for a given turn in chronological order.
    public func events(forTurn turnID: String) -> [RuntimeEvent] {
        ring.elements { $0.turnID == turnID }
    }
}
