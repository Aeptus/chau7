import Chau7Core
import Foundation

enum DashboardAgentState: String {
    case ready
    case busy
    case awaitingApproval
    case waitingInput
    case interrupted
    case failed
    case stopped
    case starting
}

enum DashboardResultStatus: String {
    case available
    case invalid
    case missing
}

struct DashboardAgentResult {
    let status: DashboardResultStatus
    let summary: String?
}

struct DashboardSessionSnapshot {
    let id: String
    let tabID: UUID
    let backendName: String
    let directory: String
    let purpose: String?
    let parentSessionID: String?
    let delegationDepth: Int
    let state: DashboardAgentState
    let turnCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let requiresApproval: Bool
    let latestResult: DashboardAgentResult?
    let createdAt: Date
    let costUSD: Double
    let journal: EventJournal

    var totalTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }
}

extension DashboardAgentState {
    init(commandStatus: CommandStatus, isAtPrompt: Bool) {
        switch commandStatus {
        case .approvalRequired:
            self = .awaitingApproval
        case .waitingForInput:
            self = .waitingInput
        case .running, .stuck:
            self = .busy
        case .exited:
            self = .stopped
        case .idle, .done:
            self = isAtPrompt ? .ready : .busy
        }
    }
}

extension DashboardSessionSnapshot {
    func mergingLiveTab(_ session: TerminalSessionModel, activeRun: TelemetryRun?) -> DashboardSessionSnapshot {
        let repoDirectory = session.displayGitRootPath ?? session.gitRootPath ?? session.currentDirectory
        let liveCost = activeRun?.costUSD ?? costUSD
        let liveTurnCount = max(turnCount, activeRun?.turnCount ?? 0)
        return DashboardSessionSnapshot(
            id: id,
            tabID: tabID,
            backendName: backendName,
            directory: repoDirectory,
            purpose: purpose,
            parentSessionID: parentSessionID,
            delegationDepth: delegationDepth,
            state: state,
            turnCount: liveTurnCount,
            inputTokens: inputTokens,
            outputTokens: outputTokens,
            cacheCreationTokens: cacheCreationTokens,
            cacheReadTokens: cacheReadTokens,
            requiresApproval: requiresApproval || session.effectiveStatus == .approvalRequired,
            latestResult: latestResult,
            createdAt: createdAt,
            costUSD: liveCost,
            journal: journal
        )
    }
}
