import Chau7Core
import Darwin
import Foundation

enum MagiMCPClientError: Error, LocalizedError {
    case socketMissing(path: String)
    case pathTooLong(path: String)
    case connectFailed(path: String, reason: String)
    case writeFailed(reason: String)
    case readTimedOut
    case disconnected
    case invalidJSON(String)
    case protocolError(String)
    case toolError(name: String, message: String)

    var errorDescription: String? {
        switch self {
        case let .socketMissing(path):
            return "Chau7 MCP socket was not found at \(path). Start Chau7 and make sure MCP is enabled."
        case let .pathTooLong(path):
            return "Chau7 MCP socket path is too long: \(path)"
        case let .connectFailed(path, reason):
            return "Could not connect to Chau7 MCP socket at \(path): \(reason). Start Chau7 and make sure MCP is enabled."
        case let .writeFailed(reason):
            return "Could not write to Chau7 MCP socket: \(reason)"
        case .readTimedOut:
            return "Timed out waiting for Chau7 MCP response."
        case .disconnected:
            return "Chau7 MCP socket disconnected."
        case let .invalidJSON(value):
            return "Chau7 MCP returned invalid JSON: \(value)"
        case let .protocolError(message):
            return "Chau7 MCP protocol error: \(message)"
        case let .toolError(name, message):
            return "Chau7 MCP tool \(name) failed: \(message)"
        }
    }
}

protocol MagiMCPToolCalling {
    func agentLaunch(_ request: MagiMCPAgentLaunchRequest) throws -> MagiMCPAgentLaunchResponse
    func renameTab(_ request: MagiMCPTabRenameRequest) throws
    func tabOutput(_ request: MagiMCPTabOutputRequest) throws -> MagiMCPTabOutputResponse
    func tabStatus(_ request: MagiMCPTabStatusRequest) throws -> MagiMCPTabStatus
    func sendInput(_ request: MagiMCPTabInputRequest) throws -> MagiMCPTabSendInputResponse
    func submitPrompt(_ request: MagiMCPTabSubmitPromptRequest) throws -> MagiMCPTabSubmitPromptResponse
    func closeTab(_ request: MagiMCPTabCloseRequest) throws
    func runtimeEvents(_ request: MagiMCPRuntimeEventsRequest) throws -> MagiMCPRuntimeEventsResponse
    func repoEvents(_ request: MagiMCPRepoGetEventsRequest) throws -> MagiMCPRepoEventsResponse
    func createTab(_ request: MagiMCPTabCreateRequest) throws -> MagiMCPTabCreateResponse
    func waitReady(_ request: MagiMCPTabWaitReadyRequest) throws -> MagiMCPTabWaitReadyResponse
    func exec(_ request: MagiMCPTabExecRequest) throws
}

final class MagiMCPClient: MagiMCPToolCalling {
    private let socketPath: String
    private var fd: CInt = -1
    private var nextID = 1
    private let responseTimeoutSeconds: Int32

    init(socketPath: String, responseTimeoutSeconds: Int32 = 60) {
        self.socketPath = socketPath
        self.responseTimeoutSeconds = responseTimeoutSeconds
    }

    deinit {
        close()
    }

    func connectAndInitialize() throws {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw MagiMCPClientError.socketMissing(path: socketPath)
        }

        let socketFD = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else {
            throw MagiMCPClientError.connectFailed(path: socketPath, reason: errnoMessage())
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(socketPath.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count + 1 <= capacity else {
            Darwin.close(socketFD)
            throw MagiMCPClientError.pathTooLong(path: socketPath)
        }

        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in pathBytes.enumerated() {
                buffer[index] = byte
            }
            buffer[pathBytes.count] = 0
        }

        guard let pathOffset = MemoryLayout.offset(of: \sockaddr_un.sun_path) else {
            Darwin.close(socketFD)
            throw MagiMCPClientError.connectFailed(path: socketPath, reason: "could not resolve Unix socket path offset")
        }
        let length = socklen_t(pathOffset + pathBytes.count + 1)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.connect(socketFD, sockaddrPointer, length)
            }
        }

        guard result == 0 else {
            let reason = errnoMessage()
            Darwin.close(socketFD)
            throw MagiMCPClientError.connectFailed(path: socketPath, reason: reason)
        }

        fd = socketFD
        _ = try sendRequest(method: "initialize", params: [
            "protocolVersion": "2025-11-25",
            "capabilities": [:],
            "clientInfo": [
                "name": "magi",
                "version": "phase10"
            ]
        ])
        try sendNotification(method: "notifications/initialized", params: [:])
    }

    func agentLaunch(_ request: MagiMCPAgentLaunchRequest) throws -> MagiMCPAgentLaunchResponse {
        try callTool(name: "agent_launch", arguments: request)
    }

    func renameTab(_ request: MagiMCPTabRenameRequest) throws {
        let _: MagiMCPOperationResponse = try callTool(name: "tab_rename", arguments: request)
    }

    func tabOutput(_ request: MagiMCPTabOutputRequest) throws -> MagiMCPTabOutputResponse {
        try callTool(name: "tab_output", arguments: request)
    }

    func tabStatus(_ request: MagiMCPTabStatusRequest) throws -> MagiMCPTabStatus {
        try callTool(name: "tab_status", arguments: request)
    }

    func sendInput(_ request: MagiMCPTabInputRequest) throws -> MagiMCPTabSendInputResponse {
        try callTool(name: "tab_send_input", arguments: request)
    }

    func submitPrompt(_ request: MagiMCPTabSubmitPromptRequest) throws -> MagiMCPTabSubmitPromptResponse {
        try callTool(name: "tab_submit_prompt", arguments: request)
    }

    func closeTab(_ request: MagiMCPTabCloseRequest) throws {
        let _: MagiMCPOperationResponse = try callTool(name: "tab_close", arguments: request)
    }

    func runtimeEvents(_ request: MagiMCPRuntimeEventsRequest) throws -> MagiMCPRuntimeEventsResponse {
        try callTool(name: "chau7_runtime_events", arguments: request)
    }

    func repoEvents(_ request: MagiMCPRepoGetEventsRequest) throws -> MagiMCPRepoEventsResponse {
        try callTool(name: "repo_get_events", arguments: request)
    }

    func createTab(_ request: MagiMCPTabCreateRequest) throws -> MagiMCPTabCreateResponse {
        try callTool(name: "tab_create", arguments: request)
    }

    func waitReady(_ request: MagiMCPTabWaitReadyRequest) throws -> MagiMCPTabWaitReadyResponse {
        try callTool(name: "tab_wait_ready", arguments: request)
    }

    func exec(_ request: MagiMCPTabExecRequest) throws {
        let _: MagiMCPOperationResponse = try callTool(name: "tab_exec", arguments: request)
    }

    private func callTool<Request: Encodable, Response: Decodable>(
        name: String,
        arguments: Request
    ) throws -> Response {
        let rawArguments = try encodeJSONObject(arguments, context: "\(name) arguments")
        let rawResult = try callToolRaw(name: name, arguments: rawArguments)
        return try decodeJSONObject(Response.self, from: rawResult, context: "\(name) result")
    }

    private func callToolRaw(name: String, arguments: [String: Any]) throws -> [String: Any] {
        let response = try sendRequest(method: "tools/call", params: [
            "name": name,
            "arguments": arguments
        ])

        if let error = response["error"] as? [String: Any] {
            let message = error["message"] as? String ?? "\(error)"
            throw MagiMCPClientError.protocolError(message)
        }

        guard let result = response["result"] as? [String: Any] else {
            throw MagiMCPClientError.protocolError("missing result for \(name)")
        }

        if result["isError"] as? Bool == true {
            let message = toolText(from: result) ?? "tool returned isError=true"
            throw MagiMCPClientError.toolError(name: name, message: message)
        }

        if let structured = result["structuredContent"] as? [String: Any] {
            return structured
        }

        if let text = toolText(from: result),
           let data = text.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }

        return result
    }

    private func encodeJSONObject<Value: Encodable>(_ value: Value, context: String) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw MagiMCPClientError.protocolError("could not encode \(context) as a JSON object")
        }
        return object
    }

    private func decodeJSONObject<Value: Decodable>(
        _ type: Value.Type,
        from object: [String: Any],
        context: String
    ) throws -> Value {
        do {
            let data = try JSONSerialization.data(withJSONObject: object, options: [])
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MagiMCPClientError.protocolError("could not decode \(context): \(error.localizedDescription)")
        }
    }

    private func sendRequest(method: String, params: [String: Any]) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params
        ]

        try writeJSONObject(request)

        while true {
            let line = try readLine()
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw MagiMCPClientError.invalidJSON(line)
            }

            if let responseID = object["id"] as? Int, responseID == id {
                return object
            }
        }
    }

    private func sendNotification(method: String, params: [String: Any]) throws {
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "method": method,
            "params": params
        ]
        try writeJSONObject(request)
    }

    private func writeJSONObject(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        var line = data
        line.append(0x0A)
        try line.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var written = 0
            while written < line.count {
                let count = Darwin.write(fd, baseAddress.advanced(by: written), line.count - written)
                if count > 0 {
                    written += count
                } else if errno == EINTR {
                    continue
                } else {
                    throw MagiMCPClientError.writeFailed(reason: errnoMessage())
                }
            }
        }
    }

    private func readLine() throws -> String {
        var data = Data()

        while true {
            var pollFD = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let pollResult = Darwin.poll(&pollFD, 1, responseTimeoutSeconds * 1000)
            if pollResult == 0 {
                throw MagiMCPClientError.readTimedOut
            }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw MagiMCPClientError.disconnected
            }

            var byte: UInt8 = 0
            let readCount = Darwin.read(fd, &byte, 1)
            if readCount == 1 {
                if byte == 0x0A { break }
                data.append(byte)
            } else if readCount == 0 {
                throw MagiMCPClientError.disconnected
            } else if errno == EINTR {
                continue
            } else {
                throw MagiMCPClientError.disconnected
            }
        }

        return String(decoding: data, as: UTF8.self)
    }

    private func close() {
        if fd >= 0 {
            Darwin.close(fd)
            fd = -1
        }
    }

    private func toolText(from result: [String: Any]) -> String? {
        guard let content = result["content"] as? [[String: Any]] else { return nil }
        return content.first { ($0["type"] as? String) == "text" }?["text"] as? String
    }

    private func errnoMessage() -> String {
        String(cString: strerror(errno))
    }
}
