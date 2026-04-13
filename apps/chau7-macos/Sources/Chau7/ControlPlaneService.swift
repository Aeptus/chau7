import Foundation
import Chau7Core

/// Canonical internal control plane shared by MCP and the local scripting API.
/// Transport adapters should only parse requests and pack responses.
final class ControlPlaneService {
    static let shared = ControlPlaneService()

    private struct PreparedTurn {
        let prompt: String
        let resultSchema: JSONValue
    }

    private struct ReviewRequest {
        let directory: String
        let backend: String
        let model: String?
        let parentSessionID: String?
        let delegationDepth: Int?
        let autoApprove: Bool?
        let prompt: String
        let taskMetadata: [String: String]
        let resultSchema: JSONValue
    }

    private let terminalControl = TerminalControlService.shared
    private let runtimeControl = RuntimeControlService.shared
    private let preparedTurnsLock = NSLock()
    private var preparedSessionTurns: [String: PreparedTurn] = [:]

    private init() {}

    func call(name: String, arguments: [String: Any]) -> String {
        switch name {
        case "tab_list":
            return terminalControl.listTabs()
        case "tab_create":
            return terminalControl.createTab(
                directory: arguments["directory"] as? String,
                windowID: arguments["window_id"] as? Int
            )
        case "tab_exec":
            guard let tabID = arguments["tab_id"] as? String,
                  let command = arguments["command"] as? String else {
                return jsonError("tab_id and command are required")
            }
            return terminalControl.execInTab(tabID: tabID, command: command)
        case "tab_status":
            guard let tabID = arguments["tab_id"] as? String else {
                return jsonError("tab_id is required")
            }
            return terminalControl.tabStatus(tabID: tabID)
        case "tab_send_input":
            guard let tabID = arguments["tab_id"] as? String,
                  let input = arguments["input"] as? String else {
                return jsonError("tab_id and input are required")
            }
            return terminalControl.sendInput(tabID: tabID, input: input)
        case "tab_press_key":
            guard let tabID = arguments["tab_id"] as? String,
                  let key = arguments["key"] as? String else {
                return jsonError("tab_id and key are required")
            }
            let modifiers = arguments["modifiers"] as? [String] ?? []
            return terminalControl.pressKey(tabID: tabID, key: key, modifiers: modifiers)
        case "tab_submit_prompt":
            guard let tabID = arguments["tab_id"] as? String else {
                return jsonError("tab_id is required")
            }
            return terminalControl.submitPrompt(tabID: tabID)
        case "tab_close":
            guard let tabID = arguments["tab_id"] as? String else {
                return jsonError("tab_id is required")
            }
            return terminalControl.closeTab(tabID: tabID, force: arguments["force"] as? Bool ?? false)
        case "tab_output":
            guard let tabID = arguments["tab_id"] as? String else {
                return jsonError("tab_id is required")
            }
            let lines = max(1, min(arguments["lines"] as? Int ?? 50, 10000))
            return terminalControl.tabOutput(
                tabID: tabID,
                lines: lines,
                waitForStableMs: arguments["wait_for_stable_ms"] as? Int,
                source: arguments["source"] as? String
            )
        case "repo_get_events":
            guard let repoPath = arguments["repo_path"] as? String,
                  !repoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return jsonError("repo_path is required")
            }
            let limit = max(1, min(arguments["limit"] as? Int ?? 25, 200))
            return terminalControl.repoGetEvents(
                repoPath: repoPath,
                limit: limit,
                tabID: arguments["tab_id"] as? String,
                eventTypes: arguments["event_types"] as? [String],
                tool: arguments["tool"] as? String,
                producer: arguments["producer"] as? String,
                sessionID: arguments["session_id"] as? String,
                truncateMessages: arguments["truncate_messages"] as? Bool ?? true
            )
        case "session_create":
            return createSession(arguments)
        case "session_events":
            return sessionEvents(arguments)
        case "session_submit_turn":
            return submitSessionTurn(arguments)
        case "session_result":
            return sessionResult(arguments)
        case "session_stop":
            return stopSession(arguments)
        case let runtimeName where runtimeName.hasPrefix("runtime_"):
            return runtimeControl.handleToolCall(name: runtimeName, arguments: arguments)
        default:
            return jsonError("Unknown control plane command: \(name)")
        }
    }

    private func createSession(_ arguments: [String: Any]) -> String {
        guard let reviewRequest = buildReviewRequest(arguments) else {
            return encodeAny(buildReviewRequestError(arguments))
        }

        var runtimeArguments: [String: Any] = [
            "backend": reviewRequest.backend,
            "directory": reviewRequest.directory,
            "purpose": "code_review",
            "task_metadata": reviewRequest.taskMetadata,
            "result_schema": reviewRequest.resultSchema.foundationValue,
            "policy": CodeReviewTaskTemplate.defaultPolicy.foundationValue
        ]
        if let model = reviewRequest.model {
            runtimeArguments["model"] = model
        }
        if let parentSessionID = reviewRequest.parentSessionID {
            runtimeArguments["parent_session_id"] = parentSessionID
            runtimeArguments["delegation_depth"] = max(reviewRequest.delegationDepth ?? 1, 1)
        }
        if let autoApprove = reviewRequest.autoApprove {
            runtimeArguments["auto_approve"] = autoApprove
        }

        guard var response = parseJSONResponse(
            runtimeControl.handleToolCall(name: "runtime_session_create", arguments: runtimeArguments)
        ) else {
            return jsonError("review_start_failed")
        }
        guard let sessionID = response["session_id"] as? String else {
            return encodeAny(response)
        }

        storePreparedTurn(
            sessionID: sessionID,
            turn: PreparedTurn(prompt: reviewRequest.prompt, resultSchema: reviewRequest.resultSchema)
        )

        response["phase"] = "created"
        response["prompt_sent"] = false
        return encodeAny(response)
    }

    private func sessionEvents(_ arguments: [String: Any]) -> String {
        guard let sessionID = arguments["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return jsonError("missing param: session_id")
        }

        let cursor = parsedCursor(arguments["cursor"])
        let limit = max(1, min(arguments["limit"] as? Int ?? 50, 200))

        guard var response = parseJSONResponse(
            runtimeControl.handleToolCall(
                name: "runtime_events_poll",
                arguments: [
                    "session_id": sessionID,
                    "cursor": NSNumber(value: cursor),
                    "limit": limit
                ]
            )
        ) else {
            return jsonError("session_events_failed")
        }

        if let filter = arguments["event_types"] as? [String], !filter.isEmpty,
           let events = response["events"] as? [[String: Any]] {
            let allowed = Set(filter.filter { !$0.isEmpty })
            response["events"] = events.filter { allowed.contains($0["type"] as? String ?? "") }
        }
        response["session_id"] = sessionID
        return encodeAny(response)
    }

    private func submitSessionTurn(_ arguments: [String: Any]) -> String {
        guard let sessionID = arguments["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return jsonError("missing param: session_id")
        }
        guard let prepared = takePreparedTurn(sessionID: sessionID) else {
            return jsonError("session turn not prepared for session \(sessionID)")
        }

        guard let session = RuntimeSessionManager.shared.session(id: sessionID) else {
            return jsonError("Session not found: \(sessionID)")
        }
        guard session.canAcceptTurn else {
            storePreparedTurn(sessionID: sessionID, turn: prepared)
            return jsonError("Session \(sessionID) is not ready to accept the review prompt (state: \(session.state.rawValue))")
        }

        guard let response = parseJSONResponse(
            runtimeControl.handleToolCall(
                name: "runtime_turn_send",
                arguments: [
                    "session_id": sessionID,
                    "prompt": prepared.prompt,
                    "result_schema": prepared.resultSchema.foundationValue
                ]
            )
        ) else {
            storePreparedTurn(sessionID: sessionID, turn: prepared)
            return jsonError("review_prompt_failed")
        }

        if let error = response["error"] as? String {
            storePreparedTurn(sessionID: sessionID, turn: prepared)
            return encodeAny([
                "error": error,
                "session_id": sessionID,
                "phase": "prompt_failed"
            ])
        }

        let sessionState = sanitizeOptionalString(response["session_state"] as? String) ?? session.state.rawValue
        let status = sanitizeOptionalString(response["status"] as? String) ?? "accepted"
        let turnID = sanitizeOptionalString(response["turn_id"] as? String)

        var result: [String: Any] = [
            "session_id": sessionID,
            "phase": "prompt_sent",
            "prompt_sent": true,
            "status": status,
            "session_state": sessionState
        ]
        if let turnID {
            result["turn_id"] = turnID
        }
        if let cursor = response["cursor"] {
            result["cursor"] = cursor
        }
        return encodeAny(result)
    }

    private func sessionResult(_ arguments: [String: Any]) -> String {
        guard let sessionID = arguments["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return jsonError("missing param: session_id")
        }
        return runtimeControl.handleToolCall(
            name: "runtime_turn_result",
            arguments: ["session_id": sessionID]
        )
    }

    private func stopSession(_ arguments: [String: Any]) -> String {
        guard let sessionID = arguments["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return jsonError("missing param: session_id")
        }
        removePreparedTurn(sessionID: sessionID)
        return runtimeControl.handleToolCall(
            name: "runtime_session_stop",
            arguments: [
                "session_id": sessionID,
                "close_tab": true,
                "force": arguments["force"] as? Bool ?? false
            ]
        )
    }

    private func parsedCursor(_ raw: Any?) -> UInt64 {
        if let number = raw as? NSNumber {
            return number.uint64Value
        }
        if let integer = raw as? Int {
            return UInt64(integer)
        }
        if let string = raw as? String, let integer = UInt64(string) {
            return integer
        }
        return 0
    }

    private func sanitizeOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func buildReviewRequest(_ params: [String: Any]) -> ReviewRequest? {
        guard let directory = sanitizeOptionalString(params["directory"] as? String) else {
            return nil
        }

        let mode = ((params["mode"] as? String) ?? "staged_diff")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let extraInstructions = sanitizeOptionalString(params["extra_instructions"] as? String)
        let prompt: String
        var taskMetadata: [String: String] = [
            "review_mode": mode,
            "session_binding": "isolated"
        ]

        switch mode {
        case "commit_range":
            guard let baseCommit = sanitizeOptionalString(params["base_commit"] as? String),
                  let headCommit = sanitizeOptionalString(params["head_commit"] as? String) else {
                return nil
            }
            taskMetadata["base_commit"] = baseCommit
            taskMetadata["head_commit"] = headCommit
            prompt = CodeReviewTaskTemplate.prompt(
                baseCommit: baseCommit,
                headCommit: headCommit,
                extraInstructions: extraInstructions
            )
        case "staged_diff":
            guard let stagedDiff = sanitizeOptionalString(params["staged_diff"] as? String) else {
                return nil
            }
            let stagedFiles = (params["staged_files"] as? [String] ?? [])
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if !stagedFiles.isEmpty {
                taskMetadata["staged_files"] = stagedFiles.joined(separator: ",")
            }
            prompt = CodeReviewTaskTemplate.promptForStagedDiff(
                stagedFiles: stagedFiles,
                diff: stagedDiff,
                extraInstructions: extraInstructions
            )
        default:
            return nil
        }

        return ReviewRequest(
            directory: directory,
            backend: sanitizeOptionalString(params["backend"] as? String) ?? "codex",
            model: sanitizeOptionalString(params["model"] as? String),
            parentSessionID: sanitizeOptionalString(params["parent_session_id"] as? String),
            delegationDepth: params["delegation_depth"] as? Int,
            autoApprove: params["auto_approve"] as? Bool,
            prompt: prompt,
            taskMetadata: taskMetadata,
            resultSchema: CodeReviewTaskTemplate.resultSchema
        )
    }

    private func buildReviewRequestError(_ params: [String: Any]) -> [String: Any] {
        guard sanitizeOptionalString(params["directory"] as? String) != nil else {
            return ["error": "missing param: directory"]
        }

        let mode = ((params["mode"] as? String) ?? "staged_diff")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch mode {
        case "commit_range":
            return ["error": "missing params for commit_range review: base_commit and head_commit are required"]
        case "staged_diff":
            return ["error": "missing param: staged_diff"]
        default:
            return ["error": "unsupported review mode: \(mode)"]
        }
    }

    private func storePreparedTurn(sessionID: String, turn: PreparedTurn) {
        preparedTurnsLock.lock()
        preparedSessionTurns[sessionID] = turn
        preparedTurnsLock.unlock()
    }

    private func takePreparedTurn(sessionID: String) -> PreparedTurn? {
        preparedTurnsLock.lock()
        let turn = preparedSessionTurns.removeValue(forKey: sessionID)
        preparedTurnsLock.unlock()
        return turn
    }

    private func removePreparedTurn(sessionID: String) {
        preparedTurnsLock.lock()
        preparedSessionTurns.removeValue(forKey: sessionID)
        preparedTurnsLock.unlock()
    }

    private func parseJSONResponse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func jsonError(_ error: String) -> String {
        encodeAny(["error": error])
    }

    private func encodeAny(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else {
            return #"{"error":"serialization_failed"}"#
        }
        return json
    }
}
