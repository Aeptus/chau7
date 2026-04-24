import Foundation
import Chau7Core

/// Handles a single MCP client connection over a Unix domain socket.
/// Implements the MCP JSON-RPC protocol for tool calls and resource reads.
final class MCPSession {
    /// Keep MCP connections open long enough for slower multi-step workflows
    /// (reviews, eval harnesses, manual debugging) without forcing clients to
    /// reconnect between tool calls.
    private static let socketIdleTimeoutSeconds = 30 * 60
    private static let supportedProtocolVersions = ["2025-11-25", "2024-11-05"]
    private static let toolRateLimiterQueue = DispatchQueue(label: "com.chau7.mcp.tool-rate-limiter")
    private static var toolRateLimiter = MCPToolRateLimiter()

    private let fd: Int32
    private let queryService = TelemetryQueryService()
    private let controlService = TerminalControlService.shared
    private let controlPlane = ControlPlaneService.shared
    private let stateSnapshotService = Chau7StateSnapshotService.shared
    private var lifecycleState: LifecycleState = .awaitingInitialize
    private let writeQueue = DispatchQueue(label: "com.chau7.mcp.session.write")
    private let subscriptionStateQueue = DispatchQueue(label: "com.chau7.mcp.session.subscription-state")
    private let notificationSink: (([String: Any]) -> Void)?
    private var liveNotificationWriter: (([String: Any]) -> Void)?

    private struct SubscriptionState {
        let id: String
        let topics: [String]
        let createdAtMillis: Int64
        let heartbeatIntervalMs: Int
        var token: UUID?
        var heartbeatTimer: DispatchSourceTimer?
        var nextDeliverySequence: Int64
        var notificationsEmittedCount: Int
        var droppedNotificationCount: Int
        var lastNotificationAtMillis: Int64?
    }

    private var subscriptionState: SubscriptionState?

    private enum LifecycleState {
        case awaitingInitialize
        case awaitingInitializedNotification
        case ready
    }

    private enum ToolCallDisposition {
        case protocolError(code: Int, message: String, data: Any? = nil)
        case toolResult(ToolResult)
    }

    private struct ToolResult {
        let text: String
        let isError: Bool
        let structuredContent: [String: Any]?
    }

    init(fd: Int32, notificationSink: (([String: Any]) -> Void)? = nil) {
        self.fd = fd
        self.notificationSink = notificationSink
    }

    deinit {
        cancelSubscription()
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
            cancelSubscription()
            liveNotificationWriter = nil
            writeQueue.sync {}
            fclose(readStream) // closes original fd
            fclose(writeStream) // closes dup'd fd
        }

        liveNotificationWriter = { [weak self] payload in
            guard let self else { return }
            writeJSON(to: writeStream, json: payload, mirrorToNotificationSink: true)
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

            if let response = handleRequestObject(json) {
                writeJSON(to: writeStream, json: response)
            }
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

    func handleRequestObject(_ request: [String: Any]) -> [String: Any]? {
        let id = request["id"]
        let isNotification = request["id"] == nil

        guard (request["jsonrpc"] as? String) == "2.0" else {
            return responseOrNil(
                isNotification: isNotification,
                response: buildError(id: id, code: -32600, message: "Invalid Request: jsonrpc must be '2.0'")
            )
        }

        guard let method = request["method"] as? String, !method.isEmpty else {
            return responseOrNil(
                isNotification: isNotification,
                response: buildError(id: id, code: -32600, message: "Invalid Request: method is required")
            )
        }

        let rawParams = request["params"]
        guard rawParams == nil || rawParams is [String: Any] else {
            return responseOrNil(
                isNotification: isNotification,
                response: buildError(id: id, code: -32602, message: "Invalid params: params must be an object")
            )
        }

        let params = rawParams as? [String: Any] ?? [:]
        return handleMethod(method, params: params, id: id, isNotification: isNotification)
    }

    private func handleMethod(_ method: String, params: [String: Any], id: Any?, isNotification: Bool) -> [String: Any]? {
        switch method {
        case "initialize":
            guard lifecycleState == .awaitingInitialize else {
                return responseOrNil(
                    isNotification: isNotification,
                    response: buildError(id: id, code: -32600, message: "Session is already initialized")
                )
            }
            guard let requestedVersion = params["protocolVersion"] as? String, !requestedVersion.isEmpty else {
                return responseOrNil(
                    isNotification: isNotification,
                    response: buildError(id: id, code: -32602, message: "Invalid params: protocolVersion is required")
                )
            }
            guard let negotiatedVersion = negotiateProtocolVersion(requestedVersion) else {
                return responseOrNil(
                    isNotification: isNotification,
                    response: buildError(
                        id: id,
                        code: -32602,
                        message: "Unsupported protocol version: \(requestedVersion)",
                        data: ["supported": Self.supportedProtocolVersions]
                    )
                )
            }

            lifecycleState = .awaitingInitializedNotification
            return responseOrNil(
                isNotification: isNotification,
                response: buildResult(id: id, result: [
                    "protocolVersion": negotiatedVersion,
                    "capabilities": [
                        "tools": ["listChanged": false],
                        "resources": ["subscribe": false, "listChanged": false]
                    ],
                    "serverInfo": [
                        "name": "chau7",
                        "version": "1.1.0"
                    ]
                ])
            )

        case "notifications/initialized":
            if lifecycleState == .awaitingInitializedNotification {
                lifecycleState = .ready
            } else {
                Log.warn("MCPSession: received notifications/initialized before initialize")
            }
            return nil

        case "tools/list":
            if let errorResponse = requireInitializedResponse(for: method, id: id, isNotification: isNotification) {
                return errorResponse
            }
            return buildResult(id: id, result: ["tools": toolDefinitions()])

        case "tools/call":
            if let errorResponse = requireInitializedResponse(for: method, id: id, isNotification: isNotification) {
                return errorResponse
            }
            guard let toolName = params["name"] as? String, !toolName.isEmpty else {
                return responseOrNil(
                    isNotification: isNotification,
                    response: buildError(id: id, code: -32602, message: "Invalid params: name is required")
                )
            }
            guard params["arguments"] == nil || params["arguments"] is [String: Any] else {
                return responseOrNil(
                    isNotification: isNotification,
                    response: buildError(id: id, code: -32602, message: "Invalid params: arguments must be an object")
                )
            }

            switch callTool(toolName, arguments: params["arguments"] as? [String: Any] ?? [:]) {
            case let .protocolError(code, message, data):
                return responseOrNil(
                    isNotification: isNotification,
                    response: buildError(id: id, code: code, message: message, data: data)
                )
            case let .toolResult(result):
                var payload: [String: Any] = [
                    "content": [["type": "text", "text": result.text]]
                ]
                if result.isError {
                    payload["isError"] = true
                }
                if let structuredContent = result.structuredContent {
                    payload["structuredContent"] = structuredContent
                }
                return buildResult(id: id, result: payload)
            }

        case "resources/list":
            if let errorResponse = requireInitializedResponse(for: method, id: id, isNotification: isNotification) {
                return errorResponse
            }
            return buildResult(id: id, result: ["resources": resourceDefinitions()])

        case "resources/read":
            if let errorResponse = requireInitializedResponse(for: method, id: id, isNotification: isNotification) {
                return errorResponse
            }
            guard let uri = params["uri"] as? String, !uri.isEmpty else {
                return responseOrNil(
                    isNotification: isNotification,
                    response: buildError(id: id, code: -32602, message: "Invalid params: uri is required")
                )
            }
            switch readResource(uri) {
            case let .success(content):
                return buildResult(id: id, result: [
                    "contents": [["uri": uri, "mimeType": "application/json", "text": content]]
                ])
            case let .protocolError(code, message):
                return responseOrNil(
                    isNotification: isNotification,
                    response: buildError(id: id, code: code, message: message)
                )
            }

        case "ping":
            return responseOrNil(
                isNotification: isNotification,
                response: buildResult(id: id, result: [:])
            )

        default:
            return responseOrNil(
                isNotification: isNotification,
                response: buildError(id: id, code: -32601, message: "Method not found: \(method)")
            )
        }
    }

    // MARK: - Tool Definitions

    private func normalizedToolDefinitions(_ definitions: [[String: Any]]) -> [[String: Any]] {
        definitions.map { definition in
            guard var inputSchema = definition["inputSchema"] as? [String: Any],
                  (inputSchema["type"] as? String) == "object",
                  inputSchema["additionalProperties"] == nil else {
                return definition
            }

            var updatedDefinition = definition
            inputSchema["additionalProperties"] = false
            updatedDefinition["inputSchema"] = inputSchema
            return updatedDefinition
        }
    }

    // swiftlint:disable:next function_body_length
    private func toolDefinitions() -> [[String: Any]] {
        normalizedToolDefinitions([
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
                "description": "List telemetry/history AI sessions with run counts. Use tab_list and tab_status for live AI tab discovery.",
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
                "description": "Get currently active telemetry-backed AI sessions. Telemetry/history view only; use tab_list and tab_status for live tab discovery and control.",
                "inputSchema": ["type": "object", "properties": [:]]
            ],

            // MARK: Observability Tools

            [
                "name": "chau7_runtime_info",
                "description": "Get Chau7 build and process identity for external observability: app version, build metadata, process id, launch time, and observability schema version.",
                "inputSchema": ["type": "object", "properties": [:]]
            ],
            [
                "name": "chau7_runtime_events",
                "description": "Get recent Chau7 observability events for lifecycle correlation. Returns app-owned events plus unified non-app AI events with stable ids, timestamps, subsystem, and optional tab/session/run scoping.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "since_millis": ["type": "integer", "description": "Only return events at or after this Unix timestamp in milliseconds."],
                        "limit": ["type": "integer", "description": "Maximum events to return (default 200, max 500)."]
                    ]
                ]
            ],
            [
                "name": "chau7_timer_inventory",
                "description": "Get the current Chau7-owned timer and display-link inventory for observability. Includes stable timer ids, timer kind, subsystem, queue label, cadence, and active state.",
                "inputSchema": ["type": "object", "properties": [:]]
            ],
            [
                "name": "chau7_state_snapshot",
                "description": "Get the authoritative aggregated Chau7 state snapshot for external observers. Includes runtime identity, live tabs, pending approvals, repo event summaries, active telemetry runs/sessions, timers, the latest monotonic change sequence, and observer contract metadata.",
                "inputSchema": ["type": "object", "properties": [:]]
            ],
            [
                "name": "chau7_subscribe",
                "description": "Open a long-lived Chau7 state subscription on this MCP connection. Returns an initial aggregated snapshot, effective topic scope, subscription health metadata, and optional replayed changes since a cursor. Subsequent state deltas and heartbeat keepalives are emitted as JSON-RPC notifications.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "topics": [
                            "type": "array",
                            "items": ["type": "string"],
                            "description": "Optional topic filter. Supported topics include runtime-events, tab-state, approval-state, repo-events, telemetry-runs, timer-inventory, and session-state."
                        ],
                        "cursor": ["type": "integer", "description": "Optional last seen monotonic sequence number for replay."],
                        "replay_limit": ["type": "integer", "description": "Maximum replayed changes to include in the subscribe response (default 200, max 500)."],
                        "heartbeat_interval_ms": ["type": "integer", "description": "Optional heartbeat interval for subscription keepalive notifications (default 15000, min 1000, max 60000)."]
                    ]
                ]
            ],
            [
                "name": "chau7_unsubscribe",
                "description": "Stop the current Chau7 state subscription for this MCP connection.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "subscription_id": ["type": "string", "description": "Optional subscription id returned by chau7_subscribe."]
                    ]
                ]
            ],

            // MARK: Control Plane Tools

            [
                "name": "tab_list",
                "description": "List all open Chau7 tabs across all windows. This is the primary live discovery API for active AI work. Each tab includes a window_id field identifying which window it belongs to.",
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
                "description": "Execute a shell command in a tab. If the shell is still bootstrapping or the live view is not yet attached, Chau7 accepts the command and queues it automatically. Use tab_status.can_accept_exec or tab_wait_ready to gate deterministic launch submission, and ready_for_exec when you need immediate prompt-ready execution without queueing.",
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
                "description": "Get detailed live status of a tab: process state, working directory, active app, AI provider/session metadata, exec-acceptance fields (`can_accept_exec` / `exec_acceptance_mode`), prompt-ready fields (`ready_for_exec` / `readiness_reason`), child processes, and active telemetry run.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Deterministic tab ID, such as 'tab_1'"]
                    ],
                    "required": ["tab_id"]
                ]
            ],
            [
                "name": "tab_wait_ready",
                "description": "Wait for a tab to reach deterministic exec-acceptance state (`can_accept_exec=true`). Success means tab_exec will be accepted now, even if Chau7 still needs to queue during shell bootstrap. Returns the last observed tab status snapshot on success or timeout.",
                "inputSchema": [
                    "type": "object",
                    "properties": [
                        "tab_id": ["type": "string", "description": "Deterministic tab ID, such as 'tab_1'"],
                        "timeout_ms": ["type": "integer", "description": "Maximum wait in milliseconds before timing out. Defaults to 30000."]
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
            ]
        ])
    }

    // MARK: - Tool Execution

    private func callTool(_ name: String, arguments: [String: Any]) -> ToolCallDisposition {
        let availableDefinitions = toolDefinitions()
        guard let definition = availableDefinitions.first(where: { ($0["name"] as? String) == name }) else {
            return .protocolError(code: -32602, message: "Unknown tool: \(name)")
        }
        if let validationError = validate(arguments: arguments, against: definition, toolName: name) {
            return .protocolError(code: -32602, message: validationError)
        }

        let rateDecision = Self.toolRateLimiterQueue.sync { Self.toolRateLimiter.evaluate(toolName: name) }
        if !rateDecision.isAllowed {
            var details: [String: Any] = [
                "error": "rate_limit_exceeded",
                "tool": name
            ]
            var message = "Rate limit exceeded for tool '\(name)'."
            if let retryAfterSeconds = rateDecision.retryAfterSeconds {
                details["retry_after_seconds"] = retryAfterSeconds
                message += " Retry in \(Int(ceil(retryAfterSeconds))) seconds."
            }
            return .toolResult(toolErrorResult(message: message, structuredContent: details))
        }

        switch name {
        case "run_get":
            guard let runID = arguments["run_id"] as? String else {
                return .protocolError(code: -32602, message: "Invalid params: run_id is required")
            }
            return classifyToolResponse(queryService.getRun(runID))

        case "run_list":
            return classifyToolResponse(queryService.listRuns(arguments))

        case "run_tool_calls":
            guard let runID = arguments["run_id"] as? String else {
                return .protocolError(code: -32602, message: "Invalid params: run_id is required")
            }
            return classifyToolResponse(queryService.getToolCalls(runID))

        case "run_transcript":
            guard let runID = arguments["run_id"] as? String else {
                return .protocolError(code: -32602, message: "Invalid params: run_id is required")
            }
            return classifyToolResponse(queryService.getTranscript(runID))

        case "run_tag":
            guard let runID = arguments["run_id"] as? String,
                  let tags = arguments["tags"] as? [String] else {
                return .protocolError(code: -32602, message: "Invalid params: run_id and tags are required")
            }
            return classifyToolResponse(queryService.tagRun(runID, tags: tags))

        case "run_latest_for_repo":
            guard let repoPath = arguments["repo_path"] as? String else {
                return .protocolError(code: -32602, message: "Invalid params: repo_path is required")
            }
            let provider = arguments["provider"] as? String
            return classifyToolResponse(queryService.latestRunForRepo(repoPath, provider: provider))

        case "session_list":
            let repoPath = arguments["repo_path"] as? String
            let activeOnly = arguments["active_only"] as? Bool ?? false
            return classifyToolResponse(queryService.listSessions(repoPath: repoPath, activeOnly: activeOnly))

        case "session_current":
            return classifyToolResponse(queryService.currentSessions())

        case "chau7_runtime_info":
            return classifyToolResponse(Chau7ObservabilityService.shared.runtimeInfoJSON())

        case "chau7_runtime_events":
            let sinceMillis = arguments["since_millis"] as? Int64
                ?? (arguments["since_millis"] as? Int).map(Int64.init)
            let limit = arguments["limit"] as? Int ?? 200
            return classifyToolResponse(Chau7ObservabilityService.shared.runtimeEventsJSON(sinceMillis: sinceMillis, limit: limit))

        case "chau7_timer_inventory":
            return classifyToolResponse(Chau7ObservabilityService.shared.timerInventoryJSON())

        case "chau7_state_snapshot":
            return .toolResult(
                toolSuccessResult(
                    payload: stateSnapshotService.snapshotPayload()
                )
            )

        case "chau7_subscribe":
            return subscribeToChau7State(arguments: arguments)

        case "chau7_unsubscribe":
            return unsubscribeFromChau7State(arguments: arguments)

        // Control plane
        case "tab_list":
            return classifyToolResponse(controlPlane.call(name: "tab_list", arguments: arguments))

        case "tab_create":
            return classifyToolResponse(controlPlane.call(name: "tab_create", arguments: arguments))

        case "tab_exec":
            return classifyToolResponse(controlPlane.call(name: "tab_exec", arguments: arguments))

        case "tab_status":
            return classifyToolResponse(controlPlane.call(name: "tab_status", arguments: arguments))

        case "tab_wait_ready":
            return classifyToolResponse(controlPlane.call(name: "tab_wait_ready", arguments: arguments))

        case "tab_send_input":
            return classifyToolResponse(controlPlane.call(name: "tab_send_input", arguments: arguments))

        case "tab_press_key":
            return classifyToolResponse(controlPlane.call(name: "tab_press_key", arguments: arguments))

        case "tab_submit_prompt":
            return classifyToolResponse(controlPlane.call(name: "tab_submit_prompt", arguments: arguments))

        case "tab_close":
            return classifyToolResponse(controlPlane.call(name: "tab_close", arguments: arguments))

        case "tab_output":
            return classifyToolResponse(controlPlane.call(name: "tab_output", arguments: arguments))

        case "tab_set_cto":
            guard let tabID = arguments["tab_id"] as? String,
                  let override = arguments["override"] as? String else {
                return .protocolError(code: -32602, message: "Invalid params: tab_id and override are required")
            }
            return classifyToolResponse(controlService.setCTO(tabID: tabID, override: override))

        case "tab_rename":
            guard let tabID = arguments["tab_id"] as? String,
                  let title = arguments["title"] as? String else {
                return .protocolError(code: -32602, message: "Invalid params: tab_id and title are required")
            }
            return classifyToolResponse(controlService.renameTab(tabID: tabID, title: title))

        // Repo Metadata
        case "repo_get_metadata":
            guard let repoPath = arguments["repo_path"] as? String else {
                return .protocolError(code: -32602, message: "Invalid params: repo_path is required")
            }
            return classifyToolResponse(controlService.getRepoMetadata(repoPath: repoPath))

        case "repo_set_metadata":
            guard let repoPath = arguments["repo_path"] as? String else {
                return .protocolError(code: -32602, message: "Invalid params: repo_path is required")
            }
            return classifyToolResponse(controlService.setRepoMetadata(
                repoPath: repoPath,
                description: arguments["description"] as? String,
                labels: arguments["labels"] as? [String],
                favoriteFiles: arguments["favorite_files"] as? [String]
            ))

        case "repo_frequent_commands":
            guard let repoPath = arguments["repo_path"] as? String else {
                return .protocolError(code: -32602, message: "Invalid params: repo_path is required")
            }
            let limit = arguments["limit"] as? Int ?? 20
            return classifyToolResponse(controlService.repoFrequentCommands(repoPath: repoPath, limit: limit))

        case "repo_get_events":
            guard let repoPath = arguments["repo_path"] as? String else {
                return .protocolError(code: -32602, message: "Invalid params: repo_path is required")
            }
            let limit = min(arguments["limit"] as? Int ?? 20, 50)
            return classifyToolResponse(controlService.repoGetEvents(repoPath: repoPath, limit: limit))

        default:
            return .protocolError(code: -32602, message: "Unknown tool: \(name)")
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

    private enum ResourceReadDisposition {
        case success(String)
        case protocolError(code: Int, message: String)
    }

    private func readResource(_ uri: String) -> ResourceReadDisposition {
        switch uri {
        case "chau7://telemetry/runs":
            return .success(queryService.listRuns(["limit": 20]))
        case "chau7://telemetry/sessions":
            return .success(queryService.listSessions())
        case "chau7://telemetry/sessions/current":
            return .success(queryService.currentSessions())
        default:
            // Try chau7://telemetry/runs/<run_id>
            if uri.hasPrefix("chau7://telemetry/runs/") {
                let runID = String(uri.dropFirst("chau7://telemetry/runs/".count))
                return .success(queryService.getRun(runID))
            }
            return .protocolError(code: -32602, message: "Unknown resource: \(uri)")
        }
    }

    // MARK: - JSON-RPC Helpers

    private func buildResult(id: Any?, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id as Any, "result": result]
    }

    private func buildError(id: Any?, code: Int, message: String, data: Any? = nil) -> [String: Any] {
        var error: [String: Any] = ["code": code, "message": message]
        if let data {
            error["data"] = data
        }
        return ["jsonrpc": "2.0", "id": id as Any, "error": error]
    }

    private func writeError(to stream: UnsafeMutablePointer<FILE>, id: Any?, code: Int, message: String) {
        writeJSON(to: stream, json: buildError(id: id, code: code, message: message))
    }

    private func writeJSON(
        to stream: UnsafeMutablePointer<FILE>,
        json: [String: Any],
        mirrorToNotificationSink: Bool = false
    ) {
        writeQueue.sync {
            writeLine(to: stream, json: json)
            if mirrorToNotificationSink {
                notificationSink?(json)
            }
        }
    }

    private func writeLine(to stream: UnsafeMutablePointer<FILE>, json: [String: Any]) {
        guard !json.isEmpty,
              let data = try? JSONSerialization.data(withJSONObject: json),
              let line = String(data: data, encoding: .utf8) else { return }
        fputs(line + "\n", stream)
        fflush(stream)
    }

    private func requireInitializedResponse(for method: String, id: Any?, isNotification: Bool) -> [String: Any]? {
        guard lifecycleState == .ready else {
            return responseOrNil(
                isNotification: isNotification,
                response: buildError(
                    id: id,
                    code: -32002,
                    message: "Client must complete initialize and notifications/initialized before calling \(method)"
                )
            )
        }
        return nil
    }

    private func responseOrNil(isNotification: Bool, response: [String: Any]) -> [String: Any]? {
        isNotification ? nil : response
    }

    private func negotiateProtocolVersion(_ requestedVersion: String) -> String? {
        Self.supportedProtocolVersions.contains(requestedVersion) ? requestedVersion : nil
    }

    private func validate(arguments: [String: Any], against definition: [String: Any], toolName: String) -> String? {
        guard let schema = definition["inputSchema"] as? [String: Any] else { return nil }
        let properties = schema["properties"] as? [String: Any] ?? [:]
        let required = Set(schema["required"] as? [String] ?? [])
        let allowsAdditionalProperties = schema["additionalProperties"] as? Bool ?? true

        for key in required.sorted() where arguments[key] == nil {
            return "Invalid params: missing required argument '\(key)' for tool \(toolName)"
        }

        if !allowsAdditionalProperties {
            let unknownArguments = arguments.keys.filter { properties[$0] == nil }.sorted()
            if let unknown = unknownArguments.first {
                return "Invalid params: unknown argument '\(unknown)' for tool \(toolName)"
            }
        }

        for (key, value) in arguments {
            guard let propertySchema = properties[key] as? [String: Any],
                  !valueMatchesSchemaType(value, schema: propertySchema) else {
                continue
            }
            let expectedType = propertySchema["type"] as? String ?? "valid value"
            return "Invalid params: argument '\(key)' for tool \(toolName) must be a \(expectedType)"
        }

        return nil
    }

    private func valueMatchesSchemaType(_ value: Any, schema: [String: Any]) -> Bool {
        guard let type = schema["type"] as? String else { return true }

        switch type {
        case "string":
            return value is String
        case "integer":
            return isIntegerValue(value)
        case "boolean":
            return isBooleanValue(value)
        case "array":
            return value is [Any]
        case "object":
            return value is [String: Any]
        default:
            return true
        }
    }

    private func isIntegerValue(_ value: Any) -> Bool {
        if value is Int { return true }
        guard let number = value as? NSNumber, !isBooleanValue(number) else { return false }
        let doubleValue = number.doubleValue
        return doubleValue.rounded(.towardZero) == doubleValue
    }

    private func isBooleanValue(_ value: Any) -> Bool {
        if value is Bool { return true }
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private func classifyToolResponse(_ text: String) -> ToolCallDisposition {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else {
            return .toolResult(ToolResult(text: trimmed, isError: false, structuredContent: nil))
        }

        guard let object = json as? [String: Any] else {
            return .toolResult(ToolResult(text: trimmed, isError: false, structuredContent: nil))
        }

        if let message = object["error"] as? String {
            return .toolResult(ToolResult(text: message, isError: true, structuredContent: object))
        }

        return .toolResult(ToolResult(text: trimmed, isError: false, structuredContent: object))
    }

    private func toolSuccessResult(payload: [String: Any]) -> ToolResult {
        ToolResult(
            text: encodeJSONObject(payload) ?? "{}",
            isError: false,
            structuredContent: payload
        )
    }

    private func toolErrorResult(message: String, structuredContent: [String: Any]) -> ToolResult {
        var payload = structuredContent
        payload["message"] = message
        return ToolResult(text: message, isError: true, structuredContent: payload)
    }

    private func subscribeToChau7State(arguments: [String: Any]) -> ToolCallDisposition {
        guard canEmitNotifications else {
            return .toolResult(
                toolErrorResult(
                    message: "Subscriptions require a live MCP connection that can receive JSON-RPC notifications.",
                    structuredContent: [
                        "error": Chau7MCPObserverContract.notificationsUnavailableError,
                        "observer_contract_version": Chau7MCPObserverContract.version
                    ]
                )
            )
        }

        let requestedTopics = normalizedSubscriptionTopics(arguments["topics"] as? [String])
        let effectiveTopics = requestedTopics ?? Chau7MCPObserverContract.supportedTopics
        let cursor = (arguments["cursor"] as? Int64) ?? (arguments["cursor"] as? Int).map(Int64.init)
        let replayLimit = min(max(arguments["replay_limit"] as? Int ?? Chau7MCPObserverContract.defaultReplayLimit, 1), Chau7MCPObserverContract.maxReplayLimit)
        let heartbeatIntervalMs = min(
            max(
                arguments["heartbeat_interval_ms"] as? Int ?? Chau7MCPObserverContract.defaultHeartbeatIntervalMs,
                Chau7MCPObserverContract.minHeartbeatIntervalMs
            ),
            Chau7MCPObserverContract.maxHeartbeatIntervalMs
        )

        if let cursor,
           let oldestAvailable = Chau7ObservabilityService.shared.oldestAvailableChangeSequence(),
           cursor < oldestAvailable - 1 {
            return .toolResult(
                toolErrorResult(
                    message: "Requested cursor is no longer available. Rehydrate from a fresh snapshot.",
                    structuredContent: [
                        "error": Chau7MCPObserverContract.snapshotRequiredError,
                        "observer_contract_version": Chau7MCPObserverContract.version,
                        "latest_seq": Chau7ObservabilityService.shared.latestSequence(),
                        "oldest_available_seq": oldestAvailable
                    ]
                )
            )
        }

        cancelSubscription()

        let subscriptionID = "sub_\(UUID().uuidString)"
        let createdAtMillis = currentTimeMillis()

        // Publish the subscription state BEFORE registering the change
        // listener. If the listener were registered first, any recordEvent
        // racing in on another thread would fire the listener → call
        // `reserveNotificationDelivery` → see `subscriptionState == nil` →
        // silently drop the notification (no log line, no dropped counter,
        // since the counter lives inside the not-yet-created state). Taking
        // the replay snapshot afterward closes the secondary gap: events
        // fired between replay capture and listener registration used to
        // land in neither replay nor the live stream.
        subscriptionStateQueue.sync {
            subscriptionState = SubscriptionState(
                id: subscriptionID,
                topics: effectiveTopics,
                createdAtMillis: createdAtMillis,
                heartbeatIntervalMs: heartbeatIntervalMs,
                token: nil,
                heartbeatTimer: nil,
                nextDeliverySequence: 1,
                notificationsEmittedCount: 0,
                droppedNotificationCount: 0,
                lastNotificationAtMillis: nil
            )
        }

        let token = Chau7ObservabilityService.shared.addChangeListener(topics: requestedTopics) { [weak self] change in
            self?.emitSubscriptionNotification(subscriptionID: subscriptionID, change: change)
        }
        let replay = Chau7ObservabilityService.shared.changePayloads(
            sinceSeq: cursor,
            topics: requestedTopics,
            limit: replayLimit
        )
        let heartbeatTimer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "com.chau7.mcp.session.subscription-heartbeat.\(subscriptionID)"))
        heartbeatTimer.schedule(deadline: .now() + .milliseconds(heartbeatIntervalMs), repeating: .milliseconds(heartbeatIntervalMs))
        heartbeatTimer.setEventHandler { [weak self] in
            self?.emitSubscriptionHeartbeat(subscriptionID: subscriptionID)
        }
        heartbeatTimer.resume()

        // Patch the token and timer into the already-published state so
        // `cancelSubscription` can remove the listener / cancel the timer.
        subscriptionStateQueue.sync {
            subscriptionState?.token = token
            subscriptionState?.heartbeatTimer = heartbeatTimer
        }

        var payload = stateSnapshotService.snapshotPayload()
        payload["subscription_id"] = subscriptionID
        payload["topics"] = effectiveTopics
        if !replay.isEmpty {
            payload["replay"] = replay
        }
        payload["subscription"] = subscriptionEnvelope(
            subscriptionID: subscriptionID,
            topics: effectiveTopics,
            cursor: cursor,
            replayCount: replay.count,
            replayLimit: replayLimit
        )
        return .toolResult(toolSuccessResult(payload: payload))
    }

    private func unsubscribeFromChau7State(arguments: [String: Any]) -> ToolCallDisposition {
        if let requestedID = arguments["subscription_id"] as? String,
           let activeID = subscriptionStateQueue.sync(execute: { subscriptionState?.id }),
           requestedID != activeID {
            return .protocolError(code: -32602, message: "Unknown subscription_id: \(requestedID)")
        }

        let previousID = subscriptionStateQueue.sync { subscriptionState?.id }
        let health = subscriptionStateQueue.sync { subscriptionState.map(subscriptionHealthPayloadLocked) }
        cancelSubscription()
        return .toolResult(
            toolSuccessResult(
                payload: [
                    "ok": true,
                    "subscription_id": previousID as Any,
                    "observer_contract_version": Chau7MCPObserverContract.version,
                    "subscription_health": health as Any
                ].compactMapValues { $0 }
            )
        )
    }

    private var canEmitNotifications: Bool {
        liveNotificationWriter != nil || notificationSink != nil
    }

    private func cancelSubscription() {
        let previousState = subscriptionStateQueue.sync { () -> SubscriptionState? in
            let state = subscriptionState
            subscriptionState = nil
            return state
        }
        if let token = previousState?.token {
            Chau7ObservabilityService.shared.removeChangeListener(token)
        }
        if let timer = previousState?.heartbeatTimer {
            timer.setEventHandler {}
            timer.cancel()
        }
    }

    private func emitSubscriptionNotification(subscriptionID: String, change: [String: Any]) {
        guard let state = reserveNotificationDelivery(for: subscriptionID) else { return }
        var params = change
        params["observer_contract_version"] = Chau7MCPObserverContract.version
        params["subscription_id"] = subscriptionID
        params["delivery_seq"] = state.deliverySequence
        params["subscription_health"] = state.health
        sendNotification(method: Chau7MCPObserverContract.notificationMethod, params: params)
    }

    func emitSubscriptionHeartbeatForTests() {
        guard let subscriptionID = subscriptionStateQueue.sync(execute: { subscriptionState?.id }) else { return }
        emitSubscriptionHeartbeat(subscriptionID: subscriptionID)
    }

    private func emitSubscriptionHeartbeat(subscriptionID: String) {
        guard let state = reserveNotificationDelivery(for: subscriptionID) else { return }
        let params: [String: Any] = [
            "observer_contract_version": Chau7MCPObserverContract.version,
            "subscription_id": subscriptionID,
            "delivery_seq": state.deliverySequence,
            "type": Chau7MCPObserverContract.heartbeatEventType,
            "topic": Chau7MCPObserverContract.subscriptionControlTopic,
            "timestamp_millis": currentTimeMillis(),
            "latest_seq": Chau7ObservabilityService.shared.latestSequence(),
            "subscription_health": state.health
        ]
        sendNotification(method: Chau7MCPObserverContract.notificationMethod, params: params)
    }

    private func sendNotification(method: String, params: [String: Any]) {
        let payload: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        if let liveNotificationWriter {
            liveNotificationWriter(payload)
        } else {
            notificationSink?(payload)
        }
    }

    private func encodeJSONObject(_ object: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func normalizedSubscriptionTopics(_ topics: [String]?) -> [String]? {
        let normalized = (topics ?? [])
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { Chau7MCPObserverContract.supportedTopics.contains($0) }
        let unique = Array(Set(normalized)).sorted()
        return unique.isEmpty ? nil : unique
    }

    private func subscriptionEnvelope(
        subscriptionID: String,
        topics: [String],
        cursor: Int64?,
        replayCount: Int,
        replayLimit: Int
    ) -> [String: Any] {
        let health = subscriptionStateQueue.sync { subscriptionState.map(subscriptionHealthPayloadLocked) ?? [:] }
        return [
            "subscription_id": subscriptionID,
            "status": "active",
            "observer_contract_version": Chau7MCPObserverContract.version,
            "topics": topics,
            "cursor": cursor as Any,
            "replay_count": replayCount,
            "replay_limit": replayLimit,
            "health": health
        ].compactMapValues { $0 }
    }

    private func reserveNotificationDelivery(for subscriptionID: String) -> (deliverySequence: Int64, health: [String: Any])? {
        subscriptionStateQueue.sync {
            guard var state = subscriptionState, state.id == subscriptionID else { return nil }
            let deliverySequence = state.nextDeliverySequence
            state.nextDeliverySequence += 1
            state.notificationsEmittedCount += 1
            state.lastNotificationAtMillis = currentTimeMillis()
            subscriptionState = state
            return (deliverySequence, subscriptionHealthPayloadLocked(state))
        }
    }

    private func subscriptionHealthPayloadLocked(_ state: SubscriptionState) -> [String: Any] {
        [
            "delivery_mode": Chau7MCPObserverContract.deliveryMode,
            "lag_state": Chau7MCPObserverContract.healthyLagState,
            "buffer_depth": 0,
            "dropped_notification_count": state.droppedNotificationCount,
            "notifications_emitted_count": state.notificationsEmittedCount,
            "last_notification_at_millis": state.lastNotificationAtMillis as Any,
            "created_at_millis": state.createdAtMillis,
            "heartbeat_interval_ms": state.heartbeatIntervalMs
        ].compactMapValues { $0 }
    }

    private func currentTimeMillis() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    static func resetSharedToolRateLimiterForTests() {
        toolRateLimiterQueue.sync {
            toolRateLimiter.reset()
        }
    }
}
