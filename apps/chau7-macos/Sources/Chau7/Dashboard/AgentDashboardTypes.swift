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

extension DashboardAgentResult {
    init?(runtimeResult: RuntimeTurnResult?) {
        guard let runtimeResult else { return nil }
        self.init(
            status: DashboardResultStatus(runtimeStatus: runtimeResult.status),
            summary: runtimeResult.value?.objectValue?["summary"]?.stringValue
        )
    }
}

extension DashboardResultStatus {
    init(runtimeStatus: RuntimeTurnResultStatus) {
        switch runtimeStatus {
        case .available: self = .available
        case .invalid: self = .invalid
        case .missing: self = .missing
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
