import Foundation

public enum RemoteClientTelemetryEventType: String, Codable, CaseIterable, Sendable {
    case connectRequested = "connect_requested"
    case pairRequestSent = "pair_request_sent"
    case sessionEncrypted = "session_encrypted"
    case disconnected
    case reconnectScheduled = "reconnect_scheduled"
    case tabSwitched = "tab_switched"
    case approvalReceived = "approval_received"
    case approvalResponded = "approval_responded"
    case notificationOpened = "notification_opened"
    case protectedActionPrompted = "protected_action_prompted"
    case protectedActionSubmitted = "protected_action_submitted"
    case errorReceived = "error_received"
    case frameDecodeFailed = "frame_decode_failed"
    case frameDecryptFailed = "frame_decrypt_failed"
    case sendFailed = "send_failed"
}

public struct RemoteClientTelemetryEvent: Codable, Identifiable, Sendable {
    public let id: String
    public let source: String
    public let deviceID: String?
    public let deviceName: String?
    public let appVersion: String
    public var sessionID: String?
    public let eventType: RemoteClientTelemetryEventType
    public let status: String?
    public let tabID: UInt32?
    public let tabTitle: String?
    public let message: String?
    public let metadata: [String: String]
    public let timestamp: Date

    public init(
        id: String = UUID().uuidString,
        source: String = "ios",
        deviceID: String? = nil,
        deviceName: String? = nil,
        appVersion: String,
        sessionID: String? = nil,
        eventType: RemoteClientTelemetryEventType,
        status: String? = nil,
        tabID: UInt32? = nil,
        tabTitle: String? = nil,
        message: String? = nil,
        metadata: [String: String] = [:],
        timestamp: Date = Date()
    ) {
        self.id = id
        self.source = source
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.appVersion = appVersion
        self.sessionID = sessionID
        self.eventType = eventType
        self.status = status
        self.tabID = tabID
        self.tabTitle = tabTitle
        self.message = message
        self.metadata = metadata
        self.timestamp = timestamp
    }
}
