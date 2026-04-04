import Foundation

/// A structured event from the agent runtime.
///
/// Events are journaled per-session and consumed by orchestrators via
/// cursor-based polling (`runtime_events_poll`).
public struct RuntimeEvent: Codable, Sendable {
    /// Monotonically increasing sequence number (unique within a journal).
    public let seq: UInt64
    /// Runtime session that produced this event.
    public let sessionID: String
    /// Turn within the session (nil for session-level events).
    public let turnID: String?
    /// When the event occurred.
    public let timestamp: Date
    /// Event category. Uses the `RuntimeEventType` constants.
    public let type: String
    /// Arbitrary key-value payload (tool name, summary, token count, etc.)
    public let data: [String: String]

    public init(seq: UInt64, sessionID: String, turnID: String?, timestamp: Date, type: String, data: [String: String]) {
        self.seq = seq
        self.sessionID = sessionID
        self.turnID = turnID
        self.timestamp = timestamp
        self.type = type
        self.data = data
    }
}

/// Well-known event type constants.
/// Uses the RawRepresentable struct pattern (like `AIEventSource`) for extensibility.
public struct RuntimeEventType: RawRepresentable, Equatable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    // Session lifecycle
    public static let sessionStarting = RuntimeEventType(rawValue: "session_starting")
    public static let sessionReady = RuntimeEventType(rawValue: "session_ready")
    public static let sessionStopped = RuntimeEventType(rawValue: "session_stopped")
    public static let sessionError = RuntimeEventType(rawValue: "session_error")
    public static let stateChanged = RuntimeEventType(rawValue: "state_changed")

    // Turn lifecycle
    public static let turnStarted = RuntimeEventType(rawValue: "turn_started")
    public static let turnCompleted = RuntimeEventType(rawValue: "turn_completed")
    public static let turnFailed = RuntimeEventType(rawValue: "turn_failed")
    public static let turnResult = RuntimeEventType(rawValue: "turn_result")

    // Agent activity
    public static let agentResponding = RuntimeEventType(rawValue: "agent_responding")
    public static let notification = RuntimeEventType(rawValue: "notification")
    public static let toolUse = RuntimeEventType(rawValue: "tool_use")
    public static let toolResult = RuntimeEventType(rawValue: "tool_result")
    public static let outputChunk = RuntimeEventType(rawValue: "output_chunk")

    // Approval
    public static let approvalNeeded = RuntimeEventType(rawValue: "approval_needed")
    public static let approvalResolved = RuntimeEventType(rawValue: "approval_resolved")

    /// Stall detection
    public static let stallDetected = RuntimeEventType(rawValue: "stall_detected")

    // Turn enrichment
    public static let tokenThreshold = RuntimeEventType(rawValue: "token_threshold")
    public static let costThreshold = RuntimeEventType(rawValue: "cost_threshold")
    public static let exitClassified = RuntimeEventType(rawValue: "exit_classified")
    public static let policyBlocked = RuntimeEventType(rawValue: "policy_blocked")
}
