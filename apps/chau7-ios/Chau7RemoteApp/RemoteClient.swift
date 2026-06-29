import Foundation
import SwiftUI
import CryptoKit
import UIKit
import Chau7Core
import os

private let log = Logger(subsystem: "ch7", category: "RemoteClient")
private let perfLog = OSLog(subsystem: "ch7", category: .pointsOfInterest)

private enum RemoteProcessedFrameResult: Sendable {
    case success(RemoteFrame, Data)
    case decodeFailed(Int)
    case decryptFailed(UInt8)
}

private enum RemoteFrameProcessor {
    nonisolated
    static func process(_ data: Data, crypto: RemoteCryptoSession?) -> RemoteProcessedFrameResult {
        guard let frame = try? RemoteFrame.decode(from: data) else {
            return .decodeFailed(data.count)
        }

        if frame.flags & RemoteFrame.flagEncrypted != 0 {
            guard let crypto, let decrypted = try? crypto.decrypt(frame: frame) else {
                return .decryptFailed(frame.type)
            }
            return .success(frame, decrypted)
        }

        return .success(frame, frame.payload)
    }
}

/// Manages the encrypted WebSocket connection to a macOS Chau7 instance.
@MainActor @Observable
final class RemoteClient {
    static let shared = RemoteClient()

    // MARK: - State

    var outputText = ""
    private(set) var strippedOutputText = ""
    private(set) var tabs: [RemoteTab] = []
    private(set) var isConnected = false
    private(set) var status: RemoteConnectionStatus = .disconnected
    var activeTabID: UInt32 = 0
    var lastError: String?
    var pendingApprovals: [ApprovalRequest] = []
    var pendingInteractivePrompts: [RemoteInteractivePrompt] = []
    var approvalHistory: [ApprovalHistoryEntry] = []
    private(set) var liveActivityState: RemoteActivityState?

    // MARK: - Pairing (persisted in Keychain)

    var pairingInfo: PairingInfo? {
        didSet { RemotePairingStore.savePairing(pairingInfo) }
    }

    // MARK: - Private

    private var webSocket: URLSessionWebSocketTask?
    private var seqCounter: UInt64 = 1
    private var maxReceivedSeq: UInt64 = 0
    private var crypto: RemoteCryptoSession?
    private var nonceIOS: Data?
    private var nonceMac: Data?
    private var macPublicKey: Curve25519.KeyAgreement.PublicKey?
    private let iosKey: Curve25519.KeyAgreement.PrivateKey
    private let deviceName = UIDevice.current.name
    private var notificationTask: Task<Void, Never>?
    private var reconnectBackoff = RemoteReconnectBackoff()
    private var reconnectTask: Task<Void, Never>?
    private var handshakeRetryTask: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var shouldReconnect = false
    private var hasReceivedPairAccept = false
    private var connectionGeneration: UInt64 = 0
    private var outputStore = RemoteTerminalOutputStore()
    private var outputFlushTask: Task<Void, Never>?
    private var strippedOutputRefreshTask: Task<Void, Never>?
    private var remoteSessionID: String?
    private var telemetryBuffer = RemoteTelemetryBuffer(maxEvents: RemoteClient.maxBufferedTelemetryEvents)
    private var pendingURLActions: [RemoteActivityURLAction] = []
    private var currentAppState: RemoteClientAppState = .foreground
    private var desiredStreamMode: RemoteClientStreamMode = .full
    private var pushToken: String?
    private var notificationsAuthorized = false
    private let backgroundKeepalive = BackgroundKeepalive(name: "ch7.remote.approvals")
    private var suppressLocalNotificationsUntil: Date?
    private var pendingApprovalResponses: [String: Bool] = [:]
    private var approvalResponsesInFlight: Set<String> = []
    private var pendingStateFetchTask: Task<Void, Never>?
    private var lastPendingStateFetchAt: Date?
    private var frameRateLimiter = RemoteFrameRateLimiter()
    private var lastFrameThrottleLogAt: Date?
    let terminalRenderer = RemoteTerminalRendererStore()

    private static let maxHistory = 50
    private static let maxReconnectAttempts = RemoteReconnectBackoff.maxAttempts
    private static let maxBufferedTelemetryEvents = 100
    private static let handshakeRetryIntervalSeconds = 1.0
    private static let handshakeTimeoutSeconds = 12.0
    private static let repairFallbackAttempt = 3
    private static let pushNotificationSuppressionWindow: TimeInterval = 15
    private static let pendingStateFetchMinimumInterval: TimeInterval = 1
    /// Frames larger than this get decode/decrypt offloaded to a detached task;
    /// smaller control frames are processed inline (detach overhead > work).
    private static let frameOffloadThreshold = 8192
    static let appVersion =
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.1.0"

    var canSendInput: Bool {
        canSendInput(to: activeTabID)
    }

    /// SHA-256 fingerprint of this device's public key, for out-of-band
    /// verification against the value shown by the Mac.
    var iosKeyFingerprint: String {
        CryptoUtils.fingerprint(data: iosKey.publicKey.rawRepresentation)
    }

    /// SHA-256 fingerprint of the paired Mac's public key (from the pairing
    /// payload), or nil when not paired.
    var macKeyFingerprint: String? {
        guard let macPub = pairingInfo?.macPub,
              let data = Data(base64Encoded: macPub) else { return nil }
        return CryptoUtils.fingerprint(data: data)
    }

    // MARK: - Init

    init() {
        iosKey = RemotePairingStore.loadOrCreateIOSKey()
        pairingInfo = RemotePairingStore.loadPairing()

        backgroundKeepalive.onExpire = { [weak self] in
            self?.handleBackgroundTaskExpiration()
        }

        notificationTask = Task { [weak self] in
            for await note in NotificationCenter.default.notifications(named: .approvalNotificationResponse) {
                guard let self,
                      let id = note.userInfo?[RemoteNotificationID.UserInfoKey.requestID] as? String,
                      let approved = note.userInfo?[RemoteNotificationID.UserInfoKey.approved] as? Bool else { continue }
                self.respondToApproval(requestID: id, approved: approved)
            }
        }
    }

    // MARK: - Connection

    func connect() {
        guard let pairing = pairingInfo else { return }
        connect(pairing: pairing)
    }

    func connect(
        pairing: PairingInfo,
        preserveApprovalsAndPrompts: Bool = false,
        preserveReconnectAttempt: Bool = false
    ) {
        disconnect(
            autoReconnect: false,
            preserveApprovalsAndPrompts: preserveApprovalsAndPrompts,
            preserveReconnectAttempt: preserveReconnectAttempt
        )
        pairingInfo = pairing
        lastError = nil
        shouldReconnect = true
        if !preserveReconnectAttempt {
            reconnectBackoff.reset()
        }
        remoteSessionID = nil
        hasReceivedPairAccept = false

        if let keyData = Data(base64Encoded: pairing.macPub) {
            macPublicKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: keyData)
        }

        var components = URLComponents(string: pairing.relayURL.strippingTrailingSlash)
        guard components?.scheme?.lowercased() == "wss" else {
            lastError = "Relay URL must use wss:// (encrypted transport)."
            status = .error
            return
        }
        components?.path += "/\(pairing.deviceID)"
        components?.queryItems = [URLQueryItem(name: "role", value: "ios")]
        guard let url = components?.url else {
            lastError = "Invalid relay URL"
            return
        }

        let task = URLSession.shared.webSocketTask(with: url)
        webSocket = task
        task.resume()
        status = .connecting
        emitTelemetry(
            type: .connectRequested,
            status: "connecting",
            metadata: ["relay_host": pairing.relayURL]
        )

        listen()
        scheduleHandshake(for: connectionGeneration)
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        switch scenePhase {
        case .active:
            backgroundKeepalive.end()
            currentAppState = .foreground
            desiredStreamMode = .full
            if webSocket == nil, pairingInfo != nil {
                connect()
            } else {
                sendClientStateIfPossible()
                requestActiveTabRefreshIfPossible()
            }
            schedulePendingStateFetch(reason: "scene_active")
        case .background:
            backgroundKeepalive.begin()
            currentAppState = .background
            desiredStreamMode = .approvalsOnly
            outputFlushTask?.cancel()
            outputFlushTask = nil
            strippedOutputRefreshTask?.cancel()
            strippedOutputRefreshTask = nil
            sendClientStateIfPossible()
        case .inactive:
            break
        @unknown default:
            break
        }
    }

    func updateNotificationAuthorization(isGranted: Bool) {
        notificationsAuthorized = isGranted
        sendClientStateIfPossible()
    }

    func updatePushToken(_ token: String) {
        guard pushToken != token else { return }
        pushToken = token
        sendClientStateIfPossible()
    }

    func handlePushWake(userInfo: [AnyHashable: Any]) {
        suppressLocalNotificationsUntil = Date().addingTimeInterval(Self.pushNotificationSuppressionWindow)
        backgroundKeepalive.begin()
        currentAppState = .background
        desiredStreamMode = .approvalsOnly
        if webSocket == nil, pairingInfo != nil {
            connect()
        } else {
            sendClientStateIfPossible()
        }
        schedulePendingStateFetch(reason: "push_wake", force: true)
        emitTelemetry(
            type: .notificationOpened,
            status: "push_wake",
            metadata: userInfo.reduce(into: [String: String]()) { partial, entry in
                partial[String(describing: entry.key)] = String(describing: entry.value)
            }
        )
    }

    func disconnect(
        autoReconnect: Bool = false,
        preserveApprovalsAndPrompts: Bool = false,
        preserveReconnectAttempt: Bool = false
    ) {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        cancelHandshakeTasks()
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        isConnected = false
        status = .disconnected
        crypto = nil
        remoteSessionID = nil
        hasReceivedPairAccept = false
        nonceIOS = nil
        nonceMac = nil
        seqCounter = 1
        maxReceivedSeq = 0
        if !preserveReconnectAttempt {
            reconnectBackoff.reset()
        }
        connectionGeneration &+= 1
        tabs = []
        outputStore.reset()
        terminalRenderer.reset()
        outputFlushTask?.cancel()
        outputFlushTask = nil
        strippedOutputRefreshTask?.cancel()
        strippedOutputRefreshTask = nil
        telemetryBuffer.removeAll()
        liveActivityState = nil
        outputText = ""
        strippedOutputText = ""
        if !preserveApprovalsAndPrompts {
            pendingInteractivePrompts = []
            pendingApprovalResponses.removeAll(keepingCapacity: true)
            approvalResponsesInFlight.removeAll(keepingCapacity: true)
        }
        backgroundKeepalive.end()
        if #available(iOS 16.1, *) {
            RemoteLiveActivityManager.shared.update(with: nil)
        }
        if !autoReconnect {
            lastError = nil
            if !preserveApprovalsAndPrompts {
                pendingApprovals = []
            }
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
        refreshVisibleOutput(prioritizeStrippedOutput: true)
        terminalRenderer.setActiveTab(tabID)
        emitTelemetry(type: .tabSwitched, tabID: tabID, tabTitle: tabTitle(for: tabID))
        sendJSON(TabSwitchPayload(tabID: tabID), type: .tabSwitch)
    }

    // MARK: - Approvals

    func respondToApproval(requestID: String, approved: Bool) {
        guard let idx = pendingApprovals.firstIndex(where: { $0.requestID == requestID }) else { return }
        guard !pendingApprovals[idx].responseState.isBusy else { return }

        pendingApprovals[idx].responseState = .queued(approved)
        pendingApprovalResponses[requestID] = approved
        backgroundKeepalive.begin()
        flushPendingApprovalResponses()
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

        guard sendInteractivePromptResponse(option.response, to: prompt.tabID) else {
            return false
        }

        pendingInteractivePrompts.remove(at: promptIndex)
        RemoteNotificationScheduler.removeInteractivePromptNotifications(promptIDs: [prompt.id])
        return true
    }

    @discardableResult
    func respondToInteractivePrompt(promptID: String, customText: String) -> Bool {
        guard let promptIndex = pendingInteractivePrompts.firstIndex(where: { $0.id == promptID }) else {
            return false
        }

        let trimmed = customText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

        let prompt = pendingInteractivePrompts[promptIndex]
        guard sendInput("\u{1B}", appendNewline: false, to: prompt.tabID, allowUnlistedTab: true) else {
            return false
        }
        guard sendInteractivePromptResponse(trimmed + "\r", to: prompt.tabID) else {
            return false
        }

        pendingInteractivePrompts.remove(at: promptIndex)
        RemoteNotificationScheduler.removeInteractivePromptNotifications(promptIDs: [prompt.id])
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
            switch result {
            case .failure(let error):
                Task { @MainActor [weak self] in
                    guard let self, self.connectionGeneration == generation else { return }
                    log.error("WebSocket receive failed: \(error.localizedDescription)")
                    self.handleDisconnect(reason: error.localizedDescription)
                }
            case .success(let msg):
                let data: Data
                switch msg {
                case .data(let frameData):
                    data = frameData
                case .string(let text):
                    data = Data(text.utf8)
                @unknown default:
                    Task { @MainActor [weak self] in
                        guard let self, self.connectionGeneration == generation else { return }
                        self.listen()
                    }
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self, self.connectionGeneration == generation else { return }
                    let crypto = self.crypto
                    let signpostID = OSSignpostID(log: perfLog)
                    os_signpost(
                        .begin,
                        log: perfLog,
                        name: "RemoteFrameProcess",
                        signpostID: signpostID,
                        "bytes=%{public}d",
                        data.count
                    )
                    let processed: RemoteProcessedFrameResult
                    if data.count > Self.frameOffloadThreshold {
                        processed = await Task.detached(priority: .userInitiated) {
                            RemoteFrameProcessor.process(data, crypto: crypto)
                        }.value
                        guard self.connectionGeneration == generation else { return }
                    } else {
                        processed = RemoteFrameProcessor.process(data, crypto: crypto)
                    }
                    self.applyProcessedFrame(processed, signpostID: signpostID)
                    if self.frameRateLimiter.allow() {
                        self.listen()
                    } else {
                        // Suspected flood: read more slowly instead of dropping
                        // data, applying backpressure to a hostile relay.
                        self.noteFrameRateThrottle()
                        Task { @MainActor [weak self] in
                            try? await Task.sleep(for: .milliseconds(50))
                            guard let self, self.connectionGeneration == generation else { return }
                            self.listen()
                        }
                    }
                }
            }
        }
    }

    private func handleDisconnect(reason: String? = nil) {
        let wasConnected = isConnected
        cancelHandshakeTasks()
        isConnected = false
        status = .disconnected
        crypto = nil

        if wasConnected || reason != nil {
            emitTelemetry(type: .disconnected, status: "disconnected", message: reason)
        }

        guard shouldReconnect, reconnectBackoff.hasRemainingAttempts else {
            if !reconnectBackoff.hasRemainingAttempts {
                lastError = "Reconnect limit reached (\(Self.maxReconnectAttempts) attempts)"
                status = .connectionFailed
            }
            return
        }
        guard let delay = reconnectBackoff.nextDelay() else { return }
        status = .reconnecting(attempt: reconnectBackoff.attempt, max: Self.maxReconnectAttempts)
        emitTelemetry(
            type: .reconnectScheduled,
            status: "scheduled",
            message: reason,
            metadata: [
                "attempt": String(reconnectBackoff.attempt),
                "delay_seconds": String(format: "%.0f", delay)
            ]
        )

        reconnectTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self, let pairing = self.pairingInfo else { return }
            self.connect(
                pairing: pairing,
                preserveApprovalsAndPrompts: true,
                preserveReconnectAttempt: true
            )
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

                if attempt > 0, self.status == .connecting {
                    self.status = .waitingForMac
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
            self.status = .connectionTimedOut
            self.lastError = "No response from your Mac. Make sure Chau7 is open, Remote is enabled, and the pairing payload is still current."
            self.emitTelemetry(
                type: .errorReceived,
                status: "timeout",
                message: self.lastError
            )
        }
    }

    private func noteFrameRateThrottle() {
        let now = Date()
        if let last = lastFrameThrottleLogAt, now.timeIntervalSince(last) < 5 { return }
        lastFrameThrottleLogAt = now
        log.warning("Inbound frame rate throttled (possible relay flood)")
    }

    private func cancelHandshakeTasks() {
        handshakeRetryTask?.cancel()
        handshakeRetryTask = nil
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
    }

    // MARK: - Frame Dispatch

    private func applyProcessedFrame(_ processed: RemoteProcessedFrameResult, signpostID: OSSignpostID) {
        switch processed {
        case .decodeFailed(let byteCount):
            os_signpost(
                .end,
                log: perfLog,
                name: "RemoteFrameProcess",
                signpostID: signpostID,
                "decode_failed bytes=%{public}d",
                byteCount
            )
            log.warning("Failed to decode frame (\(byteCount) bytes)")
            emitTelemetry(
                type: .frameDecodeFailed,
                status: "decode_failed",
                metadata: ["frame_bytes": String(byteCount)]
            )
            return
        case .decryptFailed(let frameType):
            os_signpost(
                .end,
                log: perfLog,
                name: "RemoteFrameProcess",
                signpostID: signpostID,
                "decrypt_failed type=%{public}d",
                Int(frameType)
            )
            log.warning("Decryption failed for frame type=\(frameType)")
            emitTelemetry(
                type: .frameDecryptFailed,
                status: "decrypt_failed",
                metadata: ["frame_type": String(frameType)]
            )
            return
        case .success(let frame, let payload):
            os_signpost(
                .end,
                log: perfLog,
                name: "RemoteFrameProcess",
                signpostID: signpostID,
                "type=%{public}d payload=%{public}d",
                Int(frame.type),
                payload.count
            )
            handleProcessedFrame(frame, payload: payload)
        }
    }

    private func handleProcessedFrame(_ frame: RemoteFrame, payload: Data) {
        let frameType = RemoteFrameType(rawValue: frame.type)
        let isEncrypted = frame.flags & RemoteFrame.flagEncrypted != 0

        // Encryption enforcement: only the cleartext handshake frames may arrive
        // unencrypted. Every other known type carries session data and MUST be
        // encrypted once a crypto session exists — otherwise a hostile relay
        // could inject a plaintext .sessionReady / .approvalRequest / .output to
        // bypass both AEAD decryption and the replay counter below. Drop them.
        let cleartextHandshakeTypes: Set<RemoteFrameType> = [.hello, .pairAccept, .pairReject]
        if let frameType, !cleartextHandshakeTypes.contains(frameType) {
            guard isEncrypted, crypto != nil else {
                log.warning("Dropping unencrypted non-handshake frame type=\(frame.type)")
                return
            }
        }

        // Replay protection for encrypted frames: the peer uses a single
        // monotonic sequence counter, and the WebSocket delivers in order, so a
        // non-increasing seq means a duplicate/replayed frame from a hostile
        // relay. Unencrypted handshake frames (hello/pair*) are exempt, matching
        // the macOS relay client (see agent.go maxReceivedSeq).
        if isEncrypted {
            guard frame.seq > maxReceivedSeq else {
                log.warning("Dropping replayed/stale frame type=\(frame.type) seq=\(frame.seq) max=\(self.maxReceivedSeq)")
                return
            }
            maxReceivedSeq = frame.seq
        }

        switch frameType {
        case .hello:           handleHello(payload)
        case .pairAccept:      handlePairAccept(payload)
        case .pairReject:      handlePairReject(payload)
        case .sessionReady:
            isConnected = true
            status = .sessionReady
            lastError = nil
            cancelHandshakeTasks()
            flushPendingURLActions()
            schedulePendingStateFetch(reason: "session_ready", force: true)
        case .tabList:         handleTabList(payload)
        case .cachedTabList:   handleCachedTabList(payload)
        case .activityState:   handleActivityState(payload)
        case .activityCleared: clearActivityState()
        case .interactivePromptList: handleInteractivePromptList(payload)
        case .clientState:
            break
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
        RemotePairingStore.saveMacPublicKey(keyData)
        persistTrustedIdentity(for: msg)
        // If we fell back from trust-based reconnect to explicit pairing, any
        // provisional session state must be discarded before re-deriving keys.
        crypto = nil
        isConnected = false
        remoteSessionID = nil
        nonceMac = nil
        nonceIOS = CryptoUtils.randomBytes(count: 16)
        seqCounter = 1
        maxReceivedSeq = 0
        sendHello()
        establishSessionIfPossible()
    }

    private func handlePairReject(_ data: Data) {
        if let msg = try? RemoteJSON.decoder.decode(PairRejectPayload.self, from: data) {
            lastError = "Pairing rejected: \(msg.reason)"
        } else {
            lastError = "Pairing rejected"
        }
        status = .pairingRejected
        shouldReconnect = false
    }

    private func handleError(_ data: Data) {
        let (errorText, code): (String, String)
        if let msg = try? RemoteJSON.decoder.decode(RemoteErrorPayload.self, from: data) {
            (errorText, code) = ("\(msg.code): \(msg.message)", msg.code)
        } else if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            (errorText, code) = (text, "error")
        } else {
            status = .error
            return
        }
        lastError = errorText
        emitTelemetry(type: .errorReceived, status: code, message: errorText)
        status = .error
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
        activeTabID = msg.tabs.first(where: \.isActive)?.tabID ?? msg.tabs.first?.tabID ?? 0
        let visibleTabIDs = Set(msg.tabs.map(\.tabID))
        outputStore.retainVisibleTabs(visibleTabIDs)
        terminalRenderer.retainVisibleTabs(visibleTabIDs)
        pendingInteractivePrompts.removeAll { !visibleTabIDs.contains($0.tabID) }
        refreshVisibleOutput(prioritizeStrippedOutput: true)
        terminalRenderer.setActiveTab(activeTabID)
    }

    private func handleActivityState(_ data: Data) {
        do {
            let state = try RemoteJSON.decoder.decode(RemoteActivityState.self, from: data)
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
        applyPendingInteractivePrompts(payload.prompts)
    }

    /// Only ingest terminal frames when foregrounded and full-streaming is
    /// selected. Single source for the ingest guards below.
    private var isStreamingTerminalOutput: Bool {
        currentAppState == .foreground && desiredStreamMode == .full
    }

    private func appendOutput(_ data: Data, tabID: UInt32) {
        guard isStreamingTerminalOutput else { return }
        let signpostID = OSSignpostID(log: perfLog)
        os_signpost(
            .begin,
            log: perfLog,
            name: "RemoteAppendOutput",
            signpostID: signpostID,
            "bytes=%{public}d",
            data.count
        )
        let resolvedTabID = resolvedTabID(for: tabID)
        outputStore.append(data, to: resolvedTabID)
        terminalRenderer.appendOutput(data, for: resolvedTabID)

        if outputStore.pendingByteCount(for: resolvedTabID) >= RemoteOutputTuning.maxPendingBytesPerTab {
            flushPendingOutput(for: resolvedTabID)
        } else {
            scheduleOutputFlush()
        }
        os_signpost(
            .end,
            log: perfLog,
            name: "RemoteAppendOutput",
            signpostID: signpostID,
            "tab=%{public}u pending=%{public}d",
            resolvedTabID,
            outputStore.pendingByteCount(for: resolvedTabID)
        )
    }

    private func storeSnapshot(_ data: Data, tabID: UInt32) {
        guard isStreamingTerminalOutput else { return }
        let resolvedTabID = resolvedTabID(for: tabID)
        outputStore.replaceSnapshot(data, for: resolvedTabID)
        terminalRenderer.replaceSnapshot(for: resolvedTabID)
        if resolvedTabID == activeTabID || activeTabID == 0 {
            refreshVisibleOutput(prioritizeStrippedOutput: true)
        }
    }

    private func storeGridSnapshot(_ data: Data, tabID: UInt32) {
        guard isStreamingTerminalOutput else { return }
        let resolvedTabID = resolvedTabID(for: tabID)
        guard let renderState = RemoteTerminalRenderStateDecoder.decodeGridSnapshot(data) else {
            return
        }
        terminalRenderer.replaceGridSnapshot(renderState, for: resolvedTabID)
    }

    private func handleApprovalRequest(_ data: Data) {
        guard let msg: ApprovalRequestPayload = decodePayload(data, as: ApprovalRequestPayload.self, context: "handleApprovalRequest") else { return }
        upsertPendingApproval(msg)
        emitTelemetry(
            type: .approvalReceived,
            status: "pending",
            message: msg.flaggedCommand,
            metadata: ["request_id": msg.requestID]
        )
    }

    // MARK: - Session Establishment

    private func establishSessionIfPossible() {
        guard crypto == nil, let nonceIOS, let nonceMac else { return }
        guard let macPub = macPublicKey ?? RemotePairingStore.loadMacPublicKey() else {
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
        reconnectBackoff.reset()
        isConnected = true
        cancelHandshakeTasks()
        let sessionID = CryptoUtils.randomBytes(count: 8).base64EncodedString()
        remoteSessionID = sessionID
        sendJSON(SessionReadyPayload(sessionID: sessionID), type: .sessionReady, encrypt: true)
        status = .encrypted
        emitTelemetry(type: .sessionEncrypted, status: "encrypted")
        flushBufferedTelemetryEvents()
        sendClientStateIfPossible()
        flushPendingApprovalResponses()
        schedulePendingStateFetch(reason: "session_encrypted", force: true)
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
            iosName: deviceName
        ), type: .pairRequest, encrypt: false)
        if recordTelemetry {
            emitTelemetry(type: .pairRequestSent, status: "pairing")
        }
    }

    private func sendJSON<T: Encodable>(_ payload: T, type: RemoteFrameType, encrypt: Bool = true) {
        guard let data = try? RemoteJSON.encoder.encode(payload) else {
            log.error("Failed to encode \(String(describing: T.self)) for frame type \(type.rawValue)")
            return
        }
        if encrypt {
            _ = sendEncrypted(type: type, tabID: 0, payload: data)
        } else {
            _ = send(RemoteFrame(type: type.rawValue, tabID: 0, seq: nextSeq(), payload: data))
        }
    }

    private func sendApprovalResponse(
        requestID: String,
        approved: Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let payload = ApprovalResponsePayload(requestID: requestID, approved: approved)
        guard let data = try? RemoteJSON.encoder.encode(payload) else {
            log.error("Failed to encode ApprovalResponsePayload for request \(requestID)")
            completion(false)
            return
        }
        guard sendEncrypted(type: .approvalResponse, tabID: 0, payload: data, completion: completion) else {
            completion(false)
            return
        }
    }

    @discardableResult
    private func sendEncrypted(
        type: RemoteFrameType,
        tabID: UInt32,
        payload: Data,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) -> Bool {
        guard let crypto else { return false }
        let frame = RemoteFrame(type: type.rawValue, tabID: tabID, seq: nextSeq(), payload: payload)
        guard let encrypted = try? crypto.encrypt(frame: frame) else {
            log.error("Encryption failed for frame type \(type.rawValue)")
            return false
        }
        return send(encrypted, completion: completion)
    }

    @discardableResult
    private func send(
        _ frame: RemoteFrame,
        completion: (@MainActor (Bool) -> Void)? = nil
    ) -> Bool {
        guard webSocket != nil else { return false }
        webSocket?.send(.data(frame.encode())) { error in
            if let error {
                log.error("WebSocket send failed: \(error.localizedDescription)")
                Task { @MainActor [weak self] in
                    self?.emitTelemetry(type: .sendFailed, status: "send_failed", message: error.localizedDescription)
                    completion?(false)
                }
            } else if let completion {
                Task { @MainActor in
                    completion(true)
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
        case .approve(let requestID, let tabID), .deny(let requestID, let tabID):
            if let tabID {
                guard tabs.contains(where: { $0.tabID == tabID }) else { return false }
                switchTab(tabID)
            }
            guard pendingApprovals.contains(where: { $0.requestID == requestID }) else { return false }
            let approved = if case .approve = action { true } else { false }
            respondToApproval(requestID: requestID, approved: approved)
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

    private func approvalRequest(for requestID: String) -> ApprovalRequest? {
        pendingApprovals.first(where: { $0.requestID == requestID })
    }

    private func updateApprovalResponseState(
        requestID: String,
        transform: (ApprovalResponseState) -> ApprovalResponseState
    ) {
        guard let idx = pendingApprovals.firstIndex(where: { $0.requestID == requestID }) else { return }
        pendingApprovals[idx].responseState = transform(pendingApprovals[idx].responseState)
    }

    private func flushPendingApprovalResponses() {
        guard !pendingApprovalResponses.isEmpty else { return }

        guard crypto != nil, webSocket != nil else {
            status = .reconnectingToSendApproval
            if let pairing = pairingInfo, webSocket == nil {
                connect(
                    pairing: pairing,
                    preserveApprovalsAndPrompts: true,
                    preserveReconnectAttempt: true
                )
            }
            return
        }

        let queued = pendingApprovalResponses
        for (requestID, approved) in queued {
            guard approvalResponsesInFlight.contains(requestID) == false else { continue }
            guard approvalRequest(for: requestID) != nil else {
                pendingApprovalResponses.removeValue(forKey: requestID)
                continue
            }

            approvalResponsesInFlight.insert(requestID)
            updateApprovalResponseState(requestID: requestID) { _ in .sending(approved) }

            sendApprovalResponse(requestID: requestID, approved: approved) { [weak self] success in
                guard let self else { return }
                self.approvalResponsesInFlight.remove(requestID)
                guard self.pendingApprovalResponses[requestID] == approved else { return }

                if success {
                    self.pendingApprovalResponses.removeValue(forKey: requestID)
                    self.completeApprovalResponse(requestID: requestID, approved: approved)
                    if self.pendingApprovalResponses.isEmpty {
                        self.backgroundKeepalive.end()
                    }
                } else {
                    self.updateApprovalResponseState(requestID: requestID) { _ in .queued(approved) }
                    self.lastError = "Approval response was not delivered. Chau7 will retry when the connection is ready."
                    self.status = .approvalQueued
                    if let pairing = self.pairingInfo, self.webSocket == nil {
                        self.connect(
                            pairing: pairing,
                            preserveApprovalsAndPrompts: true,
                            preserveReconnectAttempt: true
                        )
                    }
                }
            }
        }
    }

    private func completeApprovalResponse(requestID: String, approved: Bool) {
        guard let idx = pendingApprovals.firstIndex(where: { $0.requestID == requestID }) else { return }
        let request = pendingApprovals.remove(at: idx)

        approvalHistory.append(ApprovalHistoryEntry(
            command: request.command,
            flaggedCommand: request.flaggedCommand,
            approved: approved,
            timestamp: Date()
        ))
        if approvalHistory.count > Self.maxHistory {
            approvalHistory.removeSubrange(0 ..< (approvalHistory.count - Self.maxHistory))
        }

        emitTelemetry(
            type: .approvalResponded,
            status: approved ? "approved" : "denied",
            message: request.flaggedCommand,
            metadata: ["request_id": requestID]
        )
        RemoteNotificationScheduler.removeApprovalNotifications(requestIDs: [requestID])
    }

    // MARK: - Input gating

    private func canSendInput(to tabID: UInt32) -> Bool {
        canSendInput(to: tabID, allowUnlistedTab: false)
    }

    private func canSendInput(to tabID: UInt32, allowUnlistedTab: Bool) -> Bool {
        guard crypto != nil, webSocket != nil, tabID != 0 else { return false }
        return allowUnlistedTab || tabs.contains(where: { $0.tabID == tabID })
    }

    @discardableResult
    private func sendInteractivePromptResponse(_ response: String, to tabID: UInt32) -> Bool {
        let normalizedResponse = response
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n", with: "\r")
        guard !normalizedResponse.isEmpty else { return false }

        if normalizedResponse.hasSuffix("\r") {
            let body = String(normalizedResponse.dropLast())
            if !body.isEmpty, !sendInput(body, appendNewline: false, to: tabID, allowUnlistedTab: true) {
                return false
            }
            return sendInput("\r", appendNewline: false, to: tabID, allowUnlistedTab: true)
        }

        return sendInput(normalizedResponse, appendNewline: false, to: tabID, allowUnlistedTab: true)
    }

    @discardableResult
    private func sendInput(_ text: String, appendNewline: Bool, to tabID: UInt32, allowUnlistedTab: Bool = false) -> Bool {
        guard !text.isEmpty else { return false }
        guard crypto != nil, webSocket != nil else {
            reportBlockedInput("Input not sent because the encrypted session is not ready yet.")
            return false
        }
        guard canSendInput(to: tabID, allowUnlistedTab: allowUnlistedTab) else {
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
        guard let storedKey = RemotePairingStore.loadMacPublicKey(),
              let trustedIdentity = RemotePairingStore.loadTrustedIdentity() else {
            return false
        }
        let currentIOSPub = iosKey.publicKey.rawRepresentation.base64EncodedString()
        return storedKey.rawRepresentation.base64EncodedString() == pairing.macPub &&
            trustedIdentity.deviceID == pairing.deviceID &&
            trustedIdentity.macPub == pairing.macPub &&
            trustedIdentity.iosPub == currentIOSPub
    }

    // MARK: - Pairing Persistence

    private func persistTrustedIdentity(for accept: PairAcceptPayload) {
        guard let pairing = pairingInfo else { return }
        RemotePairingStore.saveTrustedIdentity(
            TrustedPairingIdentity(
                deviceID: pairing.deviceID,
                macPub: accept.macPub,
                iosPub: iosKey.publicKey.rawRepresentation.base64EncodedString()
            )
        )
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

    private func refreshVisibleOutput(prioritizeStrippedOutput: Bool = false) {
        let visibleOutput = outputStore.visibleOutput(for: activeTabID)
        let outputChanged = visibleOutput != outputText
        outputText = visibleOutput

        if prioritizeStrippedOutput || outputChanged {
            scheduleStrippedOutputRefresh(immediate: prioritizeStrippedOutput)
        }
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

    private var shouldSuppressLocalNotifications: Bool {
        guard let until = suppressLocalNotificationsUntil else { return false }
        if until <= Date() {
            suppressLocalNotificationsUntil = nil
            return false
        }
        return true
    }

    private var canReceiveRemotePushNotifications: Bool {
        notificationsAuthorized && pushToken != nil && currentPushEnvironment() != nil
    }

    private func schedulePendingStateFetch(reason: String, force: Bool = false) {
        guard pairingInfo != nil else { return }
        if !force {
            if pendingStateFetchTask != nil {
                return
            }
            if let lastPendingStateFetchAt,
               Date().timeIntervalSince(lastPendingStateFetchAt) < Self.pendingStateFetchMinimumInterval {
                return
            }
        }

        pendingStateFetchTask = Task { @MainActor [weak self] in
            defer {
                self?.pendingStateFetchTask = nil
                self?.lastPendingStateFetchAt = Date()
            }
            await self?.fetchPendingState(reason: reason)
        }
    }

    private var shouldScheduleLocalApprovalNotification: Bool {
        guard !shouldSuppressLocalNotifications else { return false }
        guard currentAppState != .foreground else { return false }
        return !canReceiveRemotePushNotifications
    }

    private func fetchPendingState(reason: String) async {
        guard let request = pendingStateRequest() else { return }
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return }
            guard httpResponse.statusCode == 200 else {
                log.warning("Pending state fetch failed: status \(httpResponse.statusCode)")
                return
            }
            let payload = try RemoteJSON.decoder.decode(RemotePendingStatePayload.self, from: data)
            applyPendingApprovals(payload.approvals)
            applyPendingInteractivePrompts(payload.interactivePrompts)
            emitTelemetry(type: .remoteStateFetched, status: reason)
        } catch {
            log.error("Pending state fetch failed (\(reason)): \(error.localizedDescription)")
        }
    }

    private func pendingStateRequest() -> URLRequest? {
        guard let pairing = pairingInfo else { return nil }
        guard var components = Self.relayAPIURLComponents(from: pairing.relayURL) else {
            return nil
        }
        components.path += "/pending/\(pairing.deviceID)"
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.cachePolicy = .reloadIgnoringLocalCacheData
        return request
    }

    private static func relayAPIURLComponents(from relayURL: String) -> URLComponents? {
        var trimmed = relayURL.strippingTrailingSlash
        if trimmed.hasSuffix("/connect") {
            trimmed.removeLast("/connect".count)
        }
        guard var components = URLComponents(string: trimmed) else {
            return nil
        }
        // Only wss is permitted (mirrors the connect-time guard); map it to https
        // for the REST API. Reject ws/http/anything else so a legacy plaintext
        // pairing can't fetch pending approvals (commands + directories) over
        // cleartext http — the REST path was the one place wss wasn't enforced.
        guard components.scheme?.lowercased() == "wss" else {
            return nil
        }
        components.scheme = "https"
        return components
    }

    private func applyPendingApprovals(_ payloads: [ApprovalRequestPayload]) {
        let existingStates = Dictionary(uniqueKeysWithValues: pendingApprovals.map { ($0.requestID, $0.responseState) })
        let nextApprovals = payloads.map { payload in
            approvalRequest(from: payload, responseState: existingStates[payload.requestID] ?? .idle)
        }

        let previousApprovalIDs = Set(pendingApprovals.map(\.requestID))
        let nextApprovalIDs = Set(nextApprovals.map(\.requestID))
        pendingApprovals = nextApprovals

        let removedNotificationIDs = previousApprovalIDs.subtracting(nextApprovalIDs)
        RemoteNotificationScheduler.removeApprovalNotifications(requestIDs: Array(removedNotificationIDs))

        for payload in payloads where !previousApprovalIDs.contains(payload.requestID) {
            scheduleApprovalNotificationIfAllowed(for: payload)
        }
    }

    private func upsertPendingApproval(_ payload: ApprovalRequestPayload) {
        let approval = approvalRequest(
            from: payload,
            responseState: pendingApprovals.first(where: { $0.requestID == payload.requestID })?.responseState ?? .idle
        )
        let isNewApproval = !pendingApprovals.contains(where: { $0.requestID == payload.requestID })
        if let existingIndex = pendingApprovals.firstIndex(where: { $0.requestID == payload.requestID }) {
            pendingApprovals[existingIndex] = approval
        } else {
            pendingApprovals.append(approval)
        }

        guard isNewApproval else { return }
        scheduleApprovalNotificationIfAllowed(for: payload)
    }

    private func scheduleApprovalNotificationIfAllowed(for payload: ApprovalRequestPayload) {
        guard shouldScheduleLocalApprovalNotification else { return }
        RemoteNotificationScheduler.scheduleApproval(
            for: payload,
            redactDetails: AppSettings.hideSensitiveNotifications
        )
    }

    private func approvalRequest(from payload: ApprovalRequestPayload, responseState: ApprovalResponseState) -> ApprovalRequest {
        ApprovalRequest(
            requestID: payload.requestID,
            command: payload.command,
            flaggedCommand: payload.flaggedCommand,
            tabTitle: payload.tabTitle,
            toolName: payload.toolName,
            projectName: payload.projectName,
            branchName: payload.branchName,
            currentDirectory: payload.currentDirectory,
            recentCommand: payload.recentCommand,
            contextNote: payload.contextNote,
            sessionID: payload.sessionID,
            timestamp: Self.parseRemoteTimestamp(payload.timestamp),
            responseState: responseState
        )
    }

    private func applyPendingInteractivePrompts(_ nextPrompts: [RemoteInteractivePrompt]) {
        let previousPromptIDs = Set(pendingInteractivePrompts.map(\.id))
        let nextPromptIDs = Set(nextPrompts.map(\.id))

        pendingInteractivePrompts = nextPrompts

        let removedPromptIDs = previousPromptIDs.subtracting(nextPromptIDs)
        RemoteNotificationScheduler.removeInteractivePromptNotifications(promptIDs: Array(removedPromptIDs))

        for prompt in nextPrompts where !previousPromptIDs.contains(prompt.id) {
            if shouldScheduleLocalApprovalNotification {
                RemoteNotificationScheduler.scheduleInteractivePrompt(
                    for: prompt,
                    redactDetails: AppSettings.hideSensitiveNotifications
                )
            }
        }
    }

    private func currentPushEnvironment() -> RemotePushEnvironment? {
        #if DEBUG
        .development
        #else
        .production
        #endif
    }

    private static let iso8601Formatter = ISO8601DateFormatter()

    private static func parseRemoteTimestamp(_ value: String) -> Date {
        iso8601Formatter.date(from: value) ?? Date()
    }

    private func handleBackgroundTaskExpiration() {
        suppressLocalNotificationsUntil = Date().addingTimeInterval(Self.pushNotificationSuppressionWindow)
        disconnect(autoReconnect: false, preserveApprovalsAndPrompts: true)
        status = .backgroundSuspended
    }

    private func sendClientStateIfPossible() {
        guard crypto != nil else { return }
        let payload = RemoteClientStatePayload(
            appState: currentAppState,
            streamMode: desiredStreamMode,
            pushToken: pushToken,
            pushTopic: Bundle.main.bundleIdentifier,
            pushEnvironment: currentPushEnvironment(),
            notificationsAuthorized: notificationsAuthorized
        )
        sendJSON(payload, type: .clientState, encrypt: true)
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
        guard isStreamingTerminalOutput else {
            if tabID == nil {
                outputFlushTask?.cancel()
                outputFlushTask = nil
            }
            return
        }
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

    private func scheduleStrippedOutputRefresh(immediate: Bool) {
        strippedOutputRefreshTask?.cancel()

        let sourceText = outputText
        guard !sourceText.isEmpty else {
            strippedOutputText = ""
            strippedOutputRefreshTask = nil
            return
        }

        if immediate || sourceText.utf8.count <= 4_096 {
            let signpostID = OSSignpostID(log: perfLog)
            os_signpost(.begin, log: perfLog, name: "ANSIStrip", signpostID: signpostID)
            strippedOutputText = ANSIStripper.strip(sourceText)
            os_signpost(
                .end,
                log: perfLog,
                name: "ANSIStrip",
                signpostID: signpostID,
                "bytes=%{public}d",
                sourceText.utf8.count
            )
            strippedOutputRefreshTask = nil
            return
        }

        strippedOutputRefreshTask = Task(priority: .utility) { [weak self, sourceText] in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            let signpostID = OSSignpostID(log: perfLog)
            os_signpost(.begin, log: perfLog, name: "ANSIStrip", signpostID: signpostID)
            let stripped = ANSIStripper.strip(sourceText)
            await MainActor.run {
                guard let self, !Task.isCancelled else { return }
                os_signpost(
                    .end,
                    log: perfLog,
                    name: "ANSIStrip",
                    signpostID: signpostID,
                    "bytes=%{public}d",
                    sourceText.utf8.count
                )
                self.strippedOutputRefreshTask = nil
                guard self.outputText == sourceText else {
                    self.scheduleStrippedOutputRefresh(immediate: false)
                    return
                }
                self.strippedOutputText = stripped
            }
        }
    }

    private func requestActiveTabRefreshIfPossible() {
        guard crypto != nil, activeTabID != 0 else { return }
        sendJSON(TabSwitchPayload(tabID: activeTabID), type: .tabSwitch)
    }

    private func decodePayload<T: Decodable>(_ data: Data, as type: T.Type, context: String) -> T? {
        do {
            return try RemoteJSON.decoder.decode(type, from: data)
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
            deviceName: deviceName,
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
            telemetryBuffer.append(event)
            return
        }

        if event.sessionID == nil {
            event.sessionID = remoteSessionID
        }

        guard let data = try? RemoteJSON.encoder.encode(event) else { return }
        sendEncrypted(type: .remoteTelemetry, tabID: event.tabID ?? 0, payload: data)
    }

    private func flushBufferedTelemetryEvents() {
        guard crypto != nil, !telemetryBuffer.isEmpty else { return }
        var pendingEvents = telemetryBuffer.drain()
        for index in pendingEvents.indices {
            enqueueOrSendTelemetryEvent(&pendingEvents[index])
        }
    }

    private func tabTitle(for tabID: UInt32) -> String? {
        tabs.first(where: { $0.tabID == tabID })?.title
    }
}
