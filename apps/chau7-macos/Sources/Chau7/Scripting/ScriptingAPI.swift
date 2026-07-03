import Foundation
import Chau7Core

/// Exposes Chau7 functionality to external scripts via a JSON-over-Unix-socket API.
/// Socket path: ~/Library/Application Support/Chau7/scripting.sock
///
/// The scripting API is a thin transport adapter over the shared control plane.
/// It should not duplicate runtime or terminal orchestration behavior.
@Observable
@MainActor
final class ScriptingAPI {
    static let shared = ScriptingAPI()
    static let featureFlagKey = "feature.scriptingAPI"
    private static let defaultEnabled = true
    private static let apiVersion = 2
    private static let publicSupportedMethods = [
        "list_tabs",
        "get_tab",
        "run_command",
        "get_output",
        "create_tab",
        "send_input",
        "press_key",
        "submit_prompt",
        "close_tab",
        "get_repo_events",
        "get_history",
        "get_settings",
        "set_setting",
        "list_snippets",
        "run_snippet",
        "get_status"
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
    private var listener: UnixSocketListener?
    @ObservationIgnored
    private var clientHandlers: [Int32: ScriptingClientHandler] = [:]
    @ObservationIgnored
    private let socketQueue = DispatchQueue(label: "com.chau7.scripting", qos: .userInitiated)
    @ObservationIgnored
    private var healthCheckSource: DispatchSourceTimer?
    @ObservationIgnored
    private let controlPlane = ControlPlaneService.shared

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
        guard listener == nil else { return }

        let path = socketPath
        let dir = URL(fileURLWithPath: path).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let maxBindAttempts = 3
        var startedListener: UnixSocketListener?

        for attempt in 0 ..< maxBindAttempts {
            let candidate = UnixSocketListener(path: path, queue: socketQueue)
            guard candidate.removeStaleSocketFileIfInactive() else {
                Log.error("ScriptingAPI: refusing to replace active socket at \(path)")
                return
            }

            do {
                try candidate.start(
                    backlog: 5,
                    socketFilePermissions: 0o600,
                    onAccept: { [weak self] clientFD in
                        self?.handleAcceptedClient(clientFD)
                    },
                    onAcceptFailure: { acceptErrno in
                        Log.warn("ScriptingAPI: accept failed: \(String(cString: strerror(acceptErrno)))")
                    }
                )
                startedListener = candidate
                break
            } catch {
                guard let failure = error as? UnixSocketListener.StartFailure else {
                    Log.error("ScriptingAPI: failed to start socket listener: \(error)")
                    return
                }
                if failure.step == .createSocket {
                    Log.error("ScriptingAPI: failed to create socket: \(failure.errnoDescription)")
                    return
                }
                Log.warn(
                    "ScriptingAPI: socket start attempt \(attempt + 1)/\(maxBindAttempts) failed: " +
                        "\(failure.errnoDescription)"
                )
                if failure.step == .listen {
                    // bind succeeded, so the socket file exists — remove it
                    // before the next attempt (or on final failure).
                    candidate.removeStaleSocketFile()
                }

                guard attempt < maxBindAttempts - 1, failure.isRetriable else {
                    break
                }
                usleep(useconds_t((attempt + 1) * 200_000))
            }
        }

        guard let startedListener else {
            return
        }

        listener = startedListener
        startHealthChecks()

        startTime = Date()
        isRunning = true
        Log.info("ScriptingAPI: server started at \(path)")
    }

    func stopServer() {
        for (_, handler) in clientHandlers {
            handler.disconnect()
        }
        clientHandlers.removeAll()

        if let listener {
            listener.stop(removeSocketFile: true)
            self.listener = nil
        } else {
            unlink(socketPath)
        }
        healthCheckSource?.cancel()
        healthCheckSource = nil

        isRunning = false
        connectedClients = 0
        startTime = nil
        Log.info("ScriptingAPI: server stopped")
    }

    private func startHealthChecks() {
        healthCheckSource?.cancel()
        let source = DispatchSource.makeTimerSource(queue: socketQueue)
        source.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(3))
        source.setEventHandler { [weak self] in
            Log.wakeup("scriptingHealth")
            self?.ensureServerHealthy(reason: "periodic")
        }
        source.resume()
        healthCheckSource = source
    }

    private func ensureServerHealthy(reason: String) {
        let snapshot = LocalSocketServerHealthSnapshot(
            expectedRunning: isEnabled,
            isRunning: isRunning,
            hasSocketDescriptor: (listener?.fileDescriptor ?? -1) >= 0,
            hasAcceptSource: listener?.isAccepting == true,
            socketPathExists: FileManager.default.fileExists(atPath: socketPath)
        )
        guard LocalSocketServerHealth.needsRecovery(snapshot) == false else {
            Log.warn(
                "ScriptingAPI: unhealthy server detected reason=\(reason) running=\(snapshot.isRunning) " +
                    "fd=\(snapshot.hasSocketDescriptor) source=\(snapshot.hasAcceptSource) path=\(snapshot.socketPathExists); restarting"
            )
            stopServer()
            if isEnabled {
                startServer()
            }
            return
        }
    }

    // MARK: - Connection Handling

    private func handleAcceptedClient(_ clientFD: Int32) {
        let handler = ScriptingClientHandler(fd: clientFD, queue: socketQueue) { [weak self] json in
            guard let self else { return ["error": "server gone"] }
            return await handleRequest(json)
        } onDisconnect: { [weak self] fd in
            Task { @MainActor [weak self] in
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

    func handleRequest(_ json: [String: Any]) async -> [String: Any] {
        guard let method = json["method"] as? String else {
            return ["error": "missing method"]
        }
        let params = json["params"] as? [String: Any] ?? [:]

        Log.trace("ScriptingAPI: handling method=\(method)")

        switch method {
        case "list_tabs":
            return handleListTabs()
        case "get_tab":
            return handleGetTab(params)
        case "run_command":
            return handleRunCommand(params)
        case "get_output":
            return handleGetOutput(params)
        case "create_tab":
            return handleCreateTab(params)
        case "send_input":
            return handleSendInput(params)
        case "press_key":
            return handlePressKey(params)
        case "submit_prompt":
            return handleSubmitPrompt(params)
        case "close_tab":
            return handleCloseTab(params)
        case "get_repo_events":
            return handleGetRepoEvents(params)
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
        default:
            return ["error": "unknown method: \(method)"]
        }
    }

    // MARK: - Handlers

    private func handleListTabs() -> [String: Any] {
        // tab_list returns a top-level JSON array, which parseJSONResponse
        // (dictionary-only) cannot represent — decode it explicitly.
        let raw = controlPlane.call(name: "tab_list", arguments: [:])
        if let data = raw.data(using: .utf8),
           let tabs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] {
            return ["result": tabs]
        }
        // Dictionary payloads here are error responses — surface them as-is.
        return parseJSONResponse(raw) ?? ["result": [] as [[String: Any]]]
    }

    private func handleGetTab(_ params: [String: Any]) -> [String: Any] {
        guard let tabID = params["id"] as? String else {
            return ["error": "missing param: id"]
        }
        return controlPlaneCall(name: "tab_status", arguments: ["tab_id": tabID]) ?? ["error": "tab not found"]
    }

    private func handleRunCommand(_ params: [String: Any]) -> [String: Any] {
        guard let tabID = params["tab_id"] as? String else {
            return ["error": "missing param: tab_id"]
        }
        guard let command = params["command"] as? String else {
            return ["error": "missing param: command"]
        }
        return controlPlaneCall(name: "tab_exec", arguments: ["tab_id": tabID, "command": command])
            ?? ["error": "exec failed"]
    }

    private func handleGetOutput(_ params: [String: Any]) -> [String: Any] {
        guard let tabID = params["tab_id"] as? String else {
            return ["error": "missing param: tab_id"]
        }
        var arguments: [String: Any] = [
            "tab_id": tabID,
            "lines": params["lines"] as? Int ?? 50
        ]
        if let waitForStableMs = params["wait_for_stable_ms"] as? Int {
            arguments["wait_for_stable_ms"] = waitForStableMs
        }
        if let source = params["source"] as? String {
            arguments["source"] = source
        }
        return controlPlaneCall(name: "tab_output", arguments: arguments) ?? ["error": "output failed"]
    }

    private func handleCreateTab(_ params: [String: Any]) -> [String: Any] {
        var arguments: [String: Any] = [:]
        if let directory = params["directory"] as? String {
            arguments["directory"] = directory
        }
        if let windowID = params["window_id"] as? Int {
            arguments["window_id"] = windowID
        }
        return controlPlaneCall(name: "tab_create", arguments: arguments) ?? ["error": "create failed"]
    }

    private func handleSendInput(_ params: [String: Any]) -> [String: Any] {
        guard let tabID = params["tab_id"] as? String else {
            return ["error": "missing param: tab_id"]
        }
        guard let input = params["input"] as? String else {
            return ["error": "missing param: input"]
        }
        return controlPlaneCall(name: "tab_send_input", arguments: ["tab_id": tabID, "input": input])
            ?? ["error": "send_input failed"]
    }

    private func handlePressKey(_ params: [String: Any]) -> [String: Any] {
        guard let tabID = params["tab_id"] as? String else {
            return ["error": "missing param: tab_id"]
        }
        guard let key = params["key"] as? String else {
            return ["error": "missing param: key"]
        }
        return controlPlaneCall(
            name: "tab_press_key",
            arguments: [
                "tab_id": tabID,
                "key": key,
                "modifiers": params["modifiers"] as? [String] ?? []
            ]
        ) ?? ["error": "press_key failed"]
    }

    private func handleSubmitPrompt(_ params: [String: Any]) -> [String: Any] {
        guard let tabID = params["tab_id"] as? String else {
            return ["error": "missing param: tab_id"]
        }
        return controlPlaneCall(name: "tab_submit_prompt", arguments: ["tab_id": tabID])
            ?? ["error": "submit_prompt failed"]
    }

    private func handleCloseTab(_ params: [String: Any]) -> [String: Any] {
        guard let tabID = params["id"] as? String else {
            return ["error": "missing param: id"]
        }
        return controlPlaneCall(name: "tab_close", arguments: ["tab_id": tabID, "force": true])
            ?? ["error": "close failed"]
    }

    private func handleGetRepoEvents(_ params: [String: Any]) -> [String: Any] {
        guard let repoPath = params["repo_path"] as? String,
              !repoPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return ["error": "missing param: repo_path"]
        }

        var arguments: [String: Any] = [
            "repo_path": repoPath,
            "limit": params["limit"] as? Int ?? 25,
            "truncate_messages": params["truncate_messages"] as? Bool ?? false
        ]
        if let tabID = params["tab_id"] as? String {
            arguments["tab_id"] = tabID
        }
        if let eventTypes = params["event_types"] as? [String], !eventTypes.isEmpty {
            arguments["event_types"] = eventTypes
        }
        if let tool = params["tool"] as? String {
            arguments["tool"] = tool
        }
        if let producer = params["producer"] as? String {
            arguments["producer"] = producer
        }
        if let sessionID = params["session_id"] as? String {
            arguments["session_id"] = sessionID
        }

        return controlPlaneCall(name: "repo_get_events", arguments: arguments)
            ?? ["error": "repo events failed"]
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

        let items: [[String: Any]] = records.map { record in
            var dict: [String: Any] = [
                "command": record.command,
                "timestamp": record.timestamp.timeIntervalSince1970
            ]
            if let directory = record.directory { dict["directory"] = directory }
            if let exitCode = record.exitCode { dict["exit_code"] = exitCode }
            if let shell = record.shell { dict["shell"] = shell }
            if let tabID = record.tabID { dict["tab_id"] = tabID }
            if let duration = record.duration { dict["duration"] = duration }
            return dict
        }

        return ["result": items]
    }

    private func handleGetSettings() -> [String: Any] {
        let defaults = UserDefaults.standard
        let snapshot: [String: Any] = [
            "feature.scriptingAPI": defaults.bool(forKey: Self.featureFlagKey),
            "feature.persistentHistory": defaults.bool(forKey: "feature.persistentHistory"),
            "history.maxRecords": defaults.integer(forKey: "history.maxRecords"),
            "scripting.socket_path": socketPath,
            "scripting.socket_exists": FileManager.default.fileExists(atPath: socketPath),
            "scripting.socket_healthy": !LocalSocketServerHealth.needsRecovery(
                LocalSocketServerHealthSnapshot(
                    expectedRunning: isEnabled,
                    isRunning: isRunning,
                    hasSocketDescriptor: (listener?.fileDescriptor ?? -1) >= 0,
                    hasAcceptSource: listener?.isAccepting == true,
                    socketPathExists: FileManager.default.fileExists(atPath: socketPath)
                )
            )
        ]
        return ["result": snapshot]
    }

    private func handleSetSetting(_ params: [String: Any]) -> [String: Any] {
        guard let key = params["key"] as? String else {
            return ["error": "missing param: key"]
        }
        guard let value = params["value"] else {
            return ["error": "missing param: value"]
        }

        let allowedKeys: Set<String> = [
            Self.featureFlagKey,
            "feature.persistentHistory",
            "history.maxRecords"
        ]
        guard allowedKeys.contains(key) else {
            return ["error": "unknown or disallowed setting key: \(key)"]
        }

        let sanitized: Any
        if let boolValue = value as? Bool { sanitized = boolValue }
        else if let intValue = value as? Int { sanitized = intValue }
        else if let doubleValue = value as? Double { sanitized = doubleValue }
        else if let stringValue = value as? String { sanitized = stringValue }
        else {
            return ["error": "unsupported value type; expected Bool, Int, Double, or String"]
        }

        UserDefaults.standard.set(sanitized, forKey: key)
        return ["result": "ok"]
    }

    private func handleListSnippets() -> [String: Any] {
        let snippets = SnippetManager.shared.entries.map { entry -> [String: Any] in
            ["title": entry.snippet.title, "body": entry.snippet.body]
        }
        return ["result": snippets]
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

    private func handleGetStatus() -> [String: Any] {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "unknown"
        let uptime: TimeInterval = startTime.map { Date().timeIntervalSince($0) } ?? 0

        return [
            "result": [
                "version": version,
                "build": build,
                "api_version": Self.apiVersion,
                "supported_methods": Self.publicSupportedMethods,
                "uptime_seconds": Int(uptime),
                "connected_clients": connectedClients,
                "server_running": isRunning,
                "history_count": PersistentHistoryStore.shared.totalCount()
            ] as [String: Any]
        ]
    }

    private func controlPlaneCall(name: String, arguments: [String: Any]) -> [String: Any]? {
        parseJSONResponse(controlPlane.call(name: name, arguments: arguments))
    }

}
