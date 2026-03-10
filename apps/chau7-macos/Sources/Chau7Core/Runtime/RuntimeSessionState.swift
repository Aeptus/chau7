import Foundation

/// Pure state machine for agent runtime session lifecycle.
///
/// Follows the same pattern as `AIDetectionState`: pure struct, `private(set)` state,
/// mutation methods return Bool. Lives in Chau7Core so it can be unit-tested
/// without app dependencies.
public struct RuntimeSessionStateMachine: Sendable {

    /// Session lifecycle states.
    public enum State: String, Codable, Sendable {
        /// Tab created, backend launching.
        case starting
        /// Backend idle, can accept a prompt.
        case ready
        /// Processing a turn (agent responding, using tools).
        case busy
        /// Agent blocked on a permission request.
        case awaitingApproval
        /// Agent asked for user clarification.
        case waitingInput
        /// User sent Ctrl+C.
        case interrupted
        /// Unrecoverable error (crash, launch timeout).
        case failed
        /// Explicitly stopped or tab closed.
        case stopped
    }

    /// Events that drive state transitions.
    public enum Trigger: Sendable {
        case backendReady
        case turnSubmitted
        case turnCompleted
        case approvalNeeded
        case approvalResolved
        case inputRequested
        case inputProvided
        case interrupted
        case processCrashed(String)
        case tabClosed
        case launchTimeout
    }

    /// Current state of the session. Read-only externally.
    public private(set) var state: State = .starting

    public init() {}

    /// Apply a trigger to the state machine.
    /// Returns `true` if the transition was accepted, `false` if invalid.
    @discardableResult
    public mutating func handle(_ trigger: Trigger) -> Bool {
        guard let next = nextState(for: trigger) else { return false }
        state = next
        return true
    }

    /// Whether the session has reached a terminal state.
    public var isTerminal: Bool {
        state == .failed || state == .stopped
    }

    /// Whether the session can accept a new turn.
    public var canAcceptTurn: Bool {
        state == .ready
    }

    // MARK: - Transition Table

    private func nextState(for trigger: Trigger) -> State? {
        switch (state, trigger) {

        // starting
        case (.starting, .backendReady):       return .ready
        case (.starting, .launchTimeout):      return .failed
        case (.starting, .processCrashed):     return .failed
        case (.starting, .tabClosed):          return .stopped

        // ready
        case (.ready, .turnSubmitted):         return .busy
        case (.ready, .tabClosed):             return .stopped

        // busy
        case (.busy, .turnCompleted):          return .ready
        case (.busy, .approvalNeeded):         return .awaitingApproval
        case (.busy, .inputRequested):         return .waitingInput
        case (.busy, .interrupted):            return .interrupted
        case (.busy, .processCrashed):         return .failed
        case (.busy, .tabClosed):              return .stopped

        // awaitingApproval
        case (.awaitingApproval, .approvalResolved): return .busy
        case (.awaitingApproval, .interrupted):      return .interrupted
        case (.awaitingApproval, .tabClosed):        return .stopped

        // waitingInput
        case (.waitingInput, .inputProvided):  return .busy
        case (.waitingInput, .tabClosed):      return .stopped

        // interrupted
        case (.interrupted, .backendReady):    return .ready
        case (.interrupted, .processCrashed):  return .failed
        case (.interrupted, .tabClosed):       return .stopped

        // Terminal states accept nothing
        case (.failed, _), (.stopped, _):
            return nil

        default:
            return nil
        }
    }
}
