import Foundation

/// Shared wire payloads for the remote-control protocol.
///
/// These types are the single Swift source of truth for the JSON payloads
/// exchanged between the macOS app, the Go agent (`services/chau7-remote`),
/// and the iOS companion app. The Go side keeps mirrored structs (different
/// language); `services/chau7-remote/docs/PROTOCOL.md` is the normative spec
/// and golden fixtures under `services/chau7-remote/docs/fixtures/` are
/// round-trip-tested from both Swift and Go to prevent drift.
///
/// Everything here is pure `Codable` data — no transport, crypto, or UI
/// concerns.

// MARK: - Pairing

/// The pairing payload delivered via QR code or paste string.
public struct RemotePairingPayload: Codable, Equatable, Sendable {
    public let relayURL: String
    public let deviceID: String
    public let macPub: String
    public let pairingCode: String
    public let expiresAt: String
    /// Shared HMAC secret used to mint relay auth tokens. Optional so older
    /// pairing payloads (no secret) still decode and the client falls back to
    /// unauthenticated connects.
    public var relaySecret: String?

    public init(
        relayURL: String,
        deviceID: String,
        macPub: String,
        pairingCode: String,
        expiresAt: String,
        relaySecret: String? = nil
    ) {
        self.relayURL = relayURL
        self.deviceID = deviceID
        self.macPub = macPub
        self.pairingCode = pairingCode
        self.expiresAt = expiresAt
        self.relaySecret = relaySecret
    }

    enum CodingKeys: String, CodingKey {
        case relayURL = "relay_url"
        case deviceID = "device_id"
        case macPub = "mac_pub"
        case pairingCode = "pairing_code"
        case expiresAt = "expires_at"
        case relaySecret = "relay_secret"
    }
}

// MARK: - Handshake

public struct RemoteHelloPayload: Codable, Equatable, Sendable {
    public let deviceID: String
    public let role: String
    public let nonce: String
    public let pubKeyFP: String
    public let appVersion: String

    public init(deviceID: String, role: String, nonce: String, pubKeyFP: String, appVersion: String) {
        self.deviceID = deviceID
        self.role = role
        self.nonce = nonce
        self.pubKeyFP = pubKeyFP
        self.appVersion = appVersion
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case role, nonce
        case pubKeyFP = "pub_key_fp"
        case appVersion = "app_version"
    }
}

public struct RemotePairRequestPayload: Codable, Equatable, Sendable {
    public let deviceID: String
    public let pairingCode: String
    public let iosPub: String
    public let iosName: String

    public init(deviceID: String, pairingCode: String, iosPub: String, iosName: String) {
        self.deviceID = deviceID
        self.pairingCode = pairingCode
        self.iosPub = iosPub
        self.iosName = iosName
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case pairingCode = "pairing_code"
        case iosPub = "ios_pub"
        case iosName = "ios_name"
    }
}

public struct RemotePairAcceptPayload: Codable, Equatable, Sendable {
    public let deviceID: String
    public let macPub: String
    public let macName: String

    public init(deviceID: String, macPub: String, macName: String) {
        self.deviceID = deviceID
        self.macPub = macPub
        self.macName = macName
    }

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case macPub = "mac_pub"
        case macName = "mac_name"
    }
}

public struct RemotePairRejectPayload: Codable, Equatable, Sendable {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }
}

public struct RemoteSessionReadyPayload: Codable, Equatable, Sendable {
    public let sessionID: String

    public init(sessionID: String) {
        self.sessionID = sessionID
    }

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}

// MARK: - Client state

public enum RemoteClientAppState: String, Codable, Equatable, Sendable {
    case foreground
    case background
}

public enum RemoteClientStreamMode: String, Codable, Equatable, Sendable {
    case full
    case approvalsOnly = "approvals_only"
}

public enum RemotePushEnvironment: String, Codable, Equatable, Sendable {
    case development
    case production
}

public struct RemoteClientStatePayload: Codable, Equatable, Sendable {
    public let appState: RemoteClientAppState
    public let streamMode: RemoteClientStreamMode
    public let pushToken: String?
    public let pushTopic: String?
    public let pushEnvironment: RemotePushEnvironment?
    public let notificationsAuthorized: Bool

    public init(
        appState: RemoteClientAppState,
        streamMode: RemoteClientStreamMode,
        pushToken: String? = nil,
        pushTopic: String? = nil,
        pushEnvironment: RemotePushEnvironment? = nil,
        notificationsAuthorized: Bool
    ) {
        self.appState = appState
        self.streamMode = streamMode
        self.pushToken = pushToken
        self.pushTopic = pushTopic
        self.pushEnvironment = pushEnvironment
        self.notificationsAuthorized = notificationsAuthorized
    }

    enum CodingKeys: String, CodingKey {
        case appState = "app_state"
        case streamMode = "stream_mode"
        case pushToken = "push_token"
        case pushTopic = "push_topic"
        case pushEnvironment = "push_environment"
        case notificationsAuthorized = "notifications_authorized"
    }
}

// MARK: - Tabs

public struct RemoteTabDescriptor: Codable, Equatable, Identifiable, Sendable {
    public let tabID: UInt32
    public let title: String
    public let projectName: String?
    public let branchName: String?
    public let aiProvider: String?
    public let isActive: Bool
    public let isMCPControlled: Bool

    public var id: UInt32 { tabID }

    public init(
        tabID: UInt32,
        title: String,
        projectName: String? = nil,
        branchName: String? = nil,
        aiProvider: String? = nil,
        isActive: Bool,
        isMCPControlled: Bool
    ) {
        self.tabID = tabID
        self.title = title
        self.projectName = projectName
        self.branchName = branchName
        self.aiProvider = aiProvider
        self.isActive = isActive
        self.isMCPControlled = isMCPControlled
    }

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case title
        case projectName = "project_name"
        case branchName = "branch_name"
        case aiProvider = "ai_provider"
        case isActive = "is_active"
        case isMCPControlled = "is_mcp_controlled"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try container.decode(UInt32.self, forKey: .tabID)
        title = try container.decode(String.self, forKey: .title)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        branchName = try container.decodeIfPresent(String.self, forKey: .branchName)
        aiProvider = try container.decodeIfPresent(String.self, forKey: .aiProvider)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        // Lenient: older senders omit is_mcp_controlled.
        isMCPControlled = try container.decodeIfPresent(Bool.self, forKey: .isMCPControlled) ?? false
    }
}

public struct RemoteTabListPayload: Codable, Equatable, Sendable {
    public let tabs: [RemoteTabDescriptor]

    public init(tabs: [RemoteTabDescriptor]) {
        self.tabs = tabs
    }
}

public struct RemoteTabSwitchPayload: Codable, Equatable, Sendable {
    public let tabID: UInt32

    public init(tabID: UInt32) {
        self.tabID = tabID
    }

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
    }
}

// MARK: - Approvals

public struct ApprovalRequestPayload: Codable, Equatable, Sendable {
    public let requestID: String
    public let command: String
    public let flaggedCommand: String
    public let timestamp: String
    public let tabTitle: String?
    public let toolName: String?
    public let projectName: String?
    public let branchName: String?
    public let currentDirectory: String?
    public let recentCommand: String?
    public let contextNote: String?
    public let sessionID: String?
    /// Pre-formatted push text, composed on the Mac by the shared
    /// NotificationContentFormatter so every surface renders identical
    /// words. Optional/additive: relays and old peers ignore it; consumers
    /// fall back to local formatting when absent.
    public let pushTitle: String?
    public let pushSubtitle: String?
    public let pushBody: String?

    public init(
        requestID: String,
        command: String,
        flaggedCommand: String,
        timestamp: String,
        tabTitle: String? = nil,
        toolName: String? = nil,
        projectName: String? = nil,
        branchName: String? = nil,
        currentDirectory: String? = nil,
        recentCommand: String? = nil,
        contextNote: String? = nil,
        sessionID: String? = nil,
        pushTitle: String? = nil,
        pushSubtitle: String? = nil,
        pushBody: String? = nil
    ) {
        self.requestID = requestID
        self.command = command
        self.flaggedCommand = flaggedCommand
        self.timestamp = timestamp
        self.tabTitle = tabTitle
        self.toolName = toolName
        self.projectName = projectName
        self.branchName = branchName
        self.currentDirectory = currentDirectory
        self.recentCommand = recentCommand
        self.contextNote = contextNote
        self.sessionID = sessionID
        self.pushTitle = pushTitle
        self.pushSubtitle = pushSubtitle
        self.pushBody = pushBody
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case command
        case flaggedCommand = "flagged_command"
        case timestamp
        case tabTitle = "tab_title"
        case toolName = "tool_name"
        case projectName = "project_name"
        case branchName = "branch_name"
        case currentDirectory = "current_directory"
        case recentCommand = "recent_command"
        case contextNote = "context_note"
        case sessionID = "session_id"
        case pushTitle = "push_title"
        case pushSubtitle = "push_subtitle"
        case pushBody = "push_body"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        requestID = try container.decode(String.self, forKey: .requestID)
        command = try container.decode(String.self, forKey: .command)
        flaggedCommand = try container.decode(String.self, forKey: .flaggedCommand)
        // Lenient: the Go agent's /pending re-encode historically omitted the
        // timestamp; consumers fall back to receipt time for an empty value.
        timestamp = try container.decodeIfPresent(String.self, forKey: .timestamp) ?? ""
        tabTitle = try container.decodeIfPresent(String.self, forKey: .tabTitle)
        toolName = try container.decodeIfPresent(String.self, forKey: .toolName)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        branchName = try container.decodeIfPresent(String.self, forKey: .branchName)
        currentDirectory = try container.decodeIfPresent(String.self, forKey: .currentDirectory)
        recentCommand = try container.decodeIfPresent(String.self, forKey: .recentCommand)
        contextNote = try container.decodeIfPresent(String.self, forKey: .contextNote)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        pushTitle = try container.decodeIfPresent(String.self, forKey: .pushTitle)
        pushSubtitle = try container.decodeIfPresent(String.self, forKey: .pushSubtitle)
        pushBody = try container.decodeIfPresent(String.self, forKey: .pushBody)
    }
}

// MARK: - Notification events (frame 0x52)

/// A user-facing notification composed on the Mac (kind + pre-formatted
/// text), relayed by the agent as a push when the client can't be reached
/// over the live socket. This is what lets non-approval kinds (task
/// finished/failed) reach the phone: the agent relays, it does not decide
/// or format.
public struct RemoteNotificationEventPayload: Codable, Equatable, Sendable {
    /// NotificationSemanticKind raw value.
    public let kind: String
    /// Stable dedup key (NotificationIdentity scoped key) — the agent must
    /// deliver at most one push per identity key.
    public let identityKey: String
    public let title: String
    public let subtitle: String?
    public let body: String
    /// Lock-screen thread grouping (tab title).
    public let threadID: String?

    public init(
        kind: String,
        identityKey: String,
        title: String,
        subtitle: String? = nil,
        body: String,
        threadID: String? = nil
    ) {
        self.kind = kind
        self.identityKey = identityKey
        self.title = title
        self.subtitle = subtitle
        self.body = body
        self.threadID = threadID
    }

    enum CodingKeys: String, CodingKey {
        case kind
        case identityKey = "identity_key"
        case title
        case subtitle
        case body
        case threadID = "thread_id"
    }
}

public struct ApprovalResponsePayload: Codable, Equatable, Sendable {
    public let requestID: String
    public let approved: Bool

    public init(requestID: String, approved: Bool) {
        self.requestID = requestID
        self.approved = approved
    }

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case approved
    }
}

// MARK: - Pending state (REST /pending channel)

public struct RemotePendingStatePayload: Codable, Equatable, Sendable {
    public let approvals: [ApprovalRequestPayload]
    public let interactivePrompts: [RemoteInteractivePrompt]
    public let updatedAt: String?

    public init(
        approvals: [ApprovalRequestPayload],
        interactivePrompts: [RemoteInteractivePrompt],
        updatedAt: String? = nil
    ) {
        self.approvals = approvals
        self.interactivePrompts = interactivePrompts
        self.updatedAt = updatedAt
    }

    enum CodingKeys: String, CodingKey {
        case approvals
        case interactivePrompts = "interactive_prompts"
        case updatedAt = "updated_at"
    }
}

// MARK: - Errors

public struct RemoteErrorPayload: Codable, Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}
