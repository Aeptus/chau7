import Foundation
import CryptoKit
import Security
import UIKit
import Combine
import Chau7Core

@MainActor
final class RemoteClient: ObservableObject {
    @Published var outputText: String = ""
    @Published var tabs: [RemoteTab] = []
    @Published var isConnected: Bool = false
    @Published var status: String = "Disconnected"
    @Published var activeTabID: UInt32 = 0
    @Published var lastError: String?

    private var webSocket: URLSessionWebSocketTask?
    private var seqCounter: UInt64 = 1
    private var crypto: RemoteCryptoSession?
    private var nonceIOS: Data?
    private var nonceMac: Data?
    private var macPublicKey: Curve25519.KeyAgreement.PublicKey?
    private let iosKey: Curve25519.KeyAgreement.PrivateKey
    private var pairingInfo: PairingInfo?

    init() {
        iosKey = RemoteClient.loadOrCreateKey()
    }

    func connect(pairing: PairingInfo) {
        pairingInfo = pairing
        lastError = nil
        if let keyData = Data(base64Encoded: pairing.macPub) {
            macPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
        }
        let urlString = pairing.relayURL.trimmedTrailingSlash() + "/\(pairing.deviceID)?role=ios"
        guard let url = URL(string: urlString) else { return }

        let task = URLSession.shared.webSocketTask(with: url)
        webSocket = task
        task.resume()
        status = "Connecting"
        isConnected = true

        sendHello()
        sendPairRequest()
        listen()
    }

    func disconnect() {
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        status = "Disconnected"
        lastError = nil
        crypto = nil
        tabs = []
    }

    func sendInput(_ text: String, appendNewline: Bool) {
        guard !text.isEmpty else { return }
        var data = text.data(using: .utf8) ?? Data()
        if appendNewline {
            data.append(0x0A)
        }
        let frame = RemoteFrame(
            type: RemoteFrameType.input.rawValue,
            tabID: activeTabID,
            seq: nextSeq(),
            payload: data
        )
        send(frame: frame, encrypt: true)
    }

    func switchTab(_ tabID: UInt32) {
        activeTabID = tabID
        let payload = TabSwitchPayload(tabID: tabID)
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let frame = RemoteFrame(
            type: RemoteFrameType.tabSwitch.rawValue,
            tabID: 0,
            seq: nextSeq(),
            payload: data
        )
        send(frame: frame, encrypt: true)
    }

    private func listen() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    self.disconnect()
                case .success(let message):
                    switch message {
                    case .data(let data):
                        self.handleData(data)
                    case .string(let text):
                        self.handleData(Data(text.utf8))
                    @unknown default:
                        break
                    }
                    self.listen()
                }
            }
        }
    }

    private func handleData(_ data: Data) {
        guard let frame = try? RemoteFrame.decode(from: data) else { return }
        var workingFrame = frame
        if frame.flags & RemoteFrame.flagEncrypted != 0 {
            guard let crypto else { return }
            do {
                let payload = try crypto.decrypt(frame: frame)
                workingFrame.flags &= ~RemoteFrame.flagEncrypted
                workingFrame.payload = payload
            } catch {
                return
            }
        }

        switch RemoteFrameType(rawValue: workingFrame.type) {
        case .hello:
            handleHello(workingFrame.payload)
        case .pairAccept:
            handlePairAccept(workingFrame.payload)
        case .pairReject:
            handlePairReject(workingFrame.payload)
        case .sessionReady:
            status = "Session ready"
            lastError = nil
        case .tabList:
            handleTabList(workingFrame.payload)
        case .output:
            appendOutput(workingFrame.payload)
        case .snapshot:
            outputText = String(data: workingFrame.payload, encoding: .utf8) ?? ""
        case .ping:
            lastPingPayload = workingFrame.payload
            sendPong()
        case .error:
            handleErrorPayload(workingFrame.payload)
        default:
            break
        }
    }

    private func handleHello(_ data: Data) {
        guard let payload = try? JSONDecoder().decode(HelloPayload.self, from: data) else { return }
        guard let nonce = Data(base64Encoded: payload.nonce) else { return }
        nonceMac = nonce
        establishSessionIfPossible()
    }

    private func handlePairAccept(_ data: Data) {
        guard let payload = try? JSONDecoder().decode(PairAcceptPayload.self, from: data) else { return }
        if let keyData = Data(base64Encoded: payload.macPub) {
            macPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
            _ = KeychainStore.save(key: "mac_public_key", data: keyData)
        }
        sendHello()
        establishSessionIfPossible()
    }

    private func handlePairReject(_ data: Data) {
        if let payload = try? JSONDecoder().decode(PairRejectPayload.self, from: data) {
            lastError = "Pairing rejected (\(payload.reason))"
        } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            lastError = "Pairing rejected (\(text))"
        } else {
            lastError = "Pairing rejected"
        }
        status = "Pairing rejected"
    }

    private func handleErrorPayload(_ data: Data) {
        if let payload = try? JSONDecoder().decode(RemoteErrorPayload.self, from: data) {
            lastError = "Remote error (\(payload.code)): \(payload.message)"
        } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            lastError = "Remote error: \(text)"
        } else {
            lastError = "Remote error"
        }
        status = "Error"
    }

    private func handleTabList(_ data: Data) {
        guard let payload = try? JSONDecoder().decode(TabListPayload.self, from: data) else { return }
        tabs = payload.tabs
        if let active = payload.tabs.first(where: { $0.isActive }) {
            activeTabID = active.tabID
        }
    }

    private static let maxFrameBytes = 65536
    private static let maxOutputBytes = 200000

    private func appendOutput(_ data: Data) {
        let cappedData = data.count > Self.maxFrameBytes ? data.prefix(Self.maxFrameBytes) : data
        guard let text = String(data: cappedData, encoding: .utf8) else { return }
        outputText.append(text)
        if outputText.utf8.count > Self.maxOutputBytes {
            outputText = String(outputText.suffix(Self.maxOutputBytes))
        }
    }

    private func sendHello() {
        guard let pairingInfo else { return }
        if nonceIOS == nil {
            nonceIOS = randomBytes(count: 16)
        }
        let pubKeyFP = fingerprint(data: iosKey.publicKey.rawRepresentation)
        let payload = HelloPayload(
            deviceID: pairingInfo.deviceID,
            role: "ios",
            nonce: nonceIOS?.base64EncodedString() ?? "",
            pubKeyFP: pubKeyFP,
            appVersion: "0.1.0"
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let frame = RemoteFrame(
            type: RemoteFrameType.hello.rawValue,
            tabID: 0,
            seq: nextSeq(),
            payload: data
        )
        send(frame: frame, encrypt: false)
    }

    private func sendPairRequest() {
        guard let pairingInfo else { return }
        let payload = PairRequestPayload(
            deviceID: pairingInfo.deviceID,
            pairingCode: pairingInfo.pairingCode,
            iosPub: iosKey.publicKey.rawRepresentation.base64EncodedString(),
            iosName: UIDevice.current.name
        )
        guard let data = try? JSONEncoder().encode(payload) else { return }
        let frame = RemoteFrame(
            type: RemoteFrameType.pairRequest.rawValue,
            tabID: 0,
            seq: nextSeq(),
            payload: data
        )
        send(frame: frame, encrypt: false)
    }

    private var lastPingPayload: Data = Data()

    private func sendPong() {
        let frame = RemoteFrame(
            type: RemoteFrameType.pong.rawValue,
            tabID: 0,
            seq: nextSeq(),
            payload: lastPingPayload
        )
        send(frame: frame, encrypt: true)
    }

    private func establishSessionIfPossible() {
        guard crypto == nil else { return }
        guard let nonceIOS, let nonceMac else { return }
        let macPub = macPublicKey ?? loadStoredMacKey()
        guard let macPub else { return }
        let shared = try? iosKey.sharedSecretFromKeyAgreement(with: macPub)
        guard let shared else { return }
        guard let session = RemoteCryptoSession.create(sharedSecret: shared, nonceMac: nonceMac, nonceIOS: nonceIOS) else { return }
        crypto = session

        let ready = SessionReadyPayload(sessionID: randomBytes(count: 8).base64EncodedString())
        if let data = try? JSONEncoder().encode(ready) {
            let frame = RemoteFrame(
                type: RemoteFrameType.sessionReady.rawValue,
                tabID: 0,
                seq: nextSeq(),
                payload: data
            )
            send(frame: frame, encrypt: true)
        }
        status = "Encrypted"
    }

    private func send(frame: RemoteFrame, encrypt: Bool) {
        guard let webSocket else { return }
        var outgoing = frame
        if encrypt {
            guard let crypto else { return }
            guard let encrypted = try? crypto.encrypt(frame: frame) else { return }
            outgoing = encrypted
        }
        webSocket.send(.data(outgoing.encode())) { _ in }
    }

    private func nextSeq() -> UInt64 {
        defer { seqCounter &+= 1 }
        return seqCounter
    }

    private func loadStoredMacKey() -> Curve25519.KeyAgreement.PublicKey? {
        guard let data = KeychainStore.load(key: "mac_public_key") else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    private static func loadOrCreateKey() -> Curve25519.KeyAgreement.PrivateKey {
        if let data = KeychainStore.load(key: "ios_private_key"),
           let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: data) {
            return key
        }
        let key = Curve25519.KeyAgreement.PrivateKey()
        _ = KeychainStore.save(key: "ios_private_key", data: key.rawRepresentation)
        return key
    }
}

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

struct HelloPayload: Codable {
    let deviceID: String
    let role: String
    let nonce: String
    let pubKeyFP: String
    let appVersion: String

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case role
        case nonce
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

struct RemoteErrorPayload: Codable {
    let code: String
    let message: String
}

struct SessionReadyPayload: Codable {
    let sessionID: String

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
    }
}

struct TabSwitchPayload: Codable {
    let tabID: UInt32

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
    }
}

struct TabListPayload: Codable {
    let tabs: [RemoteTab]
}

struct RemoteTab: Codable, Identifiable {
    let tabID: UInt32
    let title: String
    let isActive: Bool

    var id: UInt32 { tabID }

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case title
        case isActive = "is_active"
    }
}

private func randomBytes(count: Int) -> Data {
    var data = Data(count: count)
    _ = data.withUnsafeMutableBytes { buffer in
        SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
    }
    return data
}

private func fingerprint(data: Data) -> String {
    let hash = SHA256.hash(data: data)
    return Data(hash.prefix(8)).base64EncodedString()
}

private extension String {
    func trimmedTrailingSlash() -> String {
        if hasSuffix("/") {
            return String(dropLast())
        }
        return self
    }
}
