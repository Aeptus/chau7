import Darwin
import Foundation
import Chau7Core

/// Monitors for running dev servers by detecting port listening and command patterns.
///
/// **Event-driven**: No perpetual timer. Port checks are triggered only by:
/// 1. Command hints (e.g., "npm run dev" detected) → burst of checks while server starts
/// 2. Output patterns (e.g., "Local: http://localhost:3000") → single check for PID enrichment
/// 3. Command completion (prompt returned) → verify server is still alive
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
    /// Fires a few times over ~10 seconds then stops.
    private var burstTimer: DispatchSourceTimer?
    private var burstChecksRemaining = 0

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
        shellPID = nil
        lastCommandHint = nil
        cachedChildPIDs.removeAll(keepingCapacity: true)
        childProcessCacheAt = Date.distantPast
        // Ensure no in-flight check on the background queue can start new work
        isStopped = true
        if currentServer != nil {
            currentServer = nil
            DispatchQueue.main.async { [weak self] in
                self?.onDevServerChanged?(nil)
            }
        }
    }

    /// Hint from command detection (e.g., "npm run dev" was executed).
    /// Starts a burst of port checks since the server needs time to bind.
    func setCommandHint(_ serverName: String?) {
        lastCommandHint = serverName
        if serverName != nil {
            childProcessCacheAt = Date.distantPast
        }
        if serverName != nil {
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
                currentServer = newServer
                lastCommandHint = nil
                if port != nil {
                    // Port already known from output — emit immediately
                    DispatchQueue.main.async { [weak self] in
                        self?.onDevServerChanged?(newServer)
                    }
                }
                // Enrich with PID (and port if not yet known) via lsof
                scheduleOneShot(delay: 0.5)
            }
        }
    }

    /// Called when a command finishes (prompt returns).
    /// Checks if a known server is still alive, or discovers a new one.
    func commandDidFinish() {
        // If we have a current server, verify it's still running
        if currentServer != nil {
            scheduleOneShot(delay: 0.3)
        }
    }

    // MARK: - Burst checking (after command hint)

    /// Starts a burst of port checks: 4 checks over ~12 seconds.
    /// Dev servers typically take 2-8 seconds to start listening.
    private func startBurstCheck() {
        burstTimer?.cancel()
        burstChecksRemaining = 4

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            burstChecksRemaining -= 1
            checkForListeningPorts()

            // Stop once we found a server or ran out of checks
            if currentServer != nil || burstChecksRemaining <= 0 {
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

    // MARK: - Port checking

    private func checkForListeningPorts() {
        guard !isStopped, let shellPID = shellPID else { return }
        guard !isCheckingPorts else { return }
        isCheckingPorts = true
        defer { isCheckingPorts = false }

        let childPIDs = getChildProcessesWithCache(of: shellPID)
        guard !childPIDs.isEmpty else {
            // No children — server has stopped
            if currentServer != nil {
                currentServer = nil
                lastCommandHint = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onDevServerChanged?(nil)
                }
            }
            return
        }

        if let serverInfo = findListeningServer(pids: childPIDs) {
            if serverInfo != currentServer {
                currentServer = serverInfo
                lastCommandHint = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onDevServerChanged?(serverInfo)
                }
            }
        }
    }

    // MARK: - Subprocess helper

    /// Runs a subprocess and returns its stdout as a String.
    /// Explicitly calls `waitpid` after `waitUntilExit` to reap the child
    /// and prevent zombie processes on background dispatch queues.
    private func runSubprocess(executablePath: String, arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        // Explicitly reap — Foundation.Process on background queues
        // may not run the SIGCHLD handler, leaving a zombie.
        var status: Int32 = 0
        waitpid(process.processIdentifier, &status, WNOHANG)

        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Process tree (single `ps` call + in-memory BFS)

    /// Get all descendant process IDs of a given parent.
    /// Uses a single `ps -axo ppid,pid` call and walks the tree in-memory.
    private func getChildProcesses(of parentPID: pid_t) -> [pid_t] {
        guard let output = runSubprocess(executablePath: "/bin/ps", arguments: ["-axo", "ppid,pid"]) else {
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

    /// Find a server listening on a dev port among the given PIDs.
    /// Uses `netstat -anv` instead of `lsof` — completes in ~7ms vs 5-10+ seconds.
    private func findListeningServer(pids: [pid_t]) -> DevServerInfo? {
        guard !pids.isEmpty else { return nil }
        guard let output = runSubprocess(executablePath: "/usr/sbin/netstat", arguments: ["-anv", "-p", "tcp"]) else {
            return nil
        }

        // netstat -anv column layout (space-separated):
        // Proto Recv-Q Send-Q Local Foreign (state) rxbytes txbytes rhiwat shiwat pid epid ...
        // Index:  0      1      2     3      4       5       6       7      8     9   10  11
        let pidSet = Set(pids)
        for line in output.split(separator: "\n") {
            guard line.contains("LISTEN") else { continue }
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 11 else { continue }

            guard let pid = Int32(columns[10]) else { continue }
            guard pidSet.contains(pid) else { continue }

            // Local address format: "*.3000" or "127.0.0.1.5173" or "::1.8080"
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
        guard let output = runSubprocess(executablePath: "/bin/ps", arguments: ["-o", "comm=", "-p", "\(pid)"]) else {
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
            return "Node Server"
        }

        return "Dev Server"
    }
}
