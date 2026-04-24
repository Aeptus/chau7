import Foundation

/// Canonical internal control plane shared by MCP and the local scripting API.
/// Transport adapters should only parse requests and pack responses.
final class ControlPlaneService {
    static let shared = ControlPlaneService()

    private let terminalControl = TerminalControlService.shared

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
        case "tab_wait_ready":
            guard let tabID = arguments["tab_id"] as? String else {
                return jsonError("tab_id is required")
            }
            return terminalControl.waitForTabReady(
                tabID: tabID,
                timeoutMs: arguments["timeout_ms"] as? Int ?? 30000
            )
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
        default:
            return jsonError("Unknown control plane command: \(name)")
        }
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
