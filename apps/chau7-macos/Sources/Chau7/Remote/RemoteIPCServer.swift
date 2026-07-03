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

    @ObservationIgnored private var listener: UnixSocketListener?
    @ObservationIgnored private var clientFD: Int32 = -1
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
            let listener = UnixSocketListener(path: path, queue: queue)
            listener.removeStaleSocketFile()

            do {
                try listener.start(
                    backlog: 1,
                    onAccept: { [weak self] newClientFD in
                        self?.handleAcceptedClient(newClientFD)
                    },
                    onAcceptFailure: { [weak self] acceptErrno in
                        self?.logger.warning("Failed to accept connection: \(String(cString: strerror(acceptErrno)), privacy: .public)")
                    }
                )
            } catch {
                logStartFailure(error)
                return
            }

            self.listener = listener
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

            if let listener {
                listener.stop(removeSocketFile: true)
                self.listener = nil
            } else {
                unlink(socketPath.path)
            }

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

            var offset = 0
            while offset < data.count {
                let written = data.withUnsafeBytes { rawBuffer in
                    let base = rawBuffer.baseAddress?.advanced(by: offset)
                    return write(fd, base, rawBuffer.count - offset)
                }

                guard written > 0 else {
                    let err = String(cString: strerror(errno))
                    logger.error("IPC write failed: \(err, privacy: .public)")
                    // Already on the IPC queue — disconnect inline. Hopping
                    // to MainActor mutated queue-owned client state off-queue.
                    disconnectClient(notify: true)
                    return
                }

                offset += written
            }
        }
    }

    private func logStartFailure(_ error: Error) {
        guard let failure = error as? UnixSocketListener.StartFailure else {
            logger.error("Failed to start IPC server: \(error.localizedDescription, privacy: .public)")
            return
        }
        switch failure.step {
        case .createSocket:
            logger.error("Failed to create socket: \(failure.errnoDescription, privacy: .public)")
        case .bind:
            logger.error("Failed to bind socket: \(failure.errnoDescription, privacy: .public)")
        case .listen:
            logger.error("Failed to listen: \(failure.errnoDescription, privacy: .public)")
        }
    }

    private func handleAcceptedClient(_ newClientFD: Int32) {
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
            // Already on the IPC queue — disconnect inline.
            disconnectClient(notify: true)
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

    /// Must run on the IPC serial queue — clientFD/clientSource/buffer are
    /// queue-owned.
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
