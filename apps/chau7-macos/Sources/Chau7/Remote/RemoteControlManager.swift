import Foundation
import os.log
import Chau7Core
import Darwin

@MainActor
@Observable
final class RemoteControlManager {
    static let shared = RemoteControlManager()

    private(set) var isAgentRunning = false
    private(set) var isIPCConnected = false
    private(set) var sessionStatus: String?
    private(set) var pairingInfo: RemotePairingInfo?
    private(set) var lastError: String?
    private(set) var pairedDevices: [RemotePairedDevice] = []
    private(set) var remoteActivity: RemoteActivityState?
    private(set) var interactivePrompts: [RemoteInteractivePrompt] = []

    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var outputPipe: Pipe?
    @ObservationIgnored private var errorPipe: Pipe?
    @ObservationIgnored private let logger = Logger(subsystem: "com.chau7.remote", category: "RemoteManager")
    @ObservationIgnored private weak var overlayModel: OverlayTabsModel?

    @ObservationIgnored private var tabRegistry = RemoteTabRegistry()
    @ObservationIgnored private var seqCounter: UInt64 = 1
    @ObservationIgnored private var pendingProtectedInputs: [String: ProtectedRemoteInput] = [:]
    @ObservationIgnored private var approvalContexts: [String: PendingRemoteApprovalContext] = [:]
    @ObservationIgnored private var connectedPairedDeviceID: String?
    @ObservationIgnored private var connectedClientAppState: RemoteClientAppState = .foreground
    @ObservationIgnored private var connectedClientStreamMode: RemoteClientStreamMode = .full
    @ObservationIgnored private var subscribedSessionIDs: Set<String> = []
    @ObservationIgnored private var activityRefreshWorkItem: DispatchWorkItem?
    @ObservationIgnored private var backgroundSnapshotTask: Task<Void, Never>?
    @ObservationIgnored private var outputFlushTask: Task<Void, Never>?
    @ObservationIgnored private var pendingOutputByTabID = RemotePendingOutputBuffer<Data>()

    @ObservationIgnored private let ipc = RemoteIPCServer.shared

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
            self?.connectedClientAppState = .foreground
            self?.connectedClientStreamMode = .full
            self?.remoteActivity = nil
            self?.cancelBackgroundSnapshotPrefetch()
            self?.cancelPendingOutputFlush()
            self?.refreshPairedDevices()
        }
        ipc.start()
        refreshPairedDevices()

        FeatureSettings.shared.onRemoteEnabledChanged = { [weak self] enabled in
            if enabled {
                self?.startAgent()
            } else {
                self?.stopAgent()
            }
        }

        FeatureSettings.shared.onRemoteRelayURLChanged = { [weak self] _ in
            self?.restartAgentIfRunning()
        }

        overlayModel.onTabsChanged = { [weak self] in
            self?.sendTabList()
            self?.sendSelectedTabSnapshot()
            self?.scheduleBackgroundSnapshotPrefetch()
            self?.rebuildSessionStateSubscriptions()
            self?.scheduleRemoteActivityRefresh()
        }

        overlayModel.onSelectedTabIDChanged = { [weak self] in
            self?.sendTabList()
            self?.sendSelectedTabSnapshot()
            self?.scheduleRemoteActivityRefresh()
        }

        rebuildSessionStateSubscriptions()
    }

    func recordOutput(_ data: Data, sessionIdentifier: String) {
        guard isIPCConnected, connectedClientStreamMode == .full else { return }
        guard let tabID = tabRegistry.tabID(forSessionIdentifier: sessionIdentifier) else { return }
        guard tabID == selectedRemoteTabID() else { return }
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
        sendTextSnapshot(for: tabID)
        sendGridSnapshot(for: tabID)
    }

    func sendTextSnapshot(for tabID: UInt32) {
        guard connectedClientStreamMode == .full else { return }
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

    func sendGridSnapshot(for tabID: UInt32) {
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
              let snapshot = session.captureRemoteGridSnapshot() else { return }
        sendFrame(type: .terminalGridSnapshot, tabID: tabID, payload: snapshot)
    }

    private func startAgent() {
        guard !isAgentRunning else { return }
        guard let binaryPath = remoteBinaryPath() else {
            let error = lastError ?? "Remote agent binary not found."
            logger.error("\(error, privacy: .public)")
            lastError = error
            return
        }

        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryPath.path)
        } catch {
            logger.warning("Failed to set remote binary permissions: \(error.localizedDescription, privacy: .public)")
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
            self?.logger.debug("Remote stdout: \(output, privacy: .public)")
        }

        errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let output = String(data: data, encoding: .utf8) else { return }
            self?.logger.warning("Remote stderr: \(output, privacy: .public)")
        }

        process.terminationHandler = { [weak self] proc in
            Task { @MainActor in
                guard let self else { return }
                self.isAgentRunning = false
                if proc.terminationStatus != 0 {
                    let error = "Remote agent exited with status \(proc.terminationStatus)"
                    self.logger.error("\(error, privacy: .public)")
                    self.lastError = error
                }
            }
        }

        do {
            try process.run()
            self.process = process
            isAgentRunning = true
            lastError = nil
            logger.info("Remote agent started from \(binaryPath.path, privacy: .public)")
            refreshPairedDevices()
        } catch {
            let errorMessage = "Failed to start remote agent: \(error.localizedDescription)"
            logger.error("\(errorMessage, privacy: .public)")
            lastError = errorMessage
        }
    }

    func stopAgent() {
        guard let process else { return }
        process.terminationHandler = nil
        cancelBackgroundSnapshotPrefetch()
        cancelPendingOutputFlush()
        // Terminate process BEFORE closing pipes to avoid SIGPIPE
        ManagedProcess.terminate(process, name: "remote agent", logger: logger)
        ManagedProcess.cleanup(outputPipe: &outputPipe, errorPipe: &errorPipe)
        self.process = nil
        isAgentRunning = false
        pendingProtectedInputs.removeAll()
    }

    func restartAgentIfRunning() {
        guard isAgentRunning else { return }
        stopAgent()
        startAgent()
    }

    private func handleIPCFrame(_ frame: RemoteFrame) {
        guard let type = RemoteFrameType(rawValue: frame.type) else {
            logger.warning("Unknown IPC frame type: 0x\(String(frame.type, radix: 16), privacy: .public)")
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
        case .clientState:
            handleClientState(frame)
        case .approvalResponse:
            handleApprovalResponse(frame)
        case .ping:
            sendFrame(type: .pong, tabID: frame.tabID, payload: frame.payload)
        case .error:
            if let message = String(data: frame.payload, encoding: .utf8) {
                lastError = message
            }
        default:
            logger.debug("Unhandled IPC frame type: 0x\(String(type.rawValue, radix: 16), privacy: .public)")
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
        logger.info("Remote: sent approval request \(requestID, privacy: .public)")
    }

    private func handleApprovalResponse(_ frame: RemoteFrame) {
        // Purge expired pending approvals on each response
        purgeExpiredProtectedInputs()

        guard let response: ApprovalResponsePayload = decodePayload(frame, as: ApprovalResponsePayload.self, context: "approval response") else { return }
        let approvalContext = approvalContexts.removeValue(forKey: response.requestID)
        if let protectedInput = pendingProtectedInputs.removeValue(forKey: response.requestID) {
            if response.approved,
               let session = session(for: protectedInput.tabID) {
                session.sendInput(protectedInput.text)
                logger.info("Remote: protected action approved for tab \(protectedInput.tabID, privacy: .public)")
            } else {
                logger.info("Remote: protected action denied for tab \(protectedInput.tabID, privacy: .public)")
            }
            sendRemoteActivity()
            return
        }
        if let approvalContext, let uuid = tabRegistry.uuid(for: approvalContext.tabID) {
            _ = TerminalControlService.shared.clearPersistentNotificationStyleAcrossWindows(tabID: uuid)
        }
        TerminalControlService.shared.resolveApproval(requestID: response.requestID, approved: response.approved)
        sendRemoteActivity()
        logger.info("Remote: approval response for \(response.requestID, privacy: .public): \(response.approved ? ", privacy: .public)allowed" : "denied")")
    }

    private func handleRemoteTelemetry(_ frame: RemoteFrame) {
        guard let event: RemoteClientTelemetryEvent = decodePayload(frame, as: RemoteClientTelemetryEvent.self, context: "remote telemetry") else { return }
        TelemetryStore.shared.insertRemoteClientEvent(event)
    }

    private func handleClientState(_ frame: RemoteFrame) {
        guard let payload: RemoteClientStatePayload = decodePayload(frame, as: RemoteClientStatePayload.self, context: "client state") else { return }
        connectedClientAppState = payload.appState
        let previousStreamMode = connectedClientStreamMode
        connectedClientStreamMode = payload.streamMode

        if previousStreamMode != payload.streamMode, payload.streamMode == .approvalsOnly {
            cancelBackgroundSnapshotPrefetch()
            cancelPendingOutputFlush()
        }

        if payload.streamMode == .full {
            sendInitialState()
        } else {
            sendPendingApprovalRequests()
            sendInteractivePrompts(force: true)
        }
    }

    private func sendInitialState() {
        sendPendingApprovalRequests()
        guard connectedClientStreamMode == .full else {
            sendInteractivePrompts(force: true)
            return
        }
        sendTabList()
        sendSelectedTabSnapshot()
        scheduleBackgroundSnapshotPrefetch()
        sendRemoteActivity(force: true)
        sendInteractivePrompts(force: true)
    }

    private func sendSelectedTabSnapshot() {
        guard connectedClientStreamMode == .full else { return }
        guard let overlayModel,
              let tabID = tabRegistry.tabID(for: overlayModel.selectedTabID) else {
            return
        }
        sendSnapshot(for: tabID)
    }

    private func rebuildSessionStateSubscriptions() {
        guard let overlayModel else {
            subscribedSessionIDs.removeAll()
            return
        }

        let sessions = overlayModel.tabs.compactMap(\.session)
        let validIDs = Set(sessions.map(\.tabIdentifier))

        // Remove stale subscriptions
        for staleID in subscribedSessionIDs where !validIDs.contains(staleID) {
            subscribedSessionIDs.remove(staleID)
        }

        // Subscribe to new sessions via callback
        for session in sessions where !subscribedSessionIDs.contains(session.tabIdentifier) {
            subscribedSessionIDs.insert(session.tabIdentifier)
            session.onSessionStateChanged = { [weak self] in
                DispatchQueue.main.async {
                    self?.scheduleRemoteActivityRefresh()
                }
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
        let activityChanged = force || nextActivity != remoteActivity
        if activityChanged {
            remoteActivity = nextActivity
        }

        if connectedClientStreamMode == .full, isIPCConnected, activityChanged {
            if let nextActivity,
               let payload = try? JSONEncoder().encode(nextActivity) {
                sendFrame(type: .activityState, tabID: nextActivity.tabID, payload: payload)
            } else {
                sendFrame(type: .activityCleared, tabID: 0, payload: Data())
            }
        }
        sendInteractivePrompts(force: force)
    }

    private func sendPendingApprovalRequests() {
        guard isIPCConnected else { return }
        purgeExpiredProtectedInputs()
        let pendingContexts = approvalContexts.values.sorted { $0.requestedAt < $1.requestedAt }
        for context in pendingContexts {
            let payload = ApprovalRequestPayload(
                requestID: context.requestID,
                command: context.command,
                flaggedCommand: context.flaggedCommand,
                timestamp: ISO8601DateFormatter().string(from: context.requestedAt),
                tabTitle: context.tabTitle,
                toolName: context.toolName,
                projectName: context.projectName,
                branchName: context.branchName,
                currentDirectory: context.currentDirectory,
                recentCommand: context.recentCommand,
                contextNote: context.contextNote,
                sessionID: context.sessionID
            )
            guard let data = try? JSONEncoder().encode(payload) else { continue }
            sendFrame(type: .approvalRequest, tabID: 0, payload: data)
        }
    }

    private func sendInteractivePrompts(force: Bool = false) {
        let nextPrompts = currentInteractivePrompts()
        guard force || nextPrompts != interactivePrompts else { return }

        interactivePrompts = nextPrompts
        guard isIPCConnected,
              let payload = try? JSONEncoder().encode(RemoteInteractivePromptListPayload(prompts: nextPrompts)) else {
            return
        }
        sendFrame(type: .interactivePromptList, tabID: 0, payload: payload)
    }

    private func currentRemoteActivity(now: Date = Date()) -> RemoteActivityState? {
        guard let overlayModel else { return nil }

        let approvalsByTabID = Dictionary(grouping: approvalContexts.values, by: \.tabID)
        let candidates = overlayModel.tabs.flatMap { tab -> [RemoteActivityCandidate] in
            guard let tabID = tabRegistry.tabID(for: tab.id) else {
                return []
            }

            let approval = approvalsByTabID[tabID]?.max { $0.requestedAt < $1.requestedAt }
            var candidates: [RemoteActivityCandidate] = []

            if let approval {
                let displayMetadata = activityDisplayMetadata(toolName: approval.toolName, provider: nil)
                candidates.append(RemoteActivityCandidate(
                    activityID: "tab-\(tabID)-approval",
                    tabID: tabID,
                    tabTitle: approval.tabTitle,
                    toolName: approval.toolName,
                    projectName: approval.projectName,
                    sessionID: approval.sessionID,
                    status: .approvalRequired,
                    detail: approval.approval.displayCommand,
                    logoAssetName: displayMetadata.logoAssetName,
                    tabColorName: displayMetadata.tabColorName,
                    isSelected: tab.id == overlayModel.selectedTabID,
                    updatedAt: approval.requestedAt,
                    startedAt: approval.requestedAt,
                    approval: approval.approval
                ))
            }

            for (paneID, session) in tab.splitController.terminalSessions {
                let toolName = activityToolName(for: session, tab: tab)
                let projectName = activityProjectName(for: session)
                let displayMetadata = activityDisplayMetadata(
                    toolName: toolName,
                    provider: session.effectiveAIProvider
                )
                let startedAt = session.agentStartedAt ?? tab.lastCommand?.startTime
                let updatedAt = activityUpdatedAt(for: session, tab: tab, approval: nil)

                guard session.aiDisplayAppName != nil ||
                    session.effectiveAIProvider != nil ||
                    session.effectiveAISessionId != nil else {
                    continue
                }

                let resolvedStatus: RemoteActivityStatus?
                let detail: String?

                switch session.effectiveStatus {
                case .approvalRequired:
                    resolvedStatus = .approvalRequired
                    detail = session.effectiveIsAtPrompt ? "Approval required at prompt" : "Approval required"
                case .waitingForInput:
                    resolvedStatus = .waitingInput
                    detail = session.effectiveIsAtPrompt ? "Waiting at prompt" : nil
                case .running:
                    resolvedStatus = .running
                    detail = nil
                case .stuck:
                    resolvedStatus = .running
                    detail = "No output for a while"
                case .done, .idle, .exited:
                    if let outcome = recentCompletionStatus(for: session, tab: tab, now: now) {
                        resolvedStatus = outcome.status
                        detail = outcome.detail
                    } else {
                        resolvedStatus = nil
                        detail = nil
                    }
                }

                guard let resolvedStatus else { continue }

                candidates.append(RemoteActivityCandidate(
                    activityID: "tab-\(tabID)-pane-\(paneID.uuidString.lowercased())",
                    tabID: tabID,
                    tabTitle: activityTabTitle(for: tab),
                    toolName: toolName,
                    projectName: projectName,
                    sessionID: session.effectiveAISessionId,
                    status: resolvedStatus,
                    detail: detail,
                    logoAssetName: displayMetadata.logoAssetName,
                    tabColorName: displayMetadata.tabColorName,
                    isSelected: tab.id == overlayModel.selectedTabID,
                    updatedAt: updatedAt,
                    startedAt: startedAt
                ))
            }

            return candidates
        }

        return RemoteActivityProjection.project(from: candidates)
    }

    private func currentInteractivePrompts() -> [RemoteInteractivePrompt] {
        guard let overlayModel else { return [] }

        return remoteControllableTabs(from: overlayModel).flatMap { tab -> [RemoteInteractivePrompt] in
            guard let tabID = tabRegistry.tabID(for: tab.id) else {
                return []
            }

            return tab.splitController.terminalSessions.compactMap { paneID, session in
                guard session.effectiveStatus == .waitingForInput else { return nil }

                let toolName = activityToolName(for: session, tab: tab)
                guard let snapshot = session.captureRemoteSnapshot(),
                      let text = String(data: snapshot, encoding: .utf8),
                      let detected = InteractivePromptDetector.detect(in: text, toolName: toolName) else {
                    return nil
                }

                return RemoteInteractivePrompt(
                    id: "tab-\(tabID)-pane-\(paneID.uuidString.lowercased())-\(detected.signature)",
                    tabID: tabID,
                    tabTitle: activityTabTitle(for: tab),
                    toolName: toolName,
                    projectName: activityProjectName(for: session),
                    branchName: activityBranchName(for: session),
                    currentDirectory: activityCurrentDirectory(for: session),
                    prompt: detected.prompt,
                    detail: detected.detail,
                    options: detected.options,
                    detectedAt: activityUpdatedAt(for: session, tab: tab, approval: nil)
                )
            }
        }
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
        if let repoName = session.repoName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !repoName.isEmpty {
            return repoName
        }
        let trimmed = session.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        return lastPathComponent.isEmpty ? trimmed : lastPathComponent
    }

    private func activityBranchName(for session: TerminalSessionModel) -> String? {
        let trimmed = session.gitBranch?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func activityCurrentDirectory(for session: TerminalSessionModel) -> String? {
        let trimmed = session.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func activityRecentCommand(for tab: OverlayTab) -> String? {
        if let sessionCommand = tab.displaySession?.lastAgentLaunchCommand?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionCommand.isEmpty {
            return sessionCommand
        }
        let trimmed = tab.lastCommand?.command.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private func activityContextNote(for session: TerminalSessionModel) -> String? {
        switch session.effectiveStatus {
        case .approvalRequired:
            return session.effectiveIsAtPrompt ? "Approval required at prompt" : "Approval required"
        case .waitingForInput:
            return session.effectiveIsAtPrompt ? "Waiting at prompt" : "Waiting for input"
        case .running:
            return "Command is running"
        case .stuck:
            return "No output for a while"
        case .done:
            return "Task finished at prompt"
        case .idle, .exited:
            return nil
        }
    }

    private func activityUpdatedAt(
        for session: TerminalSessionModel,
        tab: OverlayTab,
        approval: PendingRemoteApprovalContext?
    ) -> Date {
        [
            approval?.requestedAt,
            session.lastInputDate,
            session.lastExitAt,
            tab.lastCommand?.endTime,
            tab.lastCommand?.startTime,
            session.lastOutputDate
        ]
        .compactMap { $0 }
        .max() ?? Date()
    }

    private func recentCompletionStatus(
        for session: TerminalSessionModel,
        tab: OverlayTab,
        now: Date
    ) -> (status: RemoteActivityStatus, detail: String?)? {
        let commandText = session.lastAgentLaunchCommand?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let exitAt = session.lastExitAt,
           now.timeIntervalSince(exitAt) <= 20 {
            let exitCode = session.lastExitCode ?? 0
            if exitCode == 0 {
                return (
                    .completed,
                    commandText?.isEmpty == false ? commandText : nil
                )
            }

            if let commandText, !commandText.isEmpty {
                return (.failed, "Exit \(exitCode): \(commandText)")
            }
            return (.failed, "Exit \(exitCode)")
        }

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

    private func activityDisplayMetadata(toolName: String, provider: String?) -> AIToolDisplayMetadata {
        AIToolRegistry.displayMetadata(forName: toolName)
            ?? AIToolRegistry.displayMetadata(forName: provider)
            ?? AIToolDisplayMetadata(logoAssetName: nil, tabColorName: nil)
    }

    private func sendTabList() {
        guard connectedClientStreamMode == .full else { return }
        guard let overlayModel else { return }
        let controllableTabs = remoteControllableTabs(from: overlayModel)
        let tabPayloads = tabRegistry.rebuild(
            with: controllableTabs.map { tab in
                RemoteTabRegistryEntry(
                    id: tab.id,
                    sessionIdentifier: tab.session?.tabIdentifier,
                    title: tab.displayTitle,
                    projectName: tab.displaySession.flatMap(activityProjectName(for:)) ?? tab.session.flatMap(activityProjectName(for:)),
                    branchName: tab.displaySession.flatMap(activityBranchName(for:)) ?? tab.session.flatMap(activityBranchName(for:)),
                    isActive: tab.id == overlayModel.selectedTabID,
                    isMCPControlled: tab.isMCPControlled
                )
            }
        )

        do {
            let payload = try JSONEncoder().encode(RemoteTabListPayload(tabs: tabPayloads))
            sendFrame(type: .tabList, tabID: 0, payload: payload)
            logger.info("Remote: sent tab list with \(tabPayloads.count, privacy: .public) tabs")
            sendRemoteActivity()
            sendInteractivePrompts()
        } catch {
            logger.warning("Failed to encode tab list: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleBackgroundSnapshotPrefetch() {
        cancelBackgroundSnapshotPrefetch()
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
            flushPendingOutput()
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
        guard connectedClientStreamMode == .full, isIPCConnected, !pendingOutputByTabID.isEmpty else { return }

        let selectedRemoteTabID = selectedRemoteTabID()

        for (tabID, payload) in pendingOutputByTabID.drainAll(sortedByTabID: true) {
            guard tabID == selectedRemoteTabID else { continue }
            let token = FeatureProfiler.shared.begin(.remoteOutput, bytes: payload.count)
            sendFrame(type: .output, tabID: tabID, payload: payload)
            FeatureProfiler.shared.end(token)
            sendGridSnapshot(for: tabID)
        }
    }

    private func selectedRemoteTabID() -> UInt32? {
        guard let overlayModel else { return nil }
        return tabRegistry.tabID(for: overlayModel.selectedTabID)
    }

    private func remoteControllableTabs(from overlayModel: OverlayTabsModel) -> [OverlayTab] {
        let tabs = overlayModel.tabs.filter { $0.session != nil }
        if tabs.isEmpty {
            logger.info(
                """
                Remote: no controllable tabs. overlay tabs=\(overlayModel.tabs.count) \
                selected=\(overlayModel.selectedTabID.uuidString)
                """
            )
        }
        return tabs
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
            logger.warning("Failed to encode remote error payload for code \(code, privacy: .public)")
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
            logger.warning("Failed to decode \(context, privacy: .public): \(error.localizedDescription, privacy: .public)")
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
            logger.info("Remote: expired protected action for tab \(input.tabID, privacy: .public) after \(ProtectedRemoteInput.ttl, privacy: .public)s")
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
                tabTitle: approval.tabTitle ?? activityTabTitle(for: tab),
                toolName: approval.toolName ?? activityToolName(for: session, tab: tab),
                projectName: approval.projectName ?? activityProjectName(for: session),
                branchName: approval.branchName ?? activityBranchName(for: session),
                currentDirectory: approval.currentDirectory ?? activityCurrentDirectory(for: session),
                recentCommand: approval.recentCommand ?? activityRecentCommand(for: tab),
                contextNote: approval.contextNote ?? activityContextNote(for: session),
                sessionID: approval.sessionID ?? session.effectiveAISessionId,
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
            tabTitle: approval.tabTitle ?? activityTabTitle(for: tab),
            toolName: approval.toolName ?? activityToolName(for: session, tab: tab),
            projectName: approval.projectName ?? activityProjectName(for: session),
            branchName: approval.branchName ?? activityBranchName(for: session),
            currentDirectory: approval.currentDirectory ?? activityCurrentDirectory(for: session),
            recentCommand: approval.recentCommand ?? activityRecentCommand(for: tab),
            contextNote: approval.contextNote ?? activityContextNote(for: session),
            sessionID: approval.sessionID ?? session.effectiveAISessionId,
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
            logger.warning("Remote: pending protected inputs at capacity (\(Self.maxPendingProtectedInputs, privacy: .public)), dropping oldest")
            if let oldestKey = pendingProtectedInputs.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
                pendingProtectedInputs.removeValue(forKey: oldestKey)
            }
        }
        pendingProtectedInputs[requestID] = ProtectedRemoteInput(
            tabID: tabID,
            text: text,
            flaggedCommand: flaggedCommand
        )

        let approvalContext: PendingRemoteApprovalContext?
        if let session = session(for: tabID),
           let uuid = tabRegistry.uuid(for: tabID),
           let tab = overlayModel?.tabs.first(where: { $0.id == uuid }) {
            let context = PendingRemoteApprovalContext(
                requestID: requestID,
                tabID: tabID,
                tabTitle: activityTabTitle(for: tab),
                toolName: activityToolName(for: session, tab: tab),
                projectName: activityProjectName(for: session),
                branchName: activityBranchName(for: session),
                currentDirectory: activityCurrentDirectory(for: session),
                recentCommand: activityRecentCommand(for: tab),
                contextNote: activityContextNote(for: session),
                sessionID: session.effectiveAISessionId,
                command: text.trimmingCharacters(in: .whitespacesAndNewlines),
                flaggedCommand: flaggedCommand,
                requestedAt: Date()
            )
            approvalContexts[requestID] = context
            approvalContext = context
        } else {
            approvalContext = nil
        }

        let payload = ApprovalRequestPayload(
            requestID: requestID,
            command: text.trimmingCharacters(in: .whitespacesAndNewlines),
            flaggedCommand: flaggedCommand,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            tabTitle: approvalContext?.tabTitle,
            toolName: approvalContext?.toolName,
            projectName: approvalContext?.projectName,
            branchName: approvalContext?.branchName,
            currentDirectory: approvalContext?.currentDirectory,
            recentCommand: approvalContext?.recentCommand,
            contextNote: approvalContext?.contextNote,
            sessionID: approvalContext?.sessionID
        )

        guard let data = try? JSONEncoder().encode(payload) else {
            pendingProtectedInputs.removeValue(forKey: requestID)
            logger.error("Remote: failed to encode protected action approval payload")
            return
        }

        sendApprovalRequest(requestID: requestID, payload: data)
        logger.warning("Remote: queued protected action approval for tab \(tabID, privacy: .public) (\(sessionTitle, privacy: .public))")
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
            logger.error("Failed to create data directory: \(error.localizedDescription, privacy: .public)")
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
            logger.error("Failed to revoke paired device: \(error.localizedDescription, privacy: .public)")
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
            logger.warning("Failed to refresh paired devices: \(error.localizedDescription, privacy: .public)")
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
        let fileManager = FileManager.default

        if let sourceURL = remoteAgentSourceURL(),
           let installedPath = installedRemoteBinaryPath(),
           shouldRefreshInstalledRemoteBinary(at: installedPath, from: sourceURL) {
            if buildRemoteAgent(from: sourceURL, outputURL: installedPath),
               FileManager.default.isExecutableFile(atPath: installedPath.path) {
                return installedPath
            }
        }

        if let devPath = devRemoteBinaryPath(),
           fileManager.isExecutableFile(atPath: devPath.path) {
            return devPath
        }

        if let installedPath = installedRemoteBinaryPath(),
           fileManager.isExecutableFile(atPath: installedPath.path) {
            return installedPath
        }

        if let bundlePath = bundledRemoteBinaryPath(),
           fileManager.isExecutableFile(atPath: bundlePath.path) {
            syncInstalledRemoteBinary(from: bundlePath)
            if let installedPath = installedRemoteBinaryPath(),
               fileManager.isExecutableFile(atPath: installedPath.path) {
                return installedPath
            }
            return bundlePath
        }

        if let sourceURL = remoteAgentSourceURL(),
           let installedPath = installedRemoteBinaryPath(),
           buildRemoteAgent(from: sourceURL, outputURL: installedPath),
           fileManager.isExecutableFile(atPath: installedPath.path) {
            return installedPath
        }

        return nil
    }

    private func syncInstalledRemoteBinary(from bundledPath: URL) {
        guard let installedPath = installedRemoteBinaryPath() else { return }
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: installedPath.path),
           !shouldReplaceInstalledRemoteBinary(at: installedPath, with: bundledPath) {
            return
        }

        do {
            try fileManager.createDirectory(
                at: installedPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if fileManager.fileExists(atPath: installedPath.path) {
                try fileManager.removeItem(at: installedPath)
            }
            try fileManager.copyItem(at: bundledPath, to: installedPath)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedPath.path)
        } catch {
            logger.warning("Failed to sync bundled remote agent to App Support: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func shouldReplaceInstalledRemoteBinary(at installedPath: URL, with bundledPath: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: installedPath.path) else { return true }
        guard fileManager.isExecutableFile(atPath: installedPath.path),
              fileManager.isExecutableFile(atPath: bundledPath.path) else {
            return true
        }
        return !fileManager.contentsEqual(atPath: installedPath.path, andPath: bundledPath.path)
    }

    private func shouldRefreshInstalledRemoteBinary(at binaryURL: URL, from sourceURL: URL) -> Bool {
        guard let binaryDate = modificationDate(for: binaryURL) else {
            return true
        }

        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: sourceURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        for case let candidate as URL in enumerator {
            guard ["go", "mod", "sum"].contains(candidate.pathExtension) else { continue }
            guard let sourceDate = modificationDate(for: candidate), sourceDate > binaryDate else { continue }
            return true
        }

        return false
    }

    private func modificationDate(for url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
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
        let packagedBuildPath = projectRoot
            .appendingPathComponent("apps/chau7-macos/build/remote-agent/chau7-remote")
        if FileManager.default.isExecutableFile(atPath: packagedBuildPath.path) {
            return packagedBuildPath
        }

        let devPath = projectRoot
            .appendingPathComponent("services/chau7-remote/chau7-remote")
        if FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }

        let buildPath = projectRoot
            .appendingPathComponent("services/chau7-remote/cmd/chau7-remote/chau7-remote")
        if FileManager.default.isExecutableFile(atPath: buildPath.path) {
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
            logger.error("Failed to create remote agent output directory: \(error.localizedDescription, privacy: .public)")
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
            logger.error("Failed to launch go build: \(error.localizedDescription, privacy: .public)")
            lastError = "Failed to launch Go build for remote agent."
            return false
        }

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: outputData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            logger.error("Remote agent build failed: \(output, privacy: .public)")
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
            logger.warning("Failed to set remote binary permissions: \(error.localizedDescription, privacy: .public)")
        }

        return true
    }
}
