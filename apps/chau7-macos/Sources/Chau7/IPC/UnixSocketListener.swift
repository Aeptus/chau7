import Foundation

/// Shared Unix-domain stream-socket listener for the app's local IPC servers
/// (Proxy, MCP, Remote, Scripting). Owns socket creation, bind/listen,
/// optional socket-file permissions, and the GCD accept loop. Accepted client
/// descriptors are handed to `onAccept`; ownership of each descriptor
/// transfers to the callee.
///
/// Threading matches the servers this replaced: the accept source and its
/// cancel handler run on the `queue` passed at init, and the listening
/// descriptor is closed exactly once — by the source's cancel handler when a
/// source exists, directly otherwise.
final class UnixSocketListener {

    /// Which syscall failed during `start`, with its errno, so callers can
    /// keep their existing per-step log messages and retry policies.
    struct StartFailure: Error {
        enum Step {
            case createSocket
            case bind
            case listen
        }

        let step: Step
        let errnoValue: Int32

        var errnoDescription: String {
            String(cString: strerror(errnoValue))
        }

        /// Whether a caller's bind/listen retry loop should try again.
        var isRetriable: Bool {
            switch errnoValue {
            case EADDRINUSE, EAGAIN, EINTR:
                return true
            default:
                return false
            }
        }
    }

    let path: String

    private let queue: DispatchQueue
    private var socketFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?

    /// The listening descriptor, or -1 when closed. Exposed for the health
    /// snapshots the MCP and Scripting servers report. Reset to -1 by the
    /// accept source's cancel handler, which runs asynchronously on `queue`.
    var fileDescriptor: Int32 {
        socketFD
    }

    var isAccepting: Bool {
        acceptSource != nil
    }

    init(path: String, queue: DispatchQueue) {
        self.path = path
        self.queue = queue
    }

    deinit {
        stop(removeSocketFile: false)
    }

    /// Removes a stale socket file left behind by a previous run,
    /// unconditionally. Callers that must not steal a live socket should use
    /// `removeStaleSocketFileIfInactive()` instead.
    func removeStaleSocketFile() {
        unlink(path)
    }

    /// Removes a leftover socket file unless another process is still
    /// serving it. Returns false when the path hosts a live socket — the
    /// caller should refuse to bind.
    func removeStaleSocketFileIfInactive() -> Bool {
        guard FileManager.default.fileExists(atPath: path) else {
            return true
        }

        if Self.canConnect(toSocketAt: path) {
            return false
        }

        unlink(path)
        return true
    }

    /// Creates, binds, and listens on the socket, then starts the accept
    /// loop on `queue`. On failure the partially-created descriptor is
    /// closed and a `StartFailure` is thrown; the socket file is left for
    /// the caller's stale-file policy to reconcile.
    ///
    /// - Parameters:
    ///   - backlog: `listen(2)` backlog.
    ///   - socketFilePermissions: When set, applied to the socket file with
    ///     `chmod` after `listen` succeeds (before any client is accepted
    ///     via the accept source).
    ///   - onAccept: Called on `queue` with each accepted client descriptor.
    ///   - onAcceptFailure: Called on `queue` with the `accept(2)` errno.
    func start(
        backlog: Int32,
        socketFilePermissions: mode_t? = nil,
        onAccept: @escaping (Int32) -> Void,
        onAcceptFailure: @escaping (Int32) -> Void
    ) throws {
        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw StartFailure(step: .createSocket, errnoValue: errno)
        }

        var addr = Self.makeAddress(path: path)
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult >= 0 else {
            let bindErrno = errno
            close(socketFD)
            socketFD = -1
            throw StartFailure(step: .bind, errnoValue: bindErrno)
        }

        guard listen(socketFD, backlog) >= 0 else {
            let listenErrno = errno
            close(socketFD)
            socketFD = -1
            throw StartFailure(step: .listen, errnoValue: listenErrno)
        }

        if let socketFilePermissions {
            chmod(path, socketFilePermissions)
        }

        // Capture fd by value so the cancel handler closes the correct
        // descriptor even if `socketFD` has been reassigned since.
        let listeningFD = socketFD
        let source = DispatchSource.makeReadSource(fileDescriptor: listeningFD, queue: queue)
        source.setEventHandler { [weak self] in
            self?.acceptClient(onAccept: onAccept, onAcceptFailure: onAcceptFailure)
        }
        source.setCancelHandler { [weak self] in
            close(listeningFD)
            guard let self, socketFD == listeningFD else { return }
            socketFD = -1
        }
        source.resume()
        acceptSource = source
    }

    /// Stops accepting and closes the listening descriptor. Client
    /// descriptors already delivered to `onAccept` are untouched — those
    /// belong to the server. The cancel handler owns close(fd); don't
    /// double-close here.
    func stop(removeSocketFile: Bool) {
        if let source = acceptSource {
            acceptSource = nil
            source.cancel()
        } else if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }

        if removeSocketFile {
            unlink(path)
        }
    }

    // MARK: - Shared Socket Helpers

    /// Build a `sockaddr_un` for an `AF_UNIX` socket targeting `path`.
    /// Truncates to `sun_path`'s capacity (`PATH_MAX` is larger than
    /// `sun_path`, so callers responsible for ≤104-byte socket paths).
    static func makeAddress(path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            let buffer = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
            _ = path.withCString { cPath in
                strncpy(buffer, cPath, maxPathLength)
            }
        }
        return addr
    }

    /// Whether a process is currently accepting connections at `path`.
    static func canConnect(toSocketAt path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return false
        }
        defer { close(fd) }

        var addr = makeAddress(path: path)
        return withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    // MARK: - Private

    private func acceptClient(onAccept: (Int32) -> Void, onAcceptFailure: (Int32) -> Void) {
        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)

        let clientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                accept(socketFD, sockaddrPtr, &clientAddrLen)
            }
        }

        guard clientFD >= 0 else {
            onAcceptFailure(errno)
            return
        }

        onAccept(clientFD)
    }
}
