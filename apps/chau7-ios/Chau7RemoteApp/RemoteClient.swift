import Foundation
import CryptoKit
import UIKit
import Chau7Core
import UserNotifications

/// Manages the encrypted WebSocket connection to a macOS Chau7 instance.
@MainActor
final class RemoteClient: ObservableObject {

    // MARK: - Published State

    @Published var outputText = ""
    @Published private(set) var tabs: [RemoteTab] = []
    @Published private(set) var isConnected = false
    @Published private(set) var status: String = "Disconnected"
    @Published var activeTabID: UInt32 = 0
    @Published var lastError: String?
    @Published var pendingApprovals: [ApprovalRequest] = []
    @Published var approvalHistory: [ApprovalHistoryEntry] = []

    // MARK: - Pairing (persisted in Keychain)

    @Published var pairingInfo: PairingInfo? {
        didSet { persistPairing() }
    }

    // MARK: - Private

    private var webSocket: URLSessionWebSocketTask?
    private var seqCounter: UInt64 = 1
    private var crypto: RemoteCryptoSession?
    private var nonceIOS: Data?
    private var nonceMac: Data?
    private var macPublicKey: Curve25519.KeyAgreement.PublicKey?
    private let iosKey: Curve25519.KeyAgreement.PrivateKey
    private var notificationObserver: Any?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = false

    private static let maxOutputBytes = 200_000
    private static let maxFrameBytes = 65_536
    private static let maxHistory = 50
    private static let maxReconnectAttempts = 5
    private static let appVersion = "1.1.0"

    // MARK: - Haptics (cached)

    private let lightHaptic = UIImpactFeedbackGenerator(style: .light)
    private let warningHaptic = UINotificationFeedbackGenerator()

    // MARK: - Init

    init() {
        iosKey = Self.loadOrCreateKey()
        pairingInfo = Self.loadPairing()

        notificationObserver = NotificationCenter.default.addObserver(
            forName: .approvalNotificationResponse, object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let id = note.userInfo?["request_id"] as? String,
                  let approved = note.userInfo?["approved"] as? Bool else { return }
            Task { @MainActor in self.respondToApproval(requestID: id, approved: approved) }
        }
    }

    deinit {
        if let obs = notificationObserver { NotificationCenter.default.removeObserver(obs) }
    }

    // MARK: - Connection

    func connect() {
        guard let pairing = pairingInfo else { return }
        connect(pairing: pairing)
    }

    func connect(pairing: PairingInfo) {
        disconnect(autoReconnect: false)
        pairingInfo = pairing
        lastError = nil
        shouldReconnect = true
        reconnectAttempt = 0

        if let keyData = Data(base64Encoded: pairing.macPub) {
            macPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
        }

        let urlString = pairing.relayURL.strippingTrailingSlash + "/\(pairing.deviceID)?role=ios"
        guard let url = URL(string: urlString) else {
            lastError = "Invalid relay URL"
            return
        }

        let task = URLSession.shared.webSocketTask(with: url)
        webSocket = task
        task.resume()
        status = "Connecting"
        isConnected = true

        sendHello()
        sendPairRequest()
        listen()
    }

    func disconnect(autoReconnect: Bool = false) {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        status = "Disconnected"
        crypto = nil
        nonceIOS = nil
        nonceMac = nil
        tabs = []
        if !autoReconnect {
            lastError = nil
            pendingApprovals = []
        }
    }

    // MARK: - Input

    func sendInput(_ text: String, appendNewline: Bool) {
        guard !text.isEmpty else { return }
        var data = Data(text.utf8)
        if appendNewline { data.append(0x0A) }
        sendEncrypted(type: .input, tabID: activeTabID, payload: data)
    }

    func switchTab(_ tabID: UInt32) {
        activeTabID = tabID
        sendJSON(TabSwitchPayload(tabID: tabID), type: .tabSwitch)
    }

    func triggerLightHaptic() {
        lightHaptic.impactOccurred()
    }

    // MARK: - Approvals

    func respondToApproval(requestID: String, approved: Bool) {
        guard let idx = pendingApprovals.firstIndex(where: { $0.requestID == requestID }) else { return }
        let request = pendingApprovals.remove(at: idx)

        approvalHistory.append(ApprovalHistoryEntry(
            command: request.command, approved: approved, timestamp: Date()
        ))
        if approvalHistory.count > Self.maxHistory {
            approvalHistory.removeFirst(approvalHistory.count - Self.maxHistory)
        }

        sendJSON(ApprovalResponsePayload(requestID: requestID, approved: approved), type: .approvalResponse)

        // Dismiss matching local notification
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestID])
    }

    // MARK: - Receive Loop

    private func listen() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure:
                    self.handleDisconnect()
                case .success(let msg):
                    switch msg {
                    case .data(let data): self.handleFrame(data)
                    case .string(let text): self.handleFrame(Data(text.utf8))
                    @unknown default: break
                    }
                    self.listen()
                }
            }
        }
    }

    private func handleDisconnect() {
        let wasConnected = isConnected
        isConnected = false
        status = "Disconnected"
        crypto = nil

        guard wasConnected, shouldReconnect, reconnectAttempt < Self.maxReconnectAttempts else { return }
        reconnectAttempt += 1
        let delay = pow(2.0, Double(reconnectAttempt))
        status = "Reconnecting (\(reconnectAttempt)/\(Self.maxReconnectAttempts))..."

        reconnectTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let pairing = self.pairingInfo else { return }
            self.connect(pairing: pairing)
        }
    }

    // MARK: - Frame Dispatch

    private func handleFrame(_ data: Data) {
        guard let frame = try? RemoteFrame.decode(from: data) else { return }

        let payload: Data
        if frame.flags & RemoteFrame.flagEncrypted != 0 {
            guard let crypto, let decrypted = try? crypto.decrypt(frame: frame) else { return }
            payload = decrypted
        } else {
            payload = frame.payload
        }

        switch RemoteFrameType(rawValue: frame.type) {
        case .hello:           handleHello(payload)
        case .pairAccept:      handlePairAccept(payload)
        case .pairReject:      handlePairReject(payload)
        case .sessionReady:    status = "Session ready"; lastError = nil
        case .tabList:         handleTabList(payload)
        case .output:          appendOutput(payload)
        case .snapshot:        outputText = String(data: payload, encoding: .utf8) ?? ""
        case .approvalRequest: handleApprovalRequest(payload)
        case .ping:            sendEncrypted(type: .pong, tabID: frame.tabID, payload: payload)
        case .error:           handleError(payload)
        default:               break
        }
    }

    // MARK: - Frame Handlers

    private func handleHello(_ data: Data) {
        guard let p = try? JSONDecoder().decode(HelloPayload.self, from: data),
              let nonce = Data(base64Encoded: p.nonce) else { return }
        nonceMac = nonce
        establishSessionIfPossible()
    }

    private func handlePairAccept(_ data: Data) {
        guard let p = try? JSONDecoder().decode(PairAcceptPayload.self, from: data),
              let keyData = Data(base64Encoded: p.macPub) else { return }
        macPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
        _ = KeychainStore.save(key: "mac_public_key", data: keyData)
        sendHello()
        establishSessionIfPossible()
    }

    private func handlePairReject(_ data: Data) {
        if let p = try? JSONDecoder().decode(PairRejectPayload.self, from: data) {
            lastError = "Pairing rejected: \(p.reason)"
        } else {
            lastError = "Pairing rejected"
        }
        status = "Pairing rejected"
        shouldReconnect = false
    }

    private func handleError(_ data: Data) {
        if let p = try? JSONDecoder().decode(RemoteErrorPayload.self, from: data) {
            lastError = "\(p.code): \(p.message)"
        } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            lastError = text
        }
        status = "Error"
    }

    private func handleTabList(_ data: Data) {
        guard let p = try? JSONDecoder().decode(TabListPayload.self, from: data) else { return }
        tabs = p.tabs
        if let active = p.tabs.first(where: { $0.isActive }) {
            activeTabID = active.tabID
        }
    }

    private func appendOutput(_ data: Data) {
        let capped = data.prefix(Self.maxFrameBytes)
        guard let text = String(data: capped, encoding: .utf8) else { return }
        outputText.append(text)
        if outputText.utf8.count > Self.maxOutputBytes {
            // Trim from the front, keeping recent output
            let excess = outputText.utf8.count - Self.maxOutputBytes
            if let idx = outputText.utf8.index(outputText.utf8.startIndex, offsetBy: excess, limitedBy: outputText.utf8.endIndex) {
                outputText = String(outputText[idx...])
            }
        }
    }

    private func handleApprovalRequest(_ data: Data) {
        guard let p = try? JSONDecoder().decode(ApprovalRequestPayload.self, from: data) else { return }
        pendingApprovals.append(ApprovalRequest(
            requestID: p.requestID, command: p.command,
            flaggedCommand: p.flaggedCommand, timestamp: Date()
        ))

        warningHaptic.notificationOccurred(.warning)

        // Fire local notification for background handling
        let content = UNMutableNotificationContent()
        content.title = "MCP Command Approval"
        content.body = p.command
        content.sound = .default
        content.categoryIdentifier = "MCP_APPROVAL"
        content.userInfo = ["request_id": p.requestID]
        let req = UNNotificationRequest(
            identifier: p.requestID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(req)
    }

    // MARK: - Session Establishment

    private func establishSessionIfPossible() {
        guard crypto == nil, let nonceIOS, let nonceMac else { return }
        guard let macPub = macPublicKey ?? loadStoredMacKey(),
              let shared = try? iosKey.sharedSecretFromKeyAgreement(with: macPub),
              let session = RemoteCryptoSession.create(sharedSecret: shared, nonceMac: nonceMac, nonceIOS: nonceIOS)
        else { return }

        crypto = session
        reconnectAttempt = 0
        sendJSON(SessionReadyPayload(sessionID: CryptoUtils.randomBytes(count: 8).base64EncodedString()),
                 type: .sessionReady, encrypt: true)
        status = "Encrypted"
    }

    // MARK: - Outgoing

    private func sendHello() {
        guard let pairing = pairingInfo else { return }
        if nonceIOS == nil { nonceIOS = CryptoUtils.randomBytes(count: 16) }
        sendJSON(HelloPayload(
            deviceID: pairing.deviceID, role: "ios",
            nonce: nonceIOS?.base64EncodedString() ?? "",
            pubKeyFP: CryptoUtils.fingerprint(data: iosKey.publicKey.rawRepresentation),
            appVersion: Self.appVersion
        ), type: .hello, encrypt: false)
    }

    private func sendPairRequest() {
        guard let pairing = pairingInfo else { return }
        sendJSON(PairRequestPayload(
            deviceID: pairing.deviceID, pairingCode: pairing.pairingCode,
            iosPub: iosKey.publicKey.rawRepresentation.base64EncodedString(),
            iosName: UIDevice.current.name
        ), type: .pairRequest, encrypt: false)
    }

    private func sendJSON<T: Encodable>(_ payload: T, type: RemoteFrameType, encrypt: Bool = true) {
        guard let data = try? JSONEncoder().encode(payload) else { return }
        if encrypt {
            sendEncrypted(type: type, tabID: 0, payload: data)
        } else {
            send(RemoteFrame(type: type.rawValue, tabID: 0, seq: nextSeq(), payload: data))
        }
    }

    private func sendEncrypted(type: RemoteFrameType, tabID: UInt32, payload: Data) {
        guard let crypto else { return }
        let frame = RemoteFrame(type: type.rawValue, tabID: tabID, seq: nextSeq(), payload: payload)
        guard let encrypted = try? crypto.encrypt(frame: frame) else { return }
        send(encrypted)
    }

    private func send(_ frame: RemoteFrame) {
        webSocket?.send(.data(frame.encode())) { _ in }
    }

    private func nextSeq() -> UInt64 {
        defer { seqCounter &+= 1 }
        return seqCounter
    }

    // MARK: - Key Management

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

    // MARK: - Pairing Persistence

    private func persistPairing() {
        guard let info = pairingInfo,
              let data = try? JSONEncoder().encode(info) else {
            _ = KeychainStore.delete(key: "pairing_payload")
            return
        }
        _ = KeychainStore.save(key: "pairing_payload", data: data)
    }

    private static func loadPairing() -> PairingInfo? {
        guard let data = KeychainStore.load(key: "pairing_payload") else { return nil }
        return try? JSONDecoder().decode(PairingInfo.self, from: data)
    }
}
