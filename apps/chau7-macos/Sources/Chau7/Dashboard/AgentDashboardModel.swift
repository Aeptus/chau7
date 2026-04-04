import Chau7Core
import Foundation

/// Data model for the multi-agent dashboard tab.
///
/// Polls `RuntimeSessionManager` every 2 seconds to aggregate session data,
/// detect cross-agent file conflicts, and build a merged event timeline.
/// Scoped to a single repo group (git root path).
@Observable
final class AgentDashboardModel: Identifiable {
    let id = UUID()
    let repoGroupID: String

    // MARK: - Published State

    private(set) var agentCards: [AgentCardData] = []
    private(set) var conflicts: [DashboardConflict] = []
    private(set) var timeline: [TimelineEntry] = []
    private(set) var totalTokens = 0
    private(set) var totalCost: Double = 0
    private(set) var overallStatus: OverallStatus = .idle

    // MARK: - Internal Tracking

    @ObservationIgnored private var fileTrackers: [String: SessionFilesTracker] = [:]
    @ObservationIgnored private var journalCursors: [String: UInt64] = [:]
    @ObservationIgnored private var refreshTimer: DispatchSourceTimer?
    @ObservationIgnored private var sessionCosts: [String: Double] = [:] // sessionID -> accumulated cost
    @ObservationIgnored private var apiCallObserver: Any?

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

    deinit {
        stopPolling()
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

        // Observe proxy API call events to accumulate cost per session
        apiCallObserver = NotificationCenter.default.addObserver(
            forName: .apiCallRecorded,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let event = notification.userInfo?["event"] as? APICallEvent else { return }
            self?.sessionCosts[event.sessionId, default: 0] += event.costUSD
        }
    }

    func stopPolling() {
        refreshTimer?.cancel()
        refreshTimer = nil
        if let observer = apiCallObserver {
            NotificationCenter.default.removeObserver(observer)
            apiCallObserver = nil
        }
    }

    // MARK: - Refresh

    private func refresh() {
        let sessions = RuntimeSessionManager.shared.allSessions(includeStopped: false)
        let matching = sessions.filter { sessionMatchesRepo($0) }

        // Build agent cards
        var cards: [AgentCardData] = []
        var allTokens = 0
        var allCost: Double = 0
        var hasApprovals = false
        var hasActive = false

        for session in matching {
            let stats = session.currentTurnStats

            // Update file tracker for this session
            let tracker = fileTrackers[session.id] ?? SessionFilesTracker()
            tracker.gitRoot = repoGroupID
            tracker.update(from: session.journal)
            fileTrackers[session.id] = tracker

            // Extract last tool from journal
            let lastTool = extractLastTool(from: session.journal)

            // Cost accumulated from proxy IPC notifications
            let sessionCost = sessionCosts[session.id] ?? 0

            cards.append(AgentCardData(
                sessionID: session.id,
                tabID: session.tabID,
                backendName: session.backend.name,
                state: session.state,
                turnCount: session.turnCount,
                inputTokens: stats.inputTokens,
                outputTokens: stats.outputTokens,
                cacheCreationTokens: stats.cacheCreationTokens,
                cacheReadTokens: stats.cacheReadTokens,
                touchedFiles: tracker.touchedFiles,
                pendingApproval: session.pendingApproval,
                lastToolUsed: lastTool,
                createdAt: session.createdAt,
                costUSD: sessionCost
            ))

            allTokens += stats.inputTokens + stats.outputTokens + stats.cacheCreationTokens + stats.cacheReadTokens
            allCost += sessionCost
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
            self?.totalCost = allCost
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
                    id: "\(event.sessionID):\(event.seq)",
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
    }

    private func extractLastTool(from journal: EventJournal) -> String? {
        // Read only the last 20 events — enough to find the most recent tool_use
        let oldest = journal.oldestAvailableCursor
        let latest = journal.latestCursor
        let start = latest > 20 ? latest - 20 : oldest
        let (events, _, _) = journal.events(after: start, limit: 20)
        return events.last(where: { $0.type == RuntimeEventType.toolUse.rawValue })?.data["tool"]
    }

    // MARK: - Batch Operations State

    var isCommitting = false
    var commitError: String?
    var commitSuccess = false
    var commitMessage = "chore: agent batch commit"
    var showStartAgentSheet = false

    // MARK: - Actions

    func stopAgent(sessionID: String) {
        _ = RuntimeSessionManager.shared.stopSession(id: sessionID)
    }

    func stopAllAgents() {
        for card in agentCards {
            stopAgent(sessionID: card.sessionID)
        }
    }

    /// Commit all agent-touched files in the repo.
    func commitAllAgents() {
        let message = commitMessage.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            commitError = "Commit message cannot be empty."
            return
        }

        // Collect all files from all trackers
        var allFiles: Set<String> = []
        for tracker in fileTrackers.values {
            allFiles.formUnion(tracker.touchedFiles)
        }
        guard !allFiles.isEmpty else {
            commitError = "No files touched by agents."
            return
        }

        isCommitting = true
        commitError = nil
        commitSuccess = false

        let dir = repoGroupID
        let files = allFiles.sorted()
        let msg = message

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Stage
            var stageArgs = ["add", "--"]
            stageArgs.append(contentsOf: files)
            let stageResult = GitDiffTracker.runGitWithStatus(args: stageArgs, in: dir)
            guard stageResult.succeeded else {
                DispatchQueue.main.async {
                    self?.isCommitting = false
                    self?.commitError = "Stage failed: \(stageResult.stderr)"
                }
                return
            }

            // Commit
            let commitResult = GitDiffTracker.runGitWithStatus(args: ["commit", "-m", msg], in: dir)
            DispatchQueue.main.async {
                self?.isCommitting = false
                if commitResult.succeeded {
                    self?.commitSuccess = true
                    self?.commitMessage = "chore: agent batch commit"
                    // Clear trackers — work is shipped
                    self?.fileTrackers.values.forEach { $0.reset() }
                } else {
                    self?.commitError = "Commit failed: \(commitResult.stderr)"
                }
            }
        }
    }

    /// Commit only one agent's touched files.
    func commitAgent(sessionID: String, message: String) {
        guard let tracker = fileTrackers[sessionID] else { return }
        let files = tracker.touchedFiles.sorted()
        guard !files.isEmpty else { return }

        let dir = repoGroupID
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var args = ["add", "--"]
            args.append(contentsOf: files)
            let stageResult = GitDiffTracker.runGitWithStatus(args: args, in: dir)
            guard stageResult.succeeded else { return }

            let commitResult = GitDiffTracker.runGitWithStatus(args: ["commit", "-m", message], in: dir)
            if commitResult.succeeded {
                DispatchQueue.main.async {
                    self?.fileTrackers[sessionID]?.reset()
                }
            }
        }
    }

    /// Spawn a new agent in this repo.
    func startAgent(backend: String, model: String?, prompt: String?, autoApprove: Bool) {
        var args: [String: Any] = [
            "backend": backend,
            "directory": repoGroupID
        ]
        if let model, !model.isEmpty { args["model"] = model }
        if let prompt, !prompt.isEmpty { args["initial_prompt"] = prompt }
        if autoApprove { args["auto_approve"] = true }

        // Use RuntimeControlService which handles validation, PATH check, and retry
        _ = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: args
        )
        // The new session will appear in the next 2s poll refresh
    }

    /// Switch to the tab hosting this agent.
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
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let touchedFiles: Set<String>
    let pendingApproval: PendingApproval?
    let lastToolUsed: String?
    let createdAt: Date
    let costUSD: Double

    var totalTokens: Int {
        inputTokens + outputTokens
    }

    /// All tokens including cache — actual usage footprint.
    var totalAllTokens: Int {
        inputTokens + outputTokens + cacheCreationTokens + cacheReadTokens
    }

    var formattedTokens: String {
        formatCount(totalAllTokens)
    }

    var formattedCost: String {
        LocalizedFormatters.formatCostPrecise(costUSD)
    }

    private func formatCount(_ count: Int) -> String {
        if count > 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count > 1000 { return String(format: "%.1fk", Double(count) / 1000) }
        return "\(count)"
    }
}

struct DashboardConflict: Identifiable {
    var id: String {
        filePath
    }

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
    let id: String // sessionID:seq for stable SwiftUI diffing
    let timestamp: Date
    let sessionID: String
    let backendName: String
    let type: String
    let message: String
}
