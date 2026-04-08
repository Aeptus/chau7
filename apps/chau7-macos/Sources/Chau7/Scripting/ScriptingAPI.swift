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
/// - {"method": "start_review", "params": {...}} -> delegated review session metadata
/// - {"method": "wait_review", "params": {"session_id": "...", "timeout_ms": 60000}}
/// - {"method": "get_review_result", "params": {"session_id": "..."}}
/// - {"method": "stop_review", "params": {"session_id": "...", "force": true}}
@Observable
@MainActor
final class ScriptingAPI {
    static let shared = ScriptingAPI()
    static let featureFlagKey = "feature.scriptingAPI"
    private static let defaultEnabled = true

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

    /// Timestamp when the server was started, used for uptime calculation.
    @ObservationIgnored
    private var startTime: Date?

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
        case "start_review":
            return await handleStartReview(params)
        case "wait_review":
            return handleWaitReview(params)
        case "get_review_result":
            return handleGetReviewResult(params)
        case "stop_review":
            return handleStopReview(params)
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

    private func handleStartReview(_ params: [String: Any]) async -> [String: Any] {
        guard let directory = params["directory"] as? String,
              !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["error": "missing param: directory"]
        }

        let mode = ((params["mode"] as? String) ?? "staged_diff")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let extraInstructions = sanitizeOptionalString(params["extra_instructions"] as? String)
        let prompt: String
        var taskMetadata: [String: String] = ["review_mode": mode]

        switch mode {
        case "commit_range":
            guard let baseCommit = sanitizeOptionalString(params["base_commit"] as? String),
                  let headCommit = sanitizeOptionalString(params["head_commit"] as? String) else {
                return ["error": "missing params for commit_range review: base_commit and head_commit are required"]
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
                return ["error": "missing param: staged_diff"]
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
            return ["error": "unsupported review mode: \(mode)"]
        }

        var arguments: [String: Any] = [
            "backend": sanitizeOptionalString(params["backend"] as? String) ?? "codex",
            "directory": directory,
            "purpose": "code_review",
            "task_metadata": taskMetadata,
            "result_schema": CodeReviewTaskTemplate.resultSchema.foundationValue,
            "initial_prompt": prompt,
            "policy": CodeReviewTaskTemplate.defaultPolicy.foundationValue
        ]
        if let model = sanitizeOptionalString(params["model"] as? String) {
            arguments["model"] = model
        }
        if let parentSessionID = sanitizeOptionalString(params["parent_session_id"] as? String) {
            arguments["parent_session_id"] = parentSessionID
            arguments["delegation_depth"] = max(params["delegation_depth"] as? Int ?? 1, 1)
        }
        if let autoApprove = params["auto_approve"] as? Bool {
            arguments["auto_approve"] = autoApprove
        }

        return parseJSONResponse(
            RuntimeControlService.shared.handleToolCall(
                name: "runtime_session_create",
                arguments: arguments
            )
        ) ?? ["error": "review_start_failed"]
    }

    private func handleWaitReview(_ params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["error": "missing param: session_id"]
        }

        var arguments: [String: Any] = ["session_id": sessionID]
        if let timeoutMs = params["timeout_ms"] as? Int {
            arguments["timeout_ms"] = timeoutMs
        }
        return parseJSONResponse(
            RuntimeControlService.shared.handleToolCall(
                name: "runtime_turn_wait",
                arguments: arguments
            )
        ) ?? ["error": "review_wait_failed"]
    }

    private func handleGetReviewResult(_ params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["error": "missing param: session_id"]
        }

        return parseJSONResponse(
            RuntimeControlService.shared.handleToolCall(
                name: "runtime_turn_result",
                arguments: ["session_id": sessionID]
            )
        ) ?? ["error": "review_result_failed"]
    }

    private func handleStopReview(_ params: [String: Any]) -> [String: Any] {
        guard let sessionID = params["session_id"] as? String,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["error": "missing param: session_id"]
        }

        return parseJSONResponse(
            RuntimeControlService.shared.handleToolCall(
                name: "runtime_session_stop",
                arguments: [
                    "session_id": sessionID,
                    "close_tab": true,
                    "force": params["force"] as? Bool ?? false
                ]
            )
        ) ?? ["error": "review_stop_failed"]
    }

    private func handleGetStatus() -> [String: Any] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let uptime: TimeInterval = startTime.map { Date().timeIntervalSince($0) } ?? 0

        return [
            "result": [
                "version": version,
                "build": build,
                "uptime_seconds": Int(uptime),
                "connected_clients": connectedClients,
                "server_running": isRunning,
                "history_count": PersistentHistoryStore.shared.totalCount()
            ] as [String: Any]
        ]
    }

    private func sanitizeOptionalString(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
