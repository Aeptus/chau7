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

    private var process: Process?
    private var outputPipe: Pipe?
    private var errorPipe: Pipe?
    private let logger = Logger(subsystem: "com.chau7.remote", category: "RemoteManager")
    private var cancellables: Set<AnyCancellable> = []
    private weak var overlayModel: OverlayTabsModel?

    private var tabIDByUUID: [UUID: UInt32] = [:]
    private var uuidByTabID: [UInt32: UUID] = [:]
    private var tabIDBySessionIdentifier: [String: UInt32] = [:]
    private var nextTabID: UInt32 = 1
    private var seqCounter: UInt64 = 1
    private var pendingProtectedInputs: [String: ProtectedRemoteInput] = [:]

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
        }
        ipc.start()

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
            }
            .store(in: &cancellables)

        overlayModel.$selectedTabID
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.sendTabList()
                self?.sendSnapshot(for: 0)
            }
            .store(in: &cancellables)
    }

    func recordOutput(_ data: Data, sessionIdentifier: String) {
        guard isIPCConnected else { return }
        guard let tabID = tabIDBySessionIdentifier[sessionIdentifier] else { return }
        let token = FeatureProfiler.shared.begin(.remoteOutput, bytes: data.count)
        sendFrame(type: .output, tabID: tabID, payload: data)
        FeatureProfiler.shared.end(token)
    }

    func sendSnapshot(for tabID: UInt32) {
        guard let overlayModel else { return }
        let targetTab: OverlayTab?
        if tabID == 0 {
            targetTab = overlayModel.selectedTab
        } else if let uuid = uuidByTabID[tabID] {
            targetTab = overlayModel.tabs.first { $0.id == uuid }
        } else {
            targetTab = nil
        }
        guard let session = targetTab?.session,
              let snapshot = session.captureRemoteSnapshot() else { return }
        sendFrame(type: .snapshot, tabID: tabID, payload: snapshot)
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
        process.currentDirectoryURL = dataDirectory()

        var env = ProcessInfo.processInfo.environment
        env["CHAU7_REMOTE_SOCKET"] = ipcSocketPath().path
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
        } catch {
            let errorMessage = "Failed to start remote agent: \(error.localizedDescription)"
            logger.error("\(errorMessage)")
            lastError = errorMessage
        }
    }

    func stopAgent() {
        guard let process else { return }
        process.terminationHandler = nil
        cleanupPipes()
        terminateProcess(process, name: "remote agent")
        self.process = nil
        isAgentRunning = false
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

    private func terminateProcess(_ process: Process, name: String) {
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

    private func waitForExit(of process: Process, timeout: TimeInterval) -> Bool {
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
        case .sessionStatus:
            do {
                let status = try JSONDecoder().decode(RemoteSessionStatus.self, from: frame.payload)
                sessionStatus = status.status
            } catch {
                logger.warning("Failed to decode session status: \(error.localizedDescription)")
            }
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
            break
        }
    }

    private func handlePairingInfo(_ frame: RemoteFrame) {
        do {
            let info = try JSONDecoder().decode(RemotePairingInfo.self, from: frame.payload)
            pairingInfo = info
        } catch {
            logger.warning("Failed to decode pairing info: \(error.localizedDescription)")
        }
    }

    private func handleTabSwitch(_ frame: RemoteFrame) {
        guard let overlayModel else { return }
        do {
            let payload = try JSONDecoder().decode(RemoteTabSwitchPayload.self, from: frame.payload)
            if let uuid = uuidByTabID[payload.tabID] {
                overlayModel.selectTab(id: uuid)
                sendSnapshot(for: payload.tabID)
            }
        } catch {
            logger.warning("Failed to decode tab switch payload: \(error.localizedDescription)")
        }
    }

    private func handleInput(_ frame: RemoteFrame) {
        guard let (session, resolvedTabID) = resolveInputTarget(for: frame.tabID),
              let text = String(data: frame.payload, encoding: .utf8) else {
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
        sendFrame(type: .approvalRequest, tabID: 0, payload: payload)
        logger.info("Remote: sent approval request \(requestID)")
    }

    private func handleApprovalResponse(_ frame: RemoteFrame) {
        do {
            let response = try JSONDecoder().decode(ApprovalResponsePayload.self, from: frame.payload)
            if let protectedInput = pendingProtectedInputs.removeValue(forKey: response.requestID) {
                if response.approved,
                   let session = session(for: protectedInput.tabID) {
                    session.sendInput(protectedInput.text)
                    logger.info("Remote: protected action approved for tab \(protectedInput.tabID)")
                } else {
                    logger.info("Remote: protected action denied for tab \(protectedInput.tabID)")
                }
                return
            }
            TerminalControlService.shared.resolveApproval(requestID: response.requestID, approved: response.approved)
            logger.info("Remote: approval response for \(response.requestID): \(response.approved ? "allowed" : "denied")")
        } catch {
            logger.warning("Failed to decode approval response: \(error.localizedDescription)")
        }
    }

    private func handleRemoteTelemetry(_ frame: RemoteFrame) {
        do {
            let event = try JSONDecoder().decode(RemoteClientTelemetryEvent.self, from: frame.payload)
            TelemetryStore.shared.insertRemoteClientEvent(event)
        } catch {
            logger.warning("Failed to decode remote telemetry event: \(error.localizedDescription)")
        }
    }

    private func sendInitialState() {
        sendTabList()
        sendSnapshot(for: 0)
    }

    private func sendTabList() {
        guard let overlayModel else { return }
        var tabPayloads: [RemoteTabDescriptor] = []
        var newTabIDByUUID: [UUID: UInt32] = [:]
        var newUUIDByTabID: [UInt32: UUID] = [:]
        var newTabIDBySession: [String: UInt32] = [:]

        for tab in overlayModel.tabs {
            let tabID = tabIDByUUID[tab.id] ?? nextTabID
            if tabIDByUUID[tab.id] == nil {
                nextTabID = nextTabID &+ 1
            }
            newTabIDByUUID[tab.id] = tabID
            newUUIDByTabID[tabID] = tab.id
            if let session = tab.session {
                newTabIDBySession[session.tabIdentifier] = tabID
            }
            tabPayloads.append(
                RemoteTabDescriptor(
                    tabID: tabID,
                    title: tab.displayTitle,
                    isActive: tab.id == overlayModel.selectedTabID,
                    isMCPControlled: tab.isMCPControlled
                )
            )
        }

        tabIDByUUID = newTabIDByUUID
        uuidByTabID = newUUIDByTabID
        tabIDBySessionIdentifier = newTabIDBySession

        do {
            let payload = try JSONEncoder().encode(RemoteTabListPayload(tabs: tabPayloads))
            sendFrame(type: .tabList, tabID: 0, payload: payload)
        } catch {
            logger.warning("Failed to encode tab list: \(error.localizedDescription)")
        }
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

    private func nextSeq() -> UInt64 {
        defer { seqCounter &+= 1 }
        return seqCounter
    }

    private func resolveInputTarget(for tabID: UInt32) -> (TerminalSessionModel, UInt32)? {
        guard let overlayModel else { return nil }
        if tabID == 0 {
            guard let selectedTab = overlayModel.selectedTab?.session,
                  let resolvedTabID = tabIDByUUID[overlayModel.selectedTabID] else {
                return nil
            }
            return (selectedTab, resolvedTabID)
        }

        guard let uuid = uuidByTabID[tabID],
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
              let uuid = uuidByTabID[tabID] else {
            return nil
        }
        return overlayModel.tabs.first(where: { $0.id == uuid })?.session
    }

    private func queueProtectedRemoteInput(
        requestID: String,
        text: String,
        tabID: UInt32,
        sessionTitle: String,
        flaggedCommand: String
    ) {
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

    private func dataDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Chau7")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            logger.error("Failed to create data directory: \(error.localizedDescription)")
        }
        return dir
    }

    private func ipcSocketPath() -> URL {
        dataDirectory().appendingPathComponent("remote.sock")
    }

    private func remoteBinaryPath() -> URL? {
        if let bundlePath = bundledRemoteBinaryPath(),
           FileManager.default.isExecutableFile(atPath: bundlePath.path) {
            return bundlePath
        }

        let installedPath = installedRemoteBinaryPath()
        if FileManager.default.isExecutableFile(atPath: installedPath.path) {
            return installedPath
        }

        if let devPath = devRemoteBinaryPath(),
           FileManager.default.isExecutableFile(atPath: devPath.path) {
            return devPath
        }

        if let sourceURL = remoteAgentSourceURL(),
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

    private func installedRemoteBinaryPath() -> URL {
        dataDirectory().appendingPathComponent("chau7-remote")
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
    let isActive: Bool
    let isMCPControlled: Bool

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case title
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

struct RemoteSessionStatus: Codable, Equatable {
    let status: String
}

private struct ProtectedRemoteInput {
    let tabID: UInt32
    let text: String
    let flaggedCommand: String
}
