import Foundation
import CryptoKit
import UIKit
import Chau7Core
import UserNotifications
import os

private let log = Logger(subsystem: "ch7", category: "RemoteClient")

/// Manages the encrypted WebSocket connection to a macOS Chau7 instance.
@MainActor @Observable
final class RemoteClient {

    // MARK: - State

    var outputText = ""
    private(set) var strippedOutputText = ""
    private(set) var tabs: [RemoteTab] = []
    private(set) var isConnected = false
    private(set) var status = "Disconnected"
    var activeTabID: UInt32 = 0
    var lastError: String?
    var pendingApprovals: [ApprovalRequest] = []
    var approvalHistory: [ApprovalHistoryEntry] = []

    // MARK: - Pairing (persisted in Keychain)

    var pairingInfo: PairingInfo? {
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
    private var notificationTask: Task<Void, Never>?
    private var reconnectAttempt = 0
    private var reconnectTask: Task<Void, Never>?
    private var shouldReconnect = false
    private var outputByTabID: [UInt32: String] = [:]
    private var strippedOutputByTabID: [UInt32: String] = [:]
    private var remoteSessionID: String?
    private var bufferedTelemetryEvents: [RemoteClientTelemetryEvent] = []

    private static let maxOutputBytes = 200_000
    private static let maxFrameBytes = 65_536
    private static let maxHistory = 50
    private static let maxReconnectAttempts = 5
    private static let maxBufferedTelemetryEvents = 100
    static let appVersion = "1.1.0"

    // MARK: - Init

    init() {
        iosKey = Self.loadOrCreateKey()
        pairingInfo = Self.loadPairing()

        notificationTask = Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .approvalNotificationResponse) {
                guard let self,
                      let id = note.userInfo?["request_id"] as? String,
                      let approved = note.userInfo?["approved"] as? Bool else { continue }
                self.respondToApproval(requestID: id, approved: approved)
            }
        }
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
        remoteSessionID = nil

        if let keyData = Data(base64Encoded: pairing.macPub) {
            macPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
        }

        var components = URLComponents(string: pairing.relayURL.strippingTrailingSlash)
        components?.path += "/\(pairing.deviceID)"
        components?.queryItems = [URLQueryItem(name: "role", value: "ios")]
        guard let url = components?.url else {
            lastError = "Invalid relay URL"
            return
        }

        let task = URLSession.shared.webSocketTask(with: url)
        webSocket = task
        task.resume()
        status = "Connecting"
        emitTelemetry(
            type: .connectRequested,
            status: "connecting",
            metadata: ["relay_host": pairing.relayURL]
        )

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
        remoteSessionID = nil
        nonceIOS = nil
        nonceMac = nil
        tabs = []
        outputByTabID.removeAll()
        strippedOutputByTabID.removeAll()
        outputText = ""
        strippedOutputText = ""
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
        refreshVisibleOutput()
        emitTelemetry(type: .tabSwitched, tabID: tabID, tabTitle: tabTitle(for: tabID))
        sendJSON(TabSwitchPayload(tabID: tabID), type: .tabSwitch)
    }

    // MARK: - Approvals

    func respondToApproval(requestID: String, approved: Bool) {
        guard let idx = pendingApprovals.firstIndex(where: { $0.requestID == requestID }) else { return }
        let request = pendingApprovals.remove(at: idx)

        approvalHistory.append(ApprovalHistoryEntry(
            command: request.command,
            flaggedCommand: request.flaggedCommand,
            approved: approved,
            timestamp: Date()
        ))
        if approvalHistory.count > Self.maxHistory {
            approvalHistory.removeFirst(approvalHistory.count - Self.maxHistory)
        }

        sendJSON(ApprovalResponsePayload(requestID: requestID, approved: approved), type: .approvalResponse)
        emitTelemetry(
            type: .approvalResponded,
            status: approved ? "approved" : "denied",
            message: request.flaggedCommand,
            metadata: ["request_id": requestID]
        )
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [requestID])
    }

    // MARK: - Receive Loop

    private func listen() {
        webSocket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    log.error("WebSocket receive failed: \(error.localizedDescription)")
                    self.handleDisconnect(reason: error.localizedDescription)
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

    private func handleDisconnect(reason: String? = nil) {
        let wasConnected = isConnected
        isConnected = false
        status = "Disconnected"
        crypto = nil

        if wasConnected || reason != nil {
            emitTelemetry(type: .disconnected, status: "disconnected", message: reason)
        }

        guard wasConnected, shouldReconnect, reconnectAttempt < Self.maxReconnectAttempts else { return }
        reconnectAttempt += 1
        let delay = pow(2.0, Double(reconnectAttempt))
        status = "Reconnecting (\(reconnectAttempt)/\(Self.maxReconnectAttempts))..."
        emitTelemetry(
            type: .reconnectScheduled,
            status: "scheduled",
            message: reason,
            metadata: [
                "attempt": String(reconnectAttempt),
                "delay_seconds": String(format: "%.0f", delay)
            ]
        )

        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let pairing = self.pairingInfo else { return }
            self.connect(pairing: pairing)
        }
    }

    // MARK: - Frame Dispatch

    private func handleFrame(_ data: Data) {
        guard let frame = try? RemoteFrame.decode(from: data) else {
            log.warning("Failed to decode frame (\(data.count) bytes)")
            emitTelemetry(
                type: .frameDecodeFailed,
                status: "decode_failed",
                metadata: ["frame_bytes": String(data.count)]
            )
            return
        }

        let payload: Data
        if frame.flags & RemoteFrame.flagEncrypted != 0 {
            guard let crypto, let decrypted = try? crypto.decrypt(frame: frame) else {
                log.warning("Decryption failed for frame type=\(frame.type)")
                emitTelemetry(
                    type: .frameDecryptFailed,
                    status: "decrypt_failed",
                    metadata: ["frame_type": String(frame.type)]
                )
                return
            }
            payload = decrypted
        } else {
            payload = frame.payload
        }

        switch RemoteFrameType(rawValue: frame.type) {
        case .hello:           handleHello(payload)
        case .pairAccept:      handlePairAccept(payload)
        case .pairReject:      handlePairReject(payload)
        case .sessionReady:
            isConnected = true
            status = "Session ready"
            lastError = nil
        case .tabList:         handleTabList(payload)
        case .output:          appendOutput(payload, tabID: frame.tabID)
        case .snapshot:        storeSnapshot(payload, tabID: frame.tabID)
        case .approvalRequest: handleApprovalRequest(payload)
        case .ping:            sendEncrypted(type: .pong, tabID: frame.tabID, payload: payload)
        case .error:           handleError(payload)
        default:               break
        }
    }

    // MARK: - Frame Handlers

    private func handleHello(_ data: Data) {
        guard let msg = try? JSONDecoder().decode(HelloPayload.self, from: data),
              let nonce = Data(base64Encoded: msg.nonce) else { return }
        nonceMac = nonce
        establishSessionIfPossible()
    }

    private func handlePairAccept(_ data: Data) {
        guard let msg = try? JSONDecoder().decode(PairAcceptPayload.self, from: data),
              let keyData = Data(base64Encoded: msg.macPub) else { return }
        macPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
        _ = KeychainStore.save(key: "mac_public_key", data: keyData)
        sendHello()
        establishSessionIfPossible()
    }

    private func handlePairReject(_ data: Data) {
        if let msg = try? JSONDecoder().decode(PairRejectPayload.self, from: data) {
            lastError = "Pairing rejected: \(msg.reason)"
        } else {
            lastError = "Pairing rejected"
        }
        status = "Pairing rejected"
        shouldReconnect = false
    }

    private func handleError(_ data: Data) {
        if let msg = try? JSONDecoder().decode(RemoteErrorPayload.self, from: data) {
            lastError = "\(msg.code): \(msg.message)"
            emitTelemetry(
                type: .errorReceived,
                status: msg.code,
                message: msg.message
            )
        } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            lastError = text
            emitTelemetry(type: .errorReceived, status: "error", message: text)
        }
        status = "Error"
    }

    private func handleTabList(_ data: Data) {
        guard let msg = try? JSONDecoder().decode(TabListPayload.self, from: data) else { return }
        tabs = msg.tabs
        if let active = msg.tabs.first(where: { $0.isActive }) {
            activeTabID = active.tabID
        } else if let first = msg.tabs.first {
            activeTabID = first.tabID
        } else {
            activeTabID = 0
        }
        let visibleTabIDs = Set(msg.tabs.map(\.tabID))
        outputByTabID = outputByTabID.filter { visibleTabIDs.contains($0.key) }
        strippedOutputByTabID = strippedOutputByTabID.filter { visibleTabIDs.contains($0.key) }
        refreshVisibleOutput()
    }

    private func appendOutput(_ data: Data, tabID: UInt32) {
        let capped = data.prefix(Self.maxFrameBytes)
        guard let text = String(data: capped, encoding: .utf8) else { return }
        let resolvedTabID = resolvedTabID(for: tabID)
        var existing = outputByTabID[resolvedTabID] ?? ""
        existing.append(text)
        outputByTabID[resolvedTabID] = trimOutput(existing)
        strippedOutputByTabID[resolvedTabID] = ANSIStripper.strip(outputByTabID[resolvedTabID] ?? "")
        if resolvedTabID == activeTabID || activeTabID == 0 {
            refreshVisibleOutput()
        }
    }

    private func storeSnapshot(_ data: Data, tabID: UInt32) {
        let resolvedTabID = resolvedTabID(for: tabID)
        let text = String(data: data, encoding: .utf8) ?? ""
        outputByTabID[resolvedTabID] = trimOutput(text)
        strippedOutputByTabID[resolvedTabID] = ANSIStripper.strip(outputByTabID[resolvedTabID] ?? "")
        if resolvedTabID == activeTabID || activeTabID == 0 {
            refreshVisibleOutput()
        }
    }

    private func handleApprovalRequest(_ data: Data) {
        guard let msg = try? JSONDecoder().decode(ApprovalRequestPayload.self, from: data) else { return }
        pendingApprovals.append(ApprovalRequest(
            requestID: msg.requestID, command: msg.command,
            flaggedCommand: msg.flaggedCommand, timestamp: Date()
        ))
        emitTelemetry(
            type: .approvalReceived,
            status: "pending",
            message: msg.flaggedCommand,
            metadata: ["request_id": msg.requestID]
        )

        let content = UNMutableNotificationContent()
        let isProtectedRemoteAction = msg.flaggedCommand != msg.command
        content.title = isProtectedRemoteAction ? "Protected Remote Action" : "Command Approval"
        content.body = isProtectedRemoteAction ? msg.flaggedCommand : msg.command
        content.sound = .default
        content.categoryIdentifier = "MCP_APPROVAL"
        content.userInfo = ["request_id": msg.requestID]
        let req = UNNotificationRequest(
            identifier: msg.requestID,
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
        isConnected = true
        let sessionID = CryptoUtils.randomBytes(count: 8).base64EncodedString()
        remoteSessionID = sessionID
        sendJSON(SessionReadyPayload(sessionID: sessionID), type: .sessionReady, encrypt: true)
        status = "Encrypted"
        emitTelemetry(type: .sessionEncrypted, status: "encrypted")
        flushBufferedTelemetryEvents()
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
        emitTelemetry(type: .pairRequestSent, status: "pairing")
    }

    private func sendJSON<T: Encodable>(_ payload: T, type: RemoteFrameType, encrypt: Bool = true) {
        guard let data = try? JSONEncoder().encode(payload) else {
            log.error("Failed to encode \(String(describing: T.self)) for frame type \(type.rawValue)")
            return
        }
        if encrypt {
            sendEncrypted(type: type, tabID: 0, payload: data)
        } else {
            send(RemoteFrame(type: type.rawValue, tabID: 0, seq: nextSeq(), payload: data))
        }
    }

    private func sendEncrypted(type: RemoteFrameType, tabID: UInt32, payload: Data) {
        guard let crypto else { return }
        let frame = RemoteFrame(type: type.rawValue, tabID: tabID, seq: nextSeq(), payload: payload)
        guard let encrypted = try? crypto.encrypt(frame: frame) else {
            log.error("Encryption failed for frame type \(type.rawValue)")
            return
        }
        send(encrypted)
    }

    private func send(_ frame: RemoteFrame) {
        webSocket?.send(.data(frame.encode())) { error in
            if let error {
                log.error("WebSocket send failed: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.emitTelemetry(type: .sendFailed, status: "send_failed", message: error.localizedDescription)
                }
            }
        }
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

    func flaggedProtectedAction(for input: String) -> String? {
        RemoteProtection.flaggedTerminationAction(for: input)
    }

    func recordProtectedActionPrompt(text: String, flaggedAction: String) {
        emitTelemetry(
            type: .protectedActionPrompted,
            status: "prompted",
            message: flaggedAction,
            tabID: activeTabID,
            tabTitle: tabTitle(for: activeTabID),
            metadata: ["input_bytes": String(text.utf8.count)]
        )
    }

    func recordProtectedActionSubmission(text: String, flaggedAction: String) {
        emitTelemetry(
            type: .protectedActionSubmitted,
            status: "submitted",
            message: flaggedAction,
            tabID: activeTabID,
            tabTitle: tabTitle(for: activeTabID),
            metadata: ["input_bytes": String(text.utf8.count)]
        )
    }

    private func resolvedTabID(for tabID: UInt32) -> UInt32 {
        tabID == 0 ? activeTabID : tabID
    }

    private func refreshVisibleOutput() {
        outputText = outputByTabID[activeTabID] ?? ""
        strippedOutputText = strippedOutputByTabID[activeTabID] ?? ""
    }

    private func trimOutput(_ input: String) -> String {
        guard input.utf8.count > Self.maxOutputBytes else { return input }
        let excess = input.utf8.count - Self.maxOutputBytes
        let start = input.utf8.startIndex
        let end = input.utf8.endIndex
        guard let idx = input.utf8.index(start, offsetBy: excess, limitedBy: end) else {
            return input
        }
        let charIdx = input.index(after: String.Index(idx, within: input) ?? input.startIndex)
        return String(input[charIdx...])
    }

    private func emitTelemetry(
        type: RemoteClientTelemetryEventType,
        status: String? = nil,
        message: String? = nil,
        tabID: UInt32? = nil,
        tabTitle: String? = nil,
        metadata: [String: String] = [:]
    ) {
        var event = RemoteClientTelemetryEvent(
            deviceID: pairingInfo?.deviceID,
            deviceName: UIDevice.current.name,
            appVersion: Self.appVersion,
            sessionID: remoteSessionID,
            eventType: type,
            status: status,
            tabID: tabID,
            tabTitle: tabTitle,
            message: message,
            metadata: metadata
        )
        enqueueOrSendTelemetryEvent(&event)
    }

    private func enqueueOrSendTelemetryEvent(_ event: inout RemoteClientTelemetryEvent) {
        guard crypto != nil else {
            bufferedTelemetryEvents.append(event)
            if bufferedTelemetryEvents.count > Self.maxBufferedTelemetryEvents {
                bufferedTelemetryEvents.removeFirst(bufferedTelemetryEvents.count - Self.maxBufferedTelemetryEvents)
            }
            return
        }

        if event.sessionID == nil {
            event.sessionID = remoteSessionID
        }

        guard let data = try? JSONEncoder().encode(event) else { return }
        sendEncrypted(type: .remoteTelemetry, tabID: event.tabID ?? 0, payload: data)
    }

    private func flushBufferedTelemetryEvents() {
        guard crypto != nil, !bufferedTelemetryEvents.isEmpty else { return }
        var pendingEvents = bufferedTelemetryEvents
        bufferedTelemetryEvents.removeAll(keepingCapacity: true)
        for index in pendingEvents.indices {
            enqueueOrSendTelemetryEvent(&pendingEvents[index])
        }
    }

    private func tabTitle(for tabID: UInt32) -> String? {
        tabs.first(where: { $0.tabID == tabID })?.title
    }
}
