import Foundation
import Chau7Core

/// Manages the embedded MCP server that listens on a Unix domain socket.
/// MCP clients connect via the chau7-mcp-bridge which pipes stdio ↔ socket.
///
/// Socket path: ~/.chau7/mcp.sock
final class MCPServerManager {
    static let shared = MCPServerManager()

    private var serverSocket: Int32 = -1
    private var clientSockets: [Int32] = []
    private let socketPath: String
    private let queue = DispatchQueue(label: "com.chau7.mcp.server")
    private var isRunning = false
    private var acceptSource: DispatchSourceRead?

    private init() {
        self.socketPath = NSHomeDirectory() + "/.chau7/mcp.sock"
    }

    // MARK: - Bridge Installation

    /// Copies the MCP bridge binary from the app bundle to ~/.chau7/bin/
    /// and registers the MCP server config with all known AI coding tools.
    private func installBridgeIfNeeded() {
        let bridgeName = "chau7-mcp-bridge"
        guard let bundledURL = Bundle.main.url(forResource: bridgeName, withExtension: nil) else {
            Log.trace("MCPServer: \(bridgeName) not found in app bundle (dev build?)")
            return
        }

        let fm = FileManager.default
        let binDir = URL(fileURLWithPath: NSHomeDirectory() + "/.chau7/bin")
        let dest = binDir.appendingPathComponent(bridgeName)

        do {
            if !fm.fileExists(atPath: binDir.path) {
                try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
            }
            if fm.fileExists(atPath: dest.path) {
                try fm.removeItem(at: dest)
            }
            try fm.copyItem(at: bundledURL, to: dest)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dest.path)
            Log.info("MCPServer: installed \(bridgeName) to \(dest.path)")
        } catch {
            Log.error("MCPServer: failed to install \(bridgeName): \(error)")
        }

        registerMCPWithAllTools(bridgePath: dest.path)
    }

    /// Registers the Chau7 MCP server with every known AI coding tool's config.
    /// Each tool has its own config format and location; we only touch the chau7
    /// entry and leave everything else intact.
    private func registerMCPWithAllTools(bridgePath: String) {
        let home = NSHomeDirectory()
        let command = bridgePath

        // Claude Code: ~/.claude.json (global) — project .mcp.json is committed separately
        registerClaudeCodeGlobal(home: home, command: command)

        // Codex (OpenAI): ~/.codex/config.toml
        registerCodex(home: home, command: command)

        // Cursor: ~/.cursor/mcp.json
        registerCursorGlobal(home: home, command: command)

        // Windsurf: ~/.codeium/windsurf/mcp_config.json
        registerWindsurf(home: home, command: command)
    }

    // MARK: - Per-Tool MCP Registration

    /// Claude Code global config (~/.claude.json) — JSON with mcpServers key.
    private func registerClaudeCodeGlobal(home: String, command: String) {
        let path = home + "/.claude.json"
        let entry: [String: Any] = ["command": command, "args": [] as [String]]
        mergeJSONMCPEntry(atPath: path, serverName: "chau7", entry: entry, mcpKey: "mcpServers")
    }

    /// Cursor global config (~/.cursor/mcp.json) — same JSON shape as Claude Code.
    private func registerCursorGlobal(home: String, command: String) {
        let dir = home + "/.cursor"
        let path = dir + "/mcp.json"
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            // Don't create ~/.cursor/ if Cursor isn't installed
            return
        }
        let entry: [String: Any] = ["command": command, "args": [] as [String]]
        mergeJSONMCPEntry(atPath: path, serverName: "chau7", entry: entry, mcpKey: "mcpServers")
    }

    /// Windsurf config (~/.codeium/windsurf/mcp_config.json) — JSON with mcpServers key.
    private func registerWindsurf(home: String, command: String) {
        let dir = home + "/.codeium/windsurf"
        let path = dir + "/mcp_config.json"
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            return
        }
        let entry: [String: Any] = ["command": command, "args": [] as [String]]
        mergeJSONMCPEntry(atPath: path, serverName: "chau7", entry: entry, mcpKey: "mcpServers")
    }

    /// Codex config (~/.codex/config.toml) — TOML with [mcp_servers.chau7] section.
    private func registerCodex(home: String, command: String) {
        let path = home + "/.codex/config.toml"
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return }

        do {
            var content = try String(contentsOfFile: path, encoding: .utf8)

            // Already registered?
            if content.contains("[mcp_servers.chau7]") {
                // Update command path in case the binary moved
                let lines = content.components(separatedBy: "\n")
                var updated: [String] = []
                var inChau7Section = false
                for line in lines {
                    if line.trimmingCharacters(in: .whitespaces) == "[mcp_servers.chau7]" {
                        inChau7Section = true
                        updated.append(line)
                    } else if inChau7Section, line.trimmingCharacters(in: .whitespaces).hasPrefix("command") {
                        updated.append("command = \"\(command)\"")
                        inChau7Section = false
                    } else {
                        if inChau7Section, line.trimmingCharacters(in: .whitespaces).hasPrefix("[") {
                            inChau7Section = false
                        }
                        updated.append(line)
                    }
                }
                content = updated.joined(separator: "\n")
                try content.write(toFile: path, atomically: true, encoding: .utf8)
            } else {
                // Insert before [features] if it exists, otherwise append
                let section = """
                \n[mcp_servers.chau7]
                command = "\(command)"
                args = []
                """
                if let range = content.range(of: "\n[features]") {
                    content.insert(contentsOf: section + "\n", at: range.lowerBound)
                } else {
                    content += section + "\n"
                }
                try content.write(toFile: path, atomically: true, encoding: .utf8)
            }
            Log.info("MCPServer: registered with Codex config at \(path)")
        } catch {
            Log.error("MCPServer: failed to register with Codex: \(error)")
        }
    }

    // MARK: - JSON Config Helpers

    /// Merges a chau7 MCP server entry into a JSON config file.
    /// Creates the file if it doesn't exist. Only touches the chau7 key.
    private func mergeJSONMCPEntry(atPath path: String, serverName: String, entry: [String: Any], mcpKey: String) {
        let fm = FileManager.default
        var root: [String: Any] = [:]

        if fm.fileExists(atPath: path),
           let data = fm.contents(atPath: path),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            root = parsed
        }

        var servers = root[mcpKey] as? [String: Any] ?? [:]
        servers[serverName] = entry
        root[mcpKey] = servers

        do {
            let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            // Ensure parent directory exists
            let dir = (path as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: dir) {
                try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
            }
            try data.write(to: URL(fileURLWithPath: path))
            Log.info("MCPServer: registered with config at \(path)")
        } catch {
            Log.error("MCPServer: failed to write config at \(path): \(error)")
        }
    }

    // MARK: - Lifecycle

    func start() {
        installBridgeIfNeeded()
        queue.async { [weak self] in
            self?._start()
        }
    }

    func stop() {
        queue.sync { _stop() }
    }

    private func _start() {
        guard !isRunning else { return }

        // Remove stale socket file
        unlink(socketPath)

        // Create socket
        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            Log.error("MCPServer: failed to create socket")
            return
        }

        // Bind
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        // Copy path bytes into sun_path tuple
        var pathBytes = [CChar](repeating: 0, count: 104) // sun_path is 104 bytes on macOS
        _ = socketPath.withCString { src in
            strncpy(&pathBytes, src, 103)
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
            pathBytes.withUnsafeBytes { srcBuf in
                rawBuf.copyBytes(from: srcBuf.prefix(rawBuf.count))
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                bind(serverSocket, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            Log.error("MCPServer: failed to bind socket at \(socketPath): \(String(cString: strerror(errno)))")
            close(serverSocket)
            return
        }

        // Listen
        guard listen(serverSocket, 5) == 0 else {
            Log.error("MCPServer: failed to listen on socket")
            close(serverSocket)
            unlink(socketPath)
            return
        }

        // Set socket permissions: owner-only (bridge runs as same user)
        chmod(socketPath, 0o600)

        isRunning = true
        Log.info("MCPServer: listening on \(socketPath)")

        // Accept connections using GCD
        let source = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            close(serverSocket)
            unlink(socketPath)
        }
        source.resume()
        acceptSource = source
    }

    private func _stop() {
        guard isRunning else { return }
        isRunning = false

        acceptSource?.cancel()
        acceptSource = nil

        for client in clientSockets {
            close(client)
        }
        clientSockets.removeAll()

        Log.info("MCPServer: stopped")
    }

    // MARK: - Connection Handling

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var clientLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                accept(serverSocket, sockPtr, &clientLen)
            }
        }

        guard clientFD >= 0 else { return }

        clientSockets.append(clientFD)
        Log.info("MCPServer: client connected (fd=\(clientFD))")

        // Handle client on a dedicated queue
        let clientQueue = DispatchQueue(label: "com.chau7.mcp.client.\(clientFD)")
        let session = MCPSession(fd: clientFD)

        clientQueue.async { [weak self] in
            // MCPSession.run() takes ownership of the fd and closes it on return
            session.run()

            self?.queue.async { [weak self] in
                self?.clientSockets.removeAll(where: { $0 == clientFD })
                Log.info("MCPServer: client disconnected (fd=\(clientFD))")
            }
        }
    }
}
