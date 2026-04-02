import Foundation
import Chau7Core

/// Represents a single agent execution session managed by the runtime.
///
/// Wraps a tab UUID (resolves via `TerminalControlService` — does not own the tab).
/// Drives a `RuntimeSessionStateMachine` and journals all events.
///
/// Thread safety: all mutable state is private and accessed through lock-acquiring
/// methods/properties. The class is `@unchecked Sendable` because synchronization
/// is manual via `NSLock`.
final class RuntimeSession: @unchecked Sendable {

    /// Session identifier ("rs_" + short UUID).
    let id: String
    /// The tab hosting this agent session.
    let tabID: UUID
    /// Backend adapter driving this session.
    let backend: any AgentBackend
    /// Configuration used to create this session.
    let config: SessionConfig
    /// When this session was created.
    let createdAt: Date
    /// Whether to auto-approve tool use requests.
    let autoApprove: Bool
    /// Whether this session was adopted from an existing tab (passive).
    let adopted: Bool

    /// Per-session event journal.
    let journal: EventJournal

    // MARK: - Mutable State (all private, accessed only through lock-acquiring API)

    private var stateMachine = RuntimeSessionStateMachine()
    private let lock = NSLock()

    private var _currentTurnID: String?
    private var _turnCount = 0
    private var _pendingApproval: PendingApproval?
    private var _currentTurnStats = TurnStats()
    private var _lastDeniedApproval = false
    private var _wasInterrupted = false
    private var _lastExitReason: TurnExitReason?
    private var _lastTurnSubmittedAt: Date?
    private var approvalTimeoutWork: DispatchWorkItem?

    // MARK: - Lock-Acquiring Accessors

    var state: RuntimeSessionStateMachine.State {
        lock.lock()
        defer { lock.unlock() }
        return stateMachine.state
    }

    var isTerminal: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stateMachine.isTerminal
    }

    var canAcceptTurn: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stateMachine.canAcceptTurn
    }

    var currentTurnID: String? {
        lock.lock()
        defer { lock.unlock() }
        return _currentTurnID
    }

    var turnCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _turnCount
    }

    var pendingApproval: PendingApproval? {
        lock.lock()
        defer { lock.unlock() }
        return _pendingApproval
    }

    var currentTurnStats: TurnStats {
        lock.lock()
        defer { lock.unlock() }
        return _currentTurnStats
    }

    var lastExitReason: TurnExitReason? {
        lock.lock()
        defer { lock.unlock() }
        return _lastExitReason
    }

    var lastTurnSubmittedAt: Date? {
        lock.lock()
        defer { lock.unlock() }
        return _lastTurnSubmittedAt
    }

    // MARK: - Init

    init(
        tabID: UUID,
        backend: any AgentBackend,
        config: SessionConfig,
        autoApprove: Bool = false,
        adopted: Bool = false,
        journalCapacity: Int = 1000
    ) {
        self.id = "rs_" + UUID().uuidString.prefix(8).lowercased()
        self.tabID = tabID
        self.backend = backend
        self.config = config
        self.createdAt = Date()
        self.autoApprove = autoApprove
        self.adopted = adopted
        self.journal = EventJournal(capacity: journalCapacity)
    }

    // MARK: - State Transitions

    /// Apply a trigger to the state machine. Journals a `state_changed` event on transition.
    @discardableResult
    func transition(_ trigger: RuntimeSessionStateMachine.Trigger) -> Bool {
        lock.lock()
        let previousState = stateMachine.state
        let accepted = stateMachine.handle(trigger)
        let newState = stateMachine.state
        let turnID = _currentTurnID
        lock.unlock()

        if accepted {
            journal.append(
                sessionID: id,
                turnID: turnID,
                type: RuntimeEventType.stateChanged.rawValue,
                data: ["from": previousState.rawValue, "to": newState.rawValue]
            )
        } else {
            Log.debug("RuntimeSession \(id): transition \(trigger) rejected in state \(previousState.rawValue)")
        }
        return accepted
    }

    // MARK: - Turn Management

    /// Start a new turn. Returns the turn ID. Transitions to `.busy`.
    ///
    /// Performs the guard, transition, and state reset atomically under a single
    /// lock acquisition to prevent TOCTOU races.
    func startTurn(prompt: String) -> String? {
        lock.lock()
        guard stateMachine.canAcceptTurn else {
            let s = stateMachine.state
            lock.unlock()
            Log.debug("RuntimeSession \(id): startTurn rejected, state=\(s.rawValue)")
            return nil
        }
        guard stateMachine.handle(.turnSubmitted) else {
            lock.unlock()
            Log.error("RuntimeSession \(id): turnSubmitted rejected despite canAcceptTurn=true")
            return nil
        }
        let previousState: RuntimeSessionStateMachine.State = .ready // we know it was ready
        let newState = stateMachine.state
        _turnCount += 1
        let turnID = "t_\(_turnCount)"
        _currentTurnID = turnID
        _lastTurnSubmittedAt = Date()
        _currentTurnStats = TurnStats()
        _lastDeniedApproval = false
        _wasInterrupted = false
        lock.unlock()

        // Journal writes are self-locked
        journal.append(
            sessionID: id,
            turnID: turnID,
            type: RuntimeEventType.stateChanged.rawValue,
            data: ["from": previousState.rawValue, "to": newState.rawValue]
        )
        journal.append(
            sessionID: id,
            turnID: turnID,
            type: RuntimeEventType.turnStarted.rawValue,
            data: ["prompt_length": "\(prompt.count)"]
        )

        return turnID
    }

    /// Result of completing a turn, returned so callers can act without re-reading session state.
    struct TurnCompletionResult {
        let stats: TurnStats
        let exitReason: TurnExitReason
    }

    /// Mark the current turn as complete with enriched stats and exit classification.
    /// Returns a snapshot of the turn's stats and exit reason for the caller.
    @discardableResult
    func completeTurn(summary: String? = nil, terminalOutput: String? = nil) -> TurnCompletionResult {
        lock.lock()
        let turnID = _currentTurnID
        let stats = _currentTurnStats
        let denied = _lastDeniedApproval
        let interrupted = _wasInterrupted
        let sessionState = stateMachine.state
        lock.unlock()

        let exitReason = ExitClassifier.classify(
            sessionState: sessionState,
            lastDenied: denied,
            terminalOutput: terminalOutput,
            wasInterrupted: interrupted
        )

        var data = stats.summary()
        data["exit_reason"] = exitReason.rawValue
        if let summary { data["summary"] = summary }

        journal.append(
            sessionID: id,
            turnID: turnID,
            type: RuntimeEventType.turnCompleted.rawValue,
            data: data
        )

        let transitioned = transition(.turnCompleted)
        if !transitioned {
            Log.warn("RuntimeSession \(id): completeTurn transition rejected, state=\(state.rawValue)")
        }

        lock.lock()
        _currentTurnID = nil
        _lastExitReason = exitReason
        lock.unlock()

        return TurnCompletionResult(stats: stats, exitReason: exitReason)
    }

    /// Mark the current turn as failed. Transitions back to `.ready` via `.turnCompleted`.
    func failTurn(reason: String) {
        lock.lock()
        let turnID = _currentTurnID
        _currentTurnID = nil
        lock.unlock()

        journal.append(
            sessionID: id,
            turnID: turnID,
            type: RuntimeEventType.turnFailed.rawValue,
            data: ["reason": reason]
        )

        let transitioned = transition(.turnCompleted)
        if !transitioned {
            Log.warn("RuntimeSession \(id): failTurn transition rejected, state=\(state.rawValue)")
        }
    }

    // MARK: - Turn Stats Recording

    /// Record a tool invocation during the current turn.
    func recordToolUse(name: String, file: String?) {
        lock.lock()
        _currentTurnStats.recordToolUse(name: name, file: file)
        lock.unlock()
    }

    /// Add token counts observed during the current turn.
    func addTokens(input: Int, output: Int, cacheCreation: Int, cacheRead: Int) {
        lock.lock()
        _currentTurnStats.addTokens(input: input, output: output, cacheCreation: cacheCreation, cacheRead: cacheRead)
        lock.unlock()
    }

    /// Mark that an interrupt occurred during this turn.
    func markInterrupted() {
        lock.lock()
        _wasInterrupted = true
        lock.unlock()
    }

    // MARK: - Approval Management

    /// Record that an approval is needed. Transitions to `.awaitingApproval`.
    func requestApproval(tool: String, description: String) -> PendingApproval? {
        let approval = PendingApproval(
            id: UUID().uuidString,
            sessionID: id,
            tool: tool,
            description: description,
            requestedAt: Date()
        )

        lock.lock()
        _pendingApproval = approval
        let turnID = _currentTurnID
        lock.unlock()

        guard transition(.approvalNeeded) else {
            Log.warn("RuntimeSession \(id): approvalNeeded rejected, clearing orphaned approval")
            lock.lock()
            _pendingApproval = nil
            lock.unlock()
            return nil
        }

        journal.append(
            sessionID: id,
            turnID: turnID,
            type: RuntimeEventType.approvalNeeded.rawValue,
            data: ["approval_id": approval.id, "tool": tool, "description": description]
        )

        scheduleApprovalTimeout()

        return approval
    }

    private static let approvalTimeoutSeconds: TimeInterval = 30

    private func scheduleApprovalTimeout() {
        approvalTimeoutWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let currentState = state
            guard currentState == .awaitingApproval else { return }
            Log.warn("RuntimeSession \(id): approval timed out after \(Int(Self.approvalTimeoutSeconds))s, recovering to ready")
            lock.lock()
            _pendingApproval = nil
            lock.unlock()
            transition(.turnCompleted)
        }
        approvalTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.approvalTimeoutSeconds, execute: work)
    }

    /// Resolve a pending approval. Transitions back to `.busy`.
    @discardableResult
    func resolveApproval(id approvalID: String, approved: Bool, resolvedBy: String) -> Bool {
        approvalTimeoutWork?.cancel()
        approvalTimeoutWork = nil
        lock.lock()
        guard _pendingApproval?.id == approvalID else {
            let actual = _pendingApproval?.id ?? "none"
            lock.unlock()
            Log.warn("RuntimeSession \(id): resolveApproval mismatch, expected=\(actual) got=\(approvalID)")
            return false
        }
        _pendingApproval = nil
        if !approved {
            _lastDeniedApproval = true
        }
        let turnID = _currentTurnID
        lock.unlock()

        transition(.approvalResolved)

        journal.append(
            sessionID: id,
            turnID: turnID,
            type: RuntimeEventType.approvalResolved.rawValue,
            data: [
                "approval_id": approvalID,
                "approved": approved ? "true" : "false",
                "resolved_by": resolvedBy
            ]
        )
        return true
    }

    // MARK: - Summary

    /// JSON-encodable summary of this session for MCP responses.
    func summary() -> [String: Any] {
        lock.lock()
        let currentState = stateMachine.state
        let turn = _currentTurnID
        let turns = _turnCount
        let approval = _pendingApproval
        lock.unlock()

        var result: [String: Any] = [
            "session_id": id,
            "tab_id": tabID.uuidString,
            "backend": backend.name,
            "state": currentState.rawValue,
            "directory": config.directory,
            "turn_count": turns,
            "adopted": adopted,
            "auto_approve": autoApprove,
            "created_at": DateFormatters.iso8601.string(from: createdAt),
            "cursor": journal.latestCursor
        ]
        if let turn {
            result["current_turn_id"] = turn
        }
        if let approval {
            result["pending_approval"] = [
                "id": approval.id,
                "tool": approval.tool,
                "description": approval.description
            ]
        }
        return result
    }
}

// MARK: - Supporting Types

/// A pending approval request from the agent.
struct PendingApproval: Sendable {
    let id: String
    let sessionID: String
    let tool: String
    let description: String
    let requestedAt: Date
}
