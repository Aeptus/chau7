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

extension DashboardSessionSnapshot {
    /// Builds a tab index without trapping if an upstream source contains
    /// duplicate sessions. Keep the newest session, with ID as a stable tie-breaker.
    static func indexByTabID(_ snapshots: [DashboardSessionSnapshot]) -> [UUID: DashboardSessionSnapshot] {
        snapshots.reduce(into: [:]) { index, candidate in
            guard let current = index[candidate.tabID] else {
                index[candidate.tabID] = candidate
                return
            }

            if candidate.createdAt > current.createdAt
                || (candidate.createdAt == current.createdAt && candidate.id > current.id) {
                index[candidate.tabID] = candidate
            }
        }
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

/// Value copy of the live-tab fields the dashboard reads.
///
/// Captured on the main thread, then consumed on the dashboard's background
/// refresh queue. `TerminalSessionModel` state (notably `effectiveStatus`,
/// which consults the main-actor `AppModel`) must never be read from that
/// queue — doing so trapped in `MainActor.assumeIsolated`.
struct DashboardLiveTabState {
    let tabID: UUID
    let tabIdentifier: String
    let aiProvider: String?
    let aiSessionId: String?
    let activeAppName: String?
    let directory: String
    let status: CommandStatus
    let isAtPrompt: Bool

    @MainActor
    init(tabID: UUID, session: TerminalSessionModel) {
        self.init(
            tabID: tabID,
            tabIdentifier: session.tabIdentifier,
            aiProvider: session.effectiveAIProvider,
            aiSessionId: session.effectiveAISessionId,
            activeAppName: session.activeAppName,
            directory: session.displayGitRootPath ?? session.gitRootPath ?? session.currentDirectory,
            status: session.effectiveStatus,
            isAtPrompt: session.effectiveIsAtPrompt
        )
    }

    init(
        tabID: UUID,
        tabIdentifier: String,
        aiProvider: String?,
        aiSessionId: String?,
        activeAppName: String?,
        directory: String,
        status: CommandStatus,
        isAtPrompt: Bool
    ) {
        self.tabID = tabID
        self.tabIdentifier = tabIdentifier
        self.aiProvider = aiProvider
        self.aiSessionId = aiSessionId
        self.activeAppName = activeAppName
        self.directory = directory
        self.status = status
        self.isAtPrompt = isAtPrompt
    }

    func isAgentTab(activeRun: TelemetryRun?) -> Bool {
        activeRun != nil || aiProvider != nil || aiSessionId != nil
    }
}

extension DashboardSessionSnapshot {
    /// Snapshot for an agent tab with no runtime-managed session behind it.
    static func fallback(id: String, liveTab: DashboardLiveTabState, activeRun: TelemetryRun?) -> DashboardSessionSnapshot {
        let usage = activeRun?.tokenUsage ?? TokenUsage()
        let provider = (activeRun?.provider ?? liveTab.aiProvider ?? liveTab.activeAppName ?? "AI")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return DashboardSessionSnapshot(
            id: id,
            tabID: liveTab.tabID,
            backendName: provider.isEmpty ? "AI" : provider,
            directory: liveTab.directory,
            purpose: nil,
            parentSessionID: nil,
            delegationDepth: 0,
            state: DashboardAgentState(commandStatus: liveTab.status, isAtPrompt: liveTab.isAtPrompt),
            turnCount: activeRun?.turnCount ?? 0,
            inputTokens: usage.inputTokens,
            outputTokens: usage.outputTokens + usage.reasoningOutputTokens,
            cacheCreationTokens: usage.cacheCreationInputTokens,
            cacheReadTokens: usage.cacheReadInputTokens,
            requiresApproval: liveTab.status == .approvalRequired,
            latestResult: nil,
            createdAt: activeRun?.startedAt ?? Date.distantPast,
            costUSD: activeRun?.costUSD ?? 0,
            journal: EventJournal()
        )
    }

    func mergingLiveTab(_ liveTab: DashboardLiveTabState, activeRun: TelemetryRun?) -> DashboardSessionSnapshot {
        let repoDirectory = liveTab.directory
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
            requiresApproval: requiresApproval || liveTab.status == .approvalRequired,
            latestResult: latestResult,
            createdAt: createdAt,
            costUSD: liveCost,
            journal: journal
        )
    }
}
