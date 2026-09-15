import Foundation

public enum MCPHandshakeStatus: String, Sendable {
    case awaitingInitialize = "awaiting_initialize"
    case initializing
    case accepted
    case ready
    case rejected
}

public enum MCPHandshakeErrorClass: String, Sendable {
    case invalidParameters = "invalid_parameters"
    case unsupportedProtocolVersion = "unsupported_protocol_version"
}

/// Non-secret, per-connection MCP initialization state suitable for logs and
/// read-only diagnostics. Client-provided identity fields are normalized and
/// bounded before they leave the protocol boundary.
public struct MCPHandshakeDiagnostic: Equatable, Sendable {
    public private(set) var status: MCPHandshakeStatus = .awaitingInitialize
    public private(set) var clientName = "unknown"
    public private(set) var clientVersion = "unknown"
    public private(set) var requestedProtocolVersion = "unknown"
    public private(set) var negotiatedProtocolVersion = "unknown"
    public private(set) var errorClass = "none"

    public init() {}

    public mutating func recordAttempt(
        clientName: String?,
        clientVersion: String?,
        requestedProtocolVersion: String?
    ) {
        status = .initializing
        self.clientName = Self.normalized(clientName)
        self.clientVersion = Self.normalized(clientVersion)
        self.requestedProtocolVersion = Self.normalized(requestedProtocolVersion)
        negotiatedProtocolVersion = "unknown"
        errorClass = "none"
    }

    public mutating func recordAccepted(negotiatedProtocolVersion: String) {
        status = .accepted
        self.negotiatedProtocolVersion = Self.normalized(negotiatedProtocolVersion)
        errorClass = "none"
    }

    public mutating func recordReady() {
        status = .ready
    }

    public mutating func recordRejected(errorClass: MCPHandshakeErrorClass) {
        status = .rejected
        self.errorClass = errorClass.rawValue
    }

    public func payload(bridgeCommandPath: String, socketPath: String) -> [String: String] {
        [
            "server_name": MCPProtocolCompatibility.serverName,
            "server_version": MCPProtocolCompatibility.serverVersion,
            "client_name": clientName,
            "client_version": clientVersion,
            "resolved_command_path": bridgeCommandPath,
            "transport": "unix_socket",
            "socket_path": socketPath,
            "requested_protocol_version": requestedProtocolVersion,
            "negotiated_protocol_version": negotiatedProtocolVersion,
            "startup_status": status.rawValue,
            "error_class": errorClass
        ]
    }

    public var logSummary: String {
        "client=\(clientName) client_version=\(clientVersion) "
            + "requested_protocol=\(requestedProtocolVersion) "
            + "negotiated_protocol=\(negotiatedProtocolVersion) "
            + "startup_status=\(status.rawValue) error_class=\(errorClass)"
    }

    private static func normalized(_ value: String?) -> String {
        guard let value else { return "unknown" }
        let singleLine = value
            .unicodeScalars
            .map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !singleLine.isEmpty else { return "unknown" }
        return String(singleLine.prefix(96))
    }
}
