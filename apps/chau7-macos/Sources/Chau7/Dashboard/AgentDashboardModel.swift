import Chau7Core
import Foundation

/// Data model for the multi-agent dashboard tab.
///
/// Polls `RuntimeSessionManager` on an adaptive interval to aggregate session data,
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
    private(set) var proxyHealthy = true

    // MARK: - Internal Tracking

    @ObservationIgnored private var fileTrackers: [String: SessionFilesTracker] = [:]
    @ObservationIgnored private let fleetFileIndex = FleetFileIndex()
    @ObservationIgnored private var journalCursors: [String: UInt64] = [:]
    @ObservationIgnored private var refreshTimer: DispatchSourceTimer?
    @ObservationIgnored private var sessionCosts: [String: Double] = [:] // sessionID -> accumulated cost
    @ObservationIgnored private let costLock = NSLock()
    @ObservationIgnored private var apiCallObserver: Any?
    @ObservationIgnored private var currentPollInterval: TimeInterval = 2
    @ObservationIgnored private var pollCount = 0

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
        timer.schedule(deadline: .now() + currentPollInterval, repeating: currentPollInterval)
        timer.setEventHandler { [weak self] in
            self?.refresh()
        }
        timer.resume()
        refreshTimer = timer

        // Observe proxy API call events to accumulate cost per session
        apiCallObserver = NotificationCenter.default.addObserver(
            forName: .apiCallRecorded,
            object: nil,
            queue: nil
        ) { [weak self] notification in
            guard let self = self, let event = notification.userInfo?["event"] as? APICallEvent else { return }
            costLock.lock()
            defer { costLock.unlock() }
            sessionCosts[event.sessionId, default: 0] += event.costUSD
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
        let childCounts = Dictionary(
            grouping: matching.compactMap { session -> (String, String)? in
                guard let parentSessionID = session.config.parentSessionID else { return nil }
                return (parentSessionID, session.id)
            },
            by: \.0
        ).mapValues(\.count)

        // Build agent cards
        var cards: [AgentCardData] = []
        var allTokens = 0
        var allCost: Double = 0
        var hasApprovals = false
        var hasActive = false
        fleetFileIndex.reset()

        for session in matching {
            let stats = session.currentTurnStats

            // Update file tracker for this session
            let tracker = fileTrackers[session.id] ?? SessionFilesTracker()
            tracker.gitRoot = repoGroupID
            let commandBlocks = fetchCommandBlocks(for: session.tabID.uuidString)
            tracker.update(
                from: session.journal,
                commandBlocks: commandBlocks
            )
            fileTrackers[session.id] = tracker
            fleetFileIndex.publish(agentID: session.id, files: tracker.touchedFiles)

            // Extract last tool from journal
            let lastTool = extractLastTool(from: session.journal)

            // Cost accumulated from proxy IPC notifications (lock for thread safety)
            let sessionCost: Double = {
                costLock.lock()
                defer { costLock.unlock() }
                return sessionCosts[session.id] ?? 0
            }()

            cards.append(AgentCardData(
                sessionID: session.id,
                tabID: session.tabID,
                backendName: session.backend.name,
                purpose: session.config.purpose,
                parentSessionID: session.config.parentSessionID,
                delegationDepth: session.config.delegationDepth,
                state: session.state,
                turnCount: session.turnCount,
                inputTokens: stats.inputTokens,
                outputTokens: stats.outputTokens,
                cacheCreationTokens: stats.cacheCreationTokens,
                cacheReadTokens: stats.cacheReadTokens,
                touchedFiles: tracker.touchedFiles,
                currentTurnFiles: tracker.currentTurnFiles,
                pendingApproval: session.pendingApproval,
                lastToolUsed: lastTool,
                latestResult: session.turnResult(),
                childCount: childCounts[session.id] ?? 0,
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

        // Adaptive poll interval: fast when agents are active, slow when idle
        let desiredInterval: TimeInterval
        if hasActive || hasApprovals {
            desiredInterval = 2
        } else if !matching.isEmpty {
            desiredInterval = 5
        } else {
            desiredInterval = 10
        }
        if desiredInterval != currentPollInterval, let timer = refreshTimer {
            currentPollInterval = desiredInterval
            timer.schedule(deadline: .now() + desiredInterval, repeating: desiredInterval)
        }

        // Periodic health check (every 5th poll cycle)
        pollCount += 1
        if pollCount.isMultiple(of: 5) {
            Task {
                let healthy = await ProxyManager.shared.checkHealth()
                await MainActor.run { [weak self] in
                    self?.proxyHealthy = healthy
                }
            }
        }

        DispatchQueue.main.async { [weak self] in
            self?.agentCards = cards.sorted { lhs, rhs in
                if lhs.delegationDepth != rhs.delegationDepth {
                    return lhs.delegationDepth < rhs.delegationDepth
                }
                if lhs.parentSessionID != rhs.parentSessionID {
                    return (lhs.parentSessionID ?? "") < (rhs.parentSessionID ?? "")
                }
                return lhs.createdAt < rhs.createdAt
            }
            self?.conflicts = detectedConflicts
            self?.timeline = timelineEntries
            self?.totalTokens = allTokens
            self?.totalCost = allCost
            self?.overallStatus = status
        }
    }

    private func fetchCommandBlocks(for tabID: String) -> [CommandBlock] {
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                CommandBlockManager.shared.blocksForTab(tabID)
            }
        }
        return DispatchQueue.main.sync {
            CommandBlockManager.shared.blocksForTab(tabID)
        }
    }

    // MARK: - Conflict Detection

    private func detectConflicts(from sessions: [RuntimeSession]) -> [DashboardConflict] {
        let backendBySession = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.backend.name) })

        return fleetFileIndex.overlappingFiles()
            .filter { $0.value.count >= 2 }
            .map { path, agentIDs in
                DashboardConflict(
                    filePath: path,
                    agents: agentIDs.sorted().compactMap { sessionID in
                        guard let backend = backendBySession[sessionID] else { return nil }
                        return .init(sessionID: sessionID, backendName: backend)
                    },
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
    var showReviewSheet = false
    var reviewError: String?

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
                    // Auto-dismiss success message after 3 seconds
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.commitSuccess = false
                    }
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

    func startCodeReview(
        baseCommit: String,
        headCommit: String,
        parentSessionID: String?,
        model: String?,
        extraInstructions: String?,
        autoApprove: Bool
    ) {
        let base = baseCommit.trimmingCharacters(in: .whitespacesAndNewlines)
        let head = headCommit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !head.isEmpty else {
            reviewError = "Base and head commits are required."
            return
        }

        reviewError = nil
        var args: [String: Any] = [
            "backend": "codex",
            "directory": repoGroupID,
            "purpose": "code_review",
            "task_metadata": [
                "base_commit": base,
                "head_commit": head
            ],
            "result_schema": CodeReviewTaskTemplate.resultSchema.foundationValue,
            "initial_prompt": CodeReviewTaskTemplate.prompt(
                baseCommit: base,
                headCommit: head,
                extraInstructions: extraInstructions
            ),
            "policy": [
                "max_turns": 1,
                "allow_child_delegation": false,
                "max_delegation_depth": 0,
                "blocked_tools": ["Write", "Edit", "NotebookEdit"],
                "allow_file_writes": false
            ]
        ]
        if let parentSessionID,
           let parentCard = agentCards.first(where: { $0.sessionID == parentSessionID }) {
            args["parent_session_id"] = parentSessionID
            args["delegation_depth"] = parentCard.delegationDepth + 1
        }
        if let model, !model.isEmpty {
            args["model"] = model
        }
        if autoApprove {
            args["auto_approve"] = true
        }

        let response = RuntimeControlService.shared.handleToolCall(
            name: "runtime_session_create",
            arguments: args
        )
        if let json = parseJSONObject(response), let error = json["error"] as? String {
            reviewError = error
        }
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
    let purpose: String?
    let parentSessionID: String?
    let delegationDepth: Int
    let state: RuntimeSessionStateMachine.State
    let turnCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let touchedFiles: Set<String>
    let currentTurnFiles: Set<String>
    let pendingApproval: PendingApproval?
    let lastToolUsed: String?
    let latestResult: RuntimeTurnResult?
    let childCount: Int
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

    var latestResultStatus: RuntimeTurnResultStatus? {
        latestResult?.status
    }

    var latestResultSummary: String? {
        latestResult?.value?.objectValue?["summary"]?.stringValue
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

private extension AgentDashboardModel {
    func parseJSONObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
