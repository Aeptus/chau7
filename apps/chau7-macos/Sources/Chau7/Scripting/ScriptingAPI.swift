import Foundation
import Chau7Core

/// Exposes Chau7 functionality to external scripts via a JSON-over-Unix-socket API.
/// Socket path: ~/Library/Application Support/Chau7/scripting.sock
///
/// API Commands (JSON-RPC style):
/// - {"method": "list_tabs"} -> [{"id": "...", "title": "...", "directory": "..."}]
/// - {"method": "get_tab", "params": {"id": "..."}} -> tab details
/// - {"method": "run_command", "params": {"tab_id": "...", "command": "..."}}
/// - {"method": "get_output", "params": {"tab_id": "...", "lines": 50}}
/// - {"method": "create_tab", "params": {"command": "...", "directory": "..."}}
/// - {"method": "close_tab", "params": {"id": "..."}}
/// - {"method": "get_history", "params": {"query": "...", "limit": 50}}
/// - {"method": "get_settings"} -> current settings snapshot
/// - {"method": "set_setting", "params": {"key": "...", "value": ...}}
/// - {"method": "list_snippets"} -> all snippets
/// - {"method": "run_snippet", "params": {"name": "..."}}
/// - {"method": "get_status"} -> app status (version, tabs, uptime)
/// - {"method": "create_session", "params": {...}} -> delegated session metadata without sending the prepared turn
/// - {"method": "get_session_events", "params": {"session_id": "...", "cursor": 0, "limit": 50, "event_types": ["turn_completed"]}}
/// - {"method": "submit_session_turn", "params": {"session_id": "..."}}
/// - {"method": "get_session_result", "params": {"session_id": "..."}}
/// - {"method": "stop_session", "params": {"session_id": "...", "force": true}}
@Observable
@MainActor
final class ScriptingAPI {
    static let shared = ScriptingAPI()
    static let featureFlagKey = "feature.scriptingAPI"
    private static let defaultEnabled = true
    private static let apiVersion = 2
    private static let supportedMethods = [
        "list_tabs",
        "get_tab",
        "run_command",
        "get_output",
        "create_tab",
        "close_tab",
        "get_history",
        "get_settings",
        "set_setting",
        "list_snippets",
        "run_snippet",
        "get_status",
        "create_session",
        "get_session_events",
        "submit_session_turn",
        "get_session_result",
        "stop_session"
    ]

    var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.featureFlagKey)
            if isEnabled { startServer() } else { stopServer() }
        }
    }

    private(set) var isRunning = false
    private(set) var connectedClients = 0

    @ObservationIgnored
    private var socketFD: Int32 = -1
    @ObservationIgnored
    private var listeningSource: DispatchSourceRead?
    @ObservationIgnored
    private var clientHandlers: [Int32: ScriptingClientHandler] = [:]
    @ObservationIgnored
    private let socketQueue = DispatchQueue(label: "com.chau7.scripting", qos: .userInitiated)
    @ObservationIgnored
    private var healthCheckSource: DispatchSourceTimer?
    @ObservationIgnored
    private var preparedSessionTurns: [String: PreparedTurn] = [:]

    /// Timestamp when the server was started, used for uptime calculation.
    @ObservationIgnored
    private var startTime: Date?

    private struct PreparedTurn {
        let prompt: String
        let resultSchema: JSONValue
    }

    private var socketPath: String {
        RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("scripting.sock").path
    }

    static func initialEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: featureFlagKey) == nil {
            defaults.set(defaultEnabled, forKey: featureFlagKey)
            return defaultEnabled
        }
        return defaults.bool(forKey: featureFlagKey)
    }

    private init() {
        let hadPersistedPreference = UserDefaults.standard.object(forKey: Self.featureFlagKey) != nil
        self.isEnabled = Self.initialEnabled()
        if isEnabled {
            startServer()
            if hadPersistedPreference {
                Log.info("ScriptingAPI initialized: enabled=true")
            } else {
                Log.info("ScriptingAPI initialized: enabled=true (defaulted because no persisted preference was set)")
            }
        } else {
            Log.info("ScriptingAPI initialized: enabled=false (feature flag disabled)")
        }
    }

    // MARK: - Server Lifecycle

    func startServer() {
        guard socketFD < 0 else { return }

        let path = socketPath
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        unlink(path)

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            Log.error("ScriptingAPI: failed to create socket: \(String(cString: strerror(errno)))")
            return
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path) - 1
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let buf = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            _ = path.withCString { strncpy(buf, $0, maxLen) }
        }

        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(socketFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult >= 0 else {
            Log.error("ScriptingAPI: bind failed: \(String(cString: strerror(errno)))")
            close(socketFD)
            socketFD = -1
            return
        }

        guard listen(socketFD, 5) >= 0 else {
            Log.error("ScriptingAPI: listen failed: \(String(cString: strerror(errno)))")
            close(socketFD)
            socketFD = -1
            unlink(path)
            return
        }

        chmod(path, 0o600)

        // Capture fd by value so cancel handler closes the correct descriptor.
        let listeningFD = socketFD
        listeningSource = DispatchSource.makeReadSource(fileDescriptor: listeningFD, queue: socketQueue)
        listeningSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        listeningSource?.setCancelHandler { [weak self] in
            close(listeningFD)
            self?.socketFD = -1
        }
        listeningSource?.resume()
        startHealthChecks()

        startTime = Date()
        isRunning = true
        Log.info("ScriptingAPI: server started at \(path)")
    }

    func stopServer() {
        // Client handlers: disconnect() cancels their read source whose
        // cancel handler calls close(fd) — don't double-close here.
        for (_, handler) in clientHandlers {
            handler.disconnect()
        }
        clientHandlers.removeAll()

        // Cancel handler owns close(socketFD) — don't double-close.
        if let ls = listeningSource {
            ls.cancel()
            listeningSource = nil
        } else if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
        healthCheckSource?.cancel()
        healthCheckSource = nil

        unlink(socketPath)
        isRunning = false
        connectedClients = 0
        startTime = nil
        Log.info("ScriptingAPI: server stopped")
    }

    private func startHealthChecks() {
        healthCheckSource?.cancel()
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now() + 15, repeating: 15)
        source.setEventHandler { [weak self] in
            self?.ensureServerHealthy(reason: "periodic")
        }
        source.resume()
        healthCheckSource = source
    }

    private func ensureServerHealthy(reason: String) {
        let snapshot = LocalSocketServerHealthSnapshot(
            expectedRunning: isEnabled,
            isRunning: isRunning,
            hasSocketDescriptor: socketFD >= 0,
            hasAcceptSource: listeningSource != nil,
            socketPathExists: FileManager.default.fileExists(atPath: socketPath)
        )
        guard LocalSocketServerHealth.needsRecovery(snapshot) else {
            return
        }

        Log.warn(
            "ScriptingAPI: unhealthy server detected reason=\(reason) running=\(snapshot.isRunning) " +
                "fd=\(snapshot.hasSocketDescriptor) source=\(snapshot.hasAcceptSource) path=\(snapshot.socketPathExists); restarting"
        )
        stopServer()
        if isEnabled {
            startServer()
        }
    }

    // MARK: - Connection Handling

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(socketFD, sockPtr, &clientAddrLen)
            }
        }

        guard clientFD >= 0 else {
            Log.warn("ScriptingAPI: accept failed: \(String(cString: strerror(errno)))")
            return
        }

        let handler = ScriptingClientHandler(fd: clientFD, queue: socketQueue) { [weak self] json in
            guard let self = self else { return ["error": "server gone"] as [String: Any] }
            return await handleRequest(json)
        } onDisconnect: { [weak self] fd in
            DispatchQueue.main.async {
                self?.clientHandlers.removeValue(forKey: fd)
                self?.connectedClients = self?.clientHandlers.count ?? 0
                Log.info("ScriptingAPI: client disconnected (fd=\(fd))")
            }
        }

        clientHandlers[clientFD] = handler
        connectedClients = clientHandlers.count
        handler.startReading()
        Log.info("ScriptingAPI: client connected (fd=\(clientFD), total=\(clientHandlers.count))")
    }

    // MARK: - Request Dispatch

    /// Process a JSON-RPC style request and return a response.
    func handleRequest(_ json: [String: Any]) async -> [String: Any] {
        guard let method = json["method"] as? String else {
            return ["error": "missing method"]
        }
        let params = json["params"] as? [String: Any] ?? [:]

        Log.trace("ScriptingAPI: handling method=\(method)")

        switch method {
        case "list_tabs":
            return await handleListTabs()
        case "get_tab":
            return await handleGetTab(params)
        case "run_command":
            return await handleRunCommand(params)
        case "get_output":
            return await handleGetOutput(params)
        case "create_tab":
            return await handleCreateTab(params)
        case "close_tab":
            return await handleCloseTab(params)
        case "get_history":
            return handleGetHistory(params)
        case "get_settings":
            return handleGetSettings()
        case "set_setting":
            return handleSetSetting(params)
        case "list_snippets":
            return handleListSnippets()
        case "run_snippet":
            return await handleRunSnippet(params)
        case "get_status":
            return handleGetStatus()
        case "create_session":
            return await handleCreateSession(params)
        case "get_session_events":
            return handleGetSessionEvents(params)
        case "submit_session_turn":
            return await handleSubmitSessionTurn(params)
        case "get_session_result":
            return handleGetSessionResult(params)
        case "stop_session":
            return handleStopSession(params)
        default:
            return ["error": "unknown method: \(method)"]
        }
    }

    // MARK: - Handlers

    private func handleListTabs() async -> [String: Any] {
        let json = TerminalControlService.shared.listTabs()
        return parseJSONResponse(json) ?? ["tabs": []]
    }

    private func handleGetTab(_ params: [String: Any]) async -> [String: Any] {
        guard let tabID = params["id"] as? String else {
            return ["error": "missing param: id"]
        }
        let json = TerminalControlService.shared.tabStatus(tabID: tabID)
        return parseJSONResponse(json) ?? ["error": "tab not found"]
    }

    private func handleRunCommand(_ params: [String: Any]) async -> [String: Any] {
        guard let tabID = params["tab_id"] as? String else {
            return ["error": "missing param: tab_id"]
        }
        guard let command = params["command"] as? String else {
            return ["error": "missing param: command"]
        }
        let json = TerminalControlService.shared.execInTab(tabID: tabID, command: command)
        return parseJSONResponse(json) ?? ["error": "exec failed"]
    }

    private func handleGetOutput(_ params: [String: Any]) async -> [String: Any] {
        guard let tabID = params["tab_id"] as? String else {
            return ["error": "missing param: tab_id"]
        }
        let lines = params["lines"] as? Int ?? 50
        let json = TerminalControlService.shared.tabOutput(tabID: tabID, lines: lines)
        return parseJSONResponse(json) ?? ["error": "output failed"]
    }

    private func handleCreateTab(_ params: [String: Any]) async -> [String: Any] {
        let directory = params["directory"] as? String
        let json = TerminalControlService.shared.createTab(directory: directory, windowID: nil)
        return parseJSONResponse(json) ?? ["error": "create failed"]
    }

    private func handleCloseTab(_ params: [String: Any]) async -> [String: Any] {
        guard let tabID = params["id"] as? String else {
            return ["error": "missing param: id"]
        }
        let json = TerminalControlService.shared.closeTab(tabID: tabID, force: true)
        return parseJSONResponse(json) ?? ["error": "close failed"]
    }

    private func parseJSONResponse(_ json: String) -> [String: Any]? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return obj
    }

    private func handleGetHistory(_ params: [String: Any]) -> [String: Any] {
        let query = params["query"] as? String ?? ""
        let limit = params["limit"] as? Int ?? 50
        let store = PersistentHistoryStore.shared

        let records: [HistoryRecord]
        if query.isEmpty {
            records = store.recent(limit: limit)
        } else {
            records = store.search(query: query, limit: limit)
        }

        let items: [[String: Any]] = records.map { r in
            var dict: [String: Any] = [
                "command": r.command,
                "timestamp": r.timestamp.timeIntervalSince1970
            ]
            if let d = r.directory { dict["directory"] = d }
            if let e = r.exitCode { dict["exit_code"] = e }
            if let s = r.shell { dict["shell"] = s }
            if let t = r.tabID { dict["tab_id"] = t }
            if let dur = r.duration { dict["duration"] = dur }
            return dict
        }

        return ["result": items]
    }

    private func handleGetSettings() -> [String: Any] {
        let defaults = UserDefaults.standard
        var snapshot: [String: Any] = [:]
        snapshot["feature.scriptingAPI"] = defaults.bool(forKey: Self.featureFlagKey)
        snapshot["feature.persistentHistory"] = defaults.bool(forKey: "feature.persistentHistory")
        snapshot["history.maxRecords"] = defaults.integer(forKey: "history.maxRecords")
        snapshot["scripting.socket_path"] = socketPath
        snapshot["scripting.socket_exists"] = FileManager.default.fileExists(atPath: socketPath)
        snapshot["scripting.socket_healthy"] = !LocalSocketServerHealth.needsRecovery(
            LocalSocketServerHealthSnapshot(
                expectedRunning: isEnabled,
                isRunning: isRunning,
                hasSocketDescriptor: socketFD >= 0,
                hasAcceptSource: listeningSource != nil,
                socketPathExists: FileManager.default.fileExists(atPath: socketPath)
            )
        )
        return ["result": snapshot]
    }

    private func handleSetSetting(_ params: [String: Any]) -> [String: Any] {
        guard let key = params["key"] as? String else {
            return ["error": "missing param: key"]
        }
        guard let value = params["value"] else {
            return ["error": "missing param: value"]
        }

        let allowedKeys: Set = [
            Self.featureFlagKey,
            "feature.persistentHistory",
            "history.maxRecords"
        ]
        guard allowedKeys.contains(key) else {
            return ["error": "unknown or disallowed setting key: \(key)"]
        }

        // Only accept primitive types to prevent storing unexpected objects
        let sanitized: Any
        if let v = value as? Bool { sanitized = v }
        else if let v = value as? Int { sanitized = v }
        else if let v = value as? Double { sanitized = v }
        else if let v = value as? String { sanitized = v }
        else {
            return ["error": "unsupported value type; expected Bool, Int, Double, or String"]
        }

        UserDefaults.standard.set(sanitized, forKey: key)
        return ["result": "ok"]
    }

    private func handleListSnippets() -> [String: Any] {
        return ["result": [] as [[String: Any]]]
    }

    private func handleRunSnippet(_ params: [String: Any]) async -> [String: Any] {
        guard let name = params["name"] as? String else {
            return ["error": "missing param: name"]
        }
        let entries = SnippetManager.shared.entries
        guard let entry = entries.first(where: { $0.snippet.title == name }) else {
            return ["error": "snippet_not_found", "message": "No snippet named '\(name)'"]
        }
        return ["ok": true, "snippet": entry.snippet.title, "body": entry.snippet.body]
    }

    private func handleCreateSession(_ params: [String: Any]) async -> [String: Any] {
        guard let reviewRequest = buildReviewRequest(params) else {
            return buildReviewRequestError(params)
        }

        var arguments: [String: Any] = [
            "backend": reviewRequest.backend,
            "directory": reviewRequest.directory,
            "purpose": "code_review",
            "task_metadata": reviewRequest.taskMetadata,
            "result_schema": reviewRequest.resultSchema.foundationValue,
            "policy": CodeReviewTaskTemplate.defaultPolicy.foundationValue
        ]
        if let model = reviewRequest.model {
            arguments["model"] = model
        }
        if let parentSessionID = reviewRequest.parentSessionID {
            arguments["parent_session_id"] = parentSessionID
            arguments["delegation_depth"] = max(reviewRequest.delegationDepth ?? 1, 1)
        }
        if let autoApprove = reviewRequest.autoApprove {
            arguments["auto_approve"] = autoApprove
        }

        guard let response = parseJSONResponse(
            RuntimeControlService.shared.handleToolCall(
                name: "runtime_session_create",
                arguments: arguments
            )
        ) else {
            return ["error": "review_start_failed"]
        }
        guard let sessionID = response["session_id"] as? String else {
            return response
        }

        preparedSessionTurns[sessionID] = PreparedTurn(
            prompt: reviewRequest.prompt,
            resultSchema: reviewRequest.resultSchema
        )

        var enriched = response
        enriched["phase"] = "created"
        enriched["prompt_sent"] = false
        return enriched
    }

    private func handleGetSessionEvents(_ params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["error": "missing param: session_id"]
        }
        let cursor = parsedCursor(params["cursor"])
        let limit = max(1, min(params["limit"] as? Int ?? 50, 200))
        let eventTypes = Set((params["event_types"] as? [String] ?? []).filter { !$0.isEmpty })
        Log.trace("ScriptingAPI: get_session_events session=\(sessionID) cursor=\(cursor) limit=\(limit) filterCount=\(eventTypes.count)")

        guard var response = parseJSONResponse(
            RuntimeControlService.shared.handleToolCall(
                name: "runtime_events_poll",
                arguments: [
                    "session_id": sessionID,
                    "cursor": NSNumber(value: cursor),
                    "limit": limit
                ]
            )
        ) else {
            return ["error": "session_events_failed"]
        }

        guard var events = response["events"] as? [[String: Any]] else {
            return response
        }

        if !eventTypes.isEmpty {
            events = events.filter { eventTypes.contains($0["type"] as? String ?? "") }
            response["events"] = events
        }

        response["session_id"] = sessionID
        return response
    }

    private func handleSubmitSessionTurn(_ params: [String: Any]) async -> [String: Any] {
        guard let sessionID = params["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["error": "missing param: session_id"]
        }
        guard let prepared = preparedSessionTurns[sessionID] else {
            return ["error": "session turn not prepared for session \(sessionID)"]
        }

        guard let session = RuntimeSessionManager.shared.session(id: sessionID) else {
            preparedSessionTurns.removeValue(forKey: sessionID)
            return ["error": "Session not found: \(sessionID)"]
        }

        guard session.canAcceptTurn else {
            return [
                "error": "Session \(sessionID) is not ready to accept the review prompt (state: \(session.state.rawValue))"
            ]
        }

        let response = parseJSONResponse(
            RuntimeControlService.shared.handleToolCall(
                name: "runtime_turn_send",
                arguments: [
                    "session_id": sessionID,
                    "prompt": prepared.prompt,
                    "result_schema": prepared.resultSchema.foundationValue
                ]
            )
        ) ?? ["error": "review_prompt_failed"]

        if response["error"] == nil {
            preparedSessionTurns.removeValue(forKey: sessionID)
        }

        if let error = response["error"] as? String {
            Log.warn("ScriptingAPI: submit_session_turn failed for session \(sessionID): \(error)")
            return [
                "error": error,
                "session_id": sessionID,
                "phase": "prompt_failed"
            ]
        }

        let turnID = sanitizeOptionalString(response["turn_id"] as? String)
        let sessionState = sanitizeOptionalString(response["session_state"] as? String) ?? session.state.rawValue
        let status = sanitizeOptionalString(response["status"] as? String) ?? "accepted"
        let cursor = response["cursor"]

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
        if let cursor {
            result["cursor"] = cursor
        }
        Log.info(
            "ScriptingAPI: submit_session_turn completed for session \(sessionID) turn=\(turnID ?? "(none)") state=\(sessionState)"
        )
        return result
    }

    private func handleGetSessionResult(_ params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["error": "missing param: session_id"]
        }

        return parseJSONResponse(
            RuntimeControlService.shared.handleToolCall(
                name: "runtime_turn_result",
                arguments: ["session_id": sessionID]
            )
        ) ?? ["error": "session_result_failed"]
    }

    private func handleStopSession(_ params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["error": "missing param: session_id"]
        }

        preparedSessionTurns.removeValue(forKey: sessionID)

        return parseJSONResponse(
            RuntimeControlService.shared.handleToolCall(
                name: "runtime_session_stop",
                arguments: [
                    "session_id": sessionID,
                    "close_tab": true,
                    "force": params["force"] as? Bool ?? false
                ]
            )
        ) ?? ["error": "session_stop_failed"]
    }

    private func handleGetStatus() -> [String: Any] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let uptime: TimeInterval = startTime.map { Date().timeIntervalSince($0) } ?? 0

        return [
            "result": [
                "version": version,
                "build": build,
                "api_version": Self.apiVersion,
                "supported_methods": Self.supportedMethods,
                "uptime_seconds": Int(uptime),
                "connected_clients": connectedClients,
                "server_running": isRunning,
                "history_count": PersistentHistoryStore.shared.totalCount()
            ] as [String: Any]
        ]
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
}
