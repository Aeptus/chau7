#!/usr/bin/env swift
// Resilient stdio <-> Unix socket MCP bridge. The main loop is the sole socket
// owner; stdin only appends bounded frames. Requests whose delivery is ambiguous
// fail with their original JSON-RPC IDs and are never replayed automatically.
import Foundation

signal(SIGPIPE, SIG_IGN)
let socketPath = ProcessInfo.processInfo.environment["CHAU7_MCP_SOCKET_PATH"] ?? NSHomeDirectory() + "/.chau7/mcp.sock"
let maxFrameBytes = 8 * 1024 * 1024
let maxQueuedBytes = 16 * 1024 * 1024
let maxQueuedFrames = 64
let inputLock = NSLock()
var queued: [Data] = []
var queuedBytes = 0
var inputClosed = false
var inputOverflow = false

func uptime() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
func log(_ message: String) { FileHandle.standardError.write(Data("[chau7-mcp-bridge] \(message)\n".utf8)) }
func object(_ frame: Data) -> [String: Any]? { try? JSONSerialization.jsonObject(with: frame) as? [String: Any] }
func idKey(_ id: Any) -> String? {
    guard id is String || id is NSNumber else { return nil }
    return (try? JSONSerialization.data(withJSONObject: [id])).flatMap { String(data: $0, encoding: .utf8) }
}
func stdout(_ frame: Data) -> Bool {
    frame.withUnsafeBytes { bytes in
        guard let address = bytes.baseAddress else { return bytes.isEmpty }
        var offset = 0
        while offset < bytes.count {
            let n = Foundation.write(STDOUT_FILENO, address.advanced(by: offset), bytes.count - offset)
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }
}
func error(_ id: Any?, _ message: String) {
    let payload: [String: Any] = ["jsonrpc": "2.0", "id": id ?? NSNull(), "error": [
        "code": -32000, "message": message,
        "data": ["errorClass": "transport_interrupted", "automaticReplay": false],
    ]]
    if var frame = try? JSONSerialization.data(withJSONObject: payload) {
        frame.append(10)
        _ = stdout(frame)
    }
}

struct Frames {
    var buffer = Data()
    mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while let end = buffer.firstIndex(of: 10) {
            let count = buffer.distance(from: buffer.startIndex, to: end) + 1
            guard count <= maxFrameBytes else { throw FrameError.oversized }
            frames.append(Data(buffer.prefix(count)))
            buffer.removeFirst(count)
        }
        guard buffer.count <= maxFrameBytes else { throw FrameError.oversized }
        return frames
    }
}
enum FrameError: Error { case oversized }
func enqueue(_ frame: Data) -> Bool {
    inputLock.lock()
    defer { inputLock.unlock() }
    guard queued.count < maxQueuedFrames, queuedBytes + frame.count <= maxQueuedBytes else {
        inputOverflow = true
        return false
    }
    queued.append(frame)
    queuedBytes += frame.count
    return true
}
Thread {
    var frames = Frames()
    var bytes = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = Foundation.read(STDIN_FILENO, &bytes, bytes.count)
        if n < 0, errno == EINTR { continue }
        if n <= 0 {
            if !frames.buffer.isEmpty { _ = enqueue(frames.buffer + Data([10])) }
            break
        }
        do {
            for frame in try frames.append(Data(bytes.prefix(n))) {
                if !enqueue(frame) { break }
            }
        } catch {
            inputLock.lock(); inputOverflow = true; inputLock.unlock()
            break
        }
        inputLock.lock(); let overflow = inputOverflow; inputLock.unlock()
        if overflow { break }
    }
    inputLock.lock(); inputClosed = true; inputLock.unlock()
}.start()

func connectSocket(until deadline: TimeInterval) -> Int32 {
    guard socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path) else { return -1 }
    while uptime() < deadline {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: Array(socketPath.utf8) + [0])
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            return fd
        }
        close(fd)
        inputLock.lock(); let done = inputClosed && queued.isEmpty; inputLock.unlock()
        if done { return -1 }
        usleep(100_000)
    }
    return -1
}
func sendAll(_ fd: Int32, _ data: Data, until deadline: TimeInterval) -> Bool {
    data.withUnsafeBytes { bytes in
        guard let address = bytes.baseAddress else { return bytes.isEmpty }
        var offset = 0
        while offset < bytes.count, uptime() < deadline {
            let n = send(fd, address.advanced(by: offset), bytes.count - offset, 0)
            if n > 0 { offset += n; continue }
            if n < 0, errno == EINTR { continue }
            guard n < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
            var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&descriptor, 1, Int32(max(1, min(100, (deadline - uptime()) * 1000))))
        }
        return offset == bytes.count
    }
}

var socketFD = connectSocket(until: uptime() + 30)
guard socketFD >= 0 else { error(nil, "Chau7 connection unavailable"); exit(1) }
var received = Frames()
var outstanding: [String: Any] = [:]
var savedInitialize: Data?
var initializeID: String?
var initialized = false
var writeClosed = false
var bytes = [UInt8](repeating: 0, count: 65536)

func receiveFrame(_ frame: Data) -> Bool {
    if let json = object(frame), let id = json["id"], let key = idKey(id) {
        outstanding.removeValue(forKey: key)
        if key == initializeID, json["result"] != nil { initialized = true }
    }
    return stdout(frame)
}
func failOutstanding(_ message: String) {
    for id in outstanding.values { error(id, message) }
    outstanding.removeAll()
}
func restoreHandshake(_ fd: Int32) -> Bool {
    guard initialized, let request = savedInitialize, let initializeID else { return true }
    let deadline = uptime() + 10
    guard sendAll(fd, request, until: deadline) else { return false }
    while uptime() < deadline {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 100)
        if ready < 0, errno == EINTR { continue }
        if ready <= 0 { continue }
        let n = recv(fd, &bytes, bytes.count, 0)
        if n < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
        guard n > 0, let frames = try? received.append(Data(bytes.prefix(n))) else { return false }
        var restored = false
        for frame in frames {
            if let json = object(frame), let id = json["id"], idKey(id) == initializeID {
                guard json["result"] != nil else { return false }
                restored = true
            } else if !receiveFrame(frame) { return false }
        }
        if restored {
            return sendAll(fd, Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n".utf8), until: deadline)
        }
    }
    return false
}

mainLoop: while true {
    inputLock.lock()
    let overflow = inputOverflow
    let closed = inputClosed
    let next = queued.isEmpty ? nil : queued.removeFirst()
    if let next { queuedBytes -= next.count }
    let empty = queued.isEmpty
    inputLock.unlock()
    if overflow {
        error(nil, "Bridge input exceeded its bounded queue or frame limit")
        failOutstanding("Bridge input queue exceeded its limit; reconnect the MCP client")
        if let next { error(object(next)?["id"], "Bridge input queue exceeded its limit") }
        inputLock.lock(); let pending = queued; queued.removeAll(); inputLock.unlock()
        for frame in pending { error(object(frame)?["id"], "Bridge input queue exceeded its limit") }
        break
    }
    var dropped = false
    if let next {
        let json = object(next)
        if let id = json?["id"], let key = idKey(id) {
            guard outstanding.count < 64 else { error(id, "Too many outstanding requests"); continue }
            outstanding[key] = id
            if json?["method"] as? String == "initialize" { savedInitialize = next; initializeID = key }
        }
        dropped = !sendAll(socketFD, next, until: uptime() + 5)
    }
    if closed, empty, !writeClosed, !dropped {
        shutdown(socketFD, SHUT_WR)
        writeClosed = true
    }
    if !dropped {
        var descriptor = pollfd(fd: socketFD, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, next == nil ? 100 : 0)
        if ready < 0, errno == EINTR { continue }
        if ready < 0 { dropped = true }
        else if ready > 0 {
            let n = recv(socketFD, &bytes, bytes.count, 0)
            if n < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
            if n > 0 {
                guard let frames = try? received.append(Data(bytes.prefix(n))) else {
                    failOutstanding("Server response exceeded the frame limit")
                    break
                }
                for frame in frames { if !receiveFrame(frame) { break mainLoop } }
            } else { dropped = true }
        }
    }
    if !dropped { continue }
    close(socketFD)
    socketFD = -1
    received = Frames()
    failOutstanding("Chau7 connection interrupted; execution may have occurred. Review before retrying.")
    if closed { break }
    if !initialized { savedInitialize = nil; initializeID = nil }
    log("connection interrupted; restoring handshake before queued requests")
    socketFD = connectSocket(until: uptime() + 30)
    guard socketFD >= 0, restoreHandshake(socketFD) else {
        error(nil, "Chau7 reconnect or handshake timed out")
        inputLock.lock(); let pending = queued; inputLock.unlock()
        for frame in pending { error(object(frame)?["id"], "Chau7 reconnect failed") }
        break
    }
    writeClosed = false
}
if socketFD >= 0 { close(socketFD) }
