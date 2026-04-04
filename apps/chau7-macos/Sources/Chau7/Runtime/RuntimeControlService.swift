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

    private init() {}

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
        case "runtime_turn_send":
            return sendTurn(arguments)
        case "runtime_turn_status":
            return turnStatus(arguments)
        case "runtime_turn_result":
            return turnResult(arguments)
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

        Log
            .info(
                "MCP runtime_session_create: backend=\(backendName) model=\(model ?? "(none)") dir=\(directory) autoApprove=\(autoApprove) resume=\(resumeID ?? "(none)") backendArgs=\(backendArgs) hasInitialPrompt=\(initialPrompt != nil) attachTab=\(attachTabID ?? "(none)") purpose=\(purpose ?? "(none)") parentSession=\(parentSessionID ?? "(none)") parentRun=\(parentRunID ?? "(none)") depth=\(delegationDepth)"
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
            delegationDepth: delegationDepth
        )

        // Create or attach to tab
        let tabID: UUID
        if let attachStr = attachTabID, let uuid = UUID(uuidString: attachStr) {
            tabID = uuid
            Log.info("MCP runtime_session_create: attaching to existing tab \(attachStr)")
        } else {
            // Create a new tab via TerminalControlService
            let tabResult = controlService.createTab(directory: directory, windowID: nil)
            guard let data = tabResult.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tabIDStr = json["tab_id"] as? String,
                  let uuid = UUID(uuidString: tabIDStr) else {
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
            sessionManager.markReady(sessionID: session.id)
        }

        // Send initial prompt if provided — poll for readiness instead of fixed delay
        if let prompt = initialPrompt {
            scheduleInitialPrompt(session: session, prompt: prompt, attempt: 1)
        }

        Log.info("MCP runtime_session_create: session \(session.id) created (state=\(session.state.rawValue))")
        return encodeAny(sessionSummary(session))
    }

    /// Deliver initial_prompt with retry: waits for .ready state, backs off up to ~4s total.
    private func scheduleInitialPrompt(session: RuntimeSession, prompt: String, attempt: Int) {
        let maxAttempts = 8
        let delay = attempt <= 2 ? 0.3 : 0.5 // faster first checks, then slower

        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            if session.isTerminal {
                Log.warn("MCP initial_prompt: session \(session.id) reached terminal state before prompt could be sent (state=\(session.state.rawValue))")
                session.journal.append(
                    sessionID: session.id,
                    turnID: nil,
                    type: "initial_prompt_failed",
                    data: ["reason": "session_terminated", "state": session.state.rawValue]
                )
                return
            }

            if session.canAcceptTurn {
                Log.info("MCP initial_prompt: sending to session \(session.id) (attempt \(attempt))")
                let result = sendTurnInternal(session: session, prompt: prompt, context: nil)
                if result.contains("\"error\"") {
                    Log.warn("MCP initial_prompt: sendTurn failed — \(result)")
                }
                return
            }

            if attempt >= maxAttempts {
                Log.warn("MCP initial_prompt: giving up after \(maxAttempts) attempts, session state=\(session.state.rawValue)")
                session.journal.append(
                    sessionID: session.id,
                    turnID: nil,
                    type: "initial_prompt_failed",
                    data: ["reason": "timeout", "state": session.state.rawValue, "attempts": "\(maxAttempts)"]
                )
                return
            }

            scheduleInitialPrompt(session: session, prompt: prompt, attempt: attempt + 1)
        }
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
            _ = controlService.closeTab(tabID: session.tabID.uuidString, force: true)
        }

        return encodeAny(["ok": stopped, "session_id": sessionID, "final_state": session.state.rawValue])
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
        guard session.canAcceptTurn else {
            Log.info("MCP runtime_turn_send: rejected for session \(session.id), state=\(session.state.rawValue)")
            return jsonError("Session \(session.id) is not ready (state: \(session.state.rawValue)). Wait for ready state.")
        }

        guard let turnID = session.startTurn(prompt: prompt, resultSchema: resultSchema) else {
            Log.error("MCP runtime_turn_send: startTurn failed for session \(session.id)")
            return jsonError("Failed to start turn in session \(session.id)")
        }

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
        if let activeRun = controlService.activeRunSummary(forOverlayTabID: session.tabID) {
            summary["active_run"] = activeRun
        }
        return summary
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
