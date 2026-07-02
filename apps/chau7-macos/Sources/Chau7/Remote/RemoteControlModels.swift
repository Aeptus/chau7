import Foundation
import CryptoKit
import Chau7Core

// Wire payload types (tabs, approvals, client state, errors, handshake) live
// in Chau7Core/Remote/RemoteWirePayloads.swift — the single Swift source of
// truth shared with the iOS companion app. This file keeps only macOS-side
// pairing/agent state models.

struct RemotePairingInfo: Codable, Equatable {
    let deviceID: String
    let macPub: String
    let pairingCode: String
    let expiresAt: String
    let relayURL: String
    /// Shared HMAC secret the paired iOS device needs to authenticate to the
    /// relay. Present only when relay auth is configured; carried through to the
    /// QR/paste payload so iOS can mint tokens.
    var relaySecret: String?

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case macPub = "mac_pub"
        case pairingCode = "pairing_code"
        case expiresAt = "expires_at"
        case relayURL = "relay_url"
        case relaySecret = "relay_secret"
    }
}

/// The QR/paste payload is the shared pairing schema.
typealias RemoteQRPayload = RemotePairingPayload

struct RemotePairingRegenerationPlan: Equatable {
    let shouldStopAgent: Bool
    let shouldStartAgent: Bool

    static func make(isRemoteEnabled: Bool, isAgentRunning: Bool) -> Self {
        Self(
            shouldStopAgent: isAgentRunning,
            shouldStartAgent: isRemoteEnabled
        )
    }
}

extension RemotePairingInfo {
    func pairingJSONString(prettyPrinted: Bool = false) -> String? {
        let payload = RemoteQRPayload(
            relayURL: relayURL,
            deviceID: deviceID,
            macPub: macPub,
            pairingCode: pairingCode,
            expiresAt: expiresAt,
            relaySecret: relaySecret
        )
        let encoder = JSONEncoder()
        if prettyPrinted {
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        }
        guard let data = try? encoder.encode(payload) else {
            Log.error("RemoteControlManager: failed to encode QR payload")
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func qrPayloadString() -> String? {
        pairingJSONString()
    }
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
        self.deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
        self.macPrivateKey = try container.decodeIfPresent(String.self, forKey: .macPrivateKey)
        self.macPublicKey = try container.decodeIfPresent(String.self, forKey: .macPublicKey)
        self.pairedDevices = try container.decodeIfPresent([RemoteAgentPairedDeviceSnapshot].self, forKey: .pairedDevices) ?? []
        self.iosPublicKey = try container.decodeIfPresent(String.self, forKey: .iosPublicKey)
        self.iosName = try container.decodeIfPresent(String.self, forKey: .iosName)
        self.keyEncrypted = try container.decodeIfPresent(Bool.self, forKey: .keyEncrypted)
        self.relaySecret = try container.decodeIfPresent(String.self, forKey: .relaySecret)
        if pairedDevices.isEmpty,
           let iosPublicKey,
           let rawKey = Data(base64Encoded: iosPublicKey) {
            self.pairedDevices = [
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
    let currentDirectory: String?
    let recentCommand: String?
    let contextNote: String?
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
    let createdAt = Date()

    static let ttl: TimeInterval = 120

    var isExpired: Bool {
        Date().timeIntervalSince(createdAt) > Self.ttl
    }
}
