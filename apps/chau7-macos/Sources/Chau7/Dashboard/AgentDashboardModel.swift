import Chau7Core
import Foundation

/// Data model for the multi-agent dashboard tab.
///
/// Polls `RuntimeSessionManager` every 2 seconds to aggregate session data,
/// detect cross-agent file conflicts, and build a merged event timeline.
/// Scoped to a single repo group (git root path).
final class AgentDashboardModel: ObservableObject, Identifiable {
    let id = UUID()
    let repoGroupID: String

    // MARK: - Published State

    @Published private(set) var agentCards: [AgentCardData] = []
    @Published private(set) var conflicts: [DashboardConflict] = []
    @Published private(set) var timeline: [TimelineEntry] = []
    @Published private(set) var totalTokens = 0
    @Published private(set) var overallStatus: OverallStatus = .idle

    // MARK: - Internal Tracking

    private var fileTrackers: [String: SessionFilesTracker] = [:]
    private var journalCursors: [String: UInt64] = [:]
    private var refreshTimer: DispatchSourceTimer?

    var repoName: String {
        URL(fileURLWithPath: repoGroupID).lastPathComponent
    }

    var agentCount: Int {
        agentCards.count
    }

    // MARK: - Init

    init(repoGroupID: String) {
        self.repoGroupID = repoGroupID
    }

    // MARK: - Lifecycle

    func startPolling() {
        guard refreshTimer == nil else { return }
        refresh()
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in
            self?.refresh()
        }
        timer.resume()
        refreshTimer = timer
    }

    func stopPolling() {
        refreshTimer?.cancel()
        refreshTimer = nil
    }

    // MARK: - Refresh

    private func refresh() {
        let sessions = RuntimeSessionManager.shared.allSessions(includeStopped: false)
        let matching = sessions.filter { sessionMatchesRepo($0) }

        // Build agent cards
        var cards: [AgentCardData] = []
        var allTokens = 0
        var hasApprovals = false
        var hasActive = false

        for session in matching {
            let stats = session.currentTurnStats
            let tokens = stats.totalTokens

            // Update file tracker for this session
            let tracker = fileTrackers[session.id] ?? SessionFilesTracker()
            tracker.gitRoot = repoGroupID
            tracker.update(from: session.journal)
            fileTrackers[session.id] = tracker

            // Extract last tool from journal
            let lastTool = extractLastTool(from: session.journal)

            cards.append(AgentCardData(
                sessionID: session.id,
                tabID: session.tabID,
                backendName: session.backend.name,
                state: session.state,
                turnCount: session.turnCount,
                inputTokens: stats.inputTokens,
                outputTokens: stats.outputTokens,
                touchedFiles: tracker.touchedFiles,
                pendingApproval: session.pendingApproval,
                lastToolUsed: lastTool,
                createdAt: session.createdAt
            ))

            allTokens += tokens
            if session.state == .awaitingApproval { hasApprovals = true }
            if session.state == .busy { hasActive = true }
        }

        // Detect conflicts: files touched by 2+ agents
        let detectedConflicts = detectConflicts(from: matching)

        // Build timeline from journal events
        let timelineEntries = buildTimeline(from: matching)

        // Determine overall status
        let status: OverallStatus
        if !detectedConflicts.isEmpty {
            status = .hasConflicts
        } else if hasApprovals {
            status = .hasApprovals
        } else if hasActive {
            status = .active
        } else if matching.isEmpty {
            status = .idle
        } else {
            status = .active
        }

        // Clean up trackers for sessions that no longer exist
        let activeIDs = Set(matching.map(\.id))
        fileTrackers = fileTrackers.filter { activeIDs.contains($0.key) }
        journalCursors = journalCursors.filter { activeIDs.contains($0.key) }

        DispatchQueue.main.async { [weak self] in
            self?.agentCards = cards
            self?.conflicts = detectedConflicts
            self?.timeline = timelineEntries
            self?.totalTokens = allTokens
            self?.overallStatus = status
        }
    }

    // MARK: - Conflict Detection

    private func detectConflicts(from sessions: [RuntimeSession]) -> [DashboardConflict] {
        var fileToAgents: [String: [(sessionID: String, backendName: String)]] = [:]

        for session in sessions {
            guard let tracker = fileTrackers[session.id] else { continue }
            for file in tracker.touchedFiles {
                fileToAgents[file, default: []].append(
                    (sessionID: session.id, backendName: session.backend.name)
                )
            }
        }

        return fileToAgents
            .filter { $0.value.count >= 2 }
            .map { path, agents in
                DashboardConflict(
                    id: UUID(),
                    filePath: path,
                    agents: agents.map { .init(sessionID: $0.sessionID, backendName: $0.backendName) },
                    severity: .warning
                )
            }
            .sorted { $0.filePath < $1.filePath }
    }

    // MARK: - Timeline

    private func buildTimeline(from sessions: [RuntimeSession]) -> [TimelineEntry] {
        var entries: [TimelineEntry] = []

        for session in sessions {
            let cursor = journalCursors[session.id] ?? 0
            let (events, newCursor, _) = session.journal.events(after: cursor, limit: 50)
            journalCursors[session.id] = newCursor

            for event in events {
                entries.append(TimelineEntry(
                    id: UUID(),
                    timestamp: event.timestamp,
                    sessionID: event.sessionID,
                    backendName: session.backend.name,
                    type: event.type,
                    message: event.data["tool"] ?? event.data["summary"] ?? event.type
                ))
            }
        }

        return Array(entries.sorted { $0.timestamp > $1.timestamp }.prefix(200))
    }

    // MARK: - Helpers

    private func sessionMatchesRepo(_ session: RuntimeSession) -> Bool {
        let dir = session.config.directory
        return dir == repoGroupID
            || dir.hasPrefix(repoGroupID + "/")
            || repoGroupID.hasPrefix(dir + "/")
    }

    private func extractLastTool(from journal: EventJournal) -> String? {
        let (events, _, _) = journal.events(after: 0, limit: 500)
        return events.last(where: { $0.type == RuntimeEventType.toolUse.rawValue })?.data["tool"]
    }

    // MARK: - Actions

    func stopAgent(sessionID: String) {
        _ = RuntimeSessionManager.shared.stopSession(id: sessionID)
    }

    /// Switch to the tab hosting this agent.
    /// This needs to be wired through the view's callback since
    /// the model doesn't have access to OverlayTabsModel.
    var onSwitchToTab: ((UUID) -> Void)?

    func switchToTab(tabID: UUID) {
        onSwitchToTab?(tabID)
    }
}

// MARK: - Supporting Types

struct AgentCardData: Identifiable {
    var id: String {
        sessionID
    }

    let sessionID: String
    let tabID: UUID
    let backendName: String
    let state: RuntimeSessionStateMachine.State
    let turnCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let touchedFiles: Set<String>
    let pendingApproval: PendingApproval?
    let lastToolUsed: String?
    let createdAt: Date

    var totalTokens: Int {
        inputTokens + outputTokens
    }

    var formattedTokens: String {
        if totalTokens > 1000 {
            return String(format: "%.1fk", Double(totalTokens) / 1000)
        }
        return "\(totalTokens)"
    }
}

struct DashboardConflict: Identifiable {
    let id: UUID
    let filePath: String
    let agents: [AgentRef]
    let severity: ConflictSeverity

    struct AgentRef {
        let sessionID: String
        let backendName: String
    }
}

enum ConflictSeverity {
    case warning
    case critical
}

enum OverallStatus {
    case idle
    case active
    case hasConflicts
    case hasApprovals
}

struct TimelineEntry: Identifiable {
    let id: UUID
    let timestamp: Date
    let sessionID: String
    let backendName: String
    let type: String
    let message: String
}
