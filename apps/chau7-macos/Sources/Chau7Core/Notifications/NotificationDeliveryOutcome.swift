import Foundation

/// Stable, platform-neutral projection of one notification delivery-ledger
/// transition. AppKit delivery code produces it; observability and tests
/// consume it without depending on `NotificationHistory` internals.
public struct NotificationDeliveryOutcome: Equatable, Sendable {
    public let eventID: UUID
    public let source: String
    public let eventType: String
    public let rawType: String?
    public let semanticKind: String?
    public let reliability: String
    public let producer: String?
    public let deliveryState: String
    public let triggerID: String?
    public let actionsExecuted: [String]
    public let wasRateLimited: Bool
    public let dropReason: String?
    public let resolutionMethod: String?
    public let resolvedTabID: String?
    public let didDispatchBanner: Bool
    public let didStyleTab: Bool
    public let notes: [String]
    public let classificationConfidence: String?
    public let classificationEvidence: [String]

    public init(
        eventID: UUID,
        source: String,
        eventType: String,
        rawType: String? = nil,
        semanticKind: String? = nil,
        reliability: String,
        producer: String? = nil,
        deliveryState: String,
        triggerID: String? = nil,
        actionsExecuted: [String] = [],
        wasRateLimited: Bool = false,
        dropReason: String? = nil,
        resolutionMethod: String? = nil,
        resolvedTabID: String? = nil,
        didDispatchBanner: Bool = false,
        didStyleTab: Bool = false,
        notes: [String] = [],
        classificationConfidence: String? = nil,
        classificationEvidence: [String] = []
    ) {
        self.eventID = eventID
        self.source = source
        self.eventType = eventType
        self.rawType = rawType
        self.semanticKind = semanticKind
        self.reliability = reliability
        self.producer = producer
        self.deliveryState = deliveryState
        self.triggerID = triggerID
        self.actionsExecuted = actionsExecuted
        self.wasRateLimited = wasRateLimited
        self.dropReason = dropReason
        self.resolutionMethod = resolutionMethod
        self.resolvedTabID = resolvedTabID
        self.didDispatchBanner = didDispatchBanner
        self.didStyleTab = didStyleTab
        self.notes = notes
        self.classificationConfidence = classificationConfidence
        self.classificationEvidence = classificationEvidence
    }
}
