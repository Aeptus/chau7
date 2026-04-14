import Chau7Core
import Foundation

protocol AgentDashboardSessionControlling {
    func allSessions(includeStopped: Bool) -> [DashboardSessionSnapshot]
    @discardableResult
    func stopSession(id: String) -> Bool
    func startSession(arguments: [String: Any]) -> String
}

final class RuntimeAgentDashboardSessionController: AgentDashboardSessionControlling {
    static let shared = RuntimeAgentDashboardSessionController()
    private let terminalControl = TerminalControlService.shared
    private let recorder = TelemetryRecorder.shared

    private init() {}

    func allSessions(includeStopped: Bool) -> [DashboardSessionSnapshot] {
        let runtimeSnapshots = Dictionary(uniqueKeysWithValues: RuntimeSessionManager.shared
            .allSessions(includeStopped: includeStopped)
            .map { snapshot(from: $0) }
            .map { ($0.tabID, $0) })

        var snapshots: [DashboardSessionSnapshot] = []
        for (tabID, session) in liveTabs() {
            let activeRun = recorder.activeRunForTab(session.tabIdentifier)
            guard isAgentTab(session: session, activeRun: activeRun) else { continue }

            if let runtimeSnapshot = runtimeSnapshots[tabID] {
                snapshots.append(runtimeSnapshot.mergingLiveTab(session, activeRun: activeRun))
            } else {
                snapshots.append(fallbackSnapshot(from: session, tabID: tabID, activeRun: activeRun))
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
        let response = terminalControl.sendInput(tabID: tabID.uuidString, input: "\u{3}")
        return !response.contains("\"error\"")
    }

    func startSession(arguments: [String: Any]) -> String {
        RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: arguments
        )
    }

    private func liveTabs() -> [(UUID, TerminalSessionModel)] {
        if Thread.isMainThread {
            return MainActor.assumeIsolated { liveTabsOnMain() }
        }
        return DispatchQueue.main.sync {
            liveTabsOnMain()
        }
    }

    @MainActor
    private func liveTabsOnMain() -> [(UUID, TerminalSessionModel)] {
        terminalControl.allTabs.compactMap { tab in
            guard let session = tab.displaySession ?? tab.session else { return nil }
            return (tab.id, session)
        }
    }

    private func isAgentTab(session: TerminalSessionModel, activeRun: TelemetryRun?) -> Bool {
        activeRun != nil
            || session.effectiveAIProvider != nil
            || session.effectiveAISessionId != nil
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

    private func fallbackSnapshot(from session: TerminalSessionModel, tabID: UUID, activeRun: TelemetryRun?) -> DashboardSessionSnapshot {
        let usage = activeRun?.tokenUsage ?? TokenUsage()
        let provider = (activeRun?.provider ?? session.effectiveAIProvider ?? session.activeAppName ?? "AI")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DashboardSessionSnapshot(
            id: fallbackSessionID(for: tabID),
            tabID: tabID,
            backendName: provider.isEmpty ? "AI" : provider,
            directory: session.displayGitRootPath ?? session.gitRootPath ?? session.currentDirectory,
            purpose: nil,
            parentSessionID: nil,
            delegationDepth: 0,
            state: DashboardAgentState(commandStatus: session.effectiveStatus, isAtPrompt: session.effectiveIsAtPrompt),
            turnCount: activeRun?.turnCount ?? 0,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens + usage.reasoningOutputTokens,
            cacheCreationTokens: usage.cacheCreationInputTokens,
            cacheReadTokens: usage.cacheReadInputTokens,
            requiresApproval: session.effectiveStatus == .approvalRequired,
            latestResult: nil,
            createdAt: activeRun?.startedAt ?? Date.distantPast,
            costUSD: activeRun?.costUSD ?? 0,
            journal: EventJournal()
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
