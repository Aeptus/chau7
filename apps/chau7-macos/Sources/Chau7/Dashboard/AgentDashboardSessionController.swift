import Foundation

protocol AgentDashboardSessionControlling {
    func allSessions(includeStopped: Bool) -> [DashboardSessionSnapshot]
    @discardableResult
    func stopSession(id: String) -> Bool
    func startSession(arguments: [String: Any]) -> String
}

final class RuntimeAgentDashboardSessionController: AgentDashboardSessionControlling {
    static let shared = RuntimeAgentDashboardSessionController()

    private init() {}

    func allSessions(includeStopped: Bool) -> [DashboardSessionSnapshot] {
        RuntimeSessionManager.shared.allSessions(includeStopped: includeStopped).map { session in
            let usage = session.cumulativeTokenUsage
            let costUSD = session.estimatedCostUSD ?? 0
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
                costUSD: costUSD,
                journal: session.journal
            )
        }
    }

    @discardableResult
    func stopSession(id: String) -> Bool {
        RuntimeSessionManager.shared.stopSession(id: id)
    }

    func startSession(arguments: [String: Any]) -> String {
        RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: arguments
        )
    }
}
