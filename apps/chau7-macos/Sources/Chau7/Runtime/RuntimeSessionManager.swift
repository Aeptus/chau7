import Foundation
import Chau7Core

/// Singleton registry for all active runtime sessions.
///
/// Subscribes to `ClaudeCodeMonitor.onEvent` to drive state transitions.
/// Thread-safe via `NSLock` (same pattern as `TelemetryRecorder`).
final class RuntimeSessionManager {
    static let shared = RuntimeSessionManager()

    // MARK: - Session Storage

    private var sessions: [String: RuntimeSession] = [:]  // sessionID → session
    private var tabToSession: [UUID: String] = [:]          // tabID → sessionID
    private var cwdToSession: [String: String] = [:]        // cwd → sessionID (for event matching)
    private let lock = NSLock()

    /// Recently stopped sessions kept for final queries.
    private var recentlyStopped: [String: (session: RuntimeSession, stoppedAt: Date)] = [:]
    private static let stoppedRetentionSeconds: TimeInterval = 600 // 10 minutes

    /// Incremental transcript readers for token extraction (sessionID → reader).
    private var transcriptReaders: [String: IncrementalTranscriptReader] = [:]

    private init() {}

    // MARK: - Session Creation

    /// Create a new runtime session. Does NOT create the tab — caller is responsible.
    func createSession(
        tabID: UUID,
        backend: any AgentBackend,
        config: SessionConfig,
        autoApprove: Bool = false
    ) -> RuntimeSession {
        let session = RuntimeSession(
            tabID: tabID,
            backend: backend,
            config: config,
            autoApprove: autoApprove
        )

        lock.lock()
        sessions[session.id] = session
        tabToSession[tabID] = session.id
        cwdToSession[config.directory] = session.id
        lock.unlock()

        session.journal.append(
            sessionID: session.id,
            turnID: nil,
            type: RuntimeEventType.sessionStarting.rawValue
        )

        Log.info("RuntimeSessionManager: created session \(session.id) tab=\(tabID) backend=\(backend.name)")
        return session
    }

    /// Adopt an existing tab as a passive runtime session.
    func adoptSession(
        tabID: UUID,
        backend: any AgentBackend,
        cwd: String
    ) -> RuntimeSession {
        let config = SessionConfig(directory: cwd, provider: backend.name)
        let session = RuntimeSession(
            tabID: tabID,
            backend: backend,
            config: config,
            adopted: true
        )

        // Adopted sessions start as ready (backend already running)
        session.transition(.backendReady)

        lock.lock()
        sessions[session.id] = session
        tabToSession[tabID] = session.id
        cwdToSession[cwd] = session.id
        lock.unlock()

        session.journal.append(
            sessionID: session.id,
            turnID: nil,
            type: RuntimeEventType.sessionReady.rawValue,
            data: ["adopted": "true"]
        )

        Log.info("RuntimeSessionManager: adopted session \(session.id) tab=\(tabID)")
        return session
    }

    // MARK: - Lookups

    func session(id: String) -> RuntimeSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions[id] ?? recentlyStopped[id]?.session
    }

    func sessionForTab(_ tabID: UUID) -> RuntimeSession? {
        lock.lock()
        guard let sessionID = tabToSession[tabID] else {
            lock.unlock()
            return nil
        }
        let session = sessions[sessionID]
        lock.unlock()
        return session
    }

    func allSessions(includeStopped: Bool = false) -> [RuntimeSession] {
        lock.lock()
        defer { lock.unlock() }
        var result = Array(sessions.values)
        if includeStopped {
            result.append(contentsOf: recentlyStopped.values.map(\.session))
        }
        return result
    }

    /// Check if a tab is managed by the runtime.
    func isRuntimeManaged(_ tabID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tabToSession[tabID] != nil
    }

    // MARK: - Event Handling

    /// Called from `ClaudeCodeMonitor.onEvent` to drive session state transitions.
    /// If no session matches, adopts the tab as a passive session.
    func handleClaudeEvent(_ event: ClaudeCodeEvent) {
        lock.lock()
        // Find session by cwd (same matching as TelemetryRecorder.updateSessionID)
        let sessionID = cwdToSession[event.cwd]
        var session = sessionID.flatMap { sessions[$0] }
        lock.unlock()

        // Adopt unknown Claude Code sessions as passive
        if session == nil && !event.cwd.isEmpty {
            session = tryAdoptFromEvent(event)
        }

        guard let session else { return }

        // Map event types to session transitions and journal entries
        switch event.type {
        case .toolStart:
            // Record tool use for TurnStats
            let file = extractFilePath(from: event)
            session.recordToolUse(name: event.toolName, file: file)

            session.journal.append(
                sessionID: session.id,
                turnID: session.currentTurnID,
                type: RuntimeEventType.toolUse.rawValue,
                data: ["tool": event.toolName]
            )

            // Emit tool_called notification
            emitNotification(session: session, type: "tool_called", message: "\(event.toolName)")

            // Check if this is a file-editing tool
            let editTools = ["Write", "Edit", "NotebookEdit", "Bash"]
            if editTools.contains(event.toolName) {
                emitNotification(session: session, type: "file_edited", message: file ?? event.toolName)
            }

        case .toolComplete:
            session.journal.append(
                sessionID: session.id,
                turnID: session.currentTurnID,
                type: RuntimeEventType.toolResult.rawValue,
                data: ["tool": event.toolName]
            )

        case .permissionRequest:
            // Only create approval if session is busy (not already awaiting)
            if session.state == .busy {
                _ = session.requestApproval(
                    tool: event.toolName,
                    description: event.message
                )
                emitNotification(session: session, type: "permission", message: event.message)
            }

        case .responseComplete:
            if session.state == .busy {
                // Read transcript tokens before completing the turn
                readTranscriptTokens(for: session, event: event)

                // Capture terminal output for exit classification
                let output = captureOutput(for: session)
                let result = session.completeTurn(summary: event.message, terminalOutput: output)

                if let output, !output.isEmpty {
                    session.journal.append(
                        sessionID: session.id,
                        turnID: nil, // turn already cleared
                        type: RuntimeEventType.outputChunk.rawValue,
                        data: ["output": String(output.prefix(4096))]
                    )
                }

                // Emit finished notification
                emitNotification(session: session, type: "finished", message: event.message)

                // Check token threshold (emit if > 100k total tokens)
                if result.stats.totalTokens > 100_000 {
                    emitNotification(
                        session: session,
                        type: "token_threshold",
                        message: "Turn used \(result.stats.totalTokens) tokens"
                    )
                }

                // Emit exit classification if not success
                if result.exitReason != .success {
                    let typeStr = result.exitReason == .contextLimit ? "context_limit" : "error"
                    emitNotification(session: session, type: typeStr, message: "Exit: \(result.exitReason.rawValue)")
                }
            }

        case .sessionEnd:
            session.transition(.tabClosed)
            cleanupTranscriptReader(for: session)
            moveToStopped(session)

        case .userPrompt:
            session.journal.append(
                sessionID: session.id,
                turnID: session.currentTurnID,
                type: RuntimeEventType.agentResponding.rawValue,
                data: ["message": event.message]
            )

        default:
            Log.debug("RuntimeSessionManager: unhandled event type=\(event.type) session=\(session.id)")
        }
    }

    // MARK: - Session Lifecycle

    /// Stop a session. Optionally send interrupt signal.
    func stopSession(id: String) -> Bool {
        lock.lock()
        guard let session = sessions[id] else {
            lock.unlock()
            return false
        }
        lock.unlock()

        session.journal.append(
            sessionID: session.id,
            turnID: nil,
            type: RuntimeEventType.sessionStopped.rawValue
        )
        session.transition(.tabClosed)
        cleanupTranscriptReader(for: session)
        moveToStopped(session)
        return true
    }

    /// Mark session as ready (called when backend process is detected as running).
    func markReady(sessionID: String) {
        lock.lock()
        let session = sessions[sessionID]
        lock.unlock()

        guard let session else { return }

        session.transition(.backendReady)
        session.journal.append(
            sessionID: session.id,
            turnID: nil,
            type: RuntimeEventType.sessionReady.rawValue
        )
    }

    // MARK: - Cleanup

    private var cleanupTimer: DispatchSourceTimer?

    /// Start periodic cleanup timer (call once at app startup).
    func startCleanupTimer() {
        guard cleanupTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.cleanup()
        }
        timer.resume()
        cleanupTimer = timer
    }

    /// Periodic cleanup: detect closed tabs, prune stale stopped cache.
    func cleanup() {
        let now = Date()

        lock.lock()
        let activeSessions = Array(sessions.values)
        // Prune old stopped sessions
        recentlyStopped = recentlyStopped.filter {
            now.timeIntervalSince($0.value.stoppedAt) < Self.stoppedRetentionSeconds
        }
        lock.unlock()

        // Check for sessions whose tabs have been closed
        let controlService = TerminalControlService.shared
        for session in activeSessions where !session.isTerminal {
            // Use tab_status to check if tab still exists
            let status = controlService.tabStatus(tabID: session.tabID.uuidString)
            if status.contains("\"error\"") {
                // Tab no longer exists
                session.journal.append(
                    sessionID: session.id,
                    turnID: nil,
                    type: RuntimeEventType.sessionStopped.rawValue,
                    data: ["reason": "tab_closed"]
                )
                session.transition(.tabClosed)
                moveToStopped(session)
            }
        }
    }

    // MARK: - Adoption

    /// Try to adopt an unknown Claude Code session from a monitor event.
    /// Resolves the tab by matching cwd to existing tabs.
    private func tryAdoptFromEvent(_ event: ClaudeCodeEvent) -> RuntimeSession? {
        guard !event.cwd.isEmpty else { return nil }

        // Find the tab with matching cwd
        let tabID = resolveTabByCwd(event.cwd)
        guard let tabID else { return nil }

        let backend = ClaudeCodeBackend()
        let session = adoptSession(tabID: tabID, backend: backend, cwd: event.cwd)
        Log.info("RuntimeSessionManager: auto-adopted session \(session.id) for cwd=\(event.cwd)")
        return session
    }

    /// Find a tab UUID by working directory, searching all registered windows.
    private func resolveTabByCwd(_ cwd: String) -> UUID? {
        // Must run on main thread since OverlayTabsModel is main-thread-only
        let result: UUID? = {
            if Thread.isMainThread {
                return _resolveTabByCwd(cwd)
            }
            return DispatchQueue.main.sync { _resolveTabByCwd(cwd) }
        }()
        return result
    }

    private func _resolveTabByCwd(_ cwd: String) -> UUID? {
        let controlService = TerminalControlService.shared
        // Use listTabs to find matching tab
        let tabsJSON = controlService.listTabs()
        guard let data = tabsJSON.data(using: .utf8),
              let tabs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }
        for tab in tabs {
            if let tabCwd = tab["cwd"] as? String, tabCwd == cwd,
               let tabIDStr = tab["tab_id"] as? String,
               let uuid = UUID(uuidString: tabIDStr) {
                return uuid
            }
        }
        return nil
    }

    // MARK: - Output Capture

    /// Capture recent terminal output for a session's tab.
    private func captureOutput(for session: RuntimeSession) -> String? {
        let controlService = TerminalControlService.shared
        let result = controlService.tabOutput(tabID: session.tabID.uuidString, lines: 50)
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? String else {
            return nil
        }
        return output
    }

    // MARK: - Notification Emission

    /// Emit an AIEvent into the notification system for a runtime session.
    private func emitNotification(session: RuntimeSession, type: String, message: String) {
        let event = AIEvent(
            source: .runtime,
            type: type,
            tool: session.backend.name,
            message: message,
            ts: DateFormatters.nowISO8601(),
            directory: session.config.directory,
            tabID: session.tabID
        )
        Task { @MainActor in
            NotificationManager.shared.notify(for: event)
        }
    }

    // MARK: - Transcript Token Reading

    /// Read incremental token usage from Claude Code transcripts.
    private func readTranscriptTokens(for session: RuntimeSession, event: ClaudeCodeEvent) {
        // Extract reader under lock, create if needed
        lock.lock()
        if transcriptReaders[session.id] == nil {
            transcriptReaders[session.id] = IncrementalTranscriptReader(
                cwd: session.config.directory,
                claudeSessionID: event.sessionId.isEmpty ? nil : event.sessionId
            )
        }
        let reader = transcriptReaders[session.id]
        lock.unlock()

        // Read tokens outside the lock (reader does file I/O)
        guard let reader else { return }
        let tokens = reader.readNewTokens()
        if tokens.input > 0 || tokens.output > 0 || tokens.cacheCreation > 0 || tokens.cacheRead > 0 {
            session.addTokens(
                input: tokens.input,
                output: tokens.output,
                cacheCreation: tokens.cacheCreation,
                cacheRead: tokens.cacheRead
            )
        }
    }

    /// Clean up transcript reader when session ends.
    private func cleanupTranscriptReader(for session: RuntimeSession) {
        lock.lock()
        transcriptReaders.removeValue(forKey: session.id)
        lock.unlock()
    }

    // MARK: - Event Data Extraction

    /// Extract file path from a Claude Code event (tool-specific).
    private func extractFilePath(from event: ClaudeCodeEvent) -> String? {
        // Claude Code hook events include the file in the message for file-editing tools
        let message = event.message
        guard !message.isEmpty else { return nil }

        // Common patterns: "Write /path/to/file", "Edit /path/to/file"
        // The message often IS the file path for tool events
        if message.hasPrefix("/") {
            // Looks like a path — take just the path portion
            return message.components(separatedBy: .whitespaces).first
        }
        return nil
    }

    // MARK: - Private

    private func moveToStopped(_ session: RuntimeSession) {
        lock.lock()
        sessions.removeValue(forKey: session.id)
        tabToSession.removeValue(forKey: session.tabID)
        cwdToSession.removeValue(forKey: session.config.directory)
        recentlyStopped[session.id] = (session, Date())
        lock.unlock()

        Log.info("RuntimeSessionManager: session \(session.id) stopped")
    }
}
