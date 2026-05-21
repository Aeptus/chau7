import Foundation

/// Canonical notification event engine.
///
/// This is the single abstraction boundary between raw `AIEvent` producers and
/// user-facing notification delivery. It normalizes provider-specific payloads,
/// observes lifecycle events that are not themselves notifiable, reconciles
/// duplicate session states, and emits a delivery intent only when the event
/// should continue into the platform/UI delivery layer.
public final class AIEventNotificationEngine {
    public enum DropStage: String, Codable, Sendable {
        case ingress
        case reconciliation
    }

    public struct Drop: Equatable, Sendable {
        public let stage: DropStage
        public let reason: String
        public let eventID: UUID
        public let acceptedEvent: NotificationIngress.AcceptedEvent?
        public let rawObservationNote: String?

        public init(
            stage: DropStage,
            reason: String,
            eventID: UUID,
            acceptedEvent: NotificationIngress.AcceptedEvent? = nil,
            rawObservationNote: String? = nil
        ) {
            self.stage = stage
            self.reason = reason
            self.eventID = eventID
            self.acceptedEvent = acceptedEvent
            self.rawObservationNote = rawObservationNote
        }
    }

    public struct DeliveryIntent: Equatable, Sendable {
        public let acceptedEvent: NotificationIngress.AcceptedEvent

        public init(acceptedEvent: NotificationIngress.AcceptedEvent) {
            self.acceptedEvent = acceptedEvent
        }

        public var event: AIEvent {
            acceptedEvent.sharedEvent
        }
    }

    public enum DeliveryDecision: Equatable, Sendable {
        case disabled
        case deliver(DeliveryIntent)
        case dropped(Drop)
    }

    public struct Accepted: Equatable, Sendable {
        public let acceptedEvent: NotificationIngress.AcceptedEvent
        public let delivery: DeliveryDecision
        public let rawObservationNote: String?

        public init(
            acceptedEvent: NotificationIngress.AcceptedEvent,
            delivery: DeliveryDecision,
            rawObservationNote: String?
        ) {
            self.acceptedEvent = acceptedEvent
            self.delivery = delivery
            self.rawObservationNote = rawObservationNote
        }
    }

    public enum Outcome: Equatable, Sendable {
        case accepted(Accepted)
        case dropped(Drop)
    }

    private let sessionReconciler: AISessionEventReconciler

    public init(sessionReconciler: AISessionEventReconciler = AISessionEventReconciler()) {
        self.sessionReconciler = sessionReconciler
    }

    public func reset() {
        sessionReconciler.reset()
    }

    public func process(
        _ event: AIEvent,
        deliveryRequested: Bool,
        now: Date = Date()
    ) -> Outcome {
        let rawObservationNote = sessionReconciler.observeRawEvent(event, now: now)

        switch NotificationIngress.ingest(event) {
        case .drop(let reason):
            return .dropped(
                Drop(
                    stage: .ingress,
                    reason: reason,
                    eventID: event.id,
                    rawObservationNote: rawObservationNote
                )
            )

        case .accept(let accepted):
            let reconciliation = sessionReconciler.reconcile(accepted, now: now)
            let delivery: DeliveryDecision

            if deliveryRequested {
                switch reconciliation {
                case .emit(let reconciled):
                    delivery = .deliver(DeliveryIntent(acceptedEvent: reconciled))
                case .drop(let reason):
                    delivery = .dropped(
                        Drop(
                            stage: .reconciliation,
                            reason: reason,
                            eventID: accepted.sharedEvent.id,
                            acceptedEvent: accepted,
                            rawObservationNote: rawObservationNote
                        )
                    )
                }
            } else {
                delivery = .disabled
            }

            return .accepted(
                Accepted(
                    acceptedEvent: accepted,
                    delivery: delivery,
                    rawObservationNote: rawObservationNote
                )
            )
        }
    }
}
