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
        sessionID: String? = nil,
        parentRunID: String? = nil,
        metadata: [String: String] = [:]
    ) {
        // End any existing active run for this tab before starting a new one.
        // This prevents orphaned runs when a new AI session starts in the same tab
        // without the previous session being explicitly ended (e.g., Codex exits
        // via alternate screen without a detectable exit pattern).
        lock.lock()
        if let previousRunID = activeRuns.removeValue(forKey: tabID),
           var previousRun = inProgressRuns.removeValue(forKey: previousRunID) {
            lock.unlock()
            previousRun.endedAt = Date()
            previousRun.exitStatus = nil
            previousRun.durationMs = Int(Date().timeIntervalSince(previousRun.startedAt) * 1000)
            store.finalizeRun(previousRun, turns: [], toolCalls: [])
            Log.info("TelemetryRecorder: auto-ended orphaned run \(previousRunID) for tab \(tabID)")
        } else {
            lock.unlock()
        }

        let runID = UUID().uuidString
        let run = TelemetryRun(
            id: runID,
            sessionID: sessionID,
            tabID: tabID,
            provider: provider,
            cwd: cwd,
            repoPath: repoPath,
            startedAt: Date(),
            metadata: metadata,
            parentRunID: parentRunID
        )

        lock.lock()
        activeRuns[tabID] = runID
        inProgressRuns[runID] = run
        lock.unlock()

        store.insertRun(run)
        Log.info("TelemetryRecorder: run started \(runID) provider=\(provider) cwd=\(cwd)")
    }

    /// Called when an AI tool process exits.
    /// - Parameters:
    ///   - tabID: The session's tab identifier
    ///   - exitStatus: Process exit code
    ///   - terminalBuffer: Optional terminal scrollback snapshot captured at run-end time.
    ///   - ptyLogPath: Path to the raw PTY output log for this AI session. Used as the
    ///     primary fallback for TUI-based tools where the terminal buffer is empty
    ///     (alternate screen discards content on exit).
    func runEnded(tabID: String, exitStatus: Int?, terminalBuffer: Data? = nil, ptyLogPath: String? = nil) {
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
                let normalized = TelemetryMetricsSanitizer.sanitize(content, provider: run.provider)
                if let warning = normalized.warning {
                    Log.warn("TelemetryRecorder: \(warning) run=\(runID)")
                }

                let finalContent = normalized.content
                run.model = finalContent.model ?? run.model
                run.totalInputTokens = finalContent.totalInputTokens
                run.totalCachedInputTokens = finalContent.totalCachedInputTokens
                run.totalOutputTokens = finalContent.totalOutputTokens
                run.totalReasoningOutputTokens = finalContent.totalReasoningOutputTokens
                run.costUSD = finalContent.costUSD
                run.tokenUsageSource = finalContent.tokenUsageSource
                run.tokenUsageState = finalContent.tokenUsageState
                run.costSource = finalContent.costSource
                run.costState = finalContent.costState
                run.rawTranscriptRef = finalContent.rawTranscriptRef
                run.turnCount = finalContent.turns.count
                if finalContent.tokenUsageState == .invalid {
                    run.errorMessage = "invalidated implausible token metrics during extraction"
                }
                turns = finalContent.turns
                toolCalls = finalContent.toolCalls
                Log.info("TelemetryRecorder: extracted \(turns.count) turns, \(toolCalls.count) tool calls, model=\(finalContent.model ?? "?")")
            } else {
                Log.warn("TelemetryRecorder: content extraction returned nil for run \(runID) session=\(run.sessionID ?? "nil") cwd=\(run.cwd)")
            }
        } else {
            Log.trace("TelemetryRecorder: no content provider for \(run.provider)")
        }

        // Fallback: if no provider extracted turns, try the PTY log (primary) then
        // the terminal buffer (secondary). The PTY log captures everything written to
        // the terminal, including content rendered on the alternate screen by TUI-based
        // tools. The terminal buffer only has main-screen content, which is often just
        // a brief exit summary for TUI tools.
        if turns.isEmpty {
            var fallbackText: String?
            var fallbackSource: String?

            // Primary: read and ANSI-strip the tail of the PTY log
            if let path = ptyLogPath {
                fallbackText = Self.readPTYLogTail(path: path, maxBytes: 1_024_000)
                if fallbackText != nil { fallbackSource = "pty_log" }
            }

            // Secondary: terminal buffer snapshot
            if fallbackText == nil, let bufferData = terminalBuffer {
                let text = String(decoding: bufferData, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty {
                    fallbackText = text
                    fallbackSource = "terminal_buffer"
                }
            }

            if let text = fallbackText, let source = fallbackSource {
                let turn = TelemetryTurn(
                    id: "\(runID)-t0",
                    runID: runID,
                    turnIndex: 0,
                    role: .assistant,
                    content: text,
                    timestamp: endedAt
                )
                turns = [turn]
                run.turnCount = 1
                run.rawTranscriptRef = source
                Log.info("TelemetryRecorder: using \(source) fallback (\(text.count) chars) for run \(runID)")
            }
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
        let matches = inProgressRuns.values.filter { run in
            guard run.provider.lowercased().contains(normalizedProvider) else { return false }
            guard run.sessionID == nil || run.sessionID?.isEmpty == true else { return false }
            guard run.metadata["session_binding"]?.lowercased() != "isolated" else { return false }
            // Flexible cwd match: exact, parent, or child directory
            let a = run.cwd
            let b = cwd
            return a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/")
        }
        if matches.count == 1, let run = matches.first {
            inProgressRuns[run.id]?.sessionID = sessionID
            lock.unlock()
            store.updateRunSessionID(run.id, sessionID: sessionID)
            Log.info("TelemetryRecorder: session ID updated via cwd match: \(sessionID.prefix(8)) → run \(run.id.prefix(8))")
        } else {
            lock.unlock()
            if matches.count > 1 {
                Log.info(
                    "TelemetryRecorder: skipped session ID update via cwd match for provider=\(provider) cwd=\(cwd) because \(matches.count) runs matched"
                )
            }
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

    // MARK: - PTY Log Reading

    /// Read the tail of a PTY log file, strip ANSI escape sequences, and return readable text.
    /// TUI-based AI tools (Claude Code, Codex, etc.) render on the alternate screen, which
    /// has no scrollback. The PTY log captures the raw bytes before terminal interpretation,
    /// so it contains everything — including alternate screen content that's been discarded.
    ///
    /// Used by both the telemetry fallback (run_transcript) and MCP tools (tab_output source=pty_log).
    static func readPTYLogTail(path: String, maxBytes: Int = 1_024_000) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // Seek to tail if file is larger than maxBytes
        let fileSize = (try? handle.seekToEnd()) ?? 0
        if fileSize > UInt64(maxBytes) {
            try? handle.seek(toOffset: fileSize - UInt64(maxBytes))
        } else {
            try? handle.seek(toOffset: 0)
        }

        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        let raw = String(decoding: data, as: UTF8.self)
        let stripped = EscapeSequenceSanitizer.sanitize(raw)

        // Collapse excessive blank lines (TUI redraws create many)
        let lines = stripped.components(separatedBy: "\n")
        var result: [String] = []
        var consecutiveEmpty = 0
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                consecutiveEmpty += 1
                if consecutiveEmpty <= 2 { result.append("") }
            } else {
                consecutiveEmpty = 0
                result.append(trimmed)
            }
        }

        let text = result.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}
