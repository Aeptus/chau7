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
        let env = args["env"] as? [String: String] ?? [:]
        let backendArgs = args["backend_args"] as? [String] ?? []
        let initialPrompt = args["initial_prompt"] as? String
        let autoApprove = args["auto_approve"] as? Bool ?? false
        let attachTabID = args["attach_tab_id"] as? String

        // Resolve backend via registry
        Self.backendsLock.lock()
        let factory = Self.backends[backendName]
        let validKeys = Self.backends.keys.sorted()
        Self.backendsLock.unlock()

        guard let factory else {
            return jsonError("Unknown backend: \(backendName). Valid: \(validKeys.joined(separator: ", "))")
        }
        let backend = factory()

        let config = SessionConfig(
            directory: directory,
            provider: backendName,
            model: model,
            resumeSessionID: resumeID,
            environment: env,
            args: backendArgs,
            autoApprove: autoApprove
        )

        // Create or attach to tab
        let tabID: UUID
        if let attachStr = attachTabID, let uuid = UUID(uuidString: attachStr) {
            tabID = uuid
        } else {
            // Create a new tab via TerminalControlService
            let tabResult = controlService.createTab(directory: directory, windowID: nil)
            guard let data = tabResult.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tabIDStr = json["tab_id"] as? String,
                  let uuid = UUID(uuidString: tabIDStr) else {
                return jsonError("Failed to create tab: \(tabResult)")
            }
            tabID = uuid
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
            _ = controlService.execInTab(tabID: tabID.uuidString, command: launchCmd)
            sessionManager.markReady(sessionID: session.id)
        }

        // Send initial prompt if provided (after a short delay for backend startup)
        if let prompt = initialPrompt {
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self else { return }
                _ = sendTurnInternal(session: session, prompt: prompt, context: nil)
            }
        }

        return encodeAny(session.summary())
    }

    private func listSessions(_ args: [String: Any]) -> String {
        let includeStopped = args["include_stopped"] as? Bool ?? false
        let sessions = sessionManager.allSessions(includeStopped: includeStopped)
        let summaries = sessions.map { $0.summary() }
        return encodeAny(summaries)
    }

    private func getSession(_ args: [String: Any]) -> String {
        guard let sessionID = args["session_id"] as? String else {
            return jsonError("session_id is required")
        }
        guard let session = sessionManager.session(id: sessionID) else {
            return jsonError("Session not found: \(sessionID)")
        }
        return encodeAny(session.summary())
    }

    private func stopSession(_ args: [String: Any]) -> String {
        guard let sessionID = args["session_id"] as? String else {
            return jsonError("session_id is required")
        }
        let closeTab = args["close_tab"] as? Bool ?? false
        let force = args["force"] as? Bool ?? false

        guard let session = sessionManager.session(id: sessionID) else {
            return jsonError("Session not found: \(sessionID)")
        }

        // Send Ctrl+C if force
        if force || session.state == .busy || session.state == .awaitingApproval {
            _ = controlService.sendInput(tabID: session.tabID.uuidString, input: "\u{3}") // Ctrl+C
        }

        let stopped = sessionManager.stopSession(id: sessionID)

        if closeTab {
            _ = controlService.closeTab(tabID: session.tabID.uuidString, force: true)
        }

        return encodeAny(["ok": stopped, "session_id": sessionID])
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

        guard let session = sessionManager.session(id: sessionID) else {
            return jsonError("Session not found: \(sessionID)")
        }

        return sendTurnInternal(session: session, prompt: prompt, context: context)
    }

    private func sendTurnInternal(session: RuntimeSession, prompt: String, context: String?) -> String {
        guard session.canAcceptTurn else {
            return jsonError("Session \(session.id) is not ready (state: \(session.state.rawValue)). Wait for ready state.")
        }

        guard let turnID = session.startTurn(prompt: prompt) else {
            return jsonError("Failed to start turn in session \(session.id)")
        }

        // Format and send to PTY
        let input = session.backend.formatPromptInput(prompt, context: context)
        _ = controlService.sendInput(tabID: session.tabID.uuidString, input: input)

        return encodeAny([
            "turn_id": turnID,
            "status": "accepted",
            "cursor": session.journal.latestCursor
        ])
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
        if let approval = session.pendingApproval {
            result["pending_approval"] = [
                "id": approval.id,
                "tool": approval.tool,
                "description": approval.description
            ]
        }
        return encodeAny(result)
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
            NotificationCenter.default.post(name: .clearPersistentTabStyle, object: session.tabID)
        }

        return encodeAny(["ok": true, "approved": approved])
    }

    // MARK: - Helpers

    private func jsonError(_ message: String) -> String {
        "{\"error\":\"\(message.replacingOccurrences(of: "\"", with: "\\\""))\"}"
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
