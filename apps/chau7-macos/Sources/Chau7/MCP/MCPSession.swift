import Foundation
import Chau7Core

/// Handles a single MCP client connection over a Unix domain socket.
/// Implements the MCP JSON-RPC protocol for tool calls and resource reads.
final class MCPSession {
    private let fd: Int32
    private let queryService = TelemetryQueryService()

    init(fd: Int32) {
        self.fd = fd
    }

    /// Blocking run loop: reads JSON-RPC messages, dispatches, writes responses.
    func run() {
        let readStream = fdopen(fd, "r")
        let writeStream = fdopen(fd, "w")
        guard let readStream, let writeStream else { return }

        defer {
            fclose(readStream)
            fclose(writeStream)
        }

        var buffer = Data()

        while true {
            var line: UnsafeMutablePointer<CChar>?
            var lineCap: Int = 0
            let bytesRead = getline(&line, &lineCap, readStream)
            guard bytesRead > 0, let line else { break }
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
                    "name": "chau7-telemetry",
                    "version": "1.0.0"
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
