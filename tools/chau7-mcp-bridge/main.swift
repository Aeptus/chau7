#!/usr/bin/env swift
//
// chau7-mcp-bridge — Thin stdio <-> Unix socket bridge for MCP clients.
//
// MCP clients (Claude Code, Cursor, etc.) launch this via:
//   { "command": "chau7-mcp-bridge" }
//
// Connects to Chau7.app's MCP socket at ~/.chau7/mcp.sock
// and pipes stdin/stdout <-> socket.

import Foundation

// Ignore SIGPIPE so broken stdout pipe returns EPIPE instead of killing us.
signal(SIGPIPE, SIG_IGN)

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

func writeError(_ message: String) {
    let json = "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32000,\"message\":\"\(message)\"}}\n"
    _ = writeStdout(Data(json.utf8))
}

let socketPath = NSHomeDirectory() + "/.chau7/mcp.sock"

// Create socket
let sockFD = socket(AF_UNIX, SOCK_STREAM, 0)
guard sockFD >= 0 else {
    writeError("Failed to create socket")
    exit(1)
}

// Set up address
var addr = sockaddr_un()
addr.sun_family = sa_family_t(AF_UNIX)
var pathBytes = [CChar](repeating: 0, count: 104)
_ = socketPath.withCString { src in strncpy(&pathBytes, src, 103) }
withUnsafeMutableBytes(of: &addr.sun_path) { buf in
    pathBytes.withUnsafeBytes { src in buf.copyBytes(from: src.prefix(buf.count)) }
}

// Connect
let ok = withUnsafePointer(to: &addr) { ptr in
    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
        connect(sockFD, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
    }
}
guard ok == 0 else {
    writeError("Chau7 is not running. Start the app to enable MCP.")
    close(sockFD)
    exit(1)
}

// Pipe stdin -> socket in background
let stdinThread = Thread {
    while let line = readLine(strippingNewline: false) {
        let bytes = Array(line.utf8)
        _ = bytes.withUnsafeBufferPointer { ptr in
            send(sockFD, ptr.baseAddress, ptr.count, 0)
        }
    }
    shutdown(sockFD, SHUT_WR)
}
stdinThread.start()

// Pipe socket -> stdout on main thread
var buffer = [UInt8](repeating: 0, count: 65536)
while true {
    let n = recv(sockFD, &buffer, buffer.count, 0)
    if n <= 0 { break }
    if !writeStdout(Data(bytes: buffer, count: n)) { break }
}

close(sockFD)
