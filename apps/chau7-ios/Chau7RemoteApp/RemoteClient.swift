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
    var pendingInteractivePrompts: [RemoteInteractivePrompt] = []
    var approvalHistory: [ApprovalHistoryEntry] = []
    private(set) var liveActivityState: RemoteActivityState?

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
    private var handshakeRetryTask: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var shouldReconnect = false
    private var hasReceivedPairAccept = false
    private var connectionGeneration: UInt64 = 0
    private var outputStore = RemoteTerminalOutputStore()
    private var outputFlushTask: Task<Void, Never>?
    private var remoteSessionID: String?
    private var bufferedTelemetryEvents: [RemoteClientTelemetryEvent] = []
    private var pendingURLActions: [RemoteActivityURLAction] = []
    let terminalRenderer = RemoteTerminalRendererStore()

    private static let maxHistory = 50
    private static let maxReconnectAttempts = 5
    private static let maxBufferedTelemetryEvents = 100
    private static let handshakeRetryIntervalSeconds = 1.0
    private static let handshakeTimeoutSeconds = 12.0
    private static let repairFallbackAttempt = 3
    static let appVersion = "1.1.0"

    var canSendInput: Bool {
        canSendInput(to: activeTabID)
    }

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
        hasReceivedPairAccept = false

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

        listen()
        scheduleHandshake(for: connectionGeneration)
    }

    func disconnect(autoReconnect: Bool = false) {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelHandshakeTasks()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        status = "Disconnected"
        crypto = nil
        remoteSessionID = nil
        hasReceivedPairAccept = false
        nonceIOS = nil
        nonceMac = nil
        seqCounter = 1
        reconnectAttempt = 0
        connectionGeneration &+= 1
        tabs = []
        outputStore.reset()
        terminalRenderer.reset()
        outputFlushTask?.cancel()
        outputFlushTask = nil
        bufferedTelemetryEvents.removeAll(keepingCapacity: true)
        liveActivityState = nil
        outputText = ""
        strippedOutputText = ""
        pendingInteractivePrompts = []
        if #available(iOS 16.1, *) {
            RemoteLiveActivityManager.shared.update(with: nil)
        }
        if !autoReconnect {
            lastError = nil
            pendingApprovals = []
            pendingURLActions.removeAll()
        }
    }

    // MARK: - Input

    @discardableResult
    func sendInput(_ text: String, appendNewline: Bool) -> Bool {
        sendInput(text, appendNewline: appendNewline, to: activeTabID)
    }

    func switchTab(_ tabID: UInt32) {
        activeTabID = tabID
        flushPendingOutput(for: tabID)
        refreshVisibleOutput()
        terminalRenderer.setActiveTab(tabID, fallbackText: outputText)
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

    @discardableResult
    func respondToInteractivePrompt(promptID: String, optionID: String) -> Bool {
        guard let promptIndex = pendingInteractivePrompts.firstIndex(where: { $0.id == promptID }) else {
            return false
        }
        let prompt = pendingInteractivePrompts[promptIndex]
        guard let option = prompt.options.first(where: { $0.id == optionID }) else {
            return false
        }

        if tabs.contains(where: { $0.tabID == prompt.tabID }) {
            switchTab(prompt.tabID)
        }

        guard sendInput(option.response, appendNewline: false, to: prompt.tabID) else {
            return false
        }

        pendingInteractivePrompts.remove(at: promptIndex)
        return true
    }

    func handle(url: URL) {
        guard let action = RemoteActivityURLAction(url: url) else { return }
        if !performURLAction(action) {
            pendingURLActions.append(action)
            if webSocket == nil, pairingInfo != nil {
                connect()
            }
        }
    }

    // MARK: - Receive Loop

    private func listen() {
        let generation = connectionGeneration
        webSocket?.receive { [weak self] result in
            guard let client = self else { return }
            Task { @MainActor [client] in
                guard client.connectionGeneration == generation else { return }
                switch result {
                case .failure(let error):
                    log.error("WebSocket receive failed: \(error.localizedDescription)")
                    client.handleDisconnect(reason: error.localizedDescription)
                case .success(let msg):
                    switch msg {
                    case .data(let data): client.handleFrame(data)
                    case .string(let text): client.handleFrame(Data(text.utf8))
                    @unknown default: break
                    }
                    client.listen()
                }
            }
        }
    }

    private func handleDisconnect(reason: String? = nil) {
        let wasConnected = isConnected
        cancelHandshakeTasks()
        isConnected = false
        status = "Disconnected"
        crypto = nil

        if wasConnected || reason != nil {
            emitTelemetry(type: .disconnected, status: "disconnected", message: reason)
        }

        guard shouldReconnect, reconnectAttempt < Self.maxReconnectAttempts else {
            if reconnectAttempt >= Self.maxReconnectAttempts {
                lastError = "Reconnect limit reached (\(Self.maxReconnectAttempts) attempts)"
                status = "Connection failed"
            }
            return
        }
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

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let pairing = self.pairingInfo else { return }
            self.connect(pairing: pairing)
        }
    }

    private func scheduleHandshake(for generation: UInt64) {
        cancelHandshakeTasks()

        handshakeRetryTask = Task { @MainActor [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                guard let self,
                      self.connectionGeneration == generation,
                      self.webSocket != nil,
                      !self.isConnected else { return }

                if attempt > 0, self.status == "Connecting" {
                    self.status = "Waiting for your Mac..."
                }

                self.sendHello()
                if let pairing = self.pairingInfo,
                   self.shouldSendPairRequest(for: pairing, attempt: attempt) {
                    self.sendPairRequest(recordTelemetry: attempt == 0)
                }

                attempt += 1
                try? await Task.sleep(for: .seconds(Self.handshakeRetryIntervalSeconds))
            }
        }

        handshakeTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.handshakeTimeoutSeconds))
            guard let self,
                  self.connectionGeneration == generation,
                  self.webSocket != nil,
                  !self.isConnected else { return }

            self.shouldReconnect = false
            self.cancelHandshakeTasks()
            let socket = self.webSocket
            self.webSocket = nil
            self.connectionGeneration &+= 1
            self.isConnected = false
            self.crypto = nil
            socket?.cancel(with: .goingAway, reason: nil)
            self.status = "Connection timed out"
            self.lastError = "No response from your Mac. Make sure Chau7 is open, Remote is enabled, and the pairing payload is still current."
            self.emitTelemetry(
                type: .errorReceived,
                status: "timeout",
                message: self.lastError
            )
        }
    }

    private func cancelHandshakeTasks() {
        handshakeRetryTask?.cancel()
        handshakeRetryTask = nil
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
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
            cancelHandshakeTasks()
            flushPendingURLActions()
        case .tabList:         handleTabList(payload)
        case .cachedTabList:   handleCachedTabList(payload)
        case .activityState:   handleActivityState(payload)
        case .activityCleared: clearActivityState()
        case .interactivePromptList: handleInteractivePromptList(payload)
        case .output:          appendOutput(payload, tabID: frame.tabID)
        case .snapshot:        storeSnapshot(payload, tabID: frame.tabID)
        case .terminalGridSnapshot:
            storeGridSnapshot(payload, tabID: frame.tabID)
        case .approvalRequest: handleApprovalRequest(payload)
        case .ping:            sendEncrypted(type: .pong, tabID: frame.tabID, payload: payload)
        case .error:           handleError(payload)
        default:
            log.warning("Unhandled frame type: 0x\(String(frame.type, radix: 16))")
        }
    }

    // MARK: - Frame Handlers

    private func handleHello(_ data: Data) {
        guard let msg: HelloPayload = decodePayload(data, as: HelloPayload.self, context: "handleHello") else { return }
        guard let nonce = Data(base64Encoded: msg.nonce) else {
            log.error("handleHello: invalid nonce base64")
            return
        }
        nonceMac = nonce
        establishSessionIfPossible()
    }

    private func handlePairAccept(_ data: Data) {
        guard let msg: PairAcceptPayload = decodePayload(data, as: PairAcceptPayload.self, context: "handlePairAccept") else { return }
        guard let keyData = Data(base64Encoded: msg.macPub) else {
            log.error("handlePairAccept: invalid macPub base64")
            return
        }
        do {
            macPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
        } catch {
            log.error("handlePairAccept: invalid public key: \(error.localizedDescription)")
            return
        }
        hasReceivedPairAccept = true
        _ = KeychainStore.save(key: "mac_public_key", data: keyData)
        persistTrustedIdentity(for: msg)
        // If we fell back from trust-based reconnect to explicit pairing, any
        // provisional session state must be discarded before re-deriving keys.
        crypto = nil
        isConnected = false
        remoteSessionID = nil
        nonceMac = nil
        nonceIOS = CryptoUtils.randomBytes(count: 16)
        seqCounter = 1
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
        guard let msg: TabListPayload = decodePayload(data, as: TabListPayload.self, context: "handleTabList") else { return }
        applyTabListPayload(msg)
        flushPendingURLActions()
    }

    private func handleCachedTabList(_ data: Data) {
        guard let msg: TabListPayload = decodePayload(data, as: TabListPayload.self, context: "handleCachedTabList") else { return }
        applyTabListPayload(msg)
    }

    private func applyTabListPayload(_ msg: TabListPayload) {
        tabs = msg.tabs
        if let active = msg.tabs.first(where: { $0.isActive }) {
            activeTabID = active.tabID
        } else if let first = msg.tabs.first {
            activeTabID = first.tabID
        } else {
            activeTabID = 0
        }
        let visibleTabIDs = Set(msg.tabs.map(\.tabID))
        outputStore.retainVisibleTabs(visibleTabIDs)
        terminalRenderer.retainVisibleTabs(visibleTabIDs)
        pendingInteractivePrompts.removeAll { !visibleTabIDs.contains($0.tabID) }
        refreshVisibleOutput()
        terminalRenderer.setActiveTab(activeTabID, fallbackText: outputText)
    }

    private func handleActivityState(_ data: Data) {
        do {
            let state = try JSONDecoder().decode(RemoteActivityState.self, from: data)
            liveActivityState = state
            if #available(iOS 16.1, *) {
                RemoteLiveActivityManager.shared.update(with: state)
            }
        } catch {
            log.error("handleActivityState: decode failed: \(error.localizedDescription)")
        }
    }

    private func clearActivityState() {
        liveActivityState = nil
        if #available(iOS 16.1, *) {
            RemoteLiveActivityManager.shared.update(with: nil)
        }
    }

    private func handleInteractivePromptList(_ data: Data) {
        guard let payload: RemoteInteractivePromptListPayload = decodePayload(
            data,
            as: RemoteInteractivePromptListPayload.self,
            context: "handleInteractivePromptList"
        ) else {
            return
        }
        pendingInteractivePrompts = payload.prompts
    }

    private func appendOutput(_ data: Data, tabID: UInt32) {
        let resolvedTabID = resolvedTabID(for: tabID)
        outputStore.append(data, to: resolvedTabID)
        terminalRenderer.appendOutput(data, for: resolvedTabID)

        if outputStore.pendingByteCount(for: resolvedTabID) >= RemoteOutputTuning.maxPendingBytesPerTab {
            flushPendingOutput(for: resolvedTabID)
        } else {
            scheduleOutputFlush()
        }
    }

    private func storeSnapshot(_ data: Data, tabID: UInt32) {
        let resolvedTabID = resolvedTabID(for: tabID)
        outputStore.replaceSnapshot(data, for: resolvedTabID)
        terminalRenderer.replaceSnapshot(data, for: resolvedTabID)
        if resolvedTabID == activeTabID || activeTabID == 0 {
            refreshVisibleOutput()
        }
    }

    private func storeGridSnapshot(_ data: Data, tabID: UInt32) {
        let resolvedTabID = resolvedTabID(for: tabID)
        guard let renderState = RemoteTerminalRenderStateDecoder.decodeGridSnapshot(data) else {
            return
        }
        terminalRenderer.replaceGridSnapshot(renderState, for: resolvedTabID)
    }

    private func handleApprovalRequest(_ data: Data) {
        guard let msg: ApprovalRequestPayload = decodePayload(data, as: ApprovalRequestPayload.self, context: "handleApprovalRequest") else { return }
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
        guard let macPub = macPublicKey ?? loadStoredMacKey() else {
            log.error("Session establishment failed: no Mac public key available")
            return
        }

        let shared: SharedSecret
        do {
            shared = try iosKey.sharedSecretFromKeyAgreement(with: macPub)
        } catch {
            log.error("Session establishment failed: key agreement: \(error.localizedDescription)")
            lastError = "Key agreement failed"
            return
        }

        guard let session = RemoteCryptoSession.create(sharedSecret: shared, nonceMac: nonceMac, nonceIOS: nonceIOS) else {
            log.error("Session establishment failed: could not derive crypto session")
            lastError = "Session derivation failed"
            return
        }

        crypto = session
        reconnectAttempt = 0
        isConnected = true
        cancelHandshakeTasks()
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

    private func sendPairRequest(recordTelemetry: Bool = true) {
        guard let pairing = pairingInfo else { return }
        sendJSON(PairRequestPayload(
            deviceID: pairing.deviceID, pairingCode: pairing.pairingCode,
            iosPub: iosKey.publicKey.rawRepresentation.base64EncodedString(),
            iosName: UIDevice.current.name
        ), type: .pairRequest, encrypt: false)
        if recordTelemetry {
            emitTelemetry(type: .pairRequestSent, status: "pairing")
        }
    }

    private func sendJSON<T: Encodable>(_ payload: T, type: RemoteFrameType, encrypt: Bool = true) {
        guard let data = try? JSONEncoder().encode(payload) else {
            log.error("Failed to encode \(String(describing: T.self)) for frame type \(type.rawValue)")
            return
        }
        if encrypt {
            _ = sendEncrypted(type: type, tabID: 0, payload: data)
        } else {
            _ = send(RemoteFrame(type: type.rawValue, tabID: 0, seq: nextSeq(), payload: data))
        }
    }

    @discardableResult
    private func sendEncrypted(type: RemoteFrameType, tabID: UInt32, payload: Data) -> Bool {
        guard let crypto else { return false }
        let frame = RemoteFrame(type: type.rawValue, tabID: tabID, seq: nextSeq(), payload: payload)
        guard let encrypted = try? crypto.encrypt(frame: frame) else {
            log.error("Encryption failed for frame type \(type.rawValue)")
            return false
        }
        return send(encrypted)
    }

    @discardableResult
    private func send(_ frame: RemoteFrame) -> Bool {
        guard webSocket != nil else { return false }
        webSocket?.send(.data(frame.encode())) { error in
            if let error {
                log.error("WebSocket send failed: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.emitTelemetry(type: .sendFailed, status: "send_failed", message: error.localizedDescription)
                }
            }
        }
        return true
    }

    private func nextSeq() -> UInt64 {
        defer { seqCounter &+= 1 }
        return seqCounter
    }

    private func performURLAction(_ action: RemoteActivityURLAction) -> Bool {
        guard crypto != nil else { return false }

        switch action {
        case .open(let tabID):
            if let tabID {
                guard tabs.contains(where: { $0.tabID == tabID }) else { return false }
                switchTab(tabID)
            }
            return true
        case .switchTab(let tabID):
            guard tabs.contains(where: { $0.tabID == tabID }) else { return false }
            switchTab(tabID)
            return true
        case .approve(let requestID, let tabID):
            if let tabID {
                guard tabs.contains(where: { $0.tabID == tabID }) else { return false }
                switchTab(tabID)
            }
            guard pendingApprovals.contains(where: { $0.requestID == requestID }) else { return false }
            respondToApproval(requestID: requestID, approved: true)
            return true
        case .deny(let requestID, let tabID):
            if let tabID {
                guard tabs.contains(where: { $0.tabID == tabID }) else { return false }
                switchTab(tabID)
            }
            guard pendingApprovals.contains(where: { $0.requestID == requestID }) else { return false }
            respondToApproval(requestID: requestID, approved: false)
            return true
        }
    }

    private func flushPendingURLActions() {
        guard crypto != nil, !pendingURLActions.isEmpty else { return }

        let queued = pendingURLActions
        pendingURLActions.removeAll(keepingCapacity: true)

        for action in queued where !performURLAction(action) {
            pendingURLActions.append(action)
        }
    }

    // MARK: - Key Management

    private func loadStoredMacKey() -> Curve25519.KeyAgreement.PublicKey? {
        guard let data = KeychainStore.load(key: "mac_public_key") else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: data)
    }

    private func canSendInput(to tabID: UInt32) -> Bool {
        crypto != nil && webSocket != nil && tabID != 0 && tabs.contains(where: { $0.tabID == tabID })
    }

    @discardableResult
    private func sendInput(_ text: String, appendNewline: Bool, to tabID: UInt32) -> Bool {
        guard !text.isEmpty else { return false }
        guard crypto != nil, webSocket != nil else {
            reportBlockedInput("Input not sent because the encrypted session is not ready yet.")
            return false
        }
        guard canSendInput(to: tabID) else {
            reportBlockedInput("Input not sent because the target remote tab is no longer available.")
            return false
        }
        var data = Data(text.utf8)
        if appendNewline { data.append(0x0A) }
        guard sendEncrypted(type: .input, tabID: tabID, payload: data) else {
            reportBlockedInput("Input could not be encrypted for the current remote session.")
            return false
        }
        return true
    }

    private func shouldSendPairRequest(for pairing: PairingInfo, attempt: Int) -> Bool {
        guard !hasReceivedPairAccept else { return false }
        if !hasStoredTrust(for: pairing) {
            return true
        }
        return attempt >= Self.repairFallbackAttempt
    }

    private func hasStoredTrust(for pairing: PairingInfo) -> Bool {
        guard let storedKey = loadStoredMacKey(),
              let trustedIdentity = Self.loadTrustedPairingIdentity() else {
            return false
        }
        let currentIOSPub = iosKey.publicKey.rawRepresentation.base64EncodedString()
        return storedKey.rawRepresentation.base64EncodedString() == pairing.macPub &&
            trustedIdentity.deviceID == pairing.deviceID &&
            trustedIdentity.macPub == pairing.macPub &&
            trustedIdentity.iosPub == currentIOSPub
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
            _ = KeychainStore.delete(key: "trusted_pairing_identity")
            return
        }
        _ = KeychainStore.save(key: "pairing_payload", data: data)
    }

    private static func loadPairing() -> PairingInfo? {
        guard let data = KeychainStore.load(key: "pairing_payload") else { return nil }
        return try? JSONDecoder().decode(PairingInfo.self, from: data)
    }

    private func persistTrustedIdentity(for accept: PairAcceptPayload) {
        guard let pairing = pairingInfo,
              let data = try? JSONEncoder().encode(
                TrustedPairingIdentity(
                    deviceID: pairing.deviceID,
                    macPub: accept.macPub,
                    iosPub: iosKey.publicKey.rawRepresentation.base64EncodedString()
                )
              ) else {
            return
        }
        _ = KeychainStore.save(key: "trusted_pairing_identity", data: data)
    }

    private static func loadTrustedPairingIdentity() -> TrustedPairingIdentity? {
        guard let data = KeychainStore.load(key: "trusted_pairing_identity") else { return nil }
        return try? JSONDecoder().decode(TrustedPairingIdentity.self, from: data)
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
        outputText = outputStore.visibleOutput(for: activeTabID)
        strippedOutputText = ANSIStripper.strip(outputText)
        terminalRenderer.updateActiveFallbackText(outputText)
    }

    private func reportBlockedInput(_ message: String) {
        lastError = message
        emitTelemetry(
            type: .sendFailed,
            status: "send_blocked",
            message: message,
            tabID: activeTabID,
            tabTitle: tabTitle(for: activeTabID)
        )
    }

    private func scheduleOutputFlush() {
        guard outputFlushTask == nil, outputStore.hasPendingOutput else { return }
        outputFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: RemoteOutputTuning.flushInterval)
            guard let self, !Task.isCancelled else { return }
            self.flushPendingOutput()
        }
    }

    private func flushPendingOutput(for tabID: UInt32? = nil) {
        if tabID == nil {
            outputFlushTask?.cancel()
            outputFlushTask = nil
        }

        if let tabID {
            guard outputStore.hasPendingOutput(for: tabID) else { return }
        } else {
            guard outputStore.hasPendingOutput else { return }
        }

        let updatedTabIDs = outputStore.flushPendingOutput(for: tabID)

        if tabID == nil, outputStore.hasPendingOutput {
            scheduleOutputFlush()
        }

        if tabID == activeTabID || (tabID == nil && activeTabID == 0) || updatedTabIDs.contains(activeTabID) {
            refreshVisibleOutput()
        }
    }

    private func decodePayload<T: Decodable>(_ data: Data, as type: T.Type, context: String) -> T? {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            log.error("\(context): decode failed: \(error.localizedDescription)")
            return nil
        }
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
