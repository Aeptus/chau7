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

