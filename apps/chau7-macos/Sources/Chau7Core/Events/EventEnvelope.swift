import Foundation

/// A structural (non-AI) event recorded on the spine: tab lifecycle,
/// telemetry run transitions, approval state, timer changes, and other
/// app-internal facts that observers care about.
///
/// Field names mirror the observability surface so envelopes can be
/// projected into MCP change payloads without re-mapping.
public struct StructuralEvent: Equatable, Sendable {
    public let type: String
    public let subsystem: String
    public let tabID: String?
    public let sessionID: String?
    public let runID: String?
    public let repoPath: String?
    public let detail: [String: JSONValue]

    public init(
        type: String,
        subsystem: String,
        tabID: String? = nil,
        sessionID: String? = nil,
        runID: String? = nil,
        repoPath: String? = nil,
        detail: [String: JSONValue] = [:]
    ) {
        self.type = type
        self.subsystem = subsystem
        self.tabID = tabID
        self.sessionID = sessionID
        self.runID = runID
        self.repoPath = repoPath
        self.detail = detail
    }
}

/// The payload carried by an `EventEnvelope`.
public enum EventPayload: Equatable, Sendable {
    /// A tool-agnostic AI event (the existing canonical event shape).
    case ai(AIEvent)
    /// A structural app event (tabs, telemetry runs, approvals, timers…).
    case structural(StructuralEvent)
}

/// The canonical spine record: one envelope per ingested event, in one
/// global sequence space.
///
/// Invariants:
/// - `seq` is globally monotonic and dense, allocated by `EventSpine.ingest`
///   under a lock. Total order across all producers == seq order.
/// - `eventID` is stable end-to-end: for `.ai` payloads it is `AIEvent.id`,
///   so the same logical event keeps one identity across every projection.
/// - `occurredAt` is the producer's event time (parsed from the payload);
///   `ingestedAt` is when the spine accepted it. Journals and projections
///   must never overwrite `occurredAt` with insertion time.
/// - `topics` are assigned once at ingest via `EventTopicCatalog`, so every
///   downstream surface agrees on topic membership.
public struct EventEnvelope: Equatable, Sendable {
    public let seq: UInt64
    public let eventID: UUID
    public let correlationID: String?
    public let occurredAt: Date
    public let ingestedAt: Date
    public let topics: [String]
    /// Producer intent: whether user-facing notification delivery was
    /// requested for this event. The notification pipeline still applies its
    /// own gating; `false` means the producer explicitly asked for a silent
    /// record (e.g. API proxy calls).
    public let deliveryRequested: Bool
    public let payload: EventPayload

    public init(
        seq: UInt64,
        eventID: UUID,
        correlationID: String?,
        occurredAt: Date,
        ingestedAt: Date,
        topics: [String],
        deliveryRequested: Bool = true,
        payload: EventPayload
    ) {
        self.seq = seq
        self.eventID = eventID
        self.correlationID = correlationID
        self.occurredAt = occurredAt
        self.ingestedAt = ingestedAt
        self.topics = topics
        self.deliveryRequested = deliveryRequested
        self.payload = payload
    }

    /// The AI event carried by this envelope, if any.
    public var aiEvent: AIEvent? {
        if case let .ai(event) = payload { return event }
        return nil
    }

    /// The structural event carried by this envelope, if any.
    public var structuralEvent: StructuralEvent? {
        if case let .structural(event) = payload { return event }
        return nil
    }
}
