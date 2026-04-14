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
