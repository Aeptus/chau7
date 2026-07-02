import Foundation

/// Global journal of spine envelopes: the complete, ordered, replayable
/// record of every ingested event (pre-acceptance — projections may still
/// veto delivery downstream, but the audit record is always here).
public final class GlobalEventJournal: @unchecked Sendable {
    private let ring: RingJournal<EventEnvelope>

    public init(capacity: Int = 2000) {
        self.ring = RingJournal(capacity: capacity)
    }

    @discardableResult
    func append(_ make: (UInt64) -> EventEnvelope) -> EventEnvelope {
        ring.append(make)
    }

    /// Read envelopes after the given cursor (exclusive), oldest first.
    public func envelopes(after cursor: UInt64, limit: Int = 100) -> (envelopes: [EventEnvelope], cursor: UInt64, hasMore: Bool) {
        let result = ring.entries(after: cursor, limit: limit)
        return (result.elements, result.cursor, result.hasMore)
    }

    /// The seq of the most recent envelope (0 if empty).
    public var latestCursor: UInt64 { ring.latestCursor }

    /// The oldest available seq (0 if empty, 1 if not yet wrapped).
    public var oldestAvailableCursor: UInt64 { ring.oldestAvailableCursor }

    /// Current number of retained envelopes.
    public var count: Int { ring.count }
}

/// The single ingest funnel for all Chau7 events.
///
/// Every producer — runtime sessions, Claude hooks, the API proxy, shell
/// detectors, app emitters, MCP approvals, telemetry — calls `ingest(...)`
/// synchronously from any thread. The spine:
///
/// 1. allocates the **global monotonic seq** (total order fixed here),
/// 2. stamps `ingestedAt` while preserving the producer's `occurredAt`,
/// 3. derives `topics` once via `EventTopicCatalog`,
/// 4. appends to the `GlobalEventJournal` (complete audit/replay record),
/// 5. yields to the envelope stream, in seq order, for the single pump
///    (`EventSpineHost` app-side) to fan out to projections.
///
/// Determinism comes from seq-at-ingest plus a single stream consumer —
/// deliberately not an actor, because today's producers are synchronous
/// (DispatchQueue callbacks, NSLock'd managers) and cannot `await`.
public final class EventSpine: @unchecked Sendable {

    public let journal: GlobalEventJournal

    /// Ordered stream of ingested envelopes. Single-consumer: exactly one
    /// pump task must iterate this stream (multiple consumers would split
    /// the sequence between them).
    public let envelopes: AsyncStream<EventEnvelope>

    private let continuation: AsyncStream<EventEnvelope>.Continuation
    /// Serializes seq allocation *and* stream yield so stream order always
    /// equals seq order, even under concurrent producers.
    private let lock = NSLock()

    public init(capacity: Int = 2000) {
        self.journal = GlobalEventJournal(capacity: capacity)
        (self.envelopes, self.continuation) = AsyncStream.makeStream(
            of: EventEnvelope.self,
            bufferingPolicy: .unbounded
        )
    }

    /// Ingest an AI event. `occurredAt` is parsed from the event's `ts`
    /// (falling back to ingest time if unparseable); identity is the event's
    /// own `id`, so the same logical event keeps one identity everywhere.
    /// `deliveryRequested` carries the producer's notify intent to the pump.
    @discardableResult
    public func ingest(
        _ event: AIEvent,
        correlationID: String? = nil,
        deliveryRequested: Bool = true
    ) -> EventEnvelope {
        let ingestedAt = Date()
        let occurredAt = DateFormatters.parseISO8601(event.ts) ?? ingestedAt
        return ingestEnvelope(
            eventID: event.id,
            correlationID: correlationID,
            occurredAt: occurredAt,
            ingestedAt: ingestedAt,
            deliveryRequested: deliveryRequested,
            payload: .ai(event)
        )
    }

    /// Ingest a structural event. Pass `occurredAt` when the producer knows
    /// the true event time; it defaults to ingest time.
    @discardableResult
    public func ingest(
        structural event: StructuralEvent,
        correlationID: String? = nil,
        eventID: UUID = UUID(),
        occurredAt: Date? = nil
    ) -> EventEnvelope {
        let ingestedAt = Date()
        return ingestEnvelope(
            eventID: eventID,
            correlationID: correlationID,
            occurredAt: occurredAt ?? ingestedAt,
            ingestedAt: ingestedAt,
            deliveryRequested: false,
            payload: .structural(event)
        )
    }

    /// Ends the envelope stream. Test hook; the app-lifetime spine never
    /// finishes its stream.
    public func finish() {
        continuation.finish()
    }

    // MARK: - Private

    private func ingestEnvelope(
        eventID: UUID,
        correlationID: String?,
        occurredAt: Date,
        ingestedAt: Date,
        deliveryRequested: Bool,
        payload: EventPayload
    ) -> EventEnvelope {
        let topics = EventTopicCatalog.topics(for: payload)
        lock.lock()
        defer { lock.unlock() }
        let envelope = journal.append { seq in
            EventEnvelope(
                seq: seq,
                eventID: eventID,
                correlationID: correlationID,
                occurredAt: occurredAt,
                ingestedAt: ingestedAt,
                topics: topics,
                deliveryRequested: deliveryRequested,
                payload: payload
            )
        }
        continuation.yield(envelope)
        return envelope
    }
}
