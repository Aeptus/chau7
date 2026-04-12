import Darwin
import Foundation
import Chau7Core

/// Monitors for running dev servers by detecting port listening and command patterns.
///
/// **Event-driven with liveness polling**: Port checks are triggered by:
/// 1. Command hints (e.g., "npm run dev" detected) → burst of checks while server starts
/// 2. Output patterns (e.g., "Local: http://localhost:3000") → single check for PID enrichment
/// 3. Command completion (prompt returned) → verify or discover servers
/// 4. Liveness timer (30s) → verify detected server is still alive
///
/// Thread-safety: All callbacks dispatch to main via DispatchQueue.main.async.
final class DevServerMonitor {

    /// Information about a detected dev server
    struct DevServerInfo: Equatable {
        let name: String // e.g., "Vite", "Next.js", "Dev Server"
        let port: Int? // The port it's listening on, if detected
        let url: String? // The local URL, if detected
        let pid: Int? // Process ID, if known

        static func == (lhs: DevServerInfo, rhs: DevServerInfo) -> Bool {
            lhs.name == rhs.name && lhs.port == rhs.port
        }
    }

    /// Callback when a dev server is detected or stopped
    var onDevServerChanged: ((DevServerInfo?) -> Void)?

    private var shellPID: pid_t?
    private var currentServer: DevServerInfo?
    private var lastCommandHint: String?
    private let childCacheTtl: TimeInterval = 0.5
    private var cachedChildPIDs: [pid_t] = []
    private var cachedChildParentPID: pid_t = 0
    private var childProcessCacheAt = Date.distantPast
    private let queue = DispatchQueue(label: "com.chau7.devserver", qos: .utility)

    /// Burst timer for checking ports after a command hint.
    private var burstTimer: DispatchSourceTimer?
    private var burstChecksRemaining = 0

    /// Periodic liveness timer — runs only when a server is detected.
    private var livenessTimer: DispatchSourceTimer?
    private static let livenessInterval: TimeInterval = 30

    /// Guards against overlapping port checks.
    private var isCheckingPorts = false
    /// Set by stop() to prevent in-flight background work from starting new subprocesses.
    private var isStopped = false

    // MARK: - Public API

    /// Register the shell PID for this tab.
    /// Does NOT start any timer — monitoring is purely event-driven.
    func start(shellPID: pid_t) {
        self.shellPID = shellPID
        cachedChildPIDs.removeAll(keepingCapacity: true)
        cachedChildParentPID = shellPID
        childProcessCacheAt = Date.distantPast
        isStopped = false
    }

    /// Stop monitoring and clear state.
    func stop() {
        burstTimer?.cancel()
        burstTimer = nil
        burstChecksRemaining = 0
        stopLivenessTimer()
        shellPID = nil
        lastCommandHint = nil
        cachedChildPIDs.removeAll(keepingCapacity: true)
        childProcessCacheAt = Date.distantPast
        isStopped = true
        updateCurrentServer(nil)
    }

    /// Hint from command detection (e.g., "npm run dev" was executed).
    /// Starts a burst of port checks since the server needs time to bind.
    func setCommandHint(_ serverName: String?) {
        lastCommandHint = serverName
        if serverName != nil {
            childProcessCacheAt = Date.distantPast
            startBurstCheck()
        }
    }

    /// Check terminal output for dev server patterns.
    func checkOutput(_ output: String) {
        let cleaned = EscapeSequenceSanitizer.sanitize(output)
        if let serverName = CommandDetection.detectDevServerFromOutput(cleaned) {
            let url = CommandDetection.extractDevServerURL(from: cleaned)
            let port = url.flatMap { CommandDetection.extractPort(from: $0) }
                ?? CommandDetection.extractPort(from: cleaned)

            let newServer = DevServerInfo(
                name: serverName,
                port: port,
                url: url,
                pid: nil
            )

            if newServer != currentServer {
                lastCommandHint = nil
                if port != nil {
                    updateCurrentServer(newServer)
                }
                // Enrich with PID via netstat — only if monitor has a shell PID
                if shellPID != nil {
                    scheduleOneShot(delay: 0.5)
                }
            }
        }
    }

    /// Called when a command finishes (prompt returns).
    /// Verifies existing server and discovers new ones.
    func commandDidFinish() {
        scheduleOneShot(delay: 0.3)
    }

    // MARK: - Burst checking (after command hint)

    /// Starts a burst of port checks: 6 checks over ~25 seconds.
    /// Covers slow servers like Docker cold starts and heavy monorepo toolchains.
    private func startBurstCheck() {
        burstTimer?.cancel()
        burstChecksRemaining = 6

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1.5, repeating: 4.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            burstChecksRemaining -= 1
            checkForListeningPorts()

            if Self.shouldStopBurstChecks(currentServer: currentServer, burstChecksRemaining: burstChecksRemaining) {
                burstTimer?.cancel()
                burstTimer = nil
            }
        }
        timer.resume()
        burstTimer = timer
    }

    // MARK: - One-shot checks

    /// Schedule a single port check after a delay.
    private func scheduleOneShot(delay: TimeInterval) {
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.checkForListeningPorts()
        }
    }

    // MARK: - Liveness timer

    private func startLivenessTimer() {
        livenessTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.livenessInterval, repeating: Self.livenessInterval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            Log.wakeup("devServerLiveness")
            self?.checkForListeningPorts()
        }
        timer.resume()
        livenessTimer = timer
    }

    private func stopLivenessTimer() {
        livenessTimer?.cancel()
        livenessTimer = nil
    }

    // MARK: - Current server state management

    /// Centralized setter for currentServer. Manages liveness timer transitions
    /// and dispatches the callback.
    private func updateCurrentServer(_ newServer: DevServerInfo?) {
        let wasNil = currentServer == nil
        let isNil = newServer == nil
        guard newServer != currentServer else { return }
        currentServer = newServer

        // Manage liveness timer based on state transition
        if wasNil, !isNil {
            startLivenessTimer()
        } else if !wasNil, isNil {
            stopLivenessTimer()
        }

        DispatchQueue.main.async { [weak self] in
            self?.onDevServerChanged?(newServer)
        }
    }

    // MARK: - Port checking

    private func checkForListeningPorts() {
        guard !isStopped, let shellPID else { return }
        guard !isCheckingPorts else { return }
        isCheckingPorts = true
        defer { isCheckingPorts = false }

        let childPIDs = getChildProcessesWithCache(of: shellPID)
        guard !childPIDs.isEmpty else {
            if currentServer != nil {
                lastCommandHint = nil
                updateCurrentServer(nil)
            }
            return
        }

        if let serverInfo = findListeningServer(pids: childPIDs) {
            if serverInfo != currentServer {
                lastCommandHint = nil
                updateCurrentServer(serverInfo)
            }
        } else if currentServer != nil {
            // Children exist but none are listening — server process may have exited
            // while child processes linger. Clear the server.
            lastCommandHint = nil
            updateCurrentServer(nil)
        }
    }

    static func shouldStopBurstChecks(currentServer: DevServerInfo?, burstChecksRemaining: Int) -> Bool {
        burstChecksRemaining <= 0 || currentServer?.port != nil
    }

    // MARK: - Process tree (single `ps` call + in-memory BFS)

    /// Get all descendant process IDs of a given parent.
    /// Uses a single `ps -axo ppid,pid` call and walks the tree in-memory.
    private func getChildProcesses(of parentPID: pid_t) -> [pid_t] {
        guard let output = SubprocessRunner.run(executablePath: "/bin/ps", arguments: ["-axo", "ppid,pid"]) else {
            return []
        }

        // Build parent→children map from the full process table
        var childrenOf: [pid_t: [pid_t]] = [:]
        for line in output.split(separator: "\n") {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true)
            guard cols.count >= 2,
                  let ppid = Int32(cols[0]),
                  let pid = Int32(cols[1]) else { continue }
            childrenOf[ppid, default: []].append(pid)
        }

        // BFS walk from parentPID to collect all descendants
        var result: [pid_t] = []
        var queue = childrenOf[parentPID] ?? []
        var queueIndex = 0
        while queueIndex < queue.count {
            let pid = queue[queueIndex]
            queueIndex += 1
            result.append(pid)
            if let grandchildren = childrenOf[pid] {
                queue.append(contentsOf: grandchildren)
            }
        }
        return result
    }

    private func getChildProcessesWithCache(of parentPID: pid_t) -> [pid_t] {
        if cachedChildParentPID != parentPID {
            cachedChildPIDs.removeAll(keepingCapacity: true)
            childProcessCacheAt = Date.distantPast
            cachedChildParentPID = parentPID
        }

        let now = Date()
        if now.timeIntervalSince(childProcessCacheAt) <= childCacheTtl {
            return cachedChildPIDs
        }

        let childPIDs = getChildProcesses(of: parentPID)
        cachedChildPIDs = childPIDs
        childProcessCacheAt = now
        return childPIDs
    }

    // MARK: - Port scanning (netstat, ~7ms)

    /// Default PID column index in `netstat -anv` output (macOS standard layout).
    private static let defaultNetstatPIDColumn = 10

    /// Find a server listening on a dev port among the given PIDs.
    /// Uses `netstat -anv` instead of `lsof` — completes in ~7ms vs 5-10+ seconds.
    /// Parses the header line dynamically to find the PID column index.
    private func findListeningServer(pids: [pid_t]) -> DevServerInfo? {
        guard !pids.isEmpty else { return nil }
        guard let output = SubprocessRunner.run(executablePath: "/usr/sbin/netstat", arguments: ["-anv", "-p", "tcp"]) else {
            return nil
        }

        let lines = output.split(separator: "\n")
        guard !lines.isEmpty else { return nil }

        // Parse header to find PID column dynamically
        let headers = lines[0].split(separator: " ", omittingEmptySubsequences: true)
        let pidColumnIndex = headers.firstIndex(where: { $0.lowercased() == "pid" })
            ?? Self.defaultNetstatPIDColumn

        let pidSet = Set(pids)
        for line in lines.dropFirst() {
            guard line.contains("LISTEN") else { continue }
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count > pidColumnIndex else { continue }

            guard let pid = Int32(columns[pidColumnIndex]) else { continue }
            guard pidSet.contains(pid) else { continue }

            // Local address is always column 3
            guard columns.count > 3 else { continue }
            let localAddr = String(columns[3])
            if let port = extractPortFromNetstat(localAddr) {
                let commandName = getProcessName(pid: pid) ?? "unknown"
                let serverName = determineServerName(port: port, commandName: commandName)
                return DevServerInfo(
                    name: serverName,
                    port: port,
                    url: "http://localhost:\(port)",
                    pid: Int(pid)
                )
            }
        }

        return nil
    }

    /// Extract port number from netstat local address column.
    /// Format: "*.3000" or "127.0.0.1.5173" or "::1.8080"
    /// The port is always the last dot-separated component.
    private func extractPortFromNetstat(_ addr: String) -> Int? {
        guard let lastDot = addr.lastIndex(of: ".") else { return nil }
        let portStr = addr[addr.index(after: lastDot)...]
        return Int(portStr)
    }

    /// Get the command name for a PID via `ps`.
    private func getProcessName(pid: pid_t) -> String? {
        guard let output = SubprocessRunner.run(executablePath: "/bin/ps", arguments: ["-o", "comm=", "-p", "\(pid)"]) else {
            return nil
        }
        let name = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        // ps -o comm= returns the full path; take just the last component
        return URL(fileURLWithPath: name).lastPathComponent
    }

    /// Determine server name from port and process name
    private func determineServerName(port: Int, commandName: String) -> String {
        if let hint = lastCommandHint {
            lastCommandHint = nil
            return hint
        }

        if let knownServer = CommandDetection.commonDevPorts[port] {
            return knownServer
        }

        let normalizedCommand = commandName.lowercased()
        if let serverName = CommandDetection.devServerMap[normalizedCommand] {
            return serverName
        }

        if normalizedCommand == "node" {
            return L("devServer.node", "Node Server")
        }

        return L("devServer.generic", "Dev Server")
    }
}
