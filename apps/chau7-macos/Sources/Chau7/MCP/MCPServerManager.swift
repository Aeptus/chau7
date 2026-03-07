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

    // MARK: - Lifecycle

    func start() {
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
            close(self.serverSocket)
            unlink(self.socketPath)
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
