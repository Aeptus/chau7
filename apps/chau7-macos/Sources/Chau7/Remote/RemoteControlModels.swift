import Foundation
import CryptoKit
import Chau7Core

struct RemotePairingInfo: Codable, Equatable {
    let deviceID: String
    let macPub: String
    let pairingCode: String
    let expiresAt: String
    let relayURL: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case macPub = "mac_pub"
        case pairingCode = "pairing_code"
        case expiresAt = "expires_at"
        case relayURL = "relay_url"
    }
}

struct RemoteQRPayload: Codable, Equatable {
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

extension RemotePairingInfo {
    func qrPayloadString() -> String? {
        let payload = RemoteQRPayload(
            relayURL: relayURL,
            deviceID: deviceID,
            macPub: macPub,
            pairingCode: pairingCode,
            expiresAt: expiresAt
        )
        guard let data = try? JSONEncoder().encode(payload) else {
            Log.error("RemoteControlManager: failed to encode QR payload")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }
}

struct RemoteTabDescriptor: Codable, Equatable {
    let tabID: UInt32
    let title: String
    let projectName: String?
    let branchName: String?
    let isActive: Bool
    let isMCPControlled: Bool

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case title
        case projectName = "project_name"
        case branchName = "branch_name"
        case isActive = "is_active"
        case isMCPControlled = "is_mcp_controlled"
    }
}

struct RemoteTabListPayload: Codable, Equatable {
    let tabs: [RemoteTabDescriptor]
}

struct RemoteTabSwitchPayload: Codable, Equatable {
    let tabID: UInt32

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
    }
}

struct RemoteErrorPayload: Codable, Equatable {
    let code: String
    let message: String
}

struct RemoteSessionStatus: Codable, Equatable {
    let status: String
    let pairedDeviceID: String?
    let pairedDeviceName: String?

    enum CodingKeys: String, CodingKey {
        case status
        case pairedDeviceID = "paired_device_id"
        case pairedDeviceName = "paired_device_name"
    }
}

enum RemoteClientAppState: String, Codable, Equatable {
    case foreground
    case background
}

enum RemoteClientStreamMode: String, Codable, Equatable {
    case full
    case approvalsOnly = "approvals_only"
}

enum RemotePushEnvironment: String, Codable, Equatable {
    case development
    case production
}

struct RemoteClientStatePayload: Codable, Equatable {
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

struct RemotePairedDevice: Identifiable, Equatable {
    let id: String
    let name: String
    let fingerprint: String
    let pairedAt: String?
    let lastConnectedAt: String?
    let isConnected: Bool
}

struct RemoteAgentStateSnapshot: Codable {
    let deviceID: String?
    let macPrivateKey: String?
    let macPublicKey: String?
    var pairedDevices: [RemoteAgentPairedDeviceSnapshot]
    let iosPublicKey: String?
    let iosName: String?
    let keyEncrypted: Bool?
    let relaySecret: String?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case macPrivateKey = "mac_private_key"
        case macPublicKey = "mac_public_key"
        case pairedDevices = "paired_devices"
        case iosPublicKey = "ios_public_key"
        case iosName = "ios_name"
        case keyEncrypted = "key_encrypted"
        case relaySecret = "relay_secret"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        macPrivateKey = try container.decodeIfPresent(String.self, forKey: .macPrivateKey)
        macPublicKey = try container.decodeIfPresent(String.self, forKey: .macPublicKey)
        pairedDevices = try container.decodeIfPresent([RemoteAgentPairedDeviceSnapshot].self, forKey: .pairedDevices) ?? []
        iosPublicKey = try container.decodeIfPresent(String.self, forKey: .iosPublicKey)
        iosName = try container.decodeIfPresent(String.self, forKey: .iosName)
        keyEncrypted = try container.decodeIfPresent(Bool.self, forKey: .keyEncrypted)
        relaySecret = try container.decodeIfPresent(String.self, forKey: .relaySecret)
        if pairedDevices.isEmpty,
           let iosPublicKey,
           let rawKey = Data(base64Encoded: iosPublicKey) {
            pairedDevices = [
                RemoteAgentPairedDeviceSnapshot(
                    id: Self.fingerprint(for: rawKey),
                    name: iosName ?? "",
                    iosPublicKey: iosPublicKey,
                    publicKeyFingerprint: Self.fingerprint(for: rawKey),
                    pairedAt: nil,
                    lastConnectedAt: nil
                )
            ]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(deviceID, forKey: .deviceID)
        try container.encodeIfPresent(macPrivateKey, forKey: .macPrivateKey)
        try container.encodeIfPresent(macPublicKey, forKey: .macPublicKey)
        try container.encode(pairedDevices, forKey: .pairedDevices)
        try container.encodeIfPresent(pairedDevices.first?.iosPublicKey, forKey: .iosPublicKey)
        try container.encodeIfPresent(pairedDevices.first?.name, forKey: .iosName)
        try container.encodeIfPresent(keyEncrypted, forKey: .keyEncrypted)
        try container.encodeIfPresent(relaySecret, forKey: .relaySecret)
    }

    mutating func removePairedDevice(id: String) {
        pairedDevices.removeAll { $0.id == id }
    }

    private static func fingerprint(for rawKey: Data) -> String {
        Data(SHA256.hash(data: rawKey).prefix(8)).base64EncodedString()
    }
}

struct RemoteAgentPairedDeviceSnapshot: Codable, Equatable {
    let id: String
    let name: String
    let iosPublicKey: String
    let publicKeyFingerprint: String
    let pairedAt: String?
    let lastConnectedAt: String?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case iosPublicKey = "ios_public_key"
        case publicKeyFingerprint = "public_key_fingerprint"
        case pairedAt = "paired_at"
        case lastConnectedAt = "last_connected_at"
    }
}

struct PendingRemoteApprovalContext {
    let requestID: String
    let tabID: UInt32
    let tabTitle: String
    let toolName: String
    let projectName: String?
    let branchName: String?
    let sessionID: String?
    let command: String
    let flaggedCommand: String
    let requestedAt: Date

    var approval: RemoteActivityApproval {
        RemoteActivityApproval(
            requestID: requestID,
            command: command,
            flaggedCommand: flaggedCommand
        )
    }
}

struct ProtectedRemoteInput {
    let tabID: UInt32
    let text: String
    let flaggedCommand: String
    let createdAt: Date = Date()

    static let ttl: TimeInterval = 120

    var isExpired: Bool { Date().timeIntervalSince(createdAt) > Self.ttl }
}
