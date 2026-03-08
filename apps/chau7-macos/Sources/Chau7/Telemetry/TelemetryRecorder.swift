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

        var turns: [TelemetryTurn] = []
        var toolCalls: [TelemetryToolCall] = []

        // Extract content from provider-specific storage.
        // The provider receives runID so all child entities are born with correct IDs.
        if let provider = providers.first(where: { $0.canHandle(provider: run.provider) }) {
            if let content = provider.extractContent(
                runID: runID,
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
                turns = content.turns
                toolCalls = content.toolCalls
                Log.info("TelemetryRecorder: extracted \(turns.count) turns, \(toolCalls.count) tool calls, model=\(content.model ?? "?")")
            } else {
                Log.warn("TelemetryRecorder: content extraction returned nil for run \(runID) session=\(run.sessionID ?? "nil") cwd=\(run.cwd)")
            }
        } else {
            Log.trace("TelemetryRecorder: no content provider for \(run.provider)")
        }

        // Atomic: UPDATE the run row + INSERT turns + INSERT tool calls in one transaction.
        // This avoids the INSERT OR REPLACE cascade-delete problem.
        store.finalizeRun(run, turns: turns, toolCalls: toolCalls)
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

        // Update just the session_id column in SQLite
        store.updateRunSessionID(runID, sessionID: sessionID)
    }

    /// Update session ID for an active run matched by provider and working directory.
    /// Used when session IDs arrive from external monitors (e.g. Claude Code hooks)
    /// that don't know the Chau7 tab ID.
    ///
    /// Uses flexible cwd matching: exact match or parent/child directory relationship,
    /// since the hook event cwd may be a subdirectory of the terminal's cwd or vice versa.
    func updateSessionID(provider: String, cwd: String, sessionID: String) {
        lock.lock()
        let normalizedProvider = provider.lowercased()
        let match = inProgressRuns.first { (_, run) in
            guard run.provider.lowercased().contains(normalizedProvider) else { return false }
            guard run.sessionID == nil || run.sessionID?.isEmpty == true else { return false }
            // Flexible cwd match: exact, parent, or child directory
            let a = run.cwd
            let b = cwd
            return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
        }
        if let (_, run) = match {
            inProgressRuns[run.id]?.sessionID = sessionID
            lock.unlock()
            store.updateRunSessionID(run.id, sessionID: sessionID)
            Log.info("TelemetryRecorder: session ID updated via cwd match: \(sessionID.prefix(8)) → run \(run.id.prefix(8))")
        } else {
            lock.unlock()
        }
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
