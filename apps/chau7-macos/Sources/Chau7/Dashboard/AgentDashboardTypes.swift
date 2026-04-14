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
