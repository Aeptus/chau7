import Chau7Core
import Foundation

protocol AgentDashboardSessionControlling {
    func allSessions(includeStopped: Bool) -> [DashboardSessionSnapshot]
    @discardableResult
    func stopSession(id: String) -> Bool
    func startSession(arguments: [String: Any]) -> String
}

final class AgentDashboardSessionController: AgentDashboardSessionControlling {
    static let shared = AgentDashboardSessionController()
    private let terminalControl = TerminalControlService.shared
    private let recorder = TelemetryRecorder.shared

    private init() {}

    func allSessions(includeStopped: Bool) -> [DashboardSessionSnapshot] {
        let runtimeSnapshots = DashboardSessionSnapshot.indexByTabID(
            RuntimeSessionManager.shared
                .allSessions(includeStopped: includeStopped)
                .map { snapshot(from: $0) }
        )

        var snapshots: [DashboardSessionSnapshot] = []
        for liveTab in liveTabs() {
            let activeRun = recorder.activeRunForTab(liveTab.tabIdentifier)
            guard liveTab.isAgentTab(activeRun: activeRun) else { continue }

            if let runtimeSnapshot = runtimeSnapshots[liveTab.tabID] {
                snapshots.append(runtimeSnapshot.mergingLiveTab(liveTab, activeRun: activeRun))
            } else {
                snapshots.append(.fallback(
                    id: fallbackSessionID(for: liveTab.tabID),
                    liveTab: liveTab,
                    activeRun: activeRun
                ))
            }
        }
        return snapshots.sorted { $0.createdAt < $1.createdAt }
    }

    @discardableResult
    func stopSession(id: String) -> Bool {
        if RuntimeSessionManager.shared.stopSession(id: id) {
            return true
        }

        guard let tabID = fallbackTabID(from: id) else {
            return false
        }
        let response = MainActorBridge.sync { terminalControl.sendInput(tabID: tabID.uuidString, input: "\u{3}") }
        return !response.contains("\"error\"")
    }

    func startSession(arguments: [String: Any]) -> String {
        RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: arguments
        )
    }

    /// Callers run on the dashboard's background refresh queue, so every
    /// session read happens here, inside the main-thread hop.
    private func liveTabs() -> [DashboardLiveTabState] {
        MainActorBridge.sync { liveTabsOnMain() }
    }

    @MainActor
    private func liveTabsOnMain() -> [DashboardLiveTabState] {
        terminalControl.allTabs.compactMap { tab in
            guard let session = tab.displaySession ?? tab.session else { return nil }
            return DashboardLiveTabState(tabID: tab.id, session: session)
        }
    }

    private func snapshot(from session: RuntimeSession) -> DashboardSessionSnapshot {
        let usage = session.cumulativeTokenUsage
        return DashboardSessionSnapshot(
            id: session.id,
            tabID: session.tabID,
            backendName: session.backend.name,
            directory: session.config.directory,
            purpose: session.config.purpose,
            parentSessionID: session.config.parentSessionID,
            delegationDepth: session.config.delegationDepth,
            state: DashboardAgentState(runtimeState: session.state),
            turnCount: session.turnCount,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens + usage.reasoningOutputTokens,
            cacheCreationTokens: session.cumulativeCacheCreationTokens,
            cacheReadTokens: session.cumulativeCacheReadTokens,
            requiresApproval: session.pendingApproval != nil,
            latestResult: DashboardAgentResult(runtimeResult: session.turnResult()),
            createdAt: session.createdAt,
            costUSD: session.estimatedCostUSD ?? 0,
            journal: session.journal
        )
    }

    private func fallbackSessionID(for tabID: UUID) -> String {
        "tab:\(tabID.uuidString)"
    }

    private func fallbackTabID(from sessionID: String) -> UUID? {
        guard sessionID.hasPrefix("tab:") else { return nil }
        return UUID(uuidString: String(sessionID.dropFirst(4)))
    }
}

private extension DashboardAgentState {
    init(runtimeState: RuntimeSessionStateMachine.State) {
        switch runtimeState {
        case .ready: self = .ready
        case .busy: self = .busy
        case .awaitingApproval: self = .awaitingApproval
        case .waitingInput: self = .waitingInput
        case .interrupted: self = .interrupted
        case .failed: self = .failed
        case .stopped: self = .stopped
        case .starting: self = .starting
        }
    }
}

private extension DashboardAgentResult {
    init?(runtimeResult: RuntimeTurnResult?) {
        guard let runtimeResult else { return nil }
        self.init(
            status: DashboardResultStatus(runtimeStatus: runtimeResult.status),
            summary: runtimeResult.value?.objectValue?["summary"]?.stringValue
        )
    }
}

private extension DashboardResultStatus {
    init(runtimeStatus: RuntimeTurnResultStatus) {
        switch runtimeStatus {
        case .available: self = .available
        case .invalid: self = .invalid
        case .missing: self = .missing
        }
    }
}
