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
    private var _lastPrompt: String?
    private var _pendingInitialPrompt: String?
    private var _lastCompletedTurnID: String?
    private var _currentResultSchema: JSONValue?
    private var _turnResults: [String: RuntimeTurnResult] = [:]
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

    var lastCompletedTurnID: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastCompletedTurnID
    }

    var lastPrompt: String? {
        lock.lock()
        defer { lock.unlock() }
        return _lastPrompt
    }

    var pendingInitialPrompt: String? {
        lock.lock()
        defer { lock.unlock() }
        return _pendingInitialPrompt
    }

    func turnResult(id turnID: String? = nil) -> RuntimeTurnResult? {
        lock.lock()
        defer { lock.unlock() }
        if let turnID {
            return _turnResults[turnID]
        }
        guard let latestTurnID = _lastCompletedTurnID else { return nil }
        return _turnResults[latestTurnID]
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
    func startTurn(prompt: String, resultSchema: JSONValue? = nil) -> String? {
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
        _lastPrompt = prompt
        _pendingInitialPrompt = nil
        _currentResultSchema = resultSchema ?? config.resultSchema
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

    func queueInitialPrompt(_ prompt: String) {
        lock.lock()
        _pendingInitialPrompt = prompt
        lock.unlock()
    }

    func clearPendingInitialPrompt() {
        lock.lock()
        _pendingInitialPrompt = nil
        lock.unlock()
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
        let resultSchema = _currentResultSchema
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

        if let turnID,
           let result = StructuredResultExtractor.capture(
               sessionID: id,
               turnID: turnID,
               summary: summary,
               output: terminalOutput,
               schema: resultSchema
           ) {
            storeTurnResult(result)
        }

        let transitioned = transition(.turnCompleted)
        if !transitioned {
            let currentState = state
            if currentState == .ready {
                Log.debug("RuntimeSession \(id): duplicate completeTurn ignored in state=\(currentState.rawValue)")
            } else {
                Log.warn("RuntimeSession \(id): completeTurn transition rejected, state=\(currentState.rawValue)")
            }
        }

        lock.lock()
        _currentTurnID = nil
        _currentResultSchema = nil
        _lastCompletedTurnID = turnID
        _lastExitReason = exitReason
        lock.unlock()

        return TurnCompletionResult(stats: stats, exitReason: exitReason)
    }

    /// Mark the current turn as failed. Transitions back to `.ready` via `.turnCompleted`.
    func failTurn(reason: String) {
        lock.lock()
        let turnID = _currentTurnID
        _currentTurnID = nil
        _currentResultSchema = nil
        lock.unlock()

        journal.append(
            sessionID: id,
            turnID: turnID,
            type: RuntimeEventType.turnFailed.rawValue,
            data: ["reason": reason]
        )

        let transitioned = transition(.turnCompleted)
        if !transitioned {
            let currentState = state
            if currentState == .ready {
                Log.debug("RuntimeSession \(id): duplicate failTurn ignored in state=\(currentState.rawValue)")
            } else {
                Log.warn("RuntimeSession \(id): failTurn transition rejected, state=\(currentState.rawValue)")
            }
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

    func recordPolicyBlock(tool: String, reason: String) {
        lock.lock()
        _lastDeniedApproval = true
        let turnID = _currentTurnID
        lock.unlock()

        journal.append(
            sessionID: id,
            turnID: turnID,
            type: RuntimeEventType.policyBlocked.rawValue,
            data: [
                "tool": tool,
                "reason": reason
            ]
        )
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
            let currentState = state
            if currentState == .ready, currentTurnID == nil {
                Log.debug("RuntimeSession \(id): duplicate approval request ignored in state=\(currentState.rawValue)")
            } else {
                Log.warn("RuntimeSession \(id): approvalNeeded rejected, clearing orphaned approval")
            }
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
            handleApprovalTimeout()
        }
        approvalTimeoutWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.approvalTimeoutSeconds, execute: work)
    }

    func handleApprovalTimeout() {
        approvalTimeoutWork?.cancel()
        approvalTimeoutWork = nil

        let currentState = state
        guard currentState == .awaitingApproval else {
            Log.debug("RuntimeSession \(id): duplicate approval timeout ignored in state=\(currentState.rawValue)")
            return
        }

        lock.lock()
        _pendingApproval = nil
        lock.unlock()

        failTurn(reason: "approval_timeout")
        Log.warn("RuntimeSession \(id): approval timed out after \(Int(Self.approvalTimeoutSeconds))s, recovering to ready")
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
        let completedTurnID = _lastCompletedTurnID
        let latestTurnResult = completedTurnID.flatMap { _turnResults[$0] }
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
        if let purpose = config.purpose {
            result["purpose"] = purpose
        }
        if let parentSessionID = config.parentSessionID {
            result["parent_session_id"] = parentSessionID
        }
        if let parentRunID = config.parentRunID {
            result["parent_run_id"] = parentRunID
        }
        result["delegation_depth"] = config.delegationDepth
        if !config.taskMetadata.isEmpty {
            result["task_metadata"] = config.taskMetadata
        }
        if let resultSchema = config.resultSchema {
            result["result_schema"] = resultSchema.foundationValue
        }
        var policySummary: [String: Any] = [
            "allow_child_delegation": config.policy.allowChildDelegation,
            "max_delegation_depth": config.policy.maxDelegationDepth,
            "allowed_tools": config.policy.allowedTools,
            "blocked_tools": config.policy.blockedTools
        ]
        if let allowNetwork = config.policy.allowNetwork {
            policySummary["allow_network"] = allowNetwork
        }
        if let allowFileWrites = config.policy.allowFileWrites {
            policySummary["allow_file_writes"] = allowFileWrites
        }
        if let maxTurns = config.policy.maxTurns {
            policySummary["max_turns"] = maxTurns
        }
        if let maxDurationMs = config.policy.maxDurationMs {
            policySummary["max_duration_ms"] = maxDurationMs
        }
        result["policy"] = policySummary
        if let turn {
            result["current_turn_id"] = turn
        }
        if let completedTurnID {
            result["last_completed_turn_id"] = completedTurnID
        }
        if let latestTurnResult {
            result["latest_turn_result"] = turnResultDictionary(latestTurnResult)
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

    private func storeTurnResult(_ result: RuntimeTurnResult) {
        lock.lock()
        _turnResults[result.turnID] = result
        lock.unlock()

        var data: [String: String] = [
            "status": result.status.rawValue,
            "source": result.source
        ]
        if !result.validationErrors.isEmpty {
            data["validation_errors"] = result.validationErrors.joined(separator: " | ")
        }
        if let value = result.value {
            if let serialized = try? JSONSerialization.data(withJSONObject: value.foundationValue, options: [.sortedKeys]),
               let text = String(data: serialized, encoding: .utf8) {
                data["value"] = text
            }
        }
        journal.append(
            sessionID: id,
            turnID: result.turnID,
            type: RuntimeEventType.turnResult.rawValue,
            data: data
        )
    }

    private func turnResultDictionary(_ result: RuntimeTurnResult) -> [String: Any] {
        var dictionary: [String: Any] = [
            "session_id": result.sessionID,
            "turn_id": result.turnID,
            "status": result.status.rawValue,
            "source": result.source,
            "captured_at": DateFormatters.iso8601.string(from: result.capturedAt),
            "validation_errors": result.validationErrors
        ]
        if let schema = result.schema {
            dictionary["schema"] = schema.foundationValue
        }
        if let value = result.value {
            dictionary["value"] = value.foundationValue
        }
        if let rawText = result.rawText {
            dictionary["raw_text"] = rawText
        }
        return dictionary
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
