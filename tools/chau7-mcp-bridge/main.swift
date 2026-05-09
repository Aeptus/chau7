#!/usr/bin/env swift
//
// chau7-mcp-bridge — Resilient stdio <-> Unix socket bridge for MCP clients.
//
// MCP clients (Claude Code, Cursor, etc.) launch this via:
//   { "command": "chau7-mcp-bridge" }
//
// Connects to Chau7.app's MCP socket at ~/.chau7/mcp.sock and pipes
// stdin/stdout <-> socket.
//
// Resilience contract: the AI tool spawns one bridge per session and assumes
// it stays available for that session's lifetime. Chau7 itself can restart
// (rebuild loop, force-quit, app crash) while a Claude/Codex session is
// running, which would otherwise kill MCP for that session until the user
// restarts the AI tool. To avoid that, the bridge:
//
//   1. Retries the initial connect for up to `initialConnectTimeoutSec` —
//      handles the case where the AI tool launches at the same time as
//      Chau7 and beats it to the socket.
//   2. On socket EOF / error mid-session, reconnects (with retry) and
//      replays the saved `initialize` request so the new Chau7 server
//      enters the same protocol state. The first response (the new
//      initialize result) is consumed silently — the AI tool already
//      received the original; a second one would confuse its bookkeeping.
//   3. Buffers any stdin received while the socket is down and replays it
//      after reconnect, so a Claude tool call that fires at the wrong
//      moment doesn't drop on the floor.

import Foundation

// Ignore SIGPIPE so a broken stdout pipe returns EPIPE instead of killing us.
signal(SIGPIPE, SIG_IGN)

let socketPath = NSHomeDirectory() + "/.chau7/mcp.sock"
let initialConnectTimeoutSec: Double = 30.0
let reconnectTimeoutSec: Double = 30.0
let connectRetryDelayUs: useconds_t = 100_000  // 100 ms

// All socket / replay state guarded by a single lock.
let stateLock = NSLock()
var sockFD: Int32 = -1
var savedInitialize: Data?
var pendingStdin: [Data] = []
// Flipped when the stdin thread sees EOF on stdin (the AI tool closed its
// end). After that, a socket drop means "we're done" — don't try to reconnect.
var stdinClosed = false

func writeStdout(_ data: Data) -> Bool {
    data.withUnsafeBytes { buf in
        var remaining = buf.count
        var offset = 0
        while remaining > 0 {
            let n = Foundation.write(STDOUT_FILENO, buf.baseAddress! + offset, remaining)
            if n <= 0 { return false }
            offset += n
            remaining -= n
        }
        return true
    }
}

func writeJSONRPCError(_ message: String) {
    let json = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"\(message)\"}}\n"
    _ = writeStdout(Data(json.utf8))
}

func logStderr(_ message: String) {
    let line = "[chau7-mcp-bridge] \(message)\n"
    let data = Data(line.utf8)
    _ = data.withUnsafeBytes { buf in
        Foundation.write(STDERR_FILENO, buf.baseAddress, buf.count)
    }
}

func makeSocketAddr() -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    var pathBytes = [CChar](repeating: 0, count: 104)
    _ = socketPath.withCString { src in strncpy(&pathBytes, src, 103) }
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
        pathBytes.withUnsafeBytes { src in buf.copyBytes(from: src.prefix(buf.count)) }
    }
    return addr
}

/// Connect to the MCP socket with bounded retry. Returns fd ≥ 0 on success,
/// -1 on timeout. Each retry uses a fresh socket because a failed `connect`
/// leaves the fd unusable on macOS.
func connectWithRetry(timeoutSec: Double) -> Int32 {
    let deadline = Date().addingTimeInterval(timeoutSec)
    while Date() < deadline {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = makeSocketAddr()
        let ok = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if ok == 0 { return fd }
        close(fd)
        usleep(connectRetryDelayUs)
    }
    return -1
}

func sendBytes(_ fd: Int32, _ data: Data) {
    _ = data.withUnsafeBytes { buf in
        send(fd, buf.baseAddress, buf.count, 0)
    }
}

// Initial connect.
let firstFD = connectWithRetry(timeoutSec: initialConnectTimeoutSec)
guard firstFD >= 0 else {
    writeJSONRPCError("Chau7 is not running. Start the app to enable MCP.")
    exit(1)
}
stateLock.lock()
sockFD = firstFD
stateLock.unlock()
logStderr("connected to \(socketPath)")

// stdin -> socket. Buffers writes while the socket is being reconnected so
// no stdin bytes are silently dropped.
let stdinThread = Thread {
    while let line = readLine(strippingNewline: false) {
        let data = Data(line.utf8)
        stateLock.lock()
        if savedInitialize == nil {
            savedInitialize = data  // Per MCP, the first message is `initialize`.
        }
        let fd = sockFD
        if fd < 0 {
            pendingStdin.append(data)
            stateLock.unlock()
            continue
        }
        stateLock.unlock()
        sendBytes(fd, data)
    }
    stateLock.lock()
    stdinClosed = true
    let fd = sockFD
    stateLock.unlock()
    if fd >= 0 { shutdown(fd, SHUT_WR) }
}
stdinThread.start()

// socket -> stdout, with transparent reconnect on EOF / error.
var buffer = [UInt8](repeating: 0, count: 65536)
mainLoop: while true {
    stateLock.lock()
    let fd = sockFD
    stateLock.unlock()
    if fd < 0 { break }

    let n = recv(fd, &buffer, buffer.count, 0)
    if n > 0 {
        if !writeStdout(Data(bytes: buffer, count: n)) { break mainLoop }
        continue
    }

    // Socket dropped. If stdin already closed, the AI tool is done with us —
    // exit cleanly instead of holding open a reconnect loop on a dead session.
    close(fd)
    stateLock.lock()
    sockFD = -1
    let stdinIsClosed = stdinClosed
    stateLock.unlock()
    if stdinIsClosed {
        logStderr("socket dropped after stdin EOF; exiting")
        break mainLoop
    }
    logStderr("socket dropped (recv=\(n)); attempting reconnect")

    let newFD = connectWithRetry(timeoutSec: reconnectTimeoutSec)
    guard newFD >= 0 else {
        logStderr("reconnect timed out; exiting")
        break mainLoop
    }

    stateLock.lock()
    sockFD = newFD
    let initRequest = savedInitialize
    let queued = pendingStdin
    pendingStdin = []
    stateLock.unlock()

    logStderr("reconnected; replaying handshake (\(queued.count) buffered request(s))")

    if let initRequest {
        sendBytes(newFD, initRequest)
        // Drain the initialize response from the new server. The AI tool
        // already received the original initialize result; forwarding the new
        // one would duplicate it and confuse the client's request bookkeeping.
        let _ = recv(newFD, &buffer, buffer.count, 0)
        // Replay the `notifications/initialized` step the AI tool sent only
        // to the OLD server. Without it, the new MCPSession stays in
        // `.awaitingInitializedNotification` forever and every subsequent
        // tools/call returns -32002. The notification has no params per
        // MCP spec, so synthesizing it locally is safe.
        let initializedNotification = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n"
        sendBytes(newFD, Data(initializedNotification.utf8))
    }

    for data in queued {
        sendBytes(newFD, data)
    }
}
stateLock.lock()
let finalFD = sockFD
sockFD = -1
stateLock.unlock()
if finalFD >= 0 { close(finalFD) }
