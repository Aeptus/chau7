import Foundation
import Chau7Core

/// Singleton registry for all active runtime sessions.
///
/// Subscribes to `ClaudeCodeMonitor.onEvent` to drive state transitions.
/// Thread-safe via `NSLock` (same pattern as `TelemetryRecorder`).
final class RuntimeSessionManager {
    static let shared = RuntimeSessionManager()

    // MARK: - Session Storage

    private var sessions: [String: RuntimeSession] = [:] // sessionID → session
    private var tabToSession: [UUID: String] = [:] // tabID → sessionID
    private var cwdToSessions: [String: Set<String>] = [:] // cwd → runtime sessionIDs
    private var claudeToRuntimeSession: [String: String] = [:] // Claude sessionID → runtime sessionID
    private var runtimeToClaudeSession: [String: String] = [:] // runtime sessionID → Claude sessionID
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
        cwdToSessions[config.directory, default: []].insert(session.id)
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
        cwdToSessions[cwd, default: []].insert(session.id)
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

    func sessionForClaudeSessionID(_ sessionID: String) -> RuntimeSession? {
        guard let normalized = normalizeClaudeSessionID(sessionID) else { return nil }

        lock.lock()
        defer { lock.unlock() }

        guard let runtimeSessionID = claudeToRuntimeSession[normalized] else {
            return nil
        }
        return sessions[runtimeSessionID] ?? recentlyStopped[runtimeSessionID]?.session
    }

    func exactClaudeTabID(sessionID: String, cwd: String?) -> UUID? {
        guard let normalized = normalizeClaudeSessionID(sessionID) else { return nil }
        let tabs = {
            if Thread.isMainThread {
                return listAITabs()
            }
            return DispatchQueue.main.sync { listAITabs() }
        }()
        return Self.resolveAuthoritativeClaudeTabID(
            sessionID: normalized,
            cwd: cwd,
            boundSession: sessionForClaudeSessionID(normalized),
            tabs: tabs,
            strictResolver: { [weak self] sessionID, cwd in
                self?.resolveClaudeTabByStrictSession(sessionID, cwd: cwd)
            }
        )
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

    func childSessions(parentSessionID: String, includeStopped: Bool = false) -> [RuntimeSession] {
        let sessions = allSessions(includeStopped: includeStopped)
        return sessions.filter { $0.config.parentSessionID == parentSessionID }
    }

    func descendantSessions(rootSessionID: String, includeStopped: Bool = false) -> [RuntimeSession] {
        let sessions = allSessions(includeStopped: includeStopped)
        var byParent: [String: [RuntimeSession]] = [:]
        for session in sessions {
            if let parentSessionID = session.config.parentSessionID {
                byParent[parentSessionID, default: []].append(session)
            }
        }

        var result: [RuntimeSession] = []
        var queue = byParent[rootSessionID] ?? []
        while !queue.isEmpty {
            let session = queue.removeFirst()
            result.append(session)
            queue.append(contentsOf: byParent[session.id] ?? [])
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
        var session = resolveSession(for: event)

        // Adopt unknown Claude Code sessions as passive
        if session == nil, !event.cwd.isEmpty {
            session = tryAdoptFromEvent(event)
        }

        guard let session else { return }

        // Map event types to session transitions and journal entries
        switch event.type {
        case .toolStart:
            if session.currentTurnID == nil, session.canAcceptTurn {
                _ = session.startTurn(prompt: event.message)
            }
            // Record tool use for TurnStats
            let file = extractFilePath(from: event)
            session.recordToolUse(name: event.toolName, file: file)

            var toolData: [String: String] = ["tool": event.toolName]
            if let file { toolData["file"] = file }
            session.journal.append(
                sessionID: session.id,
                turnID: session.currentTurnID,
                type: RuntimeEventType.toolUse.rawValue,
                data: toolData
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
            if session.currentTurnID == nil, session.canAcceptTurn {
                _ = session.startTurn(prompt: event.message)
            }
            let canHandlePermission = session.currentTurnID != nil
                || session.state == .busy
                || session.state == .awaitingApproval
            if canHandlePermission {
                let ownsUserFacingNotifications = session.backend.name.lowercased() == "claude"
                if let policyError = session.config.policy.validateTool(event.toolName) {
                    _ = TerminalControlService.shared.sendInput(
                        tabID: session.tabID.uuidString, input: "n\n"
                    )
                    session.recordPolicyBlock(tool: event.toolName, reason: policyError)
                    if !ownsUserFacingNotifications {
                        emitNotification(session: session, type: "policy_blocked", message: policyError)
                    }
                } else if session.autoApprove {
                    // Layer 2: auto-respond to permission requests that bypass Layer 1
                    // (Layer 1 is the CLI flag like --full-auto / --dangerously-skip-permissions)
                    _ = TerminalControlService.shared.sendInput(
                        tabID: session.tabID.uuidString, input: "y\n"
                    )
                    Log.info("Auto-approved permission for session \(session.id): \(event.toolName) — \(event.message)")
                    if !ownsUserFacingNotifications {
                        emitNotification(session: session, type: "permission_auto_approved", message: event.message)
                    }
                } else {
                    _ = session.requestApproval(
                        tool: event.toolName,
                        description: event.message
                    )
                    if !ownsUserFacingNotifications {
                        emitNotification(session: session, type: "permission", message: event.message)
                    }
                }
            }

        case .responseComplete:
            let canCompleteTurn = session.currentTurnID != nil
                || session.state == .busy
                || session.state == .awaitingApproval
            if canCompleteTurn {
                // Read transcript tokens before completing the turn
                readTranscriptTokens(for: session, event: event)

                // Capture terminal output and turnID before completeTurn clears them
                let output = captureOutput(for: session)
                let turnIDForOutput = session.currentTurnID
                let result = session.completeTurn(summary: event.message, terminalOutput: output)

                if let output, !output.isEmpty {
                    session.journal.append(
                        sessionID: session.id,
                        turnID: turnIDForOutput,
                        type: RuntimeEventType.outputChunk.rawValue,
                        data: ["output": String(output.prefix(4096))]
                    )
                }

                // Claude owns waiting-input delivery through its upstream
                // Notification hook. Runtime stays responsible for state and
                // telemetry, but should not emit a second semantic notification.
                if session.backend.name.lowercased() != "claude" {
                    emitNotification(
                        session: session,
                        type: "waiting_input",
                        message: event.message.isEmpty ? "\(session.backend.name) is waiting for your input." : event.message
                    )
                }

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
                    let typeStr = result.exitReason == .contextLimit ? "context_limit" : "failed"
                    emitNotification(session: session, type: typeStr, message: "Exit: \(result.exitReason.rawValue)")
                }
            }

        case .sessionEnd:
            session.transition(.tabClosed)
            cleanupTranscriptReader(for: session)
            moveToStopped(session)

        case .userPrompt:
            if session.currentTurnID == nil, session.canAcceptTurn {
                _ = session.startTurn(prompt: event.message)
            }
            session.journal.append(
                sessionID: session.id,
                turnID: session.currentTurnID,
                type: RuntimeEventType.agentResponding.rawValue,
                data: ["message": event.message]
            )

        case .notification:
            session.journal.append(
                sessionID: session.id,
                turnID: session.currentTurnID,
                type: RuntimeEventType.notification.rawValue,
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

    private func resolveSession(for event: ClaudeCodeEvent) -> RuntimeSession? {
        let normalizedClaudeSessionID = normalizeClaudeSessionID(event.sessionId)

        lock.lock()
        if let normalizedClaudeSessionID,
           let runtimeSessionID = claudeToRuntimeSession[normalizedClaudeSessionID],
           let exactSession = sessions[runtimeSessionID] {
            lock.unlock()
            return exactSession
        }

        let candidateIDs = Array(cwdToSessions[event.cwd] ?? [])
        let candidates = candidateIDs.compactMap { sessions[$0] }
        let existingBindings = runtimeToClaudeSession
        lock.unlock()

        if let normalizedClaudeSessionID,
           let exactTabID = resolveClaudeTabBySessionID(normalizedClaudeSessionID, cwd: event.cwd),
           let exactSession = sessionForTab(exactTabID) {
            associateClaudeSessionID(normalizedClaudeSessionID, withRuntimeSessionID: exactSession.id)
            Log.info(
                "RuntimeSessionManager: resolved Claude session \(normalizedClaudeSessionID) via exact tab \(exactTabID)"
            )
            return exactSession
        }

        let claudeCandidates = candidates.filter { $0.backend.name == "claude" }
        guard !claudeCandidates.isEmpty else { return nil }

        let eligibleCandidates = claudeCandidates.filter { candidate in
            guard let normalizedClaudeSessionID else {
                return true
            }
            guard let boundClaudeSessionID = existingBindings[candidate.id] else {
                return true
            }
            return boundClaudeSessionID == normalizedClaudeSessionID
        }

        let chosenPool = eligibleCandidates.isEmpty ? claudeCandidates : eligibleCandidates
        guard chosenPool.count == 1 else {
            let runtimeSessionIDs = chosenPool.map(\.id).joined(separator: ", ")
            if let normalizedClaudeSessionID {
                Log.warn(
                    "RuntimeSessionManager: refusing ambiguous Claude binding for session=\(normalizedClaudeSessionID) cwd=\(event.cwd) candidates=[\(runtimeSessionIDs)]"
                )
            } else {
                Log.warn(
                    "RuntimeSessionManager: refusing ambiguous Claude binding without session ID for cwd=\(event.cwd) candidates=[\(runtimeSessionIDs)]"
                )
            }
            return nil
        }

        let chosen = chosenPool.first
        guard let chosen else { return nil }

        if let normalizedClaudeSessionID {
            associateClaudeSessionID(normalizedClaudeSessionID, withRuntimeSessionID: chosen.id)
        }

        return chosen
    }

    private func associateClaudeSessionID(_ claudeSessionID: String, withRuntimeSessionID runtimeSessionID: String) {
        lock.lock()
        if let previousClaudeSessionID = runtimeToClaudeSession[runtimeSessionID],
           previousClaudeSessionID != claudeSessionID {
            claudeToRuntimeSession.removeValue(forKey: previousClaudeSessionID)
        }
        claudeToRuntimeSession[claudeSessionID] = runtimeSessionID
        runtimeToClaudeSession[runtimeSessionID] = claudeSessionID
        lock.unlock()
    }

    private func normalizeClaudeSessionID(_ sessionID: String) -> String? {
        let trimmed = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Try to adopt an unknown Claude Code session from a monitor event.
    /// Resolves the tab by matching cwd to existing tabs.
    private func tryAdoptFromEvent(_ event: ClaudeCodeEvent) -> RuntimeSession? {
        guard !event.cwd.isEmpty else { return nil }

        let normalizedClaudeSessionID = normalizeClaudeSessionID(event.sessionId)
        let tabID: UUID?
        if let normalizedClaudeSessionID {
            tabID = resolveClaudeTabBySessionID(normalizedClaudeSessionID, cwd: event.cwd)
            if tabID == nil {
                Log.warn(
                    "RuntimeSessionManager: refusing Claude auto-adopt without exact tab for session=\(normalizedClaudeSessionID) cwd=\(event.cwd)"
                )
            }
        } else {
            tabID = resolveUniqueUnboundClaudeTabByCwd(event.cwd)
            if tabID == nil {
                Log.warn(
                    "RuntimeSessionManager: refusing Claude auto-adopt without exact session ID for cwd=\(event.cwd)"
                )
            }
        }
        guard let tabID else { return nil }

        let backend = ClaudeCodeBackend()
        let session = adoptSession(tabID: tabID, backend: backend, cwd: event.cwd)
        if let normalizedClaudeSessionID {
            associateClaudeSessionID(normalizedClaudeSessionID, withRuntimeSessionID: session.id)
        }
        Log.info("RuntimeSessionManager: auto-adopted session \(session.id) for cwd=\(event.cwd)")
        return session
    }

    /// Find a tab UUID by working directory, searching all registered windows.
    private func resolveClaudeTabBySessionID(_ sessionID: String, cwd: String) -> UUID? {
        // Must run on main thread since OverlayTabsModel is main-thread-only
        return {
            if Thread.isMainThread {
                return _resolveClaudeTabBySessionID(sessionID, cwd: cwd)
            }
            return DispatchQueue.main.sync { _resolveClaudeTabBySessionID(sessionID, cwd: cwd) }
        }()
    }

    private func _resolveClaudeTabBySessionID(_ sessionID: String, cwd: String) -> UUID? {
        let tabs = listAITabs()
        if let resolved = Self.resolveClaudeTabID(sessionID: sessionID, cwd: cwd, tabs: tabs) {
            return resolved
        }

        let matches = tabs.filter { $0.sessionID == sessionID }
        guard !matches.isEmpty else { return nil }

        let tabIDs = matches.map(\.tabID.uuidString).joined(separator: ", ")
        Log.warn(
            "RuntimeSessionManager: ambiguous Claude tab resolution for session=\(sessionID) cwd=\(cwd) matches=[\(tabIDs)]"
        )
        return nil
    }

    private func resolveUniqueClaudeTabByCwd(_ cwd: String) -> UUID? {
        // Must run on main thread since OverlayTabsModel is main-thread-only
        return {
            if Thread.isMainThread {
                return _resolveUniqueClaudeTabByCwd(cwd)
            }
            return DispatchQueue.main.sync { _resolveUniqueClaudeTabByCwd(cwd) }
        }()
    }

    private func _resolveUniqueClaudeTabByCwd(_ cwd: String) -> UUID? {
        let matches = listAITabs().filter { $0.provider == "claude" && $0.cwd == cwd }
        guard matches.count == 1 else {
            if !matches.isEmpty {
                let tabIDs = matches.map(\.tabID.uuidString).joined(separator: ", ")
                Log.warn(
                    "RuntimeSessionManager: ambiguous Claude cwd resolution for cwd=\(cwd) matches=[\(tabIDs)]"
                )
            }
            return nil
        }
        return matches.first?.tabID
    }

    private func resolveUniqueUnboundClaudeTabByCwd(_ cwd: String) -> UUID? {
        guard let tabID = resolveUniqueClaudeTabByCwd(cwd) else { return nil }
        if sessionForTab(tabID) != nil {
            Log.warn("RuntimeSessionManager: refusing Claude auto-adopt for already managed tab \(tabID) cwd=\(cwd)")
            return nil
        }
        return tabID
    }

    private func resolveClaudeTabByStrictSession(_ sessionID: String, cwd: String?) -> UUID? {
        {
            if Thread.isMainThread {
                return _resolveClaudeTabByStrictSession(sessionID, cwd: cwd)
            }
            return DispatchQueue.main.sync { _resolveClaudeTabByStrictSession(sessionID, cwd: cwd) }
        }()
    }

    private func _resolveClaudeTabByStrictSession(_ sessionID: String, cwd: String?) -> UUID? {
        let normalizedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = TabTarget(
            tool: "Claude",
            directory: normalizedCwd?.isEmpty == false ? normalizedCwd : nil,
            tabID: nil,
            sessionID: sessionID
        )
        let tabs = TerminalControlService.shared.allTabs
        return TabResolver.resolveStrictSession(target, in: tabs)?.id
    }

    struct AITabSummary {
        let tabID: UUID
        let cwd: String
        let provider: String?
        let sessionID: String?
    }

    static func resolveAuthoritativeClaudeTabID(
        sessionID: String,
        cwd: String?,
        boundSession: RuntimeSession?,
        tabs: [AITabSummary],
        strictResolver: (_ sessionID: String, _ cwd: String?) -> UUID?
    ) -> UUID? {
        if let boundSession {
            let normalizedCwd = cwd?.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalizedCwd == nil
                || normalizedCwd?.isEmpty == true
                || DirectoryPathMatcher.bidirectionalPrefixRank(
                    targetPath: normalizedCwd ?? "",
                    candidatePath: boundSession.config.directory
                ) != nil {
                return boundSession.tabID
            }
        }

        if let resolved = resolveClaudeTabID(sessionID: sessionID, cwd: cwd ?? "", tabs: tabs) {
            return resolved
        }

        return strictResolver(sessionID, cwd)
    }

    static func resolveClaudeTabID(sessionID: String, cwd: String, tabs: [AITabSummary]) -> UUID? {
        let matchingTabs = tabs.filter { $0.sessionID == sessionID }
        guard !matchingTabs.isEmpty else { return nil }

        let preferredTabs = matchingTabs.filter { $0.provider == "claude" }
        let candidateTabs = preferredTabs.isEmpty ? matchingTabs : preferredTabs

        if candidateTabs.count == 1 {
            return candidateTabs[0].tabID
        }

        let trimmedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCwd.isEmpty else { return nil }

        let rankedTabs = candidateTabs.compactMap { summary -> (tabID: UUID, rank: Int)? in
            guard let rank = DirectoryPathMatcher.bidirectionalPrefixRank(
                targetPath: trimmedCwd,
                candidatePath: summary.cwd
            ) else {
                return nil
            }
            return (summary.tabID, rank)
        }

        guard !rankedTabs.isEmpty else { return nil }
        let bestRank = rankedTabs.map(\.rank).min() ?? 0
        let bestMatches = rankedTabs.filter { $0.rank == bestRank }
        guard bestMatches.count == 1 else { return nil }
        return bestMatches[0].tabID
    }

    private func listAITabs() -> [AITabSummary] {
        let controlService = TerminalControlService.shared
        let tabsJSON = controlService.listTabs()
        guard let data = tabsJSON.data(using: .utf8),
              let tabs = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return tabs.compactMap { tab in
            guard let tabIDStr = tab["tab_id"] as? String,
                  let uuid = UUID(uuidString: tabIDStr) else {
                return nil
            }
            let provider = AIResumeParser.normalizeProviderName(
                (tab["ai_provider"] as? String) ?? (tab["active_app"] as? String) ?? ""
            )
            let sessionID = (tab["ai_session_id"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return AITabSummary(
                tabID: uuid,
                cwd: (tab["cwd"] as? String) ?? "",
                provider: provider,
                sessionID: sessionID?.isEmpty == false ? sessionID : nil
            )
        }
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
        lock.lock()
        let externalSessionID = runtimeToClaudeSession[session.id]
        lock.unlock()

        let event = AIEvent(
            source: .runtime,
            type: type,
            tool: session.backend.name,
            message: message,
            ts: DateFormatters.nowISO8601(),
            directory: session.config.directory,
            tabID: session.tabID,
            sessionID: externalSessionID ?? session.id,
            producer: "runtime_session_manager",
            reliability: .authoritative
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
        // Claude Code hook events include the file in the message for file-editing tools.
        // Only extract for tools that operate on files.
        let fileTools: Set = ["Write", "Edit", "Read", "NotebookEdit"]
        guard fileTools.contains(event.toolName) else { return nil }

        let message = event.message
        guard !message.isEmpty else { return nil }

        // The message is often the file path itself.
        // Handle both absolute (/path) and relative (src/file.swift) paths.
        let candidate = message.components(separatedBy: .whitespaces).first ?? message

        if candidate.hasPrefix("/") {
            return candidate
        }

        // Relative path — resolve against the event's cwd if available
        if !candidate.isEmpty, !event.cwd.isEmpty {
            return event.cwd + "/" + candidate
        }

        return nil
    }

    // MARK: - Private

    private func moveToStopped(_ session: RuntimeSession) {
        lock.lock()
        sessions.removeValue(forKey: session.id)
        tabToSession.removeValue(forKey: session.tabID)
        if var sessionIDs = cwdToSessions[session.config.directory] {
            sessionIDs.remove(session.id)
            if sessionIDs.isEmpty {
                cwdToSessions.removeValue(forKey: session.config.directory)
            } else {
                cwdToSessions[session.config.directory] = sessionIDs
            }
        }
        if let claudeSessionID = runtimeToClaudeSession.removeValue(forKey: session.id) {
            claudeToRuntimeSession.removeValue(forKey: claudeSessionID)
        }
        recentlyStopped[session.id] = (session, Date())
        lock.unlock()

        Log.info("RuntimeSessionManager: session \(session.id) stopped")
    }

    func resetForTesting() {
        lock.lock()
        sessions.removeAll()
        tabToSession.removeAll()
        cwdToSessions.removeAll()
        claudeToRuntimeSession.removeAll()
        runtimeToClaudeSession.removeAll()
        recentlyStopped.removeAll()
        transcriptReaders.removeAll()
        lock.unlock()
    }
}
