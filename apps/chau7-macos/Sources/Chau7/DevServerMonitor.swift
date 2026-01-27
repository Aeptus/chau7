import Foundation
import Chau7Core

/// Monitors for running dev servers by detecting port listening and command patterns.
/// Thread-safety: All callbacks dispatch to main via DispatchQueue.main.async.
final class DevServerMonitor {

    /// Information about a detected dev server
    struct DevServerInfo: Equatable {
        let name: String        // e.g., "Vite", "Next.js", "Dev Server"
        let port: Int?          // The port it's listening on, if detected
        let url: String?        // The local URL, if detected
        let pid: Int?           // Process ID, if known

        static func == (lhs: DevServerInfo, rhs: DevServerInfo) -> Bool {
            lhs.name == rhs.name && lhs.port == rhs.port
        }
    }

    /// Callback when a dev server is detected or stopped
    var onDevServerChanged: ((DevServerInfo?) -> Void)?

    private var checkTimer: DispatchSourceTimer?
    private var shellPID: pid_t?
    private var currentServer: DevServerInfo?
    private var lastCommandHint: String?  // Hint from command detection
    private let queue = DispatchQueue(label: "com.chau7.devserver", qos: .utility)

    // MARK: - Public API

    /// Start monitoring for dev servers
    /// - Parameter shellPID: The PID of the shell process to monitor
    func start(shellPID: pid_t) {
        self.shellPID = shellPID
        startPeriodicCheck()
    }

    /// Stop monitoring
    func stop() {
        checkTimer?.cancel()
        checkTimer = nil
        shellPID = nil
        lastCommandHint = nil
        if currentServer != nil {
            currentServer = nil
            DispatchQueue.main.async { [weak self] in
                self?.onDevServerChanged?(nil)
            }
        }
    }

    /// Hint from command detection (e.g., "npm run dev" was executed)
    /// This helps identify the server type before port detection kicks in
    func setCommandHint(_ serverName: String?) {
        lastCommandHint = serverName
    }

    /// Check terminal output for dev server patterns
    /// - Parameter output: Recent terminal output
    func checkOutput(_ output: String) {
        // Check for dev server output patterns
        if let serverName = CommandDetection.detectDevServerFromOutput(output) {
            let url = CommandDetection.extractDevServerURL(from: output)
            let port = url.flatMap { CommandDetection.extractPort(from: $0) }
                ?? CommandDetection.extractPort(from: output)

            let newServer = DevServerInfo(
                name: serverName,
                port: port,
                url: url,
                pid: nil
            )

            if newServer != currentServer {
                currentServer = newServer
                lastCommandHint = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onDevServerChanged?(newServer)
                }
            }
        }
    }

    // MARK: - Private

    private func startPeriodicCheck() {
        checkTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2.0, repeating: 3.0)  // Check every 3 seconds
        timer.setEventHandler { [weak self] in
            self?.checkForListeningPorts()
        }
        timer.resume()
        checkTimer = timer
    }

    private func checkForListeningPorts() {
        guard let shellPID = shellPID else { return }

        // Get child processes of the shell
        let childPIDs = getChildProcesses(of: shellPID)
        guard !childPIDs.isEmpty else {
            // No child processes - server might have stopped
            if currentServer != nil {
                currentServer = nil
                lastCommandHint = nil
                DispatchQueue.main.async { [weak self] in
                    self?.onDevServerChanged?(nil)
                }
            }
            return
        }

        // Check if any child process is listening on a dev port
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

    /// Get child process IDs of a given parent
    private func getChildProcesses(of parentPID: pid_t) -> [pid_t] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-o", "pid=", "--ppid", "\(parentPID)"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)

        var pids: [pid_t] = []
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let pid = Int32(trimmed) {
                pids.append(pid)
                // Recursively get grandchildren
                pids.append(contentsOf: getChildProcesses(of: pid))
            }
        }
        return pids
    }

    /// Find a server listening on a dev port among the given PIDs
    private func findListeningServer(pids: [pid_t]) -> DevServerInfo? {
        guard !pids.isEmpty else { return nil }

        // Use lsof to find listening ports
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-i", "-P", "-n", "-sTCP:LISTEN"]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(decoding: data, as: UTF8.self)

        // Parse lsof output to find our processes
        let pidSet = Set(pids)
        for line in output.split(separator: "\n") {
            let columns = line.split(separator: " ", omittingEmptySubsequences: true)
            guard columns.count >= 9 else { continue }

            // Column format: COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME
            guard let pid = Int32(columns[1]) else { continue }
            guard pidSet.contains(pid) else { continue }

            // Extract port from NAME column (e.g., "*:3000" or "127.0.0.1:5173")
            let name = columns[8...].joined(separator: " ")
            if let port = extractPortFromLsof(name) {
                let serverName = determineServerName(port: port, commandName: String(columns[0]))
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

    /// Extract port number from lsof NAME column
    private func extractPortFromLsof(_ name: String) -> Int? {
        // Format: "*:3000" or "127.0.0.1:5173" or "[::1]:8080"
        let pattern = ":(\\d{2,5})"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return nil }
        let range = NSRange(name.startIndex..., in: name)
        let matches = regex.matches(in: name, options: [], range: range)
        guard let match = matches.last, match.numberOfRanges > 1,
              let matchRange = Range(match.range(at: 1), in: name) else {
            return nil
        }
        return Int(name[matchRange])
    }

    /// Determine server name from port and process name
    private func determineServerName(port: Int, commandName: String) -> String {
        // First, check if we have a command hint
        if let hint = lastCommandHint {
            lastCommandHint = nil
            return hint
        }

        // Check known port mappings
        if let knownServer = CommandDetection.commonDevPorts[port] {
            return knownServer
        }

        // Check command name
        let normalizedCommand = commandName.lowercased()
        if let serverName = CommandDetection.devServerMap[normalizedCommand] {
            return serverName
        }

        // Check for node-based servers
        if normalizedCommand == "node" {
            // Could be any Node.js server
            return "Node Server"
        }

        return "Dev Server"
    }
}
