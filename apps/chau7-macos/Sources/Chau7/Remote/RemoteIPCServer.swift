import Foundation
import os.log
import Chau7Core

@Observable
final class RemoteIPCServer {
    static let shared = RemoteIPCServer()

    private(set) var isListening = false

    @ObservationIgnored var onFrame: ((RemoteFrame) -> Void)?
    @ObservationIgnored var onClientConnected: (() -> Void)?
    @ObservationIgnored var onClientDisconnected: (() -> Void)?

    @ObservationIgnored private var socketFD: Int32 = -1
    @ObservationIgnored private var clientFD: Int32 = -1
    @ObservationIgnored private var listeningSource: DispatchSourceRead?
    @ObservationIgnored private var clientSource: DispatchSourceRead?
    @ObservationIgnored private var isListeningState = false
    @ObservationIgnored private let queue = DispatchQueue(label: "com.chau7.remote.ipc", qos: .utility)
    @ObservationIgnored private let logger = Logger(subsystem: "com.chau7.remote", category: "IPCServer")
    @ObservationIgnored private var buffer = Data()
    @ObservationIgnored private let maxFrameSize = 5 * 1024 * 1024

    private var socketPath: URL {
        RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("remote.sock")
    }

    private init() {}

    func start() {
        queue.sync {
            guard !isListeningState else { return }

            let path = socketPath.path
            let dir = socketPath.deletingLastPathComponent()
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                logger.error("Failed to create IPC socket directory: \(error.localizedDescription, privacy: .public)")
                return
            }
            unlink(path)

            socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
            guard socketFD >= 0 else {
                logger.error("Failed to create socket: \(String(cString: strerror(errno)), privacy: .public)")
                return
            }

            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let maxPathLength = MemoryLayout.size(ofValue: addr.sun_path) - 1
            withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
                let buffer = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: CChar.self)
                _ = path.withCString { cPath in
                    strncpy(buffer, cPath, maxPathLength)
                }
            }

            let bindResult = withUnsafePointer(to: &addr) { addrPtr in
                addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    bind(socketFD, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }

            guard bindResult >= 0 else {
                logger.error("Failed to bind socket: \(String(cString: strerror(errno)), privacy: .public)")
                close(socketFD)
                socketFD = -1
                return
            }

            guard listen(socketFD, 1) >= 0 else {
                logger.error("Failed to listen: \(String(cString: strerror(errno)), privacy: .public)")
                close(socketFD)
                socketFD = -1
                return
            }

            let listeningFD = socketFD
            listeningSource = DispatchSource.makeReadSource(fileDescriptor: listeningFD, queue: queue)
            listeningSource?.setEventHandler { [weak self] in
                self?.acceptConnection()
            }
            listeningSource?.setCancelHandler { [weak self] in
                close(listeningFD)
                self?.socketFD = -1
            }
            listeningSource?.resume()

            isListeningState = true
            DispatchQueue.main.async { [weak self] in
                self?.isListening = true
            }
            logger.info("Remote IPC listening at \(path, privacy: .public)")
        }
    }

    func stop() {
        queue.sync {
            if let cs = clientSource {
                cs.cancel()
                clientSource = nil
            } else if clientFD >= 0 {
                close(clientFD)
                clientFD = -1
            }

            if let ls = listeningSource {
                ls.cancel()
                listeningSource = nil
            } else if socketFD >= 0 {
                close(socketFD)
                socketFD = -1
            }

            unlink(socketPath.path)
            isListeningState = false
            DispatchQueue.main.async { [weak self] in
                self?.isListening = false
            }
        }
    }

    func send(_ frame: RemoteFrame) {
        let data = FrameParser.packForTransport(frame)

        queue.async { [weak self] in
            guard let self else { return }
            guard clientFD >= 0 else { return }
            let fd = clientFD
            // Re-validate fd hasn't been closed/recycled since we captured it
            guard clientFD == fd else { return }

            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { rawBuffer in
                    let base = rawBuffer.baseAddress?.advanced(by: offset)
                    return write(fd, base, rawBuffer.count - offset)
                }

                guard written > 0 else {
                    let err = String(cString: strerror(errno))
                    logger.error("IPC write failed: \(err, privacy: .public)")
                    Task { @MainActor [weak self] in
                        self?.disconnectClient(notify: true)
                    }
                    return
                }

                offset += written
            }
        }
    }

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        var clientAddrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let newClientFD = withUnsafeMutablePointer(to: &clientAddr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                accept(socketFD, sockaddrPtr, &clientAddrLen)
            }
        }

        guard newClientFD >= 0 else {
            logger.warning("Failed to accept connection: \(String(cString: strerror(errno)), privacy: .public)")
            return
        }

        // Close previous client if any — cancel handler owns close(fd)
        if let cs = clientSource {
            cs.cancel()
            clientSource = nil
        } else if clientFD >= 0 {
            close(clientFD)
        }

        // Prevent SIGPIPE on broken-pipe writes — return EPIPE error instead of killing the process.
        var one: Int32 = 1
        setsockopt(newClientFD, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        clientFD = newClientFD
        buffer.removeAll(keepingCapacity: true)

        // Capture fd by value so cancel handler closes the correct descriptor.
        clientSource = DispatchSource.makeReadSource(fileDescriptor: newClientFD, queue: queue)
        clientSource?.setEventHandler { [weak self] in
            self?.readFromClient()
        }
        clientSource?.setCancelHandler { [weak self] in
            close(newClientFD)
            guard let self, clientFD == newClientFD else { return }
            clientFD = -1
        }
        clientSource?.resume()

        DispatchQueue.main.async { [weak self] in
            self?.onClientConnected?()
        }
    }

    private func readFromClient() {
        guard clientFD >= 0 else { return }
        var readBuffer = [UInt8](repeating: 0, count: 4096)
        let bytesRead = read(clientFD, &readBuffer, readBuffer.count)
        if bytesRead <= 0 {
            Task { @MainActor [weak self] in
                self?.disconnectClient(notify: true)
            }
            return
        }

        buffer.append(contentsOf: readBuffer.prefix(bytesRead))
        processBuffer()
    }

    private func processBuffer() {
        let result = FrameParser.parseFrames(from: &buffer, maxFrameSize: maxFrameSize)

        for error in result.errors {
            logger.warning("Frame error: \(error.localizedDescription, privacy: .public)")
        }

        for frame in result.frames {
            DispatchQueue.main.async { [weak self] in
                self?.onFrame?(frame)
            }
        }
    }

    private func disconnectClient(notify: Bool) {
        let hadClient = clientFD >= 0

        if let source = clientSource {
            clientSource = nil
            source.cancel()
        } else if clientFD >= 0 {
            close(clientFD)
            clientFD = -1
        }

        buffer.removeAll(keepingCapacity: true)

        guard notify, hadClient else { return }
        DispatchQueue.main.async { [weak self] in
            self?.onClientDisconnected?()
        }
    }
}
