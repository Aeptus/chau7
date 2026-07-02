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
    private(set) var tabs: [RemoteTab] = [] {
        didSet {
            guard oldValue.map(\.tabID) != tabs.map(\.tabID) else { return }
            DiagnosticsLog.shared.info(.tab, "Tab list updated", [
                "count": String(tabs.count),
                "active_tab": String(activeTabID)
            ])
        }
    }
    private(set) var isConnected = false {
        didSet {
            guard oldValue != isConnected else { return }
            DiagnosticsLog.shared.info(.connection, "Connection state changed", [
                "connected": isConnected ? "true" : "false"
            ])
        }
    }
    private(set) var status: RemoteConnectionStatus = .disconnected {
        didSet {
            guard oldValue != status else { return }
            DiagnosticsLog.shared.info(.connection, "Status changed", ["status": status.displayText])
        }
    }
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

    /// Socket + generation counter + strictly-ordered receive pump + inbound
    /// rate limiting (C6 extraction from this class).
    @ObservationIgnored private let transport = RemoteTransport()
    /// Crypto-session state machine: key material, handshake nonces, seq
    /// counter, replay guard (C6 extraction from this class).
    @ObservationIgnored private let session: RemoteSessionController
    /// Approval-response ledger: queued answers, in-flight sends, and send
    /// outcomes (C7 extraction from this class).
    @ObservationIgnored private let approvalCoordinator = ApprovalCoordinator()
    /// Single merge authority for approvals/prompts across the WS and REST
    /// channels (NF-1 fix: stale snapshots can no longer clobber live state).
    @ObservationIgnored private var pendingReconciler = PendingStateReconciler()
    private var crypto: RemoteCryptoSession? { session.crypto }
    private let deviceName = UIDevice.current.name
    private var reconnectBackoff = RemoteReconnectBackoff()
    private var reconnectTask: Task<Void, Never>?
    private var handshakeRetryTask: Task<Void, Never>?
    private var handshakeTimeoutTask: Task<Void, Never>?
    private var shouldReconnect = false
    private var outputStore = RemoteTerminalOutputStore()
    private var outputFlushTask: Task<Void, Never>?
    private var strippedOutputRefreshTask: Task<Void, Never>?
    private var remoteSessionID: String?
    private var telemetryBuffer = RemoteTelemetryBuffer(maxEvents: RemoteClient.maxBufferedTelemetryEvents)
    /// Per-event failed-send attempts (bounded retry for the drain-on-success path).
    private var telemetrySendAttempts: [String: Int] = [:]
    private var pendingURLActions: [RemoteActivityURLAction] = []
    private var currentAppState: RemoteClientAppState = .foreground
    private var desiredStreamMode: RemoteClientStreamMode = .full
    private var pushToken: String?
    private(set) var notificationsAuthorized = false
    private let backgroundKeepalive = BackgroundKeepalive(name: "ch7.remote.approvals")
    /// IDs (approval request IDs / prompt IDs) already delivered to the user
    /// as a remote push — local notifications for exactly these are skipped.
    /// Replaces the old 15s wall-clock suppression window, which was
    /// timing-dependent and could mute unrelated notifications.
    private var pushDeliveredIDs: [String] = []
    private static let pushDeliveredIDCap = 128
    /// Interactive prompts the user just answered or dismissed, keyed by prompt
    /// id → when it was suppressed. The Mac keeps re-pushing a prompt until its
    /// terminal actually advances, so without this the just-handled prompt
    /// reappears on the next authoritative list. Suppression is dropped once the
    /// Mac stops listing the prompt (the tab cleared) or after a safety timeout.
    private var suppressedPromptIDs: [String: Date] = [:]
    private var pendingStateFetchTask: Task<Void, Never>?
    private var lastPendingStateFetchAt: Date?
    let terminalRenderer = RemoteTerminalRendererStore()

    private static let maxHistory = 50
    private static let maxReconnectAttempts = RemoteReconnectBackoff.maxAttempts
    private static let maxBufferedTelemetryEvents = 100
    private static let handshakeRetryIntervalSeconds = 1.0
    private static let handshakeTimeoutSeconds = 12.0
    private static let repairFallbackAttempt = 3
    private static let pendingStateFetchMinimumInterval: TimeInterval = 1
    /// How long a just-answered/dismissed prompt stays hidden if the Mac keeps
    /// listing it (i.e. the terminal never advanced). After this the prompt is
    /// shown again so a still-pending action isn't lost forever.
    private static let promptSuppressionMaxAge: TimeInterval = 20
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
        session.iosKeyFingerprint
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
        session = RemoteSessionController(iosKey: RemotePairingStore.loadOrCreateIOSKey())
        pairingInfo = RemotePairingStore.loadPairing()

        backgroundKeepalive.onExpire = { [weak self] in
            self?.handleBackgroundTaskExpiration()
        }

        // The approval-notification-response bridge lives on the root view's
        // `.task` (structured, cancelled with the scene) instead of an
        // unstructured Task cancelled from a deinit that a static singleton
        // never runs.
        transport.onMessage = { [weak self] data, generation in
            await self?.processIncomingMessage(data, generation: generation)
        }
        transport.onFailure = { [weak self] error in
            self?.handleDisconnect(reason: error.localizedDescription)
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

        if let keyData = Data(base64Encoded: pairing.macPub) {
            _ = session.adoptMacPublicKey(keyData)
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

        // Carry the connect-scoped auth token in the Authorization header of the
        // upgrade request (never the query string). When no relay secret is
        // present, connect unauthenticated for backward compatibility.
        var request = URLRequest(url: url)
        if let token = RelayToken.make(pairing: pairing, role: "ios", scope: "connect") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        transport.open(request: request)
        status = .connecting
        emitTelemetry(
            type: .connectRequested,
            status: "connecting",
            metadata: ["relay_host": pairing.relayURL]
        )
        scheduleHandshake(for: transport.generation)
    }

    func handleScenePhase(_ scenePhase: ScenePhase) {
        DiagnosticsLog.shared.info(.lifecycle, "Scene phase changed", ["phase": String(describing: scenePhase)])
        switch scenePhase {
        case .active:
            DiagnosticsLog.shared.capturePerformanceSnapshot(reason: "scene_active")
            backgroundKeepalive.end()
            currentAppState = .foreground
            desiredStreamMode = .full
            if !transport.isOpen, pairingInfo != nil {
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
            // Persist diagnostics immediately so nothing is lost if the app
            // is suspended or terminated while backgrounded.
            DiagnosticsLog.shared.flush()
        case .inactive:
            // Transitional (app switcher, incoming call, lock animation):
            // keep the connection and stream mode, but persist diagnostics in
            // case the transition ends in suspension rather than .active.
            DiagnosticsLog.shared.flush()
        @unknown default:
            break
        }
    }

    func updateNotificationAuthorization(isGranted: Bool) {
        notificationsAuthorized = isGranted
        sendClientStateIfPossible()
    }

    /// Re-reads the system notification authorization so Settings reflects changes
    /// the user made in iOS Settings while the app was backgrounded.
    func refreshNotificationAuthorization() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
                || settings.authorizationStatus == .ephemeral
            Task { @MainActor [weak self] in
                guard let self, self.notificationsAuthorized != granted else { return }
                self.updateNotificationAuthorization(isGranted: granted)
            }
        }
    }

    func updatePushToken(_ token: String) {
        guard pushToken != token else { return }
        pushToken = token
        sendClientStateIfPossible()
    }

    func handlePushWake(userInfo: [AnyHashable: Any]) {
        // The push payload names exactly what it delivered — skip local
        // notifications for those IDs only (deterministic, not time-based).
        if let requestID = userInfo[RemoteNotificationID.UserInfoKey.requestID] as? String {
            recordPushDeliveredID(requestID)
        }
        if let promptID = userInfo[RemoteNotificationID.UserInfoKey.promptID] as? String {
            recordPushDeliveredID(promptID)
        }
        backgroundKeepalive.begin()
        currentAppState = .background
        desiredStreamMode = .approvalsOnly
        if !transport.isOpen, pairingInfo != nil {
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
        transport.close()
        isConnected = false
        status = .disconnected
        session.invalidateSession(clearHandshakeMaterial: true)
        remoteSessionID = nil
        if !preserveReconnectAttempt {
            reconnectBackoff.reset()
        }
        tabs = []
        outputStore.reset()
        terminalRenderer.reset()
        outputFlushTask?.cancel()
        outputFlushTask = nil
        strippedOutputRefreshTask?.cancel()
        strippedOutputRefreshTask = nil
        // Telemetry buffered before/through the disconnect survives to the
        // next session — connect() calls disconnect() first, so wiping here
        // routinely lost pre-session events on flaky connects (NF-9).
        liveActivityState = nil
        outputText = ""
        strippedOutputText = ""
        if !preserveApprovalsAndPrompts {
            pendingInteractivePrompts = []
            approvalCoordinator.reset()
            pendingReconciler.reset()
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
        approvalCoordinator.queue(requestID: requestID, approved: approved)
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

        completeInteractivePrompt(at: promptIndex, id: prompt.id)
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

        completeInteractivePrompt(at: promptIndex, id: prompt.id)
        return true
    }

    func handle(url: URL) {
        guard let action = RemoteActivityURLAction(url: url) else { return }
        if !performURLAction(action) {
            pendingURLActions.append(action)
            if !transport.isOpen, pairingInfo != nil {
                connect()
            }
        }
    }

    // MARK: - Receive Loop

    /// Per-message handler for the transport's receive pump: decode/decrypt
    /// (offloading large frames to a detached task) and apply. The transport
    /// awaits this before issuing the next receive, preserving strict FIFO.
    private func processIncomingMessage(_ data: Data, generation: UInt64) async {
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
            guard transport.generation == generation else { return }
        } else {
            processed = RemoteFrameProcessor.process(data, crypto: crypto)
        }
        applyProcessedFrame(processed, signpostID: signpostID)
    }

    private func handleDisconnect(reason: String? = nil) {
        let wasConnected = isConnected
        cancelHandshakeTasks()
        isConnected = false
        status = .disconnected
        session.invalidateSession(clearHandshakeMaterial: false)

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
                      self.transport.generation == generation,
                      self.transport.isOpen,
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
                  self.transport.generation == generation,
                  self.transport.isOpen,
                  !self.isConnected else { return }

            // Deduped teardown: the transport owns socket + generation, the
            // session controller owns crypto state — no second hand-rolled
            // copy of disconnect's steps.
            self.cancelHandshakeTasks()
            self.transport.close()
            self.isConnected = false
            self.session.invalidateSession(clearHandshakeMaterial: false)
            self.lastError = "No response from your Mac. Make sure Chau7 is open, Remote is enabled, and the pairing payload is still current."
            self.emitTelemetry(
                type: .errorReceived,
                status: "timeout",
                message: self.lastError
            )
            // A handshake timeout is usually a transient relay/Mac delay rather
            // than a permanent failure. Route through the normal disconnect path
            // so the reconnect backoff retries instead of stranding the
            // connection until the user manually reconnects.
            self.handleDisconnect(reason: "handshake_timeout")
        }
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
            if case let .resetSession(reason) = session.noteDecryptFailure() {
                log.warning("Replay guard ordered session reset: \(reason)")
                session.resetForRehandshake()
                isConnected = false
                remoteSessionID = nil
                sendHello()
            }
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
            if case let .drop(reason) = session.evaluateEncryptedFrame(seq: frame.seq) {
                log.warning("Dropping frame type=\(frame.type): \(reason)")
                return
            }
            session.noteDecryptSuccess()
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
        // A changed mac nonce while a crypto session exists means the agent
        // re-handshook (restart): the old session key and seq space are dead.
        // Reset deliberately and re-handshake instead of silently dropping
        // every future frame as replayed.
        if case let .resetSession(reason) = session.evaluateHello(macNonce: nonce) {
            log.warning("Replay guard ordered session reset: \(reason)")
            session.resetForRehandshake()
            isConnected = false
            remoteSessionID = nil
            sendHello()
        }
        session.setMacNonce(nonce)
        establishSessionIfPossible()
    }

    private func handlePairAccept(_ data: Data) {
        guard let msg: PairAcceptPayload = decodePayload(data, as: PairAcceptPayload.self, context: "handlePairAccept") else { return }
        guard let keyData = Data(base64Encoded: msg.macPub) else {
            log.error("handlePairAccept: invalid macPub base64")
            return
        }
        guard session.adoptMacPublicKey(keyData) else {
            log.error("handlePairAccept: invalid public key")
            return
        }
        session.markPairAcceptReceived()
        RemotePairingStore.saveMacPublicKey(keyData)
        persistTrustedIdentity(for: msg)
        // If we fell back from trust-based reconnect to explicit pairing, any
        // provisional session state must be discarded before re-deriving keys.
        session.invalidateSession(clearHandshakeMaterial: false)
        session.clearMacNonce()
        session.mintIOSNonce()
        isConnected = false
        remoteSessionID = nil
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
        syncPrompts(with: pendingReconciler.applyWSPromptList(payload.prompts, now: Date()))
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
        syncApprovals(with: pendingReconciler.applyWSApprovalUpsert(msg, now: Date()))
        emitTelemetry(
            type: .approvalReceived,
            status: "pending",
            message: msg.flaggedCommand,
            metadata: ["request_id": msg.requestID]
        )
    }

    // MARK: - Session Establishment

    private func establishSessionIfPossible() {
        switch session.establishIfPossible() {
        case .notReady:
            return
        case .failed(let message):
            lastError = message
            return
        case .established:
            break
        }

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
        let nonce = session.nonceIOS ?? session.mintIOSNonce()
        sendJSON(HelloPayload(
            deviceID: pairing.deviceID, role: "ios",
            nonce: nonce.base64EncodedString(),
            pubKeyFP: session.iosKeyFingerprint,
            appVersion: Self.appVersion
        ), type: .hello, encrypt: false)
    }

    private func sendPairRequest(recordTelemetry: Bool = true) {
        guard let pairing = pairingInfo else { return }
        sendJSON(PairRequestPayload(
            deviceID: pairing.deviceID, pairingCode: pairing.pairingCode,
            iosPub: session.iosKey.publicKey.rawRepresentation.base64EncodedString(),
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
            _ = send(RemoteFrame(type: type.rawValue, tabID: 0, seq: session.nextSeq(), payload: data))
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
        let frame = RemoteFrame(type: type.rawValue, tabID: tabID, seq: session.nextSeq(), payload: payload)
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
        transport.send(frame.encode()) { [weak self] success, errorDescription in
            if !success {
                self?.emitTelemetry(type: .sendFailed, status: "send_failed", message: errorDescription)
            }
            completion?(success)
        }
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
        guard approvalCoordinator.hasQueuedResponses else { return }

        guard crypto != nil, transport.isOpen else {
            status = .reconnectingToSendApproval
            if let pairing = pairingInfo, !transport.isOpen {
                connect(
                    pairing: pairing,
                    preserveApprovalsAndPrompts: true,
                    preserveReconnectAttempt: true
                )
            }
            return
        }

        // The coordinator owns the double-send/requeue/supersede bookkeeping;
        // this method owns the side effects (UI states, reconnects, keepalive).
        let sendable = approvalCoordinator.takeSendable { requestID in
            approvalRequest(for: requestID) != nil
        }
        for (requestID, approved) in sendable {
            updateApprovalResponseState(requestID: requestID) { _ in .sending(approved) }

            sendApprovalResponse(requestID: requestID, approved: approved) { [weak self] success in
                guard let self else { return }
                switch self.approvalCoordinator.resolveSend(requestID: requestID, approved: approved, success: success) {
                case .completed(let approved):
                    self.completeApprovalResponse(requestID: requestID, approved: approved)
                    if !self.approvalCoordinator.hasQueuedResponses {
                        self.backgroundKeepalive.end()
                    }
                case .requeue(let approved):
                    self.updateApprovalResponseState(requestID: requestID) { _ in .queued(approved) }
                    self.lastError = "Approval response was not delivered. Chau7 will retry when the connection is ready."
                    self.status = .approvalQueued
                    if let pairing = self.pairingInfo, !self.transport.isOpen {
                        self.connect(
                            pairing: pairing,
                            preserveApprovalsAndPrompts: true,
                            preserveReconnectAttempt: true
                        )
                    }
                case .superseded:
                    break
                }
            }
        }
    }

    private func completeApprovalResponse(requestID: String, approved: Bool) {
        guard let idx = pendingApprovals.firstIndex(where: { $0.requestID == requestID }) else { return }
        let request = pendingApprovals.remove(at: idx)
        // Journal the resolution so a stale /pending snapshot can't resurrect it.
        _ = pendingReconciler.applyLocalApprovalResolution(requestID: requestID, now: Date())
        clearPushDeliveredID(requestID)

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
        guard crypto != nil, transport.isOpen, tabID != 0 else { return false }
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
        guard crypto != nil, transport.isOpen else {
            reportBlockedInput(
                "Input not sent because the encrypted session is not ready yet.",
                reason: "session_not_ready",
                tabID: tabID
            )
            return false
        }
        guard canSendInput(to: tabID, allowUnlistedTab: allowUnlistedTab) else {
            reportBlockedInput(
                "Input not sent because the target remote tab is no longer available.",
                reason: "tab_unavailable",
                tabID: tabID
            )
            return false
        }
        var data = Data(text.utf8)
        if appendNewline { data.append(0x0A) }
        guard sendEncrypted(type: .input, tabID: tabID, payload: data) else {
            reportBlockedInput(
                "Input could not be encrypted for the current remote session.",
                reason: "encrypt_failed",
                tabID: tabID
            )
            return false
        }
        // A successful send clears any stale block message so the UI banner
        // does not linger after recovery.
        if lastError != nil { lastError = nil }
        DiagnosticsLog.shared.debug(.input, "Input forwarded to relay", [
            "tab_id": String(tabID),
            "bytes": String(data.count),
            "newline": appendNewline ? "true" : "false"
        ])
        return true
    }

    private func shouldSendPairRequest(for pairing: PairingInfo, attempt: Int) -> Bool {
        guard !session.hasReceivedPairAccept else { return false }
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
        let currentIOSPub = session.iosKey.publicKey.rawRepresentation.base64EncodedString()
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
                iosPub: session.iosKey.publicKey.rawRepresentation.base64EncodedString()
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

    private func reportBlockedInput(_ message: String, reason: String = "blocked", tabID: UInt32? = nil) {
        lastError = message
        DiagnosticsLog.shared.error(.input, "Input blocked", [
            "reason": reason,
            "tab_id": String(tabID ?? activeTabID),
            "is_connected": isConnected ? "true" : "false",
            "status": status.displayText
        ])
        emitTelemetry(
            type: .sendFailed,
            status: "send_blocked",
            message: message,
            tabID: activeTabID,
            tabTitle: tabTitle(for: activeTabID)
        )
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

        // Cancel any in-flight fetch before starting a new one so forced
        // refreshes (push wake, scene-active, pair-accept) don't stack
        // concurrent network requests.
        pendingStateFetchTask?.cancel()
        pendingStateFetchTask = Task { @MainActor [weak self] in
            defer {
                self?.pendingStateFetchTask = nil
                self?.lastPendingStateFetchAt = Date()
            }
            await self?.fetchPendingState(reason: reason)
        }
    }

    private var shouldScheduleLocalApprovalNotification: Bool {
        guard currentAppState != .foreground else { return false }
        return !canReceiveRemotePushNotifications
    }

    private func recordPushDeliveredID(_ id: String) {
        guard !pushDeliveredIDs.contains(id) else { return }
        pushDeliveredIDs.append(id)
        if pushDeliveredIDs.count > Self.pushDeliveredIDCap {
            pushDeliveredIDs.removeFirst(pushDeliveredIDs.count - Self.pushDeliveredIDCap)
        }
    }

    private func clearPushDeliveredID(_ id: String) {
        pushDeliveredIDs.removeAll { $0 == id }
    }

    private func fetchPendingState(reason: String) async {
        guard let request = pendingStateRequest() else { return }
        // Mark the fetch instant: WS deltas arriving at/after this moment
        // outrank whatever the snapshot says (see PendingStateReconciler).
        pendingReconciler.beginSnapshotFetch(now: Date())
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else { return }
            guard httpResponse.statusCode == 200 else {
                log.warning("Pending state fetch failed: status \(httpResponse.statusCode)")
                return
            }
            let payload = try RemoteJSON.decoder.decode(RemotePendingStatePayload.self, from: data)
            // Phase-B arbitration: versioned snapshots (newer agents) are
            // ordered by (session_epoch, state_version); a stale one is
            // discarded outright. Unversioned snapshots rely on the
            // reconciler's delta-journal invariants as before.
            guard pendingReconciler.admitSnapshot(
                epoch: payload.sessionEpoch,
                version: payload.stateVersion
            ) else {
                log.info("Pending state snapshot discarded as stale (epoch/version arbitration)")
                return
            }
            let busyIDs = Set(pendingApprovals.filter(\.responseState.isBusy).map(\.requestID))
            syncApprovals(with: pendingReconciler.applySnapshotApprovals(
                payload.approvals,
                busyRequestIDs: busyIDs,
                now: Date()
            ))
            if let promptChanges = pendingReconciler.applySnapshotPrompts(payload.interactivePrompts, now: Date()) {
                syncPrompts(with: promptChanges)
            }
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
        if let token = RelayToken.make(pairing: pairing, role: "ios", scope: "pending") {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
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

    /// Project the reconciler's authoritative approval list into the UI
    /// models (preserving in-flight response states) and apply the delta's
    /// notification side effects.
    private func syncApprovals(with changes: PendingStateReconciler.ApprovalChanges) {
        let existingStates = Dictionary(uniqueKeysWithValues: pendingApprovals.map { ($0.requestID, $0.responseState) })
        pendingApprovals = changes.approvals.map { payload in
            approvalRequest(from: payload, responseState: existingStates[payload.requestID] ?? .idle)
        }
        if !changes.removedIDs.isEmpty {
            RemoteNotificationScheduler.removeApprovalNotifications(requestIDs: changes.removedIDs)
        }
        for payload in changes.added {
            scheduleApprovalNotificationIfAllowed(for: payload)
        }
    }

    private func scheduleApprovalNotificationIfAllowed(for payload: ApprovalRequestPayload) {
        guard shouldScheduleLocalApprovalNotification else { return }
        // Already on the lock screen via push — don't double-notify.
        guard !pushDeliveredIDs.contains(payload.requestID) else { return }
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

    /// Project the reconciler's authoritative prompt list into the UI,
    /// applying the answered-prompt suppression overlay on top.
    private func syncPrompts(with changes: PendingStateReconciler.PromptChanges) {
        let now = Date()
        let nextPromptIDs = Set(changes.prompts.map(\.id))

        // Drop suppression once the Mac stops listing the prompt (the terminal
        // advanced, so the tab cleared) or after the safety timeout, so a
        // genuinely-still-pending prompt resurfaces instead of vanishing.
        suppressedPromptIDs = suppressedPromptIDs.filter { id, suppressedAt in
            nextPromptIDs.contains(id) && now.timeIntervalSince(suppressedAt) < Self.promptSuppressionMaxAge
        }

        // Hide prompts the user just answered/dismissed; the Mac re-pushes them
        // until its terminal catches up, which is what made them "come back".
        let visiblePrompts = changes.prompts.filter { suppressedPromptIDs[$0.id] == nil }

        let previousPromptIDs = Set(pendingInteractivePrompts.map(\.id))
        let visiblePromptIDs = Set(visiblePrompts.map(\.id))

        pendingInteractivePrompts = visiblePrompts

        let removedPromptIDs = previousPromptIDs.subtracting(visiblePromptIDs)
        RemoteNotificationScheduler.removeInteractivePromptNotifications(promptIDs: Array(removedPromptIDs))

        for prompt in visiblePrompts where !previousPromptIDs.contains(prompt.id) {
            if shouldScheduleLocalApprovalNotification, !pushDeliveredIDs.contains(prompt.id) {
                RemoteNotificationScheduler.scheduleInteractivePrompt(
                    for: prompt,
                    redactDetails: AppSettings.hideSensitiveNotifications
                )
            }
        }
    }

    /// Finish a prompt locally: remove it from the pending list, suppress its
    /// re-add until the Mac's list catches up, and tear down any scheduled
    /// notification. The single place that defines what "done with a prompt"
    /// means on the client, shared by the answer and dismiss paths.
    private func completeInteractivePrompt(at index: Int, id: String) {
        pendingInteractivePrompts.remove(at: index)
        _ = pendingReconciler.applyLocalPromptCompletion(promptID: id)
        clearPushDeliveredID(id)
        suppressedPromptIDs[id] = Date()
        RemoteNotificationScheduler.removeInteractivePromptNotifications(promptIDs: [id])
    }

    /// Dismiss a detected prompt from the phone without sending anything to the
    /// terminal. It resurfaces if the Mac still lists it after the safety
    /// timeout, or sooner if the tab briefly clears and the prompt recurs.
    func dismissInteractivePrompt(promptID: String) {
        guard let index = pendingInteractivePrompts.firstIndex(where: { $0.id == promptID }) else { return }
        completeInteractivePrompt(at: index, id: promptID)
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
        // No blanket notification suppression here: the pending-state
        // reconciler already dedupes re-delivered approvals/prompts on
        // reconnect (only genuinely new entries notify), and the old
        // wall-clock window could mute a legitimately new approval that
        // arrived while suspended.
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

    private static let maxTelemetrySendAttempts = 3

    private func enqueueOrSendTelemetryEvent(_ event: inout RemoteClientTelemetryEvent) {
        guard crypto != nil else {
            telemetryBuffer.append(event)
            return
        }

        if event.sessionID == nil {
            event.sessionID = remoteSessionID
        }

        guard let data = try? RemoteJSON.encoder.encode(event) else { return }
        // Drain-on-send-success: a failed WS send re-buffers the event for
        // the next flush (bounded per-event attempts), instead of the old
        // fire-and-forget that silently dropped it.
        let rebufferCandidate = event
        let sent = sendEncrypted(type: .remoteTelemetry, tabID: event.tabID ?? 0, payload: data) { [weak self] success in
            guard let self else { return }
            if success {
                self.telemetrySendAttempts.removeValue(forKey: rebufferCandidate.id)
            } else {
                self.rebufferTelemetryEvent(rebufferCandidate)
            }
        }
        if !sent {
            rebufferTelemetryEvent(rebufferCandidate)
        }
    }

    private func rebufferTelemetryEvent(_ event: RemoteClientTelemetryEvent) {
        let attempts = (telemetrySendAttempts[event.id] ?? 0) + 1
        guard attempts < Self.maxTelemetrySendAttempts else {
            telemetrySendAttempts.removeValue(forKey: event.id)
            log.warning("Dropping telemetry event after \(attempts) failed sends: \(event.eventType.rawValue)")
            return
        }
        telemetrySendAttempts[event.id] = attempts
        telemetryBuffer.append(event)
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

// RelayToken now lives in Chau7Core/Remote/RelayToken.swift, shared and
// vector-tested against the Go agent and relay verifier.
