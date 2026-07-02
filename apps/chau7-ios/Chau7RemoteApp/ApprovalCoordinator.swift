import Foundation

/// The approval-response ledger: which responses the user has queued, which
/// are in flight on the socket, and what to do with each send outcome.
///
/// Extracted from `RemoteClient` (C7): the bookkeeping that prevents
/// double-sends, requeues failed deliveries, and detects superseded answers
/// is a pure state machine here; the client owns the side effects (UI
/// response states, connect-to-send, keepalive, notification teardown).
@MainActor
final class ApprovalCoordinator {

    enum SendOutcome: Equatable {
        /// Delivered and still the user's current answer — complete it.
        case completed(approved: Bool)
        /// Delivery failed and the answer is still current — requeue.
        case requeue(approved: Bool)
        /// The user changed (or cleared) the answer while the send was in
        /// flight — drop this outcome on the floor.
        case superseded
    }

    private(set) var queuedResponses: [String: Bool] = [:]
    private var inFlight: Set<String> = []

    var hasQueuedResponses: Bool {
        !queuedResponses.isEmpty
    }

    /// Record the user's answer for a request. Overwrites a previously
    /// queued answer (the newest wins).
    func queue(requestID: String, approved: Bool) {
        queuedResponses[requestID] = approved
    }

    /// Responses eligible to send right now: queued, not already in flight.
    /// Marks them in flight. `isStillPending` filters out requests that no
    /// longer exist (resolved elsewhere) — those are forgotten.
    func takeSendable(isStillPending: (String) -> Bool) -> [(requestID: String, approved: Bool)] {
        var sendable: [(String, Bool)] = []
        for (requestID, approved) in queuedResponses {
            guard !inFlight.contains(requestID) else { continue }
            guard isStillPending(requestID) else {
                queuedResponses.removeValue(forKey: requestID)
                continue
            }
            inFlight.insert(requestID)
            sendable.append((requestID, approved))
        }
        return sendable
    }

    /// Resolve a send completion for the answer that was sent.
    func resolveSend(requestID: String, approved: Bool, success: Bool) -> SendOutcome {
        inFlight.remove(requestID)
        guard queuedResponses[requestID] == approved else {
            return .superseded
        }
        if success {
            queuedResponses.removeValue(forKey: requestID)
            return .completed(approved: approved)
        }
        return .requeue(approved: approved)
    }

    /// Drop a request entirely (it was resolved through another path).
    func forget(requestID: String) {
        queuedResponses.removeValue(forKey: requestID)
        inFlight.remove(requestID)
    }

    func reset() {
        queuedResponses.removeAll(keepingCapacity: true)
        inFlight.removeAll(keepingCapacity: true)
    }
}
