import Foundation
import Combine
import os.log
import Chau7Core

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
            }
            .store(in: &cancellables)
    }

    func recordOutput(_ data: Data, sessionIdentifier: String) {
        guard isIPCConnected else { return }
        guard let tabID = tabIDBySessionIdentifier[sessionIdentifier] else { return }
        sendFrame(type: .output, tabID: tabID, payload: data)
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
            let error = "Remote agent binary not found."
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
        process.terminate()
        self.process = nil
        isAgentRunning = false
    }

    private func restartAgentIfRunning() {
        guard isAgentRunning else { return }
        stopAgent()
        startAgent()
    }

    private func handleIPCFrame(_ frame: RemoteFrame) {
        guard let type = RemoteFrameType(rawValue: frame.type) else { return }
        switch type {
        case .pairingInfo:
            handlePairingInfo(frame)
        case .sessionReady:
            isIPCConnected = true
        case .sessionStatus:
            if let status = try? JSONDecoder().decode(RemoteSessionStatus.self, from: frame.payload) {
                sessionStatus = status.status
            }
        case .tabSwitch:
            handleTabSwitch(frame)
        case .input:
            handleInput(frame)
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
            }
        } catch {
            logger.warning("Failed to decode tab switch payload: \(error.localizedDescription)")
        }
    }

    private func handleInput(_ frame: RemoteFrame) {
        guard let overlayModel else { return }
        let session: TerminalSessionModel?
        if frame.tabID == 0 {
            session = overlayModel.selectedTab?.session
        } else if let uuid = uuidByTabID[frame.tabID] {
            session = overlayModel.tabs.first(where: { $0.id == uuid })?.session
        } else {
            session = nil
        }
        guard let session else { return }
        if let text = String(data: frame.payload, encoding: .utf8) {
            session.sendInput(text)
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
                    isActive: tab.id == overlayModel.selectedTabID
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

    private func dataDirectory() -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("Chau7")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func ipcSocketPath() -> URL {
        dataDirectory().appendingPathComponent("remote.sock")
    }

    private func remoteBinaryPath() -> URL? {
        if let bundlePath = Bundle.main.url(forResource: "chau7-remote", withExtension: nil) {
            return bundlePath
        }

        if let resourcesURL = Bundle.main.resourceURL {
            let candidate = resourcesURL.appendingPathComponent("chau7-remote")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
        }

        let projectRoot = URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()

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
        guard let data = try? JSONEncoder().encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}

struct RemoteTabDescriptor: Codable, Equatable {
    let tabID: UInt32
    let title: String
    let isActive: Bool

    enum CodingKeys: String, CodingKey {
        case tabID = "tab_id"
        case title
        case isActive = "is_active"
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
