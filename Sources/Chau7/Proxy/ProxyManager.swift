import Foundation
import os.log

/// ProxyManager handles the lifecycle of the chau7-proxy Go binary.
/// It starts the proxy when API analytics is enabled and stops it when disabled.
/// The proxy runs as a subprocess, communicating back via Unix socket IPC.
@MainActor
public final class ProxyManager: ObservableObject {

    // MARK: - Singleton

    public static let shared = ProxyManager()

    // MARK: - Published State

    @Published public private(set) var isRunning = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var port: Int = 18080

    // MARK: - Private Properties

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private let logger = Logger(subsystem: "com.chau7.proxy", category: "ProxyManager")

    /// Path to the bundled proxy binary
    private var proxyBinaryPath: URL? {
        // Look in the app bundle first
        if let bundlePath = Bundle.main.url(forResource: "chau7-proxy", withExtension: nil) {
            return bundlePath
        }

        // Fallback to Resources directory
        if let resourcesURL = Bundle.main.resourceURL {
            let proxyPath = resourcesURL.appendingPathComponent("chau7-proxy")
            if FileManager.default.fileExists(atPath: proxyPath.path) {
                return proxyPath
            }
        }

        // Development fallback: check project build directory
        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

        // Check Go proxy build output
        let goBuildPath = projectRoot
            .appendingPathComponent("chau7-proxy/build/darwin/chau7-proxy")
        if FileManager.default.fileExists(atPath: goBuildPath.path) {
            return goBuildPath
        }

        // Check local Go proxy directory (for development)
        let devPath = projectRoot
            .appendingPathComponent("chau7-proxy/chau7-proxy")
        if FileManager.default.fileExists(atPath: devPath.path) {
            return devPath
        }

        return nil
    }

    /// Directory for proxy data (database, socket)
    private var dataDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let chau7Dir = appSupport.appendingPathComponent("Chau7/Proxy")
        try? FileManager.default.createDirectory(at: chau7Dir, withIntermediateDirectories: true)
        return chau7Dir
    }

    private var databasePath: URL {
        dataDirectory.appendingPathComponent("analytics.db")
    }

    private var socketPath: URL {
        dataDirectory.appendingPathComponent("proxy.sock")
    }

    // MARK: - Initialization

    private init() {
        // Observe settings changes
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: .apiAnalyticsSettingsChanged,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public Interface

    /// Starts the proxy server if API analytics is enabled
    public func startIfEnabled() {
        let settings = FeatureSettings.shared
        guard settings.isAPIAnalyticsEnabled else {
            logger.info("API analytics disabled, not starting proxy")
            return
        }

        start(port: settings.apiAnalyticsPort)
    }

    /// Starts the proxy server on the specified port
    public func start(port: Int = 18080) {
        guard !isRunning else {
            logger.info("Proxy already running")
            return
        }

        guard let binaryPath = proxyBinaryPath else {
            let error = "Proxy binary not found. Please build chau7-proxy first."
            logger.error("\(error)")
            lastError = error
            NotificationCenter.default.post(name: .proxyStatusChanged, object: nil, userInfo: ["status": "error", "message": error])
            return
        }

        // Ensure binary is executable
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath.path)
        } catch {
            logger.warning("Failed to set binary permissions: \(error.localizedDescription)")
        }

        self.port = port

        // Remove stale socket file
        try? FileManager.default.removeItem(at: socketPath)

        // Configure process
        let process = Process()
        process.executableURL = binaryPath
        process.currentDirectoryURL = dataDirectory

        // Set environment variables for the proxy
        var env = ProcessInfo.processInfo.environment
        env["CHAU7_PROXY_PORT"] = String(port)
        env["CHAU7_DB_PATH"] = databasePath.path
        env["CHAU7_IPC_SOCKET"] = socketPath.path
        env["CHAU7_LOG_LEVEL"] = "info"
        env["CHAU7_LOG_PROMPTS"] = FeatureSettings.shared.apiAnalyticsLogPrompts ? "1" : "0"
        process.environment = env

        // Setup pipes for output
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        self.outputPipe = outputPipe
        self.errorPipe = errorPipe

        // Handle output asynchronously
        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.logger.debug("Proxy stdout: \(output)")
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.logger.warning("Proxy stderr: \(output)")
        }

        // Handle process termination
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self = self else { return }
                self.isRunning = false

                if proc.terminationStatus != 0 {
                    let error = "Proxy exited with status \(proc.terminationStatus)"
                    self.logger.error("\(error)")
                    self.lastError = error
                    NotificationCenter.default.post(name: .proxyStatusChanged, object: nil, userInfo: ["status": "stopped", "error": error])
                } else {
                    self.logger.info("Proxy stopped cleanly")
                    NotificationCenter.default.post(name: .proxyStatusChanged, object: nil, userInfo: ["status": "stopped"])
                }
            }
        }

        // Start the process
        do {
            try process.run()
            self.process = process
            isRunning = true
            lastError = nil

            logger.info("Proxy started on port \(port)")
            NotificationCenter.default.post(name: .proxyStatusChanged, object: nil, userInfo: ["status": "running", "port": port])

        } catch {
            let errorMessage = "Failed to start proxy: \(error.localizedDescription)"
            logger.error("\(errorMessage)")
            lastError = errorMessage
            NotificationCenter.default.post(name: .proxyStatusChanged, object: nil, userInfo: ["status": "error", "message": errorMessage])
        }
    }

    /// Stops the proxy server
    public func stop() {
        guard isRunning, let process = process else {
            logger.info("Proxy not running")
            return
        }

        logger.info("Stopping proxy...")

        // Send SIGTERM for graceful shutdown
        process.terminate()

        // Give it a moment to shut down gracefully
        DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) { [weak self] in
            if self?.process?.isRunning == true {
                self?.logger.warning("Proxy didn't stop gracefully, killing...")
                self?.process?.interrupt()
            }
        }

        // Clean up pipes
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil

        isRunning = false
        self.process = nil
    }

    /// Restarts the proxy server
    public func restart() {
        stop()

        // Wait a moment before restarting
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.startIfEnabled()
        }
    }

    /// Checks if the proxy is healthy by hitting the health endpoint
    public func checkHealth() async -> Bool {
        guard isRunning else { return false }

        let url = URL(string: "http://127.0.0.1:\(port)/health")!

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            // Parse response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String {
                return status == "ok"
            }

            return false
        } catch {
            logger.warning("Health check failed: \(error.localizedDescription)")
            return false
        }
    }

    /// Gets current proxy statistics
    public func getStats() async -> APICallStats? {
        guard isRunning else { return nil }

        let url = URL(string: "http://127.0.0.1:\(port)/stats")!

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            // Parse stats response
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return APICallStats(
                    callCount: json["calls_today"] as? Int ?? 0,
                    totalInputTokens: json["input_tokens_today"] as? Int ?? 0,
                    totalOutputTokens: json["output_tokens_today"] as? Int ?? 0,
                    totalCost: json["cost_today"] as? Double ?? 0.0,
                    averageLatencyMs: json["avg_latency_ms"] as? Double ?? 0.0
                )
            }

            return nil
        } catch {
            logger.warning("Stats fetch failed: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - Task Management

    /// Gets the current task candidate for a tab
    public func getTaskCandidate(tabId: String) async -> TaskCandidate? {
        guard isRunning else { return nil }

        let url = URL(string: "http://127.0.0.1:\(port)/task/candidate?tab_id=\(tabId)")!

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            struct CandidateResponse: Decodable {
                let hasCandidate: Bool
                let candidateId: String?
                let suggestedName: String?
                let trigger: String?
                let graceRemainingMs: Int64?
                let confidence: Double?

                enum CodingKeys: String, CodingKey {
                    case hasCandidate = "has_candidate"
                    case candidateId = "candidate_id"
                    case suggestedName = "suggested_name"
                    case trigger
                    case graceRemainingMs = "grace_remaining_ms"
                    case confidence
                }
            }

            let resp = try JSONDecoder().decode(CandidateResponse.self, from: data)

            guard resp.hasCandidate,
                  let candidateId = resp.candidateId,
                  let suggestedName = resp.suggestedName,
                  let trigger = resp.trigger,
                  let graceRemainingMs = resp.graceRemainingMs else {
                return nil
            }

            return TaskCandidate(
                id: candidateId,
                tabId: tabId,
                sessionId: "",
                projectPath: "",
                suggestedName: suggestedName,
                trigger: TaskTrigger(rawValue: trigger) ?? .manual,
                confidence: resp.confidence ?? 0.5,
                gracePeriodEnd: Date().addingTimeInterval(Double(graceRemainingMs) / 1000.0),
                createdAt: Date()
            )
        } catch {
            logger.warning("Failed to get task candidate: \(error.localizedDescription)")
            return nil
        }
    }

    /// Gets the current active task for a tab
    public func getCurrentTask(tabId: String) async -> TrackedTask? {
        guard isRunning else { return nil }

        let url = URL(string: "http://127.0.0.1:\(port)/task/current?tab_id=\(tabId)")!

        do {
            let (data, response) = try await URLSession.shared.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            struct CurrentTaskResponse: Decodable {
                let hasTask: Bool
                let taskId: String?
                let taskName: String?
                let state: String?
                let totalCalls: Int?
                let totalTokens: Int?
                let totalCostUSD: Double?
                let durationSec: Int64?
                let startMethod: String?
                let trigger: String?
                let projectPath: String?

                enum CodingKeys: String, CodingKey {
                    case hasTask = "has_task"
                    case taskId = "task_id"
                    case taskName = "task_name"
                    case state
                    case totalCalls = "total_calls"
                    case totalTokens = "total_tokens"
                    case totalCostUSD = "total_cost_usd"
                    case durationSec = "duration_sec"
                    case startMethod = "start_method"
                    case trigger
                    case projectPath = "project_path"
                }
            }

            let resp = try JSONDecoder().decode(CurrentTaskResponse.self, from: data)

            guard resp.hasTask,
                  let taskId = resp.taskId,
                  let taskName = resp.taskName else {
                return nil
            }

            return TrackedTask(
                id: taskId,
                candidateId: nil,
                tabId: tabId,
                sessionId: "",
                projectPath: resp.projectPath ?? "",
                name: taskName,
                state: TaskState(rawValue: resp.state ?? "active") ?? .active,
                startMethod: TaskStartMethod(rawValue: resp.startMethod ?? "manual") ?? .manual,
                trigger: TaskTrigger(rawValue: resp.trigger ?? "manual") ?? .manual,
                startedAt: Date().addingTimeInterval(-Double(resp.durationSec ?? 0)),
                completedAt: nil,
                totalAPICalls: resp.totalCalls ?? 0,
                totalTokens: resp.totalTokens ?? 0,
                totalCostUSD: resp.totalCostUSD ?? 0
            )
        } catch {
            logger.warning("Failed to get current task: \(error.localizedDescription)")
            return nil
        }
    }

    /// Starts a new task manually
    public func startTask(tabId: String, taskName: String?, candidateId: String? = nil) async -> TrackedTask? {
        guard isRunning else { return nil }

        let url = URL(string: "http://127.0.0.1:\(port)/task/start")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct StartRequest: Encodable {
            let tabId: String
            let taskName: String?
            let candidateId: String?

            enum CodingKeys: String, CodingKey {
                case tabId = "tab_id"
                case taskName = "task_name"
                case candidateId = "candidate_id"
            }
        }

        do {
            request.httpBody = try JSONEncoder().encode(StartRequest(
                tabId: tabId,
                taskName: taskName,
                candidateId: candidateId
            ))

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return nil
            }

            struct StartResponse: Decodable {
                let taskId: String
                let taskName: String

                enum CodingKeys: String, CodingKey {
                    case taskId = "task_id"
                    case taskName = "task_name"
                }
            }

            let resp = try JSONDecoder().decode(StartResponse.self, from: data)

            return TrackedTask(
                id: resp.taskId,
                candidateId: candidateId,
                tabId: tabId,
                sessionId: "",
                projectPath: "",
                name: resp.taskName,
                state: .active,
                startMethod: candidateId != nil ? .userConfirmed : .manual,
                trigger: .manual,
                startedAt: Date(),
                completedAt: nil,
                totalAPICalls: 0,
                totalTokens: 0,
                totalCostUSD: 0
            )
        } catch {
            logger.warning("Failed to start task: \(error.localizedDescription)")
            return nil
        }
    }

    /// Dismisses a pending task candidate
    public func dismissCandidate(tabId: String, candidateId: String) async -> Bool {
        guard isRunning else { return false }

        let url = URL(string: "http://127.0.0.1:\(port)/task/dismiss")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct DismissRequest: Encodable {
            let tabId: String
            let candidateId: String

            enum CodingKeys: String, CodingKey {
                case tabId = "tab_id"
                case candidateId = "candidate_id"
            }
        }

        do {
            request.httpBody = try JSONEncoder().encode(DismissRequest(
                tabId: tabId,
                candidateId: candidateId
            ))

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            struct DismissResponse: Decodable {
                let dismissed: Bool
            }

            let resp = try JSONDecoder().decode(DismissResponse.self, from: data)
            return resp.dismissed
        } catch {
            logger.warning("Failed to dismiss candidate: \(error.localizedDescription)")
            return false
        }
    }

    /// Assesses a task as success or failure
    public func assessTask(taskId: String, approved: Bool, note: String? = nil) async -> Bool {
        guard isRunning else { return false }

        let url = URL(string: "http://127.0.0.1:\(port)/task/assess")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        struct AssessRequest: Encodable {
            let taskId: String
            let approved: Bool
            let note: String?

            enum CodingKeys: String, CodingKey {
                case taskId = "task_id"
                case approved
                case note
            }
        }

        do {
            request.httpBody = try JSONEncoder().encode(AssessRequest(
                taskId: taskId,
                approved: approved,
                note: note
            ))

            let (data, response) = try await URLSession.shared.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else {
                return false
            }

            struct AssessResponse: Decodable {
                let success: Bool
            }

            let resp = try JSONDecoder().decode(AssessResponse.self, from: data)
            return resp.success
        } catch {
            logger.warning("Failed to assess task: \(error.localizedDescription)")
            return false
        }
    }

    // MARK: - Private Methods

    @objc private func settingsChanged() {
        let settings = FeatureSettings.shared

        if settings.isAPIAnalyticsEnabled && !isRunning {
            start(port: settings.apiAnalyticsPort)
        } else if !settings.isAPIAnalyticsEnabled && isRunning {
            stop()
        } else if isRunning && settings.apiAnalyticsPort != port {
            // Port changed, restart
            restart()
        }
    }
}

