import Foundation
import Combine
import os.log
import Chau7Core
import Darwin

@MainActor
final class RemoteControlManager: ObservableObject {
    static let shared = RemoteControlManager()

    @Published private(set) var isAgentRunning = false
    @Published private(set) var isIPCConnected = false
    @Published private(set) var sessionStatus: String?
    @Published private(set) var pairingInfo: RemotePairingInfo?
    @Published private(set) var lastError: String?
    @Published private(set) var pairedDevices: [RemotePairedDevice] = []
    @Published private(set) var remoteActivity: RemoteActivityState?

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private let logger = Logger(subsystem: "com.chau7.remote", category: "RemoteManager")
    private var cancellables: Set<AnyCancellable> = []
    private weak var overlayModel: OverlayTabsModel?

    private var tabRegistry = RemoteTabRegistry()
    private var seqCounter: UInt64 = 1
    private var pendingProtectedInputs: [String: ProtectedRemoteInput] = [:]
    private var approvalContexts: [String: PendingRemoteApprovalContext] = [:]
    private var connectedPairedDeviceID: String?
    private var sessionStateCancellables: [String: AnyCancellable] = [:]
    private var activityRefreshWorkItem: DispatchWorkItem?
    private var backgroundSnapshotTask: Task<Void, Never>?
    private var outputFlushTask: Task<Void, Never>?
    private var pendingOutputByTabID = RemotePendingOutputBuffer<Data>()

    private let ipc = RemoteIPCServer.shared

    private init() {}

    func configure(overlayModel: OverlayTabsModel) {
        self.overlayModel = overlayModel
        ipc.onFrame = { [weak self] frame in
            self?.handleIPCFrame(frame)
        }
        ipc.onClientConnected = { [weak self] in
            self?.isIPCConnected = true
            self?.sendInitialState()
        }
        ipc.onClientDisconnected = { [weak self] in
            self?.isIPCConnected = false
            self?.sessionStatus = nil
            self?.connectedPairedDeviceID = nil
            self?.remoteActivity = nil
            self?.cancelBackgroundSnapshotPrefetch()
            self?.cancelPendingOutputFlush()
            self?.refreshPairedDevices()
        }
        ipc.start()
        refreshPairedDevices()

        FeatureSettings.shared.$isRemoteEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                if enabled {
                    self?.startAgent()
                } else {
                    self?.stopAgent()
                }
            }
            .store(in: &cancellables)

        FeatureSettings.shared.$remoteRelayURL
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.restartAgentIfRunning()
            }
            .store(in: &cancellables)

        overlayModel.$tabs
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.sendTabList()
                self?.sendSelectedTabSnapshot()
                self?.scheduleBackgroundSnapshotPrefetch()
                self?.rebuildSessionStateSubscriptions()
                self?.scheduleRemoteActivityRefresh()
            }
            .store(in: &cancellables)

        overlayModel.$selectedTabID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.sendTabList()
                self?.sendSelectedTabSnapshot()
                self?.scheduleRemoteActivityRefresh()
            }
            .store(in: &cancellables)

        rebuildSessionStateSubscriptions()
    }

    func recordOutput(_ data: Data, sessionIdentifier: String) {
        guard isIPCConnected else { return }
        guard let tabID = tabRegistry.tabID(forSessionIdentifier: sessionIdentifier) else { return }
        pendingOutputByTabID.append(data, to: tabID) { existing, chunk in
            existing.append(chunk)
        }

        if pendingOutputByTabID[tabID]?.count ?? 0 >= RemoteOutputTuning.maxPendingBytesPerTab {
            flushPendingOutput()
        } else {
            schedulePendingOutputFlush()
        }
    }

    func sendSnapshot(for tabID: UInt32) {
        guard let overlayModel else { return }
        let targetTab: OverlayTab?
        if tabID == 0 {
            targetTab = overlayModel.selectedTab
        } else if let uuid = tabRegistry.uuid(for: tabID) {
            targetTab = overlayModel.tabs.first { $0.id == uuid }
        } else {
            targetTab = nil
        }
        guard let session = targetTab?.session,
              let snapshot = session.captureRemoteSnapshot() else { return }
        sendFrame(type: .snapshot, tabID: tabID, payload: RemoteOutputTuning.capSnapshot(snapshot))
    }

    private func startAgent() {
        guard !isAgentRunning else { return }
        guard let binaryPath = remoteBinaryPath() else {
            let error = lastError ?? "Remote agent binary not found."
            logger.error("\(error)")
            lastError = error
            return
        }

        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath.path)
        } catch {
            logger.warning("Failed to set remote binary permissions: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = binaryPath
        guard let dataDir = dataDirectory() else {
            lastError = "Cannot start remote agent: data directory unavailable"
            return
        }
        process.currentDirectoryURL = dataDir

        var env = ProcessInfo.processInfo.environment
        guard let socketPath = ipcSocketPath() else {
            lastError = "Cannot start remote agent: socket path unavailable"
            return
        }
        env["CHAU7_REMOTE_SOCKET"] = socketPath.path
        env["CHAU7_RELAY_URL"] = FeatureSettings.shared.remoteRelayURL
        env["CHAU7_MAC_NAME"] = Host.current().localizedName ?? "Mac"
        process.environment = env

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        self.outputPipe = outputPipe
        self.errorPipe = errorPipe

        outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.logger.debug("Remote stdout: \(output)")
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.logger.warning("Remote stderr: \(output)")
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.isAgentRunning = false
                if proc.terminationStatus != 0 {
                    let error = "Remote agent exited with status \(proc.terminationStatus)"
                    self.logger.error("\(error)")
                    self.lastError = error
                }
            }
        }

        do {
            try process.run()
            self.process = process
            isAgentRunning = true
            lastError = nil
            logger.info("Remote agent started")
            refreshPairedDevices()
        } catch {
            let errorMessage = "Failed to start remote agent: \(error.localizedDescription)"
            logger.error("\(errorMessage)")
            lastError = errorMessage
        }
    }

    func stopAgent() {
        guard let process else { return }
        process.terminationHandler = nil
        cancelBackgroundSnapshotPrefetch()
        cancelPendingOutputFlush()
        // Terminate process BEFORE closing pipes to avoid SIGPIPE
        terminateProcess(process, name: "remote agent")
        cleanupPipes()
        self.process = nil
        isAgentRunning = false
        pendingProtectedInputs.removeAll()
    }

    func restartAgentIfRunning() {
        guard isAgentRunning else { return }
        stopAgent()
        startAgent()
    }

    private func cleanupPipes() {
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        errorPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        errorPipe = nil
    }

    /// Terminates a process with escalating signals. Safe to call from any
    /// isolation context — the spin-wait runs off the main actor.
    nonisolated private func terminateProcess(_ process: Process, name: String) {
        guard process.isRunning else { return }

        process.terminate()
        if waitForExit(of: process, timeout: 1.0) {
            return
        }

        logger.warning("\(name) did not exit after SIGTERM; sending SIGINT")
        process.interrupt()
        if waitForExit(of: process, timeout: 0.5) {
            return
        }

        let pid = process.processIdentifier
        logger.error("\(name) still running after SIGINT; sending SIGKILL to pid \(pid)")
        _ = Darwin.kill(pid, SIGKILL)
        _ = waitForExit(of: process, timeout: 0.5)
    }

    nonisolated private func waitForExit(of process: Process, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            usleep(50000)
        }
        return !process.isRunning
    }

    private func handleIPCFrame(_ frame: RemoteFrame) {
        guard let type = RemoteFrameType(rawValue: frame.type) else {
            logger.warning("Unknown IPC frame type: 0x\(String(frame.type, radix: 16))")
            return
        }
        switch type {
        case .pairingInfo:
            handlePairingInfo(frame)
        case .sessionReady:
            isIPCConnected = true
            sendInitialState()
        case .sessionStatus:
            guard let status: RemoteSessionStatus = decodePayload(frame, as: RemoteSessionStatus.self, context: "session status") else { return }
            sessionStatus = status.status
            connectedPairedDeviceID = status.pairedDeviceID
            if status.status == "ready" {
                sendInitialState()
            }
            refreshPairedDevices()
        case .tabSwitch:
            handleTabSwitch(frame)
        case .input:
            handleInput(frame)
        case .remoteTelemetry:
            handleRemoteTelemetry(frame)
        case .approvalResponse:
            handleApprovalResponse(frame)
        case .ping:
            sendFrame(type: .pong, tabID: frame.tabID, payload: frame.payload)
        case .error:
            if let message = String(data: frame.payload, encoding: .utf8) {
                lastError = message
            }
        default:
            logger.debug("Unhandled IPC frame type: 0x\(String(type.rawValue, radix: 16))")
        }
    }

    private func handlePairingInfo(_ frame: RemoteFrame) {
        guard let info: RemotePairingInfo = decodePayload(frame, as: RemotePairingInfo.self, context: "pairing info") else { return }
        pairingInfo = info
        refreshPairedDevices()
    }

    private func handleTabSwitch(_ frame: RemoteFrame) {
        guard let overlayModel else { return }
        guard let payload: RemoteTabSwitchPayload = decodePayload(frame, as: RemoteTabSwitchPayload.self, context: "tab switch") else { return }
        if let uuid = tabRegistry.uuid(for: payload.tabID) {
            overlayModel.selectTab(id: uuid)
            sendSnapshot(for: payload.tabID)
        } else {
            sendError(code: "tab_unavailable", message: "That tab is no longer available for remote control.", tabID: payload.tabID)
        }
    }

    private func handleInput(_ frame: RemoteFrame) {
        guard let text = String(data: frame.payload, encoding: .utf8) else {
            sendError(code: "invalid_input_encoding", message: "Remote input must be valid UTF-8.", tabID: frame.tabID)
            return
        }
        guard let (session, resolvedTabID) = resolveInputTarget(for: frame.tabID) else {
            sendError(code: "tab_unavailable", message: "That tab cannot receive remote input right now.", tabID: frame.tabID)
            return
        }

        if let flaggedCommand = protectedRemoteActionLabel(for: text) {
            queueProtectedRemoteInput(
                requestID: UUID().uuidString,
                text: text,
                tabID: resolvedTabID,
                sessionTitle: session.title,
                flaggedCommand: flaggedCommand
            )
            return
        }

        session.sendInput(text)
    }

    // MARK: - Approval Frames

    /// Send a command approval request to the iOS app.
    func sendApprovalRequest(requestID: String, payload: Data) {
        guard isIPCConnected else { return }
        registerApprovalContext(requestID: requestID, payload: payload)
        sendFrame(type: .approvalRequest, tabID: 0, payload: payload)
        sendRemoteActivity()
        logger.info("Remote: sent approval request \(requestID)")
    }

    private func handleApprovalResponse(_ frame: RemoteFrame) {
        // Purge expired pending approvals on each response
        purgeExpiredProtectedInputs()

        guard let response: ApprovalResponsePayload = decodePayload(frame, as: ApprovalResponsePayload.self, context: "approval response") else { return }
        approvalContexts.removeValue(forKey: response.requestID)
        if let protectedInput = pendingProtectedInputs.removeValue(forKey: response.requestID) {
            if response.approved,
               let session = session(for: protectedInput.tabID) {
                session.sendInput(protectedInput.text)
                logger.info("Remote: protected action approved for tab \(protectedInput.tabID)")
            } else {
                logger.info("Remote: protected action denied for tab \(protectedInput.tabID)")
            }
            sendRemoteActivity()
            return
        }
        TerminalControlService.shared.resolveApproval(requestID: response.requestID, approved: response.approved)
        sendRemoteActivity()
        logger.info("Remote: approval response for \(response.requestID): \(response.approved ? "allowed" : "denied")")
    }

    private func handleRemoteTelemetry(_ frame: RemoteFrame) {
        guard let event: RemoteClientTelemetryEvent = decodePayload(frame, as: RemoteClientTelemetryEvent.self, context: "remote telemetry") else { return }
        TelemetryStore.shared.insertRemoteClientEvent(event)
    }

    private func sendInitialState() {
        sendTabList()
        sendSelectedTabSnapshot()
        scheduleBackgroundSnapshotPrefetch()
        sendRemoteActivity(force: true)
    }

    private func sendSelectedTabSnapshot() {
        guard let overlayModel,
              let tabID = tabRegistry.tabID(for: overlayModel.selectedTabID) else {
            return
        }
        sendSnapshot(for: tabID)
    }

    private func rebuildSessionStateSubscriptions() {
        guard let overlayModel else {
            sessionStateCancellables.removeAll()
            return
        }

        let sessions = overlayModel.tabs.compactMap(\.session)
        let validIDs = Set(sessions.map(\.tabIdentifier))

        for staleID in sessionStateCancellables.keys where !validIDs.contains(staleID) {
            sessionStateCancellables.removeValue(forKey: staleID)
        }

        for session in sessions where sessionStateCancellables[session.tabIdentifier] == nil {
            sessionStateCancellables[session.tabIdentifier] = session.objectWillChange
                .receive(on: RunLoop.main)
                .sink { [weak self] _ in
                    self?.scheduleRemoteActivityRefresh()
                }
        }
    }

    private func scheduleRemoteActivityRefresh() {
        activityRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.sendRemoteActivity()
        }
        activityRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
    }

    private func sendRemoteActivity(force: Bool = false) {
        let nextActivity = currentRemoteActivity()
        guard force || nextActivity != remoteActivity else { return }

        remoteActivity = nextActivity
        guard isIPCConnected else { return }

        if let nextActivity,
           let payload = try? JSONEncoder().encode(nextActivity) {
            sendFrame(type: .activityState, tabID: nextActivity.tabID, payload: payload)
        } else {
            sendFrame(type: .activityCleared, tabID: 0, payload: Data())
        }
    }

    private func currentRemoteActivity(now: Date = Date()) -> RemoteActivityState? {
        guard let overlayModel else { return nil }

        let approvalsByTabID = Dictionary(grouping: approvalContexts.values, by: \.tabID)
        let candidates = overlayModel.tabs.compactMap { tab -> RemoteActivityCandidate? in
            guard let tabID = tabRegistry.tabID(for: tab.id) else {
                return nil
            }

            let approval = approvalsByTabID[tabID]?.max { $0.requestedAt < $1.requestedAt }
            let activityID = "tab-\(tabID)"

            if let approval {
                return RemoteActivityCandidate(
                    activityID: activityID,
                    tabID: tabID,
                    tabTitle: approval.tabTitle,
                    toolName: approval.toolName,
                    projectName: approval.projectName,
                    sessionID: approval.sessionID,
                    status: .waitingInput,
                    detail: approval.approval.displayCommand,
                    isSelected: tab.id == overlayModel.selectedTabID,
                    updatedAt: approval.requestedAt,
                    startedAt: approval.requestedAt,
                    approval: approval.approval
                )
            }

            guard let session = tab.session else { return nil }

            let toolName = activityToolName(for: session, tab: tab)
            let projectName = activityProjectName(for: session)
            let startedAt = tab.lastCommand?.startTime
            let updatedAt = activityUpdatedAt(for: session, tab: tab, approval: nil)

            guard session.aiDisplayAppName != nil ||
                    session.effectiveAIProvider != nil ||
                    session.effectiveAISessionId != nil else {
                return nil
            }

            let resolvedStatus: RemoteActivityStatus?
            let detail: String?

            switch session.effectiveStatus {
            case .waitingForInput:
                resolvedStatus = .waitingInput
                detail = session.effectiveIsAtPrompt ? "Waiting at prompt" : nil
            case .running:
                resolvedStatus = .running
                detail = nil
            case .stuck:
                resolvedStatus = .running
                detail = "No output for a while"
            case .idle, .exited:
                if let outcome = recentCompletionStatus(for: tab, now: now) {
                    resolvedStatus = outcome.status
                    detail = outcome.detail
                } else {
                    resolvedStatus = nil
                    detail = nil
                }
            }

            guard let resolvedStatus else { return nil }

            return RemoteActivityCandidate(
                activityID: activityID,
                tabID: tabID,
                tabTitle: activityTabTitle(for: tab),
                toolName: toolName,
                projectName: projectName,
                sessionID: session.effectiveAISessionId,
                status: resolvedStatus,
                detail: detail,
                isSelected: tab.id == overlayModel.selectedTabID,
                updatedAt: updatedAt,
                startedAt: startedAt
            )
        }

        return RemoteActivityProjection.project(from: candidates)
    }

    private func activityTabTitle(for tab: OverlayTab) -> String {
        let trimmedCustom = tab.customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedCustom.isEmpty {
            return trimmedCustom
        }
        return tab.displayTitle
    }

    private func activityToolName(for session: TerminalSessionModel, tab: OverlayTab) -> String {
        let activeName = session.aiDisplayAppName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !activeName.isEmpty {
            return activeName
        }
        let provider = session.effectiveAIProvider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !provider.isEmpty {
            return provider.capitalized
        }
        return activityTabTitle(for: tab)
    }

    private func activityProjectName(for session: TerminalSessionModel) -> String? {
        let trimmed = session.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        return lastPathComponent.isEmpty ? trimmed : lastPathComponent
    }

    private func activityUpdatedAt(
        for session: TerminalSessionModel,
        tab: OverlayTab,
        approval: PendingRemoteApprovalContext?
    ) -> Date {
        [
            approval?.requestedAt,
            tab.lastCommand?.endTime,
            tab.lastCommand?.startTime,
            session.lastOutputDate
        ]
        .compactMap { $0 }
        .max() ?? Date()
    }

    private func recentCompletionStatus(
        for tab: OverlayTab,
        now: Date
    ) -> (status: RemoteActivityStatus, detail: String?)? {
        guard let lastCommand = tab.lastCommand,
              let endTime = lastCommand.endTime,
              now.timeIntervalSince(endTime) <= 20 else {
            return nil
        }

        let trimmedCommand = lastCommand.command.trimmingCharacters(in: .whitespacesAndNewlines)
        let exitCode = lastCommand.exitCode ?? 0
        if exitCode == 0 {
            return (
                .completed,
                trimmedCommand.isEmpty ? nil : trimmedCommand
            )
        }

        if trimmedCommand.isEmpty {
            return (.failed, "Exit \(exitCode)")
        }
        return (.failed, "Exit \(exitCode): \(trimmedCommand)")
    }

    private func sendTabList() {
        guard let overlayModel else { return }
        let tabPayloads = tabRegistry.rebuild(
            with: remoteControllableTabs(from: overlayModel).map { tab in
                RemoteTabRegistryEntry(
                    id: tab.id,
                    sessionIdentifier: tab.session?.tabIdentifier,
                    title: tab.displayTitle,
                    isActive: tab.id == overlayModel.selectedTabID,
                    isMCPControlled: tab.isMCPControlled
                )
            }
        )

        do {
            let payload = try JSONEncoder().encode(RemoteTabListPayload(tabs: tabPayloads))
            sendFrame(type: .tabList, tabID: 0, payload: payload)
            sendRemoteActivity()
        } catch {
            logger.warning("Failed to encode tab list: \(error.localizedDescription)")
        }
    }

    private func scheduleBackgroundSnapshotPrefetch() {
        cancelBackgroundSnapshotPrefetch()
        guard isIPCConnected, let overlayModel else { return }

        let backgroundTabIDs = tabRegistry.backgroundTabIDs(
            for: remoteControllableTabs(from: overlayModel).map(\.id),
            selectedTabID: overlayModel.selectedTabID
        )

        guard !backgroundTabIDs.isEmpty else { return }

        backgroundSnapshotTask = Task { @MainActor [weak self] in
            for (index, tabID) in backgroundTabIDs.enumerated() {
                guard let self, !Task.isCancelled, self.isIPCConnected else { return }
                if index > 0 {
                    try? await Task.sleep(for: .milliseconds(75))
                }
                self.sendSnapshot(for: tabID)
            }
        }
    }

    private func cancelBackgroundSnapshotPrefetch() {
        backgroundSnapshotTask?.cancel()
        backgroundSnapshotTask = nil
    }

    private func schedulePendingOutputFlush() {
        guard outputFlushTask == nil, isIPCConnected, !pendingOutputByTabID.isEmpty else { return }
        outputFlushTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: RemoteOutputTuning.flushInterval)
            guard let self, !Task.isCancelled else { return }
            self.flushPendingOutput()
        }
    }

    private func cancelPendingOutputFlush() {
        outputFlushTask?.cancel()
        outputFlushTask = nil
        pendingOutputByTabID.removeAll(keepingCapacity: true)
    }

    private func flushPendingOutput() {
        outputFlushTask?.cancel()
        outputFlushTask = nil
        guard isIPCConnected, !pendingOutputByTabID.isEmpty else { return }

        for (tabID, payload) in pendingOutputByTabID.drainAll(sortedByTabID: true) {
            let token = FeatureProfiler.shared.begin(.remoteOutput, bytes: payload.count)
            sendFrame(type: .output, tabID: tabID, payload: payload)
            FeatureProfiler.shared.end(token)
        }
    }

    private func remoteControllableTabs(from overlayModel: OverlayTabsModel) -> [OverlayTab] {
        overlayModel.tabs.filter { $0.session != nil }
    }

    private func sendFrame(type: RemoteFrameType, tabID: UInt32, payload: Data) {
        let frame = RemoteFrame(
            type: type.rawValue,
            flags: 0,
            reserved: 0,
            tabID: tabID,
            seq: nextSeq(),
            payload: payload
        )
        ipc.send(frame)
    }

    private func sendError(code: String, message: String, tabID: UInt32 = 0) {
        let payload = RemoteErrorPayload(code: code, message: message)
        guard let data = try? JSONEncoder().encode(payload) else {
            logger.warning("Failed to encode remote error payload for code \(code)")
            return
        }
        sendFrame(type: .error, tabID: tabID, payload: data)
    }

    private func nextSeq() -> UInt64 {
        defer { seqCounter &+= 1 }
        return seqCounter
    }

    private func decodePayload<T: Decodable>(_ frame: RemoteFrame, as type: T.Type, context: String) -> T? {
        do {
            return try JSONDecoder().decode(type, from: frame.payload)
        } catch {
            logger.warning("Failed to decode \(context): \(error.localizedDescription)")
            return nil
        }
    }

    private func resolveInputTarget(for tabID: UInt32) -> (TerminalSessionModel, UInt32)? {
        guard let overlayModel else { return nil }
        if tabID == 0 {
            guard let selectedTab = overlayModel.selectedTab?.session,
                  let resolvedTabID = tabRegistry.tabID(for: overlayModel.selectedTabID) else {
                return nil
            }
            return (selectedTab, resolvedTabID)
        }

        guard let uuid = tabRegistry.uuid(for: tabID),
              let session = overlayModel.tabs.first(where: { $0.id == uuid })?.session else {
            return nil
        }
        return (session, tabID)
    }

    private func session(for tabID: UInt32) -> TerminalSessionModel? {
        if tabID == 0 {
            return overlayModel?.selectedTab?.session
        }

        guard let overlayModel,
              let uuid = tabRegistry.uuid(for: tabID) else {
            return nil
        }
        return overlayModel.tabs.first(where: { $0.id == uuid })?.session
    }

    private static let maxPendingProtectedInputs = 20

    private func purgeExpiredProtectedInputs() {
        let expired = pendingProtectedInputs.filter { $0.value.isExpired }
        for (key, input) in expired {
            pendingProtectedInputs.removeValue(forKey: key)
            approvalContexts.removeValue(forKey: key)
            logger.info("Remote: expired protected action for tab \(input.tabID) after \(ProtectedRemoteInput.ttl)s")
        }
    }

    private func registerApprovalContext(requestID: String, payload: Data) {
        guard let approval = try? JSONDecoder().decode(ApprovalRequestPayload.self, from: payload) else {
            return
        }

        if let protectedInput = pendingProtectedInputs[requestID],
           let session = session(for: protectedInput.tabID),
           let uuid = tabRegistry.uuid(for: protectedInput.tabID),
           let tab = overlayModel?.tabs.first(where: { $0.id == uuid }) {
            approvalContexts[requestID] = PendingRemoteApprovalContext(
                requestID: approval.requestID,
                tabID: protectedInput.tabID,
                tabTitle: activityTabTitle(for: tab),
                toolName: activityToolName(for: session, tab: tab),
                projectName: activityProjectName(for: session),
                sessionID: session.effectiveAISessionId,
                command: approval.command,
                flaggedCommand: approval.flaggedCommand,
                requestedAt: Self.parseApprovalDate(approval.timestamp)
            )
            return
        }

        guard let overlayModel,
              let tab = overlayModel.selectedTab,
              let session = tab.session,
              let tabID = tabRegistry.tabID(for: tab.id) else {
            return
        }

        approvalContexts[requestID] = PendingRemoteApprovalContext(
            requestID: approval.requestID,
            tabID: tabID,
            tabTitle: activityTabTitle(for: tab),
            toolName: activityToolName(for: session, tab: tab),
            projectName: activityProjectName(for: session),
            sessionID: session.effectiveAISessionId,
            command: approval.command,
            flaggedCommand: approval.flaggedCommand,
            requestedAt: Self.parseApprovalDate(approval.timestamp)
        )
    }

    private func queueProtectedRemoteInput(
        requestID: String,
        text: String,
        tabID: UInt32,
        sessionTitle: String,
        flaggedCommand: String
    ) {
        purgeExpiredProtectedInputs()
        if pendingProtectedInputs.count >= Self.maxPendingProtectedInputs {
            logger.warning("Remote: pending protected inputs at capacity (\(Self.maxPendingProtectedInputs)), dropping oldest")
            if let oldestKey = pendingProtectedInputs.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
                pendingProtectedInputs.removeValue(forKey: oldestKey)
            }
        }
        pendingProtectedInputs[requestID] = ProtectedRemoteInput(
            tabID: tabID,
            text: text,
            flaggedCommand: flaggedCommand
        )

        let payload = ApprovalRequestPayload(
            requestID: requestID,
            command: text.trimmingCharacters(in: .whitespacesAndNewlines),
            flaggedCommand: flaggedCommand,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        guard let data = try? JSONEncoder().encode(payload) else {
            pendingProtectedInputs.removeValue(forKey: requestID)
            logger.error("Remote: failed to encode protected action approval payload")
            return
        }

        sendApprovalRequest(requestID: requestID, payload: data)
        logger.warning("Remote: queued protected action approval for tab \(tabID) (\(sessionTitle))")
    }

    private func protectedRemoteActionLabel(for input: String) -> String? {
        RemoteProtection.flaggedTerminationAction(for: input)
    }

    private static func parseApprovalDate(_ timestamp: String) -> Date {
        ISO8601DateFormatter().date(from: timestamp) ?? Date()
    }

    private func dataDirectory() -> URL? {
        let dir = RuntimeIsolation.appSupportDirectory(named: "Chau7")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create data directory: \(error.localizedDescription)")
            lastError = "Failed to create data directory"
            return nil
        }
        return dir
    }

    private func ipcSocketPath() -> URL? {
        dataDirectory()?.appendingPathComponent("remote.sock")
    }

    private func stateFileURL() -> URL {
        RuntimeIsolation.chau7Directory()
            .appendingPathComponent("remote")
            .appendingPathComponent("state.json")
    }

    func revokePairedDevice(id: String) {
        do {
            guard var state = try loadAgentState() else { return }
            state.removePairedDevice(id: id)
            try saveAgentState(state)
            if connectedPairedDeviceID == id {
                connectedPairedDeviceID = nil
                sessionStatus = "disconnected"
            }
            refreshPairedDevices()
            restartAgentIfRunning()
        } catch {
            logger.error("Failed to revoke paired device: \(error.localizedDescription)")
            lastError = "Failed to revoke paired device"
        }
    }

    private func refreshPairedDevices() {
        do {
            guard let state = try loadAgentState() else {
                pairedDevices = []
                return
            }
            pairedDevices = state.pairedDevices.map { device in
                RemotePairedDevice(
                    id: device.id,
                    name: device.name.isEmpty ? "Unnamed iPhone" : device.name,
                    fingerprint: device.publicKeyFingerprint.isEmpty ? device.id : device.publicKeyFingerprint,
                    pairedAt: device.pairedAt,
                    lastConnectedAt: device.lastConnectedAt,
                    isConnected: sessionStatus == "ready" && connectedPairedDeviceID == device.id
                )
            }
        } catch {
            logger.warning("Failed to refresh paired devices: \(error.localizedDescription)")
        }
    }

    private func loadAgentState() throws -> RemoteAgentStateSnapshot? {
        let url = stateFileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(RemoteAgentStateSnapshot.self, from: data)
    }

    private func saveAgentState(_ state: RemoteAgentStateSnapshot) throws {
        let url = stateFileURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }

    private func remoteBinaryPath() -> URL? {
        if let bundlePath = bundledRemoteBinaryPath(),
           FileManager.default.isExecutableFile(atPath: bundlePath.path) {
            return bundlePath
        }

        if let installedPath = installedRemoteBinaryPath(),
           FileManager.default.isExecutableFile(atPath: installedPath.path) {
            return installedPath
        }

        if let devPath = devRemoteBinaryPath(),
           FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }

        if let sourceURL = remoteAgentSourceURL(),
           let installedPath = installedRemoteBinaryPath(),
           buildRemoteAgent(from: sourceURL, outputURL: installedPath),
           FileManager.default.isExecutableFile(atPath: installedPath.path) {
            return installedPath
        }

        return nil
    }

    private func bundledRemoteBinaryPath() -> URL? {
        if let bundlePath = Chau7Resources.bundle.url(forResource: "chau7-remote", withExtension: nil) {
            return bundlePath
        }

        if let resourcesURL = Chau7Resources.bundle.resourceURL {
            let candidate = resourcesURL.appendingPathComponent("chau7-remote")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        return nil
    }

    private func installedRemoteBinaryPath() -> URL? {
        dataDirectory()?.appendingPathComponent("chau7-remote")
    }

    private func devRemoteBinaryPath() -> URL? {
        guard let projectRoot = projectRootURL() else { return nil }
        let devPath = projectRoot
            .appendingPathComponent("services/chau7-remote/chau7-remote")
        if FileManager.default.fileExists(atPath: devPath.path) {
            return devPath
        }

        let buildPath = projectRoot
            .appendingPathComponent("services/chau7-remote/cmd/chau7-remote/chau7-remote")
        if FileManager.default.fileExists(atPath: buildPath.path) {
            return buildPath
        }

        return nil
    }

    private func remoteAgentSourceURL() -> URL? {
        guard let projectRoot = projectRootURL() else { return nil }
        let sourceURL = projectRoot.appendingPathComponent("services/chau7-remote")
        let goMod = sourceURL.appendingPathComponent("go.mod")
        guard FileManager.default.fileExists(atPath: goMod.path) else { return nil }
        return sourceURL
    }

    private func projectRootURL() -> URL? {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func buildRemoteAgent(from sourceURL: URL, outputURL: URL) -> Bool {
        let outputDir = outputURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create remote agent output directory: \(error.localizedDescription)")
            lastError = "Failed to create remote agent output directory."
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["go", "build", "-o", outputURL.path, "./cmd/chau7-remote"]
        process.currentDirectoryURL = sourceURL

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            logger.error("Failed to launch go build: \(error.localizedDescription)")
            lastError = "Failed to launch Go build for remote agent."
            return false
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            logger.error("Remote agent build failed: \(output)")
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                lastError = "Remote agent build failed. Make sure Go is installed."
            } else {
                lastError = "Remote agent build failed. \(trimmed)"
            }
            return false
        }

        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: outputURL.path)
        } catch {
            logger.warning("Failed to set remote binary permissions: \(error.localizedDescription)")
        }

        return true
    }
}
