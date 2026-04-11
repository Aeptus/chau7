import Foundation
import Chau7Core

/// Bridges MCP `runtime_*` tool calls to the runtime session system.
///
/// Follows `TerminalControlService` pattern: `static let shared`, dispatches
/// to main thread for tab operations, `NSLock` for session state.
final class RuntimeControlService {
    static let shared = RuntimeControlService()

    private let controlService = TerminalControlService.shared
    private let sessionManager = RuntimeSessionManager.shared
    private let telemetryStore = TelemetryStore.shared
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    var launchReadinessProbe: ((RuntimeSession) -> RuntimeLaunchReadinessSnapshot?)?
    private var runtimeReadinessObserver: NSObjectProtocol?

    // MARK: - Backend Registry

    private static let backendsLock = NSLock()
    private static var backends: [String: () -> any AgentBackend] = [
        "claude": { ClaudeCodeBackend() },
        "codex": { CodexBackend() },
        "shell": { GenericShellBackend() }
    ]

    static func registerBackend(name: String, factory: @escaping () -> any AgentBackend) {
        backendsLock.lock()
        defer { backendsLock.unlock() }
        backends[name] = factory
    }

    private init() {
        self.runtimeReadinessObserver = NotificationCenter.default.addObserver(
            forName: .terminalSessionRuntimeReadinessChanged,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self,
                  let terminalSession = notification.object as? TerminalSessionModel,
                  let tabID = terminalSession.ownerTabID else {
                return
            }
            let source = notification.userInfo?["source"] as? String ?? "unknown"
            handleRuntimeReadinessChange(forTabID: tabID, source: source)
        }
    }

    // MARK: - Tool Dispatch

    func handleToolCall(name: String, arguments: [String: Any]) -> String {
        switch name {
        case "runtime_session_create":
            return createSession(arguments)
        case "runtime_session_list":
            return listSessions(arguments)
        case "runtime_session_get":
            return getSession(arguments)
        case "runtime_session_stop":
            return stopSession(arguments)
        case "runtime_session_children":
            return listChildSessions(arguments)
        case "runtime_session_cancel_children":
            return cancelChildSessions(arguments)
        case "runtime_session_retry":
            return retrySession(arguments)
        case "runtime_turn_send":
            return sendTurn(arguments)
        case "runtime_turn_status":
            return turnStatus(arguments)
        case "runtime_turn_result":
            return turnResult(arguments)
        case "runtime_turn_wait":
            return waitForTurn(arguments)
        case "runtime_events_poll":
            return pollEvents(arguments)
        case "runtime_approval_respond":
            return respondToApproval(arguments)
        default:
            return jsonError("Unknown runtime tool: \(name)")
        }
    }

    // MARK: - Session Management

    private func createSession(_ args: [String: Any]) -> String {
        let createStartedAt = CFAbsoluteTimeGetCurrent()
        defer { logSlowRuntimeLifecycle(operation: "runtime_session_create", startedAt: createStartedAt) }
        let backendName = args["backend"] as? String ?? "claude"
        let directory = args["directory"] as? String ?? FileManager.default.currentDirectoryPath
        let model = args["model"] as? String
        let resumeID = args["resume_session_id"] as? String
        var env = sanitizeStringDict(args["env"]) ?? [:]
        let backendArgs = args["backend_args"] as? [String] ?? []
        let initialPrompt = args["initial_prompt"] as? String
        let autoApprove = args["auto_approve"] as? Bool ?? false
        let attachTabID = args["attach_tab_id"] as? String
        let purpose = sanitizeOptionalString(args["purpose"] as? String)
        let parentSessionID = sanitizeOptionalString(args["parent_session_id"] as? String)
        let parentRunID = sanitizeOptionalString(args["parent_run_id"] as? String)
        let taskMetadata = sanitizeStringDict(args["task_metadata"]) ?? [:]
        let resultSchema = args["result_schema"].flatMap(JSONValue.from(any:))
        let delegationDepth = max(0, args["delegation_depth"] as? Int ?? 0)
        let policy = parsePolicy(args["policy"]) ?? RuntimeDelegationPolicy()

        if let policyError = policy.validateStart(turnCount: 1, elapsedMs: 0, delegationDepth: delegationDepth) {
            return jsonError(policyError)
        }
        if let parentSessionID {
            guard let parentSession = sessionManager.session(id: parentSessionID) else {
                return jsonError("Parent session not found: \(parentSessionID)")
            }
            if let policyError = parentSession.config.policy.validateChildCreation(childDelegationDepth: delegationDepth) {
                return jsonError(policyError)
            }
        }

        if let purpose {
            env["CHAU7_SESSION_PURPOSE"] = purpose
        }
        if let parentSessionID {
            env["CHAU7_PARENT_SESSION_ID"] = parentSessionID
        }
        if let parentRunID {
            env["CHAU7_PARENT_RUN_ID"] = parentRunID
        }
        env["CHAU7_DELEGATION_DEPTH"] = "\(delegationDepth)"
        env["CHAU7_ALLOW_CHILD_DELEGATION"] = policy.allowChildDelegation ? "1" : "0"
        env["CHAU7_MAX_DELEGATION_DEPTH"] = "\(policy.maxDelegationDepth)"
        if let maxTurns = policy.maxTurns {
            env["CHAU7_MAX_TURNS"] = "\(maxTurns)"
        }
        if let maxDurationMs = policy.maxDurationMs {
            env["CHAU7_MAX_DURATION_MS"] = "\(maxDurationMs)"
        }
        if let allowNetwork = policy.allowNetwork {
            env["CHAU7_ALLOW_NETWORK"] = allowNetwork ? "1" : "0"
        }
        if let allowFileWrites = policy.allowFileWrites {
            env["CHAU7_ALLOW_FILE_WRITES"] = allowFileWrites ? "1" : "0"
        }

        Log
            .info(
                "MCP runtime_session_create: backend=\(backendName) model=\(model ?? "(none)") dir=\(directory) autoApprove=\(autoApprove) resume=\(resumeID ?? "(none)") backendArgs=\(backendArgs) hasInitialPrompt=\(initialPrompt != nil) attachTab=\(attachTabID ?? "(none)") purpose=\(purpose ?? "(none)") parentSession=\(parentSessionID ?? "(none)") parentRun=\(parentRunID ?? "(none)") depth=\(delegationDepth) policy[maxTurns=\(policy.maxTurns.map(String.init) ?? "-"), maxDurationMs=\(policy.maxDurationMs.map(String.init) ?? "-"), allowChildDelegation=\(policy.allowChildDelegation)]"
            )

        // Resolve backend via registry
        Self.backendsLock.lock()
        let factory = Self.backends[backendName]
        let validKeys = Self.backends.keys.sorted()
        Self.backendsLock.unlock()

        guard let factory else {
            Log.warn("MCP runtime_session_create: unknown backend '\(backendName)'")
            return jsonError("Unknown backend: \(backendName). Valid: \(validKeys.joined(separator: ", "))")
        }
        let backend = factory()

        // Validate model if provided
        if let model {
            if let validationError = Self.validateModel(model, backend: backendName) {
                Log.warn("MCP runtime_session_create: model validation failed — \(validationError)")
                return jsonError(validationError)
            }
        }

        // Verify the backend binary exists in PATH
        if attachTabID == nil {
            let binaryName = Self.binaryName(for: backendName)
            if let binaryName, !Self.binaryExistsInPath(binaryName) {
                let msg = "Backend '\(backendName)' requires '\(binaryName)' in PATH but it was not found. Install it first."
                Log.warn("MCP runtime_session_create: \(msg)")
                return jsonError(msg)
            }
        }

        let config = SessionConfig(
            directory: directory,
            provider: backendName,
            model: model,
            resumeSessionID: resumeID,
            environment: env,
            args: backendArgs,
            autoApprove: autoApprove,
            purpose: purpose,
            parentSessionID: parentSessionID,
            parentRunID: parentRunID,
            taskMetadata: taskMetadata,
            resultSchema: resultSchema,
            delegationDepth: delegationDepth,
            policy: policy
        )

        // Create or attach to tab
        let tabID: UUID
        if let attachStr = attachTabID {
            guard let uuid = controlService.resolveControlPlaneTabID(attachStr) else {
                Log.warn("MCP runtime_session_create: invalid attach tab id \(attachStr)")
                return jsonError("Invalid tab ID: \(attachStr)")
            }
            tabID = uuid
            Log.info("MCP runtime_session_create: attaching to existing tab \(attachStr)")
        } else {
            // Create a new tab via TerminalControlService
            let tabResult = controlService.createTab(
                directory: directory,
                windowID: nil,
                context: "runtime_session_create"
            )
            guard let data = tabResult.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tabIDStr = json["tab_id"] as? String,
                  let uuid = controlService.resolveControlPlaneTabID(tabIDStr) else {
                Log.error("MCP runtime_session_create: failed to create tab — \(tabResult)")
                return jsonError("Failed to create tab: \(tabResult)")
            }
            tabID = uuid
            Log.info("MCP runtime_session_create: created tab \(tabIDStr)")
        }

        let session: RuntimeSession
        if attachTabID != nil {
            session = sessionManager.adoptSession(
                tabID: tabID,
                backend: backend,
                cwd: directory
            )
        } else {
            session = sessionManager.createSession(
                tabID: tabID,
                backend: backend,
                config: config,
                autoApprove: autoApprove
            )
        }

        // Launch the backend command in the tab
        let launchCmd = backend.launchCommand(config: config)
        if !launchCmd.isEmpty, attachTabID == nil {
            Log.info("MCP runtime_session_create: launching command: \(launchCmd)")
            _ = controlService.execInTab(tabID: tabID.uuidString, command: launchCmd)
            if backend.launchReadinessStrategy == .immediate {
                sessionManager.markReady(sessionID: session.id)
            }
        }

        // Send initial prompt if provided. Delivery is driven by real terminal
        // readiness changes instead of background retry loops.
        if let prompt = initialPrompt {
            session.queueInitialPrompt(prompt)
            if !dispatchPendingInitialPromptIfReady(session) {
                session.journal.append(
                    sessionID: session.id,
                    turnID: nil,
                    type: "initial_prompt_pending",
                    data: ["reason": "awaiting_runtime_readiness"]
                )
                Log.info("MCP initial_prompt: queued for session \(session.id) pending readiness events")
            }
        }

        handleRuntimeReadinessChange(forTabID: tabID, source: "create")

        Log.info("MCP runtime_session_create: session \(session.id) created (state=\(session.state.rawValue))")
        return encodeAny(sessionSummary(session))
    }

    private func listSessions(_ args: [String: Any]) -> String {
        let includeStopped = args["include_stopped"] as? Bool ?? false
        let sessions = sessionManager.allSessions(includeStopped: includeStopped)
        let summaries = sessions.map { sessionSummary($0) }
        return encodeAny(summaries)
    }

    private func getSession(_ args: [String: Any]) -> String {
        guard let sessionID = args["session_id"] as? String else {
            return jsonError("session_id is required")
        }
        guard let session = sessionManager.session(id: sessionID) else {
            return jsonError("Session not found: \(sessionID)")
        }
        return encodeAny(sessionSummary(session))
    }

    private func stopSession(_ args: [String: Any]) -> String {
        let stopStartedAt = CFAbsoluteTimeGetCurrent()
        defer { logSlowRuntimeLifecycle(operation: "runtime_session_stop", startedAt: stopStartedAt) }
        guard let sessionID = args["session_id"] as? String else {
            return jsonError("session_id is required")
        }
        let closeTab = args["close_tab"] as? Bool ?? false
        let force = args["force"] as? Bool ?? false

        guard let session = sessionManager.session(id: sessionID) else {
            Log.info("MCP runtime_session_stop: session not found \(sessionID)")
            return jsonError("Session not found: \(sessionID)")
        }

        Log.info("MCP runtime_session_stop: session=\(sessionID) state=\(session.state.rawValue) force=\(force) closeTab=\(closeTab)")

        // Send Ctrl+C if force
        if force || session.state == .busy || session.state == .awaitingApproval {
            _ = controlService.sendInput(tabID: session.tabID.uuidString, input: "\u{3}") // Ctrl+C
        }

        let stopped = sessionManager.stopSession(id: sessionID)

        if closeTab {
            queueTabClose(tabID: session.tabID, force: force, context: "runtime_session_stop")
        }

        return encodeAny([
            "ok": stopped,
            "session_id": sessionID,
            "final_state": session.state.rawValue,
            "close_queued": closeTab
        ])
    }

    private func listChildSessions(_ args: [String: Any]) -> String {
        guard let sessionID = args["session_id"] as? String else {
            return jsonError("session_id is required")
        }
        let includeStopped = args["include_stopped"] as? Bool ?? false
        let recursive = args["recursive"] as? Bool ?? false

        let sessions = recursive
            ? sessionManager.descendantSessions(rootSessionID: sessionID, includeStopped: includeStopped)
            : sessionManager.childSessions(parentSessionID: sessionID, includeStopped: includeStopped)
        return encodeAny(sessions.map(sessionSummary))
    }

    private func cancelChildSessions(_ args: [String: Any]) -> String {
        guard let sessionID = args["session_id"] as? String else {
            return jsonError("session_id is required")
        }
        let closeTabs = args["close_tabs"] as? Bool ?? false
        let force = args["force"] as? Bool ?? false
        let children = sessionManager.descendantSessions(rootSessionID: sessionID, includeStopped: false)

        var stoppedIDs: [String] = []
        for child in children {
            if force || child.state == .busy || child.state == .awaitingApproval {
                _ = controlService.sendInput(tabID: child.tabID.uuidString, input: "\u{3}")
            }
            if sessionManager.stopSession(id: child.id) {
                stoppedIDs.append(child.id)
                if closeTabs {
                    queueTabClose(tabID: child.tabID, force: force, context: "runtime_session_cancel_children")
                }
            }
        }

        return encodeAny([
            "ok": true,
            "session_id": sessionID,
            "stopped_session_ids": stoppedIDs,
            "count": stoppedIDs.count
        ])
    }

    private func retrySession(_ args: [String: Any]) -> String {
        guard let sessionID = args["session_id"] as? String else {
            return jsonError("session_id is required")
        }
        guard let sourceSession = sessionManager.session(id: sessionID) else {
            return jsonError("Session not found: \(sessionID)")
        }

        var retryArgs: [String: Any] = [
            "backend": sourceSession.backend.name,
            "directory": sourceSession.config.directory,
            "env": sourceSession.config.environment,
            "backend_args": sourceSession.config.args,
            "auto_approve": sourceSession.autoApprove,
            "delegation_depth": sourceSession.config.delegationDepth,
            "policy": policyDictionary(sourceSession.config.policy)
        ]
        if let model = sourceSession.config.model {
            retryArgs["model"] = model
        }
        if let resumeSessionID = sourceSession.config.resumeSessionID {
            retryArgs["resume_session_id"] = resumeSessionID
        }
        if let purpose = sourceSession.config.purpose {
            retryArgs["purpose"] = purpose
        }
        if let parentSessionID = sourceSession.config.parentSessionID {
            retryArgs["parent_session_id"] = parentSessionID
        }
        if let parentRunID = sourceSession.config.parentRunID {
            retryArgs["parent_run_id"] = parentRunID
        }
        if !sourceSession.config.taskMetadata.isEmpty {
            retryArgs["task_metadata"] = sourceSession.config.taskMetadata
        }
        if let resultSchema = sourceSession.config.resultSchema {
            retryArgs["result_schema"] = resultSchema.foundationValue
        }
        if let prompt = sanitizeOptionalString(args["prompt"] as? String) ?? sourceSession.lastPrompt {
            retryArgs["initial_prompt"] = prompt
        }
        return createSession(retryArgs)
    }

    // MARK: - Turn Management

    private func sendTurn(_ args: [String: Any]) -> String {
        guard let sessionID = args["session_id"] as? String else {
            return jsonError("session_id is required")
        }
        guard let prompt = args["prompt"] as? String else {
            return jsonError("prompt is required")
        }
        let context = args["context"] as? String
        let resultSchema = args["result_schema"].flatMap(JSONValue.from(any:))

        guard let session = sessionManager.session(id: sessionID) else {
            return jsonError("Session not found: \(sessionID)")
        }

        return sendTurnInternal(session: session, prompt: prompt, context: context, resultSchema: resultSchema)
    }

    private func sendTurnInternal(session: RuntimeSession, prompt: String, context: String?, resultSchema: JSONValue? = nil) -> String {
        let elapsedMs = Int(Date().timeIntervalSince(session.createdAt) * 1000)
        if let policyError = session.config.policy.validateStart(
            turnCount: session.turnCount + 1,
            elapsedMs: elapsedMs,
            delegationDepth: session.config.delegationDepth
        ) {
            session.recordPolicyBlock(tool: "turn_submission", reason: policyError)
            return jsonError(policyError)
        }
        guard ensureSessionReadyForTurn(session) else {
            Log.info("MCP runtime_turn_send: rejected for session \(session.id), state=\(session.state.rawValue)")
            return jsonError("Session \(session.id) is not ready (state: \(session.state.rawValue)). Wait for ready state.")
        }

        guard let turnID = session.startTurn(prompt: prompt, resultSchema: resultSchema) else {
            Log.error("MCP runtime_turn_send: startTurn failed for session \(session.id)")
            return jsonError("Failed to start turn in session \(session.id)")
        }

        session.journalUserInput(prompt: prompt)

        // Format and send to PTY
        let input = session.backend.formatPromptInput(prompt, context: context)
        let sendResult = controlService.sendInput(tabID: session.tabID.uuidString, input: input)
        Log.info("MCP runtime_turn_send: session=\(session.id) turn=\(turnID) inputLen=\(input.count) sendResult=\(sendResult.prefix(100))")

        var response: [String: Any] = [
            "turn_id": turnID,
            "status": "accepted",
            "session_state": session.state.rawValue,
            "cursor": session.journal.latestCursor
        ]
        if let effectiveSchema = resultSchema ?? session.config.resultSchema {
            response["result_schema"] = effectiveSchema.foundationValue
        }
        return encodeAny(response)
    }

    private func turnStatus(_ args: [String: Any]) -> String {
        guard let sessionID = args["session_id"] as? String else {
            return jsonError("session_id is required")
        }
        guard let session = sessionManager.session(id: sessionID) else {
            return jsonError("Session not found: \(sessionID)")
        }

        var result: [String: Any] = [
            "session_id": sessionID,
            "state": session.state.rawValue,
            "turn_count": session.turnCount
        ]
        if let turnID = session.currentTurnID {
            result["current_turn_id"] = turnID
        }
        if let completedTurnID = session.lastCompletedTurnID {
            result["last_completed_turn_id"] = completedTurnID
        }
        if let exitReason = session.lastExitReason {
            result["last_exit_reason"] = exitReason.rawValue
        }
        if let turnID = args["turn_id"] as? String,
           let turnResult = session.turnResult(id: turnID),
           let encodedTurnResult = jsonObject(turnResult) {
            result["turn_result"] = encodedTurnResult
        } else if let turnResult = session.turnResult(),
                  let encodedTurnResult = jsonObject(turnResult) {
            result["latest_turn_result"] = encodedTurnResult
        }
        if let approval = session.pendingApproval {
            result["pending_approval"] = [
                "id": approval.id,
                "tool": approval.tool,
                "description": approval.description
            ]
        }
        if let activeRun = controlService.activeRunSummary(forOverlayTabID: session.tabID) {
            result["active_run"] = activeRun
        }
        return encodeAny(result)
    }

    private func turnResult(_ args: [String: Any]) -> String {
        guard let sessionID = args["session_id"] as? String else {
            return jsonError("session_id is required")
        }
        let turnID = sanitizeOptionalString(args["turn_id"] as? String)

        guard let session = sessionManager.session(id: sessionID) else {
            return jsonError("Session not found: \(sessionID)")
        }

        if let result = session.turnResult(id: turnID) {
            return encode(result)
        }

        guard turnID == nil, let fallback = fallbackTurnResult(for: session) else {
            return jsonError("Turn result not found for session \(sessionID)\(turnID.map { " turn \($0)" } ?? "")")
        }
        return encode(fallback)
    }

    private func waitForTurn(_ args: [String: Any]) -> String {
        guard let sessionID = args["session_id"] as? String else {
            return jsonError("session_id is required")
        }
        let requestedTurnID = sanitizeOptionalString(args["turn_id"] as? String)
        let defaultTimeoutMs = 30000
        let maxTimeoutMs = 3_600_000
        let timeoutMs = min(max(args["timeout_ms"] as? Int ?? defaultTimeoutMs, 100), maxTimeoutMs)
        return waitForTurnResponseSync(
            sessionID: sessionID,
            turnID: requestedTurnID,
            timeoutMs: timeoutMs
        )
    }

    // MARK: - Event Polling

    private func pollEvents(_ args: [String: Any]) -> String {
        guard let sessionID = args["session_id"] as? String else {
            return jsonError("session_id is required")
        }
        guard let session = sessionManager.session(id: sessionID) else {
            return jsonError("Session not found: \(sessionID)")
        }

        let cursor: UInt64
        if let cursorNum = args["cursor"] as? NSNumber {
            cursor = cursorNum.uint64Value
        } else if let cursorInt = args["cursor"] as? Int {
            cursor = UInt64(cursorInt)
        } else {
            cursor = 0
        }
        let limit = args["limit"] as? Int ?? 50

        let (events, newCursor, hasMore) = session.journal.events(after: cursor, limit: limit)

        // Encode events as dictionaries
        let encoded: [[String: Any]] = events.map { event in
            var dict: [String: Any] = [
                "seq": event.seq,
                "session_id": event.sessionID,
                "timestamp": DateFormatters.iso8601.string(from: event.timestamp),
                "type": event.type
            ]
            if let turnID = event.turnID {
                dict["turn_id"] = turnID
            }
            if let correlationID = event.correlationID {
                dict["correlation_id"] = correlationID
            }
            if !event.data.isEmpty {
                dict["data"] = event.data
            }
            return dict
        }

        return encodeAny([
            "events": encoded,
            "cursor": newCursor,
            "has_more": hasMore,
            "session_state": session.state.rawValue
        ])
    }

    // MARK: - Approval

    private func respondToApproval(_ args: [String: Any]) -> String {
        guard let sessionID = args["session_id"] as? String else {
            return jsonError("session_id is required")
        }
        guard let approvalID = args["approval_id"] as? String else {
            return jsonError("approval_id is required")
        }
        guard let approved = args["approved"] as? Bool else {
            return jsonError("approved is required")
        }
        let reason = args["reason"] as? String ?? "orchestrator"

        guard let session = sessionManager.session(id: sessionID) else {
            return jsonError("Session not found: \(sessionID)")
        }

        guard session.pendingApproval?.id == approvalID else {
            return jsonError("No pending approval with id \(approvalID)")
        }

        // Send y/n to the PTY
        let input = approved ? "y\n" : "n\n"
        _ = controlService.sendInput(tabID: session.tabID.uuidString, input: input)

        let didResolve = session.resolveApproval(id: approvalID, approved: approved, resolvedBy: reason)
        if didResolve {
            _ = TerminalControlService.shared.clearPersistentNotificationStyleAcrossWindows(tabID: session.tabID)
        }

        return encodeAny(["ok": true, "approved": approved])
    }

    // MARK: - Validation

    /// Known model aliases per backend. Returns nil if valid, error string if invalid.
    private static func validateModel(_ model: String, backend: String) -> String? {
        let trimmed = model.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            return "Model name is empty."
        }

        // Reject obviously wrong cross-backend models
        switch backend {
        case "codex":
            // Codex models: o3, o4-mini, gpt-4.1, etc. — reject Claude model names
            let claudePatterns = ["claude", "sonnet", "opus", "haiku"]
            if claudePatterns.contains(where: { trimmed.lowercased().contains($0) }) {
                return "Model '\(trimmed)' looks like a Claude model but backend is 'codex'. Codex models include: o3, o4-mini, gpt-4.1. Pass model names valid for the Codex CLI."
            }
        case "claude":
            // Claude models: opus, sonnet, haiku, claude-* — reject OpenAI model names
            let openAIPatterns = ["gpt-", "o1", "o3", "o4", "codex"]
            if openAIPatterns.contains(where: { trimmed.lowercased().contains($0) }) {
                return "Model '\(trimmed)' looks like an OpenAI model but backend is 'claude'. Claude models include: opus, sonnet, haiku. Pass model names valid for the Claude CLI."
            }
        default:
            break
        }

        return nil
    }

    /// Returns the CLI binary name for a given backend, or nil for backends that don't launch a process.
    private static func binaryName(for backend: String) -> String? {
        switch backend {
        case "claude": return "claude"
        case "codex": return "codex"
        default: return nil // shell and custom backends — don't validate
        }
    }

    /// Checks if a binary exists in the user's PATH.
    private static func binaryExistsInPath(_ name: String) -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = [name]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }

    // MARK: - Helpers

    private func jsonError(_ message: String) -> String {
        "{\"error\":\"\(message.replacingOccurrences(of: "\"", with: "\\\""))\"}"
    }

    private func sessionSummary(_ session: RuntimeSession) -> [String: Any] {
        var summary = session.summary()
        summary["tab_id"] = controlService.controlPlaneTabID(for: session.tabID)
        if let activeRun = controlService.activeRunSummary(forOverlayTabID: session.tabID) {
            summary["active_run"] = activeRun
        }
        return summary
    }

    private func ensureSessionReadyForTurn(_ session: RuntimeSession) -> Bool {
        if session.canAcceptTurn {
            return true
        }
        guard session.state == .starting else {
            return false
        }
        guard backendLaunchReady(for: session) else {
            return false
        }
        sessionManager.markReady(sessionID: session.id)
        return session.canAcceptTurn
    }

    private func handleRuntimeReadinessChange(forTabID tabID: UUID, source: String) {
        guard let session = sessionManager.sessionForTab(tabID) else { return }
        guard session.state == .starting || session.pendingInitialPrompt != nil else { return }

        if session.isTerminal {
            if session.pendingInitialPrompt != nil {
                Log.warn("MCP initial_prompt: session \(session.id) reached terminal state before prompt could be sent (state=\(session.state.rawValue))")
                session.clearPendingInitialPrompt()
                session.journal.append(
                    sessionID: session.id,
                    turnID: nil,
                    type: "initial_prompt_failed",
                    data: ["reason": "session_terminated", "state": session.state.rawValue, "source": source]
                )
            }
            return
        }

        if dispatchPendingInitialPromptIfReady(session) {
            Log.info("MCP initial_prompt: dispatched for session \(session.id) via \(source)")
            return
        }

        if ensureSessionReadyForTurn(session) {
            Log.info("MCP runtime_session_create: session \(session.id) became ready via \(source)")
        }
    }

    private func logSlowRuntimeLifecycle(operation: String, startedAt: CFAbsoluteTime, thresholdMs: Double = 150) {
        let durationMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0
        guard durationMs >= thresholdMs else { return }
        Log.warn("MCP \(operation): slow path \(Int(durationMs.rounded()))ms")
    }

    private func backendLaunchReady(for session: RuntimeSession) -> Bool {
        switch session.backend.launchReadinessStrategy {
        case .immediate:
            return true
        case .interactiveAgent:
            guard let snapshot = launchReadinessProbe?(session)
                ?? controlService.runtimeLaunchSnapshot(forOverlayTabID: session.tabID) else {
                return false
            }
            return RuntimeLaunchReadiness.isReady(
                snapshot: snapshot,
                backendName: session.backend.name,
                purpose: session.config.purpose
            )
        }
    }

    @discardableResult
    private func dispatchPendingInitialPromptIfReady(_ session: RuntimeSession) -> Bool {
        guard let prompt = session.pendingInitialPrompt else {
            return false
        }
        guard ensureSessionReadyForTurn(session) else {
            return false
        }

        Log.info("MCP initial_prompt: sending pending prompt to session \(session.id)")
        let result = sendTurnInternal(session: session, prompt: prompt, context: nil)
        if result.contains("\"error\"") {
            Log.warn("MCP initial_prompt: sendTurn failed — \(result)")
            return false
        }
        return true
    }

    private func sanitizeStringDict(_ value: Any?) -> [String: String]? {
        guard let value else { return nil }
        if let dict = value as? [String: String] {
            return dict
        }
        guard let dict = value as? [String: Any] else { return nil }

        var result: [String: String] = [:]
        for (key, rawValue) in dict {
            switch rawValue {
            case let string as String:
                result[key] = string
            case let number as NSNumber:
                result[key] = number.stringValue
            default:
                continue
            }
        }
        return result
    }

    private func sanitizeOptionalString(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func parsePolicy(_ value: Any?) -> RuntimeDelegationPolicy? {
        guard let policyObject = value as? [String: Any] else { return nil }
        return RuntimeDelegationPolicy(
            maxTurns: policyObject["max_turns"] as? Int,
            maxDurationMs: policyObject["max_duration_ms"] as? Int,
            allowChildDelegation: policyObject["allow_child_delegation"] as? Bool ?? true,
            maxDelegationDepth: policyObject["max_delegation_depth"] as? Int ?? 4,
            allowedTools: policyObject["allowed_tools"] as? [String] ?? [],
            blockedTools: policyObject["blocked_tools"] as? [String] ?? [],
            allowNetwork: policyObject["allow_network"] as? Bool,
            allowFileWrites: policyObject["allow_file_writes"] as? Bool
        )
    }

    private func policyDictionary(_ policy: RuntimeDelegationPolicy) -> [String: Any] {
        var result: [String: Any] = [
            "allow_child_delegation": policy.allowChildDelegation,
            "max_delegation_depth": policy.maxDelegationDepth,
            "allowed_tools": policy.allowedTools,
            "blocked_tools": policy.blockedTools
        ]
        if let maxTurns = policy.maxTurns {
            result["max_turns"] = maxTurns
        }
        if let maxDurationMs = policy.maxDurationMs {
            result["max_duration_ms"] = maxDurationMs
        }
        if let allowNetwork = policy.allowNetwork {
            result["allow_network"] = allowNetwork
        }
        if let allowFileWrites = policy.allowFileWrites {
            result["allow_file_writes"] = allowFileWrites
        }
        return result
    }

    private func turnIsFinished(session: RuntimeSession, requestedTurnID: String?) -> Bool {
        if let requestedTurnID {
            if session.state == .starting {
                return false
            }
            if session.turnResult(id: requestedTurnID) != nil {
                return true
            }
            if session.lastCompletedTurnID == requestedTurnID {
                return true
            }
            return session.currentTurnID != requestedTurnID && session.state != .busy && session.state != .awaitingApproval
        }
        return session.state != .starting && session.state != .busy && session.state != .awaitingApproval
    }

    private func statusArguments(sessionID: String, turnID: String?) -> [String: Any] {
        var arguments: [String: Any] = ["session_id": sessionID]
        if let turnID {
            arguments["turn_id"] = turnID
        }
        return arguments
    }

    private func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func fallbackTurnResult(for session: RuntimeSession) -> RuntimeTurnResult? {
        guard let run = telemetryStore.latestRunForTab(session.tabID.uuidString, provider: session.backend.name) else {
            return nil
        }
        let turns = telemetryStore.getTurns(runID: run.id)
        guard let lastAssistantTurn = turns.last(where: { $0.role == .assistant }),
              let content = lastAssistantTurn.content else {
            return nil
        }

        return StructuredResultExtractor.capture(
            sessionID: session.id,
            turnID: session.lastCompletedTurnID ?? "telemetry_latest",
            summary: content,
            output: nil,
            schema: session.config.resultSchema
        )
    }

    private func queueTabClose(tabID: UUID, force: Bool, context: String) {
        controlService.closeTabAsync(
            tabID: tabID.uuidString,
            force: force,
            context: context
        )
        guard !force else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [controlService] in
            guard controlService.tabExistsAcrossWindows(tabID: tabID) else { return }
            Log.info("MCP \(context): escalating delayed tab close for \(tabID)")
            controlService.closeTabAsync(
                tabID: tabID.uuidString,
                force: true,
                context: "\(context)_retry"
            )
        }
    }

    func waitForTurnAsync(sessionID: String, turnID: String? = nil, timeoutMs: Int) async -> String {
        await waitForTurnResponseAsync(
            sessionID: sessionID,
            turnID: sanitizeOptionalString(turnID),
            timeoutMs: min(max(timeoutMs, 100), 3_600_000)
        )
    }

    private func waitForTurnResponseSync(
        sessionID: String,
        turnID requestedTurnID: String?,
        timeoutMs: Int
    ) -> String {
        guard let session = sessionManager.session(id: sessionID) else {
            return jsonError("Session not found: \(sessionID)")
        }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        let statusArgs = statusArguments(sessionID: sessionID, turnID: requestedTurnID)

        while Date() < deadline {
            _ = dispatchPendingInitialPromptIfReady(session)
            if turnIsFinished(session: session, requestedTurnID: requestedTurnID) {
                return completedWaitResponse(statusArgs: statusArgs, timeoutMs: timeoutMs, deadline: deadline)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }

        return timedOutWaitResponse(statusArgs: statusArgs, timeoutMs: timeoutMs)
    }

    private func waitForTurnResponseAsync(
        sessionID: String,
        turnID requestedTurnID: String?,
        timeoutMs: Int
    ) async -> String {
        guard let session = sessionManager.session(id: sessionID) else {
            return jsonError("Session not found: \(sessionID)")
        }
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000.0)
        let statusArgs = statusArguments(sessionID: sessionID, turnID: requestedTurnID)

        while Date() < deadline {
            _ = dispatchPendingInitialPromptIfReady(session)
            if turnIsFinished(session: session, requestedTurnID: requestedTurnID) {
                return completedWaitResponse(statusArgs: statusArgs, timeoutMs: timeoutMs, deadline: deadline)
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        return timedOutWaitResponse(statusArgs: statusArgs, timeoutMs: timeoutMs)
    }

    private func completedWaitResponse(
        statusArgs: [String: Any],
        timeoutMs: Int,
        deadline: Date
    ) -> String {
        var response = turnStatus(statusArgs)
        if var object = parseJSONObject(response) {
            object["timed_out"] = false
            object["waited_ms"] = timeoutMs - max(Int(deadline.timeIntervalSinceNow * 1000), 0)
            response = encodeAny(object)
        }
        return response
    }

    private func timedOutWaitResponse(statusArgs: [String: Any], timeoutMs: Int) -> String {
        var response = turnStatus(statusArgs)
        if var object = parseJSONObject(response) {
            object["timed_out"] = true
            object["waited_ms"] = timeoutMs
            response = encodeAny(object)
        }
        return response
    }

    private func encode(_ value: some Encodable) -> String {
        guard let data = try? encoder.encode(value),
              let string = String(data: data, encoding: .utf8) else {
            return jsonError("Internal error: response encoding failed")
        }
        return string
    }

    private func jsonObject(_ value: some Encodable) -> Any? {
        guard let data = try? encoder.encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private func encodeAny(_ value: Any) -> String {
        do {
            let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
            guard let str = String(data: data, encoding: .utf8) else {
                Log.error("RuntimeControlService: JSON data not valid UTF-8")
                return jsonError("Internal error: response encoding failed")
            }
            return str
        } catch {
            Log.error("RuntimeControlService: JSON serialization failed: \(error)")
            return jsonError("Internal error: response serialization failed")
        }
    }
}
