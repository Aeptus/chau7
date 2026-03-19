import CryptoKit
import Chau7Core
import Foundation
import Security

// MARK: - Pairing

struct PairingInfo: Codable, Equatable {
    let relayURL: String
    let deviceID: String
    let macPub: String
    let pairingCode: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case relayURL = "relay_url"
        case deviceID = "device_id"
        case macPub = "mac_pub"
        case pairingCode = "pairing_code"
        case expiresAt = "expires_at"
    }
}

struct TrustedPairingIdentity: Codable, Equatable {
    let deviceID: String
    let macPub: String
    let iosPub: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case macPub = "mac_pub"
        case iosPub = "ios_pub"
    }
}

// MARK: - Handshake

struct HelloPayload: Codable {
    let deviceID: String
    let role: String
    let nonce: String
    let pubKeyFP: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case role, nonce
        case pubKeyFP = "pub_key_fp"
        case appVersion = "app_version"
    }
}

struct PairRequestPayload: Codable {
    let deviceID: String
    let pairingCode: String
    let iosPub: String
    let iosName: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case pairingCode = "pairing_code"
        case iosPub = "ios_pub"
        case iosName = "ios_name"
    }
}

struct PairAcceptPayload: Codable {
    let deviceID: String
    let macPub: String
    let macName: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case macPub = "mac_pub"
        case macName = "mac_name"
    }
}

struct PairRejectPayload: Codable {
    let reason: String
}

struct SessionReadyPayload: Codable {
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}

enum RemoteClientAppState: String, Codable {
    case foreground
    case background
}

enum RemoteClientStreamMode: String, Codable {
    case full
    case approvalsOnly = "approvals_only"
}

enum RemotePushEnvironment: String, Codable {
    case development
    case production
}

struct RemoteClientStatePayload: Codable {
    let appState: RemoteClientAppState
    let streamMode: RemoteClientStreamMode
    let pushToken: String?
    let pushTopic: String?
    let pushEnvironment: RemotePushEnvironment?
    let notificationsAuthorized: Bool

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

struct TabListPayload: Codable {
    let tabs: [RemoteTab]
}

struct RemoteTab: Codable, Identifiable {
    let tabID: UInt32
    let title: String
    let projectName: String?
    let branchName: String?
    let isActive: Bool
    let isMCPControlled: Bool

    var id: UInt32 { tabID }

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case title
        case projectName = "project_name"
        case branchName = "branch_name"
        case isActive = "is_active"
        case isMCPControlled = "is_mcp_controlled"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tabID = try container.decode(UInt32.self, forKey: .tabID)
        title = try container.decode(String.self, forKey: .title)
        projectName = try container.decodeIfPresent(String.self, forKey: .projectName)
        branchName = try container.decodeIfPresent(String.self, forKey: .branchName)
        isActive = try container.decode(Bool.self, forKey: .isActive)
        isMCPControlled = try container.decodeIfPresent(Bool.self, forKey: .isMCPControlled) ?? false
    }
}

struct TabSwitchPayload: Codable {
    let tabID: UInt32

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
    }
}

// MARK: - Approvals

struct ApprovalRequest: Identifiable {
    let requestID: String
    let command: String
    let flaggedCommand: String
    let tabTitle: String?
    let toolName: String?
    let projectName: String?
    let branchName: String?
    let currentDirectory: String?
    let recentCommand: String?
    let contextNote: String?
    let sessionID: String?
    let timestamp: Date

    var id: String { requestID }
    var isProtectedRemoteAction: Bool { flaggedCommand != command }
    var title: String { isProtectedRemoteAction ? "Protected Remote Action" : "Command Approval" }
    var subtitle: String? { isProtectedRemoteAction ? flaggedCommand : nil }
}

struct ApprovalHistoryEntry: Identifiable {
    let id = UUID()
    let command: String
    let flaggedCommand: String
    let approved: Bool
    let timestamp: Date

    var isProtectedRemoteAction: Bool { flaggedCommand != command }
    var title: String { isProtectedRemoteAction ? flaggedCommand : command }
}

struct ApprovalRequestPayload: Codable {
    let requestID: String
    let command: String
    let flaggedCommand: String
    let timestamp: String
    let tabTitle: String?
    let toolName: String?
    let projectName: String?
    let branchName: String?
    let currentDirectory: String?
    let recentCommand: String?
    let contextNote: String?
    let sessionID: String?

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
    }
}

struct ApprovalResponsePayload: Codable {
    let requestID: String
    let approved: Bool

    enum CodingKeys: String, CodingKey {
        case requestID = "request_id"
        case approved
    }
}

// MARK: - Errors

struct RemoteErrorPayload: Codable {
    let code: String
    let message: String
}

// MARK: - Utilities

enum CryptoUtils {
    static func randomBytes(count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let baseAddress = buffer.baseAddress else { return errSecParam }
            return SecRandomCopyBytes(kSecRandomDefault, count, baseAddress)
        }
        guard status == errSecSuccess else {
            fatalError("SecRandomCopyBytes failed with status \(status) — cannot generate secure random bytes")
        }
        return data
    }

    static func fingerprint(data: Data) -> String {
        Data(CryptoKit.SHA256.hash(data: data).prefix(8)).base64EncodedString()
    }
}

extension String {
    var strippingTrailingSlash: String {
        hasSuffix("/") ? String(dropLast()) : self
    }
}

/// Strips ANSI escape sequences from terminal output.
enum ANSIStripper {
    static func strip(_ input: String) -> String {
        var output = ""
        output.reserveCapacity(input.count)
        var iter = input.unicodeScalars.makeIterator()
        var scalar = iter.next()
        while let current = scalar {
            if current == "\u{1B}" {
                scalar = iter.next()
                if let next = scalar, next == "[" {
                    // Consume until final byte (0x40–0x7E)
                    while let ch = iter.next() {
                        if ch.value >= 0x40 && ch.value <= 0x7E {
                            scalar = iter.next()
                            break
                        }
                    }
                    continue
                }
                // Not a CSI sequence — skip the ESC but keep next char
                continue
            }
            output.unicodeScalars.append(current)
            scalar = iter.next()
        }
        return output
    }
}
