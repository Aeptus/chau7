import Foundation
import Chau7Core

/// Handles a single MCP client connection over a Unix domain socket.
/// Implements the MCP JSON-RPC protocol for tool calls and resource reads.
final class MCPSession {
    private static let socketIdleTimeoutSeconds = 120

    private let fd: Int32
    private let queryService = TelemetryQueryService()
    private let controlService = TerminalControlService.shared
    private let controlPlane = ControlPlaneService.shared

    init(fd: Int32) {
        self.fd = fd
    }

    /// Blocking run loop: reads JSON-RPC messages, dispatches, writes responses.
    /// Note: this takes ownership of fd — the fd is closed when the session ends.
    func run() {
        configureSocketTimeouts()
        let readStream = fdopen(fd, "r")
        // dup() so each FILE* owns its own fd — avoids double-close
        let writeFD = dup(fd)
        let writeStream = writeFD >= 0 ? fdopen(writeFD, "w") : nil
        guard let readStream, let writeStream else {
            if let readStream { fclose(readStream) }
            else { close(fd) }
            if writeFD >= 0, writeStream == nil { close(writeFD) }
            return
        }

        defer {
            fclose(readStream) // closes original fd
            fclose(writeStream) // closes dup'd fd
        }

        while true {
            var line: UnsafeMutablePointer<CChar>?
            var lineCap = 0
            errno = 0
            let bytesRead = getline(&line, &lineCap, readStream)
            guard bytesRead > 0, let line else {
                if errno == EINTR {
                    continue
                }
                if errno == EAGAIN || errno == EWOULDBLOCK || errno == ETIMEDOUT {
                    Log.info("MCPSession: closing idle client after read timeout (fd=\(fd))")
                } else if errno != 0 {
                    Log.warn("MCPSession: read failed for fd=\(fd): \(String(cString: strerror(errno)))")
                }
                break
            }
            defer { free(line) }

            let lineStr = String(cString: line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !lineStr.isEmpty else { continue }

            // Parse JSON-RPC request
            guard let data = lineStr.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                writeError(to: writeStream, id: nil, code: -32700, message: "Parse error")
                continue
            }

            let id = json["id"]
            let method = json["method"] as? String ?? ""
            let params = json["params"] as? [String: Any] ?? [:]

            let response = handleMethod(method, params: params, id: id)
            writeLine(to: writeStream, json: response)
        }
    }

    private func configureSocketTimeouts() {
        var timeout = timeval(tv_sec: Self.socketIdleTimeoutSeconds, tv_usec: 0)
        withUnsafePointer(to: &timeout) { ptr in
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
            _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, ptr, socklen_t(MemoryLayout<timeval>.size))
        }
    }

    // MARK: - Method Dispatch

    private func handleMethod(_ method: String, params: [String: Any], id: Any?) -> [String: Any] {
        switch method {
        case "initialize":
            return buildResult(id: id, result: [
                "protocolVersion": "2024-11-05",
                "capabilities": [
                    "tools": ["listChanged": false],
                    "resources": ["subscribe": false, "listChanged": false]
                ],
                "serverInfo": [
                    "name": "chau7",
                    "version": "1.1.0"
                ]
            ])

        case "notifications/initialized":
            // Client acknowledgment — no response needed for notifications
            return [:]

        case "tools/list":
            return buildResult(id: id, result: ["tools": toolDefinitions()])

        case "tools/call":
            let toolName = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let result = callTool(toolName, arguments: args)
            return buildResult(id: id, result: [
                "content": [["type": "text", "text": result]]
            ])

        case "resources/list":
            return buildResult(id: id, result: ["resources": resourceDefinitions()])

        case "resources/read":
            let uri = params["uri"] as? String ?? ""
            let content = readResource(uri)
            return buildResult(id: id, result: [
                "contents": [["uri": uri, "mimeType": "application/json", "text": content]]
            ])

        case "ping":
            return buildResult(id: id, result: [:])

        default:
            return buildError(id: id, code: -32601, message: "Method not found: \(method)")
        }
    }

    // MARK: - Tool Definitions

    // swiftlint:disable:next function_body_length
    private func toolDefinitions() -> [[String: Any]] {
        [
            [
                "name": "run_get",
                "description": "Get a single telemetry run by ID",
                "inputSchema": [
                    "type": "object",
                    "properties": ["run_id": ["type": "string", "description": "Run UUID"]],
                    "required": ["run_id"]
                ]
            ],
            [
                "name": "run_list",
                "description": "List telemetry runs with optional filters",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string"],
                        "repo_path": ["type": "string"],
                        "provider": ["type": "string"],
                        "parent_run_id": ["type": "string"],
                        "after": ["type": "string", "description": "ISO 8601 datetime"],
                        "before": ["type": "string", "description": "ISO 8601 datetime"],
                        "tags": ["type": "array", "items": ["type": "string"]],
                        "limit": ["type": "integer"],
                        "offset": ["type": "integer"]
                    ]
                ]
            ],
            [
                "name": "run_tool_calls",
                "description": "Get all tool calls for a run",
                "inputSchema": [
                    "type": "object",
                    "properties": ["run_id": ["type": "string"]],
                    "required": ["run_id"]
                ]
            ],
            [
                "name": "run_transcript",
                "description": "Get the full conversation transcript (turns) for a run",
                "inputSchema": [
                    "type": "object",
                    "properties": ["run_id": ["type": "string"]],
                    "required": ["run_id"]
                ]
            ],
            [
                "name": "run_tag",
                "description": "Set tags on a run",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "run_id": ["type": "string"],
                        "tags": ["type": "array", "items": ["type": "string"]]
                    ],
                    "required": ["run_id", "tags"]
                ]
            ],
            [
                "name": "run_latest_for_repo",
                "description": "Get the most recent run for a repository",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "repo_path": ["type": "string"],
                        "provider": ["type": "string"]
                    ],
                    "required": ["repo_path"]
                ]
            ],
            [
                "name": "session_list",
                "description": "List AI sessions with run counts",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "repo_path": ["type": "string"],
                        "active_only": ["type": "boolean"]
                    ]
                ]
            ],
            [
                "name": "session_current",
                "description": "Get currently active AI sessions",
                "inputSchema": ["type": "object", "properties": [:]]
            ],

            // MARK: Control Plane Tools

            [
                "name": "tab_list",
                "description": "List all open Chau7 tabs across all windows. Each tab includes a window_id field identifying which window it belongs to.",
                "inputSchema": ["type": "object", "properties": [:]]
            ],
            [
                "name": "tab_create",
                "description": "Open a new terminal tab in Chau7. Returns the tab ID for subsequent operations.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "directory": ["type": "string", "description": "Working directory for the new tab"],
                        "window_id": ["type": "integer", "description": "Target window (from tab_list). Defaults to window 0."]
                    ]
                ]
            ],
            [
                "name": "tab_exec",
                "description": "Execute a shell command in a tab. The tab must be at prompt (idle). Use tab_status to check first.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Deterministic tab ID from tab_create or tab_list, such as 'tab_1'"],
                        "command": ["type": "string", "description": "Shell command to execute"]
                    ],
                    "required": ["tab_id", "command"]
                ]
            ],
            [
                "name": "tab_status",
                "description": "Get detailed status of a tab: process state, working directory, active app, child processes, and active telemetry run",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Deterministic tab ID, such as 'tab_1'"]
                    ],
                    "required": ["tab_id"]
                ]
            ],
            [
                "name": "tab_send_input",
                "description": "Send raw input to a tab's terminal (for interactive prompts, confirmations, etc). Does NOT append newline — include \\n if needed.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Deterministic tab ID, such as 'tab_1'"],
                        "input": ["type": "string", "description": "Raw text to send to the terminal"]
                    ],
                    "required": ["tab_id", "input"]
                ]
            ],
            [
                "name": "tab_press_key",
                "description": "Send a terminal key press to a tab (for interactive TUIs like Claude Code). Use this for Enter, Escape, arrows, backspace, and control/alt key combos.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Deterministic tab ID, such as 'tab_1'"],
                        "key": [
                            "type": "string",
                            "description": "Key name, e.g. enter, escape, tab, up, down, left, right, backspace, delete, home, end, page_up, page_down, insert, or a single character for ctrl/alt combos"
                        ],
                        "modifiers": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional modifiers: shift, control/ctrl, option/alt/meta"
                        ]
                    ],
                    "required": ["tab_id", "key"]
                ]
            ],
            [
                "name": "tab_submit_prompt",
                "description": "Submit the current interactive prompt in a tab by sending Enter as a key press.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Deterministic tab ID, such as 'tab_1'"]
                    ],
                    "required": ["tab_id"]
                ]
            ],
            [
                "name": "tab_close",
                "description": "Close a tab. Fails if a process is running unless force=true.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Deterministic tab ID, such as 'tab_1'"],
                        "force": ["type": "boolean", "description": "Close even if processes are running"]
                    ],
                    "required": ["tab_id"]
                ]
            ],
            [
                "name": "tab_output",
                "description": "Get recent terminal output from a tab. By default reads the terminal scrollback buffer. Use source='pty_log' to get the full ANSI-stripped PTY output log — this captures everything including content from TUI alternate screens that is no longer in the scrollback.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Deterministic tab ID, such as 'tab_1'"],
                        "lines": ["type": "integer", "description": "Number of lines to return (default 50, max 10000)"],
                        "wait_for_stable_ms": ["type": "integer", "description": "Wait until buffer content is stable for this many ms before returning (max 30000). Only applies to source='buffer'."],
                        "source": [
                            "type": "string",
                            "description": "Data source: 'buffer' (default, terminal scrollback) or 'pty_log' (ANSI-stripped raw PTY output — captures full AI session including alternate screen content)"
                        ]
                    ],
                    "required": ["tab_id"]
                ]
            ],
            [
                "name": "tab_set_cto",
                "description": "Set the CTO (Command Token Optimization) override for a tab. 'default' follows the global mode, 'forceOn' always active, 'forceOff' always inactive.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Deterministic tab ID, such as 'tab_1'"],
                        "override": ["type": "string", "description": "Override value: 'default', 'forceOn', or 'forceOff'"]
                    ],
                    "required": ["tab_id", "override"]
                ]
            ],

            [
                "name": "tab_rename",
                "description": "Set a custom title for a tab. Pass an empty string to clear the custom title.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Deterministic tab ID, such as 'tab_1'"],
                        "title": ["type": "string", "description": "New custom title for the tab. Empty string clears it."]
                    ],
                    "required": ["tab_id", "title"]
                ]
            ],

            // MARK: Repo Metadata Tools

            [
                "name": "repo_get_metadata",
                "description": "Get metadata for a repository including description, labels, favorite files, and frequent commands.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "repo_path": ["type": "string", "description": "Absolute path to the repository root"]
                    ],
                    "required": ["repo_path"]
                ]
            ],
            [
                "name": "repo_set_metadata",
                "description": "Set metadata for a repository (description, labels, favorite files). Only provided fields are updated.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "repo_path": ["type": "string", "description": "Absolute path to the repository root"],
                        "description": ["type": "string", "description": "Repository description"],
                        "labels": ["type": "array", "items": ["type": "string"], "description": "Tags/categories for the repo"],
                        "favorite_files": ["type": "array", "items": ["type": "string"], "description": "Relative paths to important files"]
                    ],
                    "required": ["repo_path"]
                ]
            ],
            [
                "name": "repo_frequent_commands",
                "description": "Get frequently used commands for a repository, sorted by frecency.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "repo_path": ["type": "string", "description": "Absolute path to the repository root"],
                        "limit": ["type": "integer", "description": "Max commands to return (default 20)"]
                    ],
                    "required": ["repo_path"]
                ]
            ],

            [
                "name": "repo_get_events",
                "description": "Get recent events for a repository. Returns AI tool events (finished, permission, tool_called, etc.) scoped to the given repo.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "repo_path": ["type": "string", "description": "Absolute path to the repository root"],
                        "limit": ["type": "integer", "description": "Max events to return (default 20, max 50)"]
                    ],
                    "required": ["repo_path"]
                ]
            ],

            // MARK: Runtime API Tools

            [
                "name": "runtime_session_create",
                "description": "Start an agent session. Creates a tab, launches the backend (claude/codex/shell), and returns a session ID for subsequent operations.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "backend": ["type": "string", "description": "Backend to use: 'claude' (default), 'codex', or 'shell'"],
                        "directory": ["type": "string", "description": "Working directory for the session"],
                        "model": [
                            "type": "string",
                            "description": "Model override. Must match the backend: claude accepts 'opus', 'sonnet', 'haiku'; codex accepts 'o3', 'o4-mini', 'gpt-4.1'. Cross-backend models (e.g. 'sonnet' with codex) are rejected."
                        ],
                        "resume_session_id": ["type": "string", "description": "Resume an existing agent session by ID"],
                        "env": ["type": "object", "description": "Extra environment variables"],
                        "backend_args": ["type": "array", "items": ["type": "string"], "description": "Additional CLI arguments"],
                        "initial_prompt": ["type": "string", "description": "Prompt to send immediately after backend starts. Delivered with retry (up to ~4s) to handle backend startup time."],
                        "auto_approve": ["type": "boolean", "description": "Auto-approve safe tool use requests. For claude: --dangerously-skip-permissions. For codex: --full-auto."],
                        "attach_tab_id": ["type": "string", "description": "Attach to an existing deterministic tab ID such as 'tab_1' instead of creating a new tab"],
                        "purpose": ["type": "string", "description": "Optional generic purpose label for the session, such as 'code_review'."],
                        "parent_session_id": ["type": "string", "description": "Runtime session ID that delegated this child session."],
                        "parent_run_id": ["type": "string", "description": "Telemetry run ID that delegated this child session."],
                        "task_metadata": ["type": "object", "description": "Arbitrary string metadata persisted onto delegated telemetry runs."],
                        "result_schema": ["type": "object", "description": "Optional JSON-schema-like object used to extract a structured final result from completed turns."],
                        "delegation_depth": ["type": "integer", "description": "Delegation nesting depth. Zero means top-level."],
                        "policy": [
                            "type": "object",
                            "description": "Optional delegated-session policy. Enforced limits include max_turns, max_duration_ms, child delegation, depth, and tool allow/block lists. Network/filesystem flags are advisory until paired with backend sandboxing."
                        ]
                    ]
                ]
            ],
            [
                "name": "runtime_session_list",
                "description": "List active runtime sessions.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "include_stopped": ["type": "boolean", "description": "Include recently stopped sessions"]
                    ]
                ]
            ],
            [
                "name": "runtime_session_get",
                "description": "Get detailed state of a runtime session.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Runtime session ID"]
                    ],
                    "required": ["session_id"]
                ]
            ],
            [
                "name": "runtime_session_stop",
                "description": "Gracefully stop a runtime session.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Runtime session ID"],
                        "close_tab": ["type": "boolean", "description": "Also close the tab"],
                        "force": ["type": "boolean", "description": "Send Ctrl+C before stopping"]
                    ],
                    "required": ["session_id"]
                ]
            ],
            [
                "name": "runtime_session_children",
                "description": "List child runtime sessions delegated from a parent session.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Parent runtime session ID"],
                        "include_stopped": ["type": "boolean", "description": "Include recently stopped child sessions"],
                        "recursive": ["type": "boolean", "description": "Include all descendants, not just direct children"]
                    ],
                    "required": ["session_id"]
                ]
            ],
            [
                "name": "runtime_session_cancel_children",
                "description": "Stop all active descendant sessions delegated from a parent session.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Parent runtime session ID"],
                        "close_tabs": ["type": "boolean", "description": "Also close child tabs after stopping them"],
                        "force": ["type": "boolean", "description": "Send Ctrl+C to busy child sessions before stopping"]
                    ],
                    "required": ["session_id"]
                ]
            ],
            [
                "name": "runtime_session_retry",
                "description": "Create a fresh session using the configuration of an existing runtime session.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Runtime session ID to clone"],
                        "prompt": ["type": "string", "description": "Optional prompt override; defaults to the last submitted prompt when available"]
                    ],
                    "required": ["session_id"]
                ]
            ],
            [
                "name": "runtime_turn_send",
                "description": "Send a prompt to an agent session. Session must be in 'ready' state. Use runtime_turn_status or runtime_events_poll to check readiness first. Returns error with current state if not ready.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Runtime session ID"],
                        "prompt": ["type": "string", "description": "The prompt to send to the agent"],
                        "context": ["type": "string", "description": "Optional context prepended to the prompt"],
                        "result_schema": ["type": "object", "description": "Optional turn-specific JSON-schema-like object used to extract a structured result."]
                    ],
                    "required": ["session_id", "prompt"]
                ]
            ],
            [
                "name": "runtime_turn_status",
                "description": "Check the current turn state of a session.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Runtime session ID"],
                        "turn_id": ["type": "string", "description": "Optional specific turn ID"]
                    ],
                    "required": ["session_id"]
                ]
            ],
            [
                "name": "runtime_turn_result",
                "description": "Fetch the latest structured result captured for a session, or a specific turn result when turn_id is provided.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Runtime session ID"],
                        "turn_id": ["type": "string", "description": "Optional specific turn ID"]
                    ],
                    "required": ["session_id"]
                ]
            ],
            [
                "name": "runtime_turn_wait",
                "description": "Block until the current turn or a specific turn finishes, then return the latest turn status.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Runtime session ID"],
                        "turn_id": ["type": "string", "description": "Optional specific turn ID"],
                        "timeout_ms": ["type": "integer", "description": "Maximum time to wait before returning a timed_out=true response"]
                    ],
                    "required": ["session_id"]
                ]
            ],
            [
                "name": "runtime_events_poll",
                "description": "Poll for new events from a session using a cursor. Returns events after the cursor position.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Runtime session ID"],
                        "cursor": ["type": "integer", "description": "Cursor from previous poll (0 for first poll)"],
                        "limit": ["type": "integer", "description": "Max events to return (default 50)"]
                    ],
                    "required": ["session_id"]
                ]
            ],
            [
                "name": "runtime_approval_respond",
                "description": "Approve or deny a pending tool use request from the agent.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "session_id": ["type": "string", "description": "Runtime session ID"],
                        "approval_id": ["type": "string", "description": "Approval request ID from approval_needed event"],
                        "approved": ["type": "boolean", "description": "Whether to approve the tool use"],
                        "reason": ["type": "string", "description": "Reason for decision"]
                    ],
                    "required": ["session_id", "approval_id", "approved"]
                ]
            ]
        ]
    }

    // MARK: - Tool Execution

    private func callTool(_ name: String, arguments: [String: Any]) -> String {
        switch name {
        case "run_get":
            guard let runID = arguments["run_id"] as? String else {
                return jsonError("run_id is required")
            }
            return queryService.getRun(runID)

        case "run_list":
            return queryService.listRuns(arguments)

        case "run_tool_calls":
            guard let runID = arguments["run_id"] as? String else {
                return jsonError("run_id is required")
            }
            return queryService.getToolCalls(runID)

        case "run_transcript":
            guard let runID = arguments["run_id"] as? String else {
                return jsonError("run_id is required")
            }
            return queryService.getTranscript(runID)

        case "run_tag":
            guard let runID = arguments["run_id"] as? String,
                  let tags = arguments["tags"] as? [String] else {
                return jsonError("run_id and tags are required")
            }
            return queryService.tagRun(runID, tags: tags)

        case "run_latest_for_repo":
            guard let repoPath = arguments["repo_path"] as? String else {
                return jsonError("repo_path is required")
            }
            let provider = arguments["provider"] as? String
            return queryService.latestRunForRepo(repoPath, provider: provider)

        case "session_list":
            let repoPath = arguments["repo_path"] as? String
            let activeOnly = arguments["active_only"] as? Bool ?? false
            return queryService.listSessions(repoPath: repoPath, activeOnly: activeOnly)

        case "session_current":
            return queryService.currentSessions()

        // Control plane
        case "tab_list":
            return controlPlane.call(name: "tab_list", arguments: arguments)

        case "tab_create":
            return controlPlane.call(name: "tab_create", arguments: arguments)

        case "tab_exec":
            return controlPlane.call(name: "tab_exec", arguments: arguments)

        case "tab_status":
            return controlPlane.call(name: "tab_status", arguments: arguments)

        case "tab_send_input":
            return controlPlane.call(name: "tab_send_input", arguments: arguments)

        case "tab_press_key":
            return controlPlane.call(name: "tab_press_key", arguments: arguments)

        case "tab_submit_prompt":
            return controlPlane.call(name: "tab_submit_prompt", arguments: arguments)

        case "tab_close":
            return controlPlane.call(name: "tab_close", arguments: arguments)

        case "tab_output":
            return controlPlane.call(name: "tab_output", arguments: arguments)

        case "tab_set_cto":
            guard let tabID = arguments["tab_id"] as? String,
                  let override = arguments["override"] as? String else {
                return jsonError("tab_id and override are required")
            }
            return controlService.setCTO(tabID: tabID, override: override)

        case "tab_rename":
            guard let tabID = arguments["tab_id"] as? String,
                  let title = arguments["title"] as? String else {
                return jsonError("tab_id and title are required")
            }
            return controlService.renameTab(tabID: tabID, title: title)

        // Repo Metadata
        case "repo_get_metadata":
            guard let repoPath = arguments["repo_path"] as? String else {
                return jsonError("repo_path is required")
            }
            return controlService.getRepoMetadata(repoPath: repoPath)

        case "repo_set_metadata":
            guard let repoPath = arguments["repo_path"] as? String else {
                return jsonError("repo_path is required")
            }
            return controlService.setRepoMetadata(
                repoPath: repoPath,
                description: arguments["description"] as? String,
                labels: arguments["labels"] as? [String],
                favoriteFiles: arguments["favorite_files"] as? [String]
            )

        case "repo_frequent_commands":
            guard let repoPath = arguments["repo_path"] as? String else {
                return jsonError("repo_path is required")
            }
            let limit = arguments["limit"] as? Int ?? 20
            return controlService.repoFrequentCommands(repoPath: repoPath, limit: limit)

        case "repo_get_events":
            guard let repoPath = arguments["repo_path"] as? String else {
                return jsonError("repo_path is required")
            }
            let limit = min(arguments["limit"] as? Int ?? 20, 50)
            return controlService.repoGetEvents(repoPath: repoPath, limit: limit)

        // Runtime API
        case let name where name.hasPrefix("runtime_"):
            return controlPlane.call(name: name, arguments: arguments)

        default:
            return jsonError("Unknown tool: \(name)")
        }
    }

    // MARK: - Resource Definitions

    private func resourceDefinitions() -> [[String: Any]] {
        [
            [
                "uri": "chau7://telemetry/runs",
                "name": "Recent Runs",
                "description": "Latest telemetry run summaries",
                "mimeType": "application/json"
            ],
            [
                "uri": "chau7://telemetry/sessions",
                "name": "Sessions",
                "description": "AI session index",
                "mimeType": "application/json"
            ],
            [
                "uri": "chau7://telemetry/sessions/current",
                "name": "Current Sessions",
                "description": "Currently active AI sessions",
                "mimeType": "application/json"
            ]
        ]
    }

    private func readResource(_ uri: String) -> String {
        switch uri {
        case "chau7://telemetry/runs":
            return queryService.listRuns(["limit": 20])
        case "chau7://telemetry/sessions":
            return queryService.listSessions()
        case "chau7://telemetry/sessions/current":
            return queryService.currentSessions()
        default:
            // Try chau7://telemetry/runs/<run_id>
            if uri.hasPrefix("chau7://telemetry/runs/") {
                let runID = String(uri.dropFirst("chau7://telemetry/runs/".count))
                return queryService.getRun(runID)
            }
            return jsonError("Unknown resource: \(uri)")
        }
    }

    // MARK: - JSON-RPC Helpers

    private func buildResult(id: Any?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id as Any, "result": result]
    }

    private func buildError(id: Any?, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id as Any, "error": ["code": code, "message": message]]
    }

    private func writeError(to stream: UnsafeMutablePointer<FILE>, id: Any?, code: Int, message: String) {
        writeLine(to: stream, json: buildError(id: id, code: code, message: message))
    }

    private func writeLine(to stream: UnsafeMutablePointer<FILE>, json: [String: Any]) {
        guard !json.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: json),
              let line = String(data: data, encoding: .utf8) else { return }
        fputs(line + "\n", stream)
        fflush(stream)
    }

    private func jsonError(_ message: String) -> String {
        "{\"error\":\"\(message.replacingOccurrences(of: "\"", with: "\\\""))\"}"
    }
}
