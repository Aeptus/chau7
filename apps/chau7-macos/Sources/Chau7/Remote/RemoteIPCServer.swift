import Foundation
import os.log
import Chau7Core

@MainActor
final class RemoteIPCServer: ObservableObject {
    static let shared = RemoteIPCServer()

    @Published private(set) var isListening = false

    var onFrame: ((RemoteFrame) -> Void)?
    var onClientConnected: (() -> Void)?
    var onClientDisconnected: (() -> Void)?

    private var socketFD: Int32 = -1
    private var clientFD: Int32 = -1
    private var listeningSource: DispatchSourceRead?
    private var clientSource: DispatchSourceRead?
    private let queue = DispatchQueue(label: "com.chau7.remote.ipc", qos: .utility)
    private let logger = Logger(subsystem: "com.chau7.remote", category: "IPCServer")
    private var buffer = Data()
    private let maxFrameSize = 5 * 1024 * 1024

    private var socketPath: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return appSupport
            .appendingPathComponent("Chau7")
            .appendingPathComponent("remote.sock")
    }

    private init() {}

    func start() {
        guard !isListening else { return }

        let path = socketPath.path
        let dir = socketPath.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        unlink(path)

        socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            logger.error("Failed to create socket: \(String(cString: strerror(errno)))")
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
            logger.error("Failed to bind socket: \(String(cString: strerror(errno)))")
            close(socketFD)
            socketFD = -1
            return
        }

        guard listen(socketFD, 1) >= 0 else {
            logger.error("Failed to listen: \(String(cString: strerror(errno)))")
            close(socketFD)
            socketFD = -1
            return
        }

        listeningSource = DispatchSource.makeReadSource(fileDescriptor: socketFD, queue: queue)
        listeningSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        listeningSource?.setCancelHandler { [weak self] in
            if let fd = self?.socketFD, fd >= 0 {
                close(fd)
            }
            self?.socketFD = -1
        }
        listeningSource?.resume()

        isListening = true
        logger.info("Remote IPC listening at \(path)")
    }

    func stop() {
        clientSource?.cancel()
        clientSource = nil
        listeningSource?.cancel()
        listeningSource = nil

        if clientFD >= 0 {
            close(clientFD)
            clientFD = -1
        }
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }

        unlink(socketPath.path)
        isListening = false
    }

    func send(_ frame: RemoteFrame) {
        guard clientFD >= 0 else { return }
        let payload = frame.encode()
        var lengthPrefix = Data()
        lengthPrefix.appendUInt32LE(UInt32(payload.count))
        let data = lengthPrefix + payload

        queue.async { [weak self] in
            guard let self else { return }
            data.withUnsafeBytes { rawBuffer in
                _ = write(self.clientFD, rawBuffer.baseAddress, rawBuffer.count)
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
            logger.warning("Failed to accept connection: \(String(cString: strerror(errno)))")
            return
        }

        if clientFD >= 0 {
            clientSource?.cancel()
            close(clientFD)
        }

        clientFD = newClientFD
        buffer.removeAll(keepingCapacity: true)

        clientSource = DispatchSource.makeReadSource(fileDescriptor: newClientFD, queue: queue)
        clientSource?.setEventHandler { [weak self] in
            self?.readFromClient()
        }
        clientSource?.setCancelHandler { [weak self] in
            if let fd = self?.clientFD, fd >= 0 {
                close(fd)
            }
            self?.clientFD = -1
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
            DispatchQueue.main.async { [weak self] in
                self?.onClientDisconnected?()
            }
            clientSource?.cancel()
            return
        }

        buffer.append(contentsOf: readBuffer.prefix(bytesRead))
        processBuffer()
    }

    private func processBuffer() {
        while buffer.count >= 4 {
            let frameLen = Int(buffer.readUInt32LE(at: 0))
            if frameLen <= 0 || frameLen > maxFrameSize {
                logger.warning("Dropping IPC frame with invalid length: \(frameLen)")
                buffer.removeAll()
                return
            }

            let totalNeeded = 4 + frameLen
            guard buffer.count >= totalNeeded else { return }

            let frameData = buffer.subdata(in: 4..<totalNeeded)
            buffer.removeSubrange(0..<totalNeeded)

            do {
                let frame = try RemoteFrame.decode(from: frameData)
                DispatchQueue.main.async { [weak self] in
                    self?.onFrame?(frame)
                }
            } catch {
                logger.warning("Failed to decode remote IPC frame: \(error.localizedDescription)")
            }
        }
    }
}

private extension Data {
    mutating func appendUInt32LE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 24))
    }

    func readUInt32LE(at offset: Int) -> UInt32 {
        let b0 = UInt32(self[offset])
        let b1 = UInt32(self[offset + 1]) << 8
        let b2 = UInt32(self[offset + 2]) << 16
        let b3 = UInt32(self[offset + 3]) << 24
        return b0 | b1 | b2 | b3
    }
}
