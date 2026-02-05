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
@MainActor
final class ScriptingAPI: ObservableObject {
    static let shared = ScriptingAPI()

    @Published var isEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: "feature.scriptingAPI")
            if isEnabled { startServer() } else { stopServer() }
        }
    }

    @Published private(set) var isRunning = false
    @Published private(set) var connectedClients = 0

    private var socketFD: Int32 = -1
    private var listeningSource: DispatchSourceRead?
    private var clientHandlers: [Int32: ScriptingClientHandler] = [:]
    private let socketQueue = DispatchQueue(label: "com.chau7.scripting", qos: .userInitiated)

    /// Timestamp when the server was started, used for uptime calculation.
    private var startTime: Date?

    private var socketPath: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return support.appendingPathComponent("Chau7/scripting.sock").path
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: "feature.scriptingAPI")
        if isEnabled { startServer() }
        Log.info("ScriptingAPI initialized: enabled=\(isEnabled)")
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
            return
        }

        listeningSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: socketQueue)
        listeningSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        listeningSource?.setCancelHandler { [weak self] in
            if let fd = self?.socketFD, fd >= 0 {
                close(fd)
            }
            self?.socketFD = -1
        }
        listeningSource?.resume()

        startTime = Date()
        isRunning = true
        Log.info("ScriptingAPI: server started at \(path)")
    }

    func stopServer() {
        for (fd, handler) in clientHandlers {
            handler.disconnect()
            close(fd)
        }
        clientHandlers.removeAll()

        listeningSource?.cancel()
        listeningSource = nil

        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }

        unlink(socketPath)
        isRunning = false
        connectedClients = 0
        startTime = nil
        Log.info("ScriptingAPI: server stopped")
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
            return await self.handleRequest(json)
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
        default:
            return ["error": "unknown method: \(method)"]
        }
    }

    // MARK: - Handlers

    private func handleListTabs() async -> [String: Any] {
        return ["error": "not_implemented", "message": "list_tabs requires AppModel wiring"]
    }

    private func handleGetTab(_ params: [String: Any]) async -> [String: Any] {
        guard params["id"] is String else {
            return ["error": "missing param: id"]
        }
        return ["error": "not_implemented", "message": "get_tab requires AppModel wiring"]
    }

    private func handleRunCommand(_ params: [String: Any]) async -> [String: Any] {
        guard params["tab_id"] is String else {
            return ["error": "missing param: tab_id"]
        }
        guard params["command"] is String else {
            return ["error": "missing param: command"]
        }
        return ["error": "not_implemented", "message": "run_command requires terminal wiring"]
    }

    private func handleGetOutput(_ params: [String: Any]) async -> [String: Any] {
        guard params["tab_id"] is String else {
            return ["error": "missing param: tab_id"]
        }
        return ["error": "not_implemented", "message": "get_output requires terminal wiring"]
    }

    private func handleCreateTab(_ params: [String: Any]) async -> [String: Any] {
        return ["error": "not_implemented", "message": "create_tab requires AppModel wiring"]
    }

    private func handleCloseTab(_ params: [String: Any]) async -> [String: Any] {
        guard params["id"] is String else {
            return ["error": "missing param: id"]
        }
        return ["error": "not_implemented", "message": "close_tab requires AppModel wiring"]
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
                "timestamp": r.timestamp.timeIntervalSince1970,
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
        snapshot["feature.scriptingAPI"] = defaults.bool(forKey: "feature.scriptingAPI")
        snapshot["feature.persistentHistory"] = defaults.bool(forKey: "feature.persistentHistory")
        snapshot["history.maxRecords"] = defaults.integer(forKey: "history.maxRecords")
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
            "feature.scriptingAPI",
            "feature.persistentHistory",
            "history.maxRecords",
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
        guard params["name"] is String else {
            return ["error": "missing param: name"]
        }
        return ["error": "not_implemented", "message": "run_snippet requires SnippetManager wiring"]
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
                "history_count": PersistentHistoryStore.shared.totalCount(),
            ] as [String: Any]
        ]
    }
}
