import Chau7Core
import Foundation

/// Data model for the multi-agent dashboard tab.
///
/// Polls the dashboard session controller on an adaptive interval to aggregate
/// live tab-backed session data, detect cross-agent file conflicts, and build a
/// merged event timeline. Scoped to a single repo group (git root path).
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
    private(set) var companionPlanPath: String?
    private(set) var companionPlanProgress = PlanProgress(checked: 0, total: 0)
    private(set) var detectedPlanFiles: [String] = []
    private(set) var companionPlanLastLoadedAt: Date?

    // MARK: - Internal Tracking

    /// Serial queue owning all refresh-side state below. The poll timer fires
    /// here, and every other entry point (commit actions, start/stop) hops
    /// onto it before touching trackers/cursors — unsynchronized Dictionary
    /// mutation across threads is memory-unsafe.
    @ObservationIgnored private let refreshQueue = DispatchQueue(label: "com.chau7.agent-dashboard.refresh", qos: .userInitiated)

    // Confined to refreshQueue:
    @ObservationIgnored private var fileTrackers: [String: SessionFilesTracker] = [:]
    @ObservationIgnored private let fleetFileIndex = FleetFileIndex()
    @ObservationIgnored private var journalCursors: [String: UInt64] = [:]
    @ObservationIgnored private var currentPollInterval: TimeInterval = AgentDashboardModel.initialPollInterval
    @ObservationIgnored private var pollCount = 0
    @ObservationIgnored private var lastCompanionPlanHash: String?
    @ObservationIgnored private var lastCompanionPlanPath: String?
    @ObservationIgnored private var lastDetectedPlanFilesSorted: [String] = []

    // Confined to the main thread:
    @ObservationIgnored private var refreshTimer: DispatchSourceTimer?
    @ObservationIgnored private var apiCallObserver: Any?

    // Cross-thread (lock-protected):
    @ObservationIgnored private var sessionCosts: [String: Double] = [:] // sessionID -> accumulated cost
    @ObservationIgnored private let costLock = NSLock()

    @ObservationIgnored private let sessionController: AgentDashboardSessionControlling

    private static let initialPollInterval: TimeInterval = 2

    var repoName: String {
        URL(fileURLWithPath: repoGroupID).lastPathComponent
    }

    var agentCount: Int {
        agentCards.count
    }

    // MARK: - Init

    init(
        repoGroupID: String,
        sessionController: AgentDashboardSessionControlling = AgentDashboardSessionController.shared
    ) {
        self.repoGroupID = repoGroupID
        self.sessionController = sessionController
    }

    deinit {
        stopPolling()
    }

    // MARK: - Lifecycle

    func startPolling() {
        guard refreshTimer == nil else { return }
        refreshQueue.async { [weak self] in
            guard let self else { return }
            currentPollInterval = Self.initialPollInterval
            refreshCompanionPlan(trackerValues: Array(fileTrackers.values), sessionIDs: [])
            refresh()
        }
        let timer = DispatchSource.makeTimerSource(queue: refreshQueue)
        timer.schedule(deadline: .now() + Self.initialPollInterval, repeating: Self.initialPollInterval)
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
        let sessions = sessionController.allSessions(includeStopped: false)
        let matching = sessions.filter { sessionMatchesRepo($0) }
        let childCounts = Dictionary(
            grouping: matching.compactMap { session -> (String, String)? in
                guard let parentSessionID = session.parentSessionID else { return nil }
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
            let sessionCost = session.costUSD > 0 ? session.costUSD : {
                costLock.lock()
                defer { costLock.unlock() }
                return sessionCosts[session.id] ?? 0
            }()

            cards.append(AgentCardData(
                sessionID: session.id,
                tabID: session.tabID,
                backendName: session.backendName,
                purpose: session.purpose,
                parentSessionID: session.parentSessionID,
                delegationDepth: session.delegationDepth,
                state: session.state,
                turnCount: session.turnCount,
                inputTokens: session.inputTokens,
                outputTokens: session.outputTokens,
                cacheCreationTokens: session.cacheCreationTokens,
                cacheReadTokens: session.cacheReadTokens,
                touchedFiles: tracker.touchedFiles,
                currentTurnFiles: tracker.currentTurnFiles,
                requiresApproval: session.requiresApproval,
                lastToolUsed: lastTool,
                latestResult: session.latestResult,
                childCount: childCounts[session.id] ?? 0,
                createdAt: session.createdAt,
                costUSD: sessionCost
            ))

            allTokens += session.totalTokens
            allCost += sessionCost
            if session.requiresApproval || session.state == .awaitingApproval { hasApprovals = true }
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
        if desiredInterval != currentPollInterval {
            currentPollInterval = desiredInterval
            // refreshTimer is main-confined; only the reschedule hops over.
            DispatchQueue.main.async { [weak self] in
                self?.refreshTimer?.schedule(deadline: .now() + desiredInterval, repeating: desiredInterval)
            }
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

        refreshCompanionPlan(trackerValues: Array(fileTrackers.values), sessionIDs: matching.map(\.id))

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

    private func refreshCompanionPlan(trackerValues: [SessionFilesTracker], sessionIDs: [String]) {
        let touchedPlanFiles = Set(trackerValues.flatMap { tracker in
            CompanionPlanLocator.detectedPlanCandidates(from: tracker.touchedFiles)
        })
        let preferredPath = CompanionPlanLocator.preferredPlanPath(
            repoRoot: repoGroupID,
            touchedFiles: touchedPlanFiles,
            sessionIDs: sessionIDs
        )
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: preferredPath) {
            let directory = (preferredPath as NSString).deletingLastPathComponent
            try? fileManager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let repoName = URL(fileURLWithPath: repoGroupID).lastPathComponent
            // User-visible action: a failed skeleton write must be loggable,
            // not "create plan" silently producing nothing.
            _ = FileOperations.writeString(
                CompanionPlanLocator.defaultSkeleton(repoName: repoName),
                to: preferredPath
            )
        }
        guard let content = try? String(contentsOfFile: preferredPath, encoding: .utf8) else {
            return
        }
        let contentHash = String(content.hashValue)
        let sortedPlanFiles = Array(touchedPlanFiles).sorted()
        // Compare against queue-confined shadows, not the main-mutated
        // observable properties (reading those here would race main writes).
        guard contentHash != lastCompanionPlanHash || lastCompanionPlanPath != preferredPath || lastDetectedPlanFilesSorted != sortedPlanFiles else {
            return
        }
        let progress = computePlanProgress(from: content)
        lastCompanionPlanHash = contentHash
        lastCompanionPlanPath = preferredPath
        lastDetectedPlanFilesSorted = sortedPlanFiles
        DispatchQueue.main.async { [weak self] in
            self?.companionPlanPath = preferredPath
            self?.companionPlanProgress = progress
            self?.detectedPlanFiles = sortedPlanFiles
            self?.companionPlanLastLoadedAt = Date()
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

    private func detectConflicts(from sessions: [DashboardSessionSnapshot]) -> [DashboardConflict] {
        let backendBySession = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.backendName) })

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

    private func buildTimeline(from sessions: [DashboardSessionSnapshot]) -> [TimelineEntry] {
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
                    backendName: session.backendName,
                    type: event.type,
                    message: event.data["tool"] ?? event.data["summary"] ?? event.type
                ))
            }
        }

        return Array(entries.sorted { $0.timestamp > $1.timestamp }.prefix(200))
    }

    // MARK: - Helpers

    private func sessionMatchesRepo(_ session: DashboardSessionSnapshot) -> Bool {
        let dir = session.directory
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
        _ = sessionController.stopSession(id: sessionID)
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

        isCommitting = true
        commitError = nil
        commitSuccess = false

        let dir = repoGroupID
        let msg = message

        // Trackers are refreshQueue-confined; snapshot the file set there.
        refreshQueue.async { [weak self] in
            guard let self else { return }
            var allFiles: Set<String> = []
            for tracker in fileTrackers.values {
                allFiles.formUnion(tracker.touchedFiles)
            }
            guard !allFiles.isEmpty else {
                DispatchQueue.main.async { [weak self] in
                    self?.isCommitting = false
                    self?.commitError = "No files touched by agents."
                }
                return
            }
            let files = allFiles.sorted()
            runCommitAll(files: files, message: msg, dir: dir)
        }
    }

    private func runCommitAll(files: [String], message msg: String, dir: String) {
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
            // Clear trackers on their owning queue — work is shipped
            if commitResult.succeeded {
                self?.refreshQueue.async { [weak self] in
                    self?.fileTrackers.values.forEach { $0.reset() }
                }
            }
            DispatchQueue.main.async {
                self?.isCommitting = false
                if commitResult.succeeded {
                    self?.commitSuccess = true
                    self?.commitMessage = "chore: agent batch commit"
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
        let dir = repoGroupID
        // Trackers are refreshQueue-confined; snapshot the file list there.
        refreshQueue.async { [weak self] in
            guard let self, let tracker = fileTrackers[sessionID] else { return }
            let files = tracker.touchedFiles.sorted()
            guard !files.isEmpty else { return }

            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                var args = ["add", "--"]
                args.append(contentsOf: files)
                let stageResult = GitDiffTracker.runGitWithStatus(args: args, in: dir)
                guard stageResult.succeeded else { return }

                let commitResult = GitDiffTracker.runGitWithStatus(args: ["commit", "-m", message], in: dir)
                if commitResult.succeeded {
                    self?.refreshQueue.async { [weak self] in
                        self?.fileTrackers[sessionID]?.reset()
                    }
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

        _ = sessionController.startSession(arguments: args)
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

        let response = sessionController.startSession(arguments: args)
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
    let state: DashboardAgentState
    let turnCount: Int
    let inputTokens: Int
    let outputTokens: Int
    let cacheCreationTokens: Int
    let cacheReadTokens: Int
    let touchedFiles: Set<String>
    let currentTurnFiles: Set<String>
    let requiresApproval: Bool
    let lastToolUsed: String?
    let latestResult: DashboardAgentResult?
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

    var latestResultStatus: DashboardResultStatus? {
        latestResult?.status
    }

    var latestResultSummary: String? {
        latestResult?.summary
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
