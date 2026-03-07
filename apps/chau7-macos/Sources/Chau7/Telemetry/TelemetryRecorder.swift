import Foundation
import Chau7Core

/// Observes terminal session lifecycle events and records telemetry runs.
///
/// Lifecycle data comes from Chau7's terminal monitoring (process start/exit, cwd, timing).
/// Content data comes from pluggable RunContentProviders that read provider-specific storage.
final class TelemetryRecorder {
    static let shared = TelemetryRecorder()

    private let store = TelemetryStore.shared
    private let providers: [RunContentProvider]

    /// Maps tab identifier → in-progress run ID
    private var activeRuns: [String: String] = [:]
    /// Maps run ID → run record (for in-progress updates)
    private var inProgressRuns: [String: TelemetryRun] = [:]
    private let lock = NSLock()

    private init() {
        self.providers = [
            ClaudeCodeContentProvider(),
            CodexContentProvider()
        ]
    }

    // MARK: - Run Lifecycle

    /// Called when an AI tool process starts in a tab.
    func runStarted(
        tabID: String,
        provider: String,
        cwd: String,
        repoPath: String? = nil,
        sessionID: String? = nil
    ) {
        let runID = UUID().uuidString
        let run = TelemetryRun(
            id: runID,
            sessionID: sessionID,
            tabID: tabID,
            provider: provider,
            cwd: cwd,
            repoPath: repoPath,
            startedAt: Date()
        )

        lock.lock()
        activeRuns[tabID] = runID
        inProgressRuns[runID] = run
        lock.unlock()

        store.insertRun(run)
        Log.info("TelemetryRecorder: run started \(runID) provider=\(provider) cwd=\(cwd)")
    }

    /// Called when an AI tool process exits.
    func runEnded(tabID: String, exitStatus: Int?) {
        lock.lock()
        guard let runID = activeRuns.removeValue(forKey: tabID),
              var run = inProgressRuns.removeValue(forKey: runID) else {
            lock.unlock()
            return
        }
        lock.unlock()

        let endedAt = Date()
        run.endedAt = endedAt
        run.exitStatus = exitStatus
        run.durationMs = Int(endedAt.timeIntervalSince(run.startedAt) * 1000)

        // Extract content from provider-specific storage
        if let provider = providers.first(where: { $0.canHandle(provider: run.provider) }) {
            if let content = provider.extractContent(
                sessionID: run.sessionID,
                cwd: run.cwd,
                startedAt: run.startedAt
            ) {
                run.model = content.model ?? run.model
                run.totalInputTokens = content.totalInputTokens
                run.totalOutputTokens = content.totalOutputTokens
                run.costUSD = content.costUSD
                run.rawTranscriptRef = content.rawTranscriptRef
                run.turnCount = content.turns.count

                // Persist turns and tool calls
                store.insertTurns(content.turns)
                if !content.toolCalls.isEmpty {
                    store.insertToolCalls(content.toolCalls)
                }
            }
        }

        store.insertRun(run)
        Log.info("TelemetryRecorder: run ended \(runID) exit=\(exitStatus ?? -1) duration=\(run.durationMs ?? 0)ms turns=\(run.turnCount)")
    }

    /// Update session ID for an active run (may be discovered after process start).
    func updateSessionID(tabID: String, sessionID: String) {
        lock.lock()
        guard let runID = activeRuns[tabID] else {
            lock.unlock()
            return
        }
        inProgressRuns[runID]?.sessionID = sessionID
        lock.unlock()

        // Also update in SQLite
        store.insertRunSync(TelemetryRun(
            id: runID,
            sessionID: sessionID,
            provider: inProgressRuns[runID]?.provider ?? "unknown",
            cwd: inProgressRuns[runID]?.cwd ?? ""
        ))
    }

    /// Tag a run (e.g., "control", "aethyme").
    func tagRun(_ runID: String, tags: [String]) {
        store.updateRunTags(runID, tags: tags)
    }

    // MARK: - Queries (for MCP and internal use)

    func activeRunForTab(_ tabID: String) -> TelemetryRun? {
        lock.lock()
        let runID = activeRuns[tabID]
        let run = runID.flatMap { inProgressRuns[$0] }
        lock.unlock()
        return run
    }

    var allActiveRuns: [TelemetryRun] {
        lock.lock()
        let runs = Array(inProgressRuns.values)
        lock.unlock()
        return runs
    }
}
