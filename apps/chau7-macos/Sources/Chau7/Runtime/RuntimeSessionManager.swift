import Foundation
import Chau7Core

/// Singleton registry for all active runtime sessions.
///
/// Subscribes to `ClaudeCodeMonitor.onEvent` to drive state transitions.
/// Thread-safe via `NSLock` (same pattern as `TelemetryRecorder`).
final class RuntimeSessionManager {
    static let shared = RuntimeSessionManager()

    private struct PendingToolInvocation {
        let turnID: String
        let correlationID: String
        let toolName: String
        let file: String?
        let argsSummary: String?
        let startedAt: Date
    }

    private struct OutputJournalState {
        let turnID: String
        var emittedCharacterCount: Int
        var nextChunkIndex: Int
    }

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
    private var pendingToolInvocations: [String: [PendingToolInvocation]] = [:]
    private var outputJournalStates: [String: OutputJournalState] = [:]

    private var outputChunkPreviewLimit: Int {
        FeatureSettings.shared.runtimeOutputChunkLimit
    }

    private init() {}

    /// Unified attribution resolver — replaces the scatter of session/tab
    /// matching logic that produced today's leak chain. Migration is
    /// incremental: this commit migrates only `tryAdoptFromEvent`; remaining
    /// callers still go through the legacy resolvers.
    private lazy var tabAttribution = TabAttribution {
        TerminalControlService.shared.routingRecords()
    }

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
            autoApprove: autoApprove,
            journalCapacity: FeatureSettings.shared.runtimeEventJournalCapacity
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
            adopted: true,
            journalCapacity: FeatureSettings.shared.runtimeEventJournalCapacity
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

        // Bound-session fast path: if we already adopted this session, the
        // bound tab is authoritative when the cwd still looks consistent
        // with the binding. Preserves the historical behaviour of
        // `resolveAuthoritativeClaudeTabID`'s boundSession check.
        if let bound = sessionForClaudeSessionID(normalized) {
            let tabExists = tabExistsLocked(bound.tabID)
            let cwdMatches = cwd.map { incoming -> Bool in
                let trimmed = incoming.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return true }
                return DirectoryPathMatcher.bidirectionalPrefixRank(
                    targetPath: trimmed,
                    candidatePath: bound.config.directory
                ) != nil
            } ?? true
            if tabExists, cwdMatches {
                return bound.tabID
            }
        }

        let target = TabTarget(tool: "Claude", directory: cwd, sessionID: normalized)
        let result = tabAttribution.resolve(target: target, policy: .requireSessionMatch)
        if case let .matched(tabID, _) = result {
            return tabID
        }
        return nil
    }

    private func tabExistsLocked(_ tabID: UUID) -> Bool {
        TerminalControlService.shared.routingRecords().contains { $0.tabID == tabID }
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
            let file = extractFilePath(from: event)
            let argsSummary = RuntimeToolEventMetadata.argsSummary(from: event.message)
            let correlationID = registerPendingToolInvocation(
                sessionID: session.id,
                turnID: session.currentTurnID ?? "unknown",
                toolName: event.toolName,
                file: file,
                argsSummary: argsSummary
            )

            session.recordToolUse(name: event.toolName, file: file)

            var toolData: [String: String] = ["tool": event.toolName]
            if let file { toolData["file"] = file }
            if let argsSummary { toolData["args_summary"] = argsSummary }
            session.journal.append(
                sessionID: session.id,
                turnID: session.currentTurnID,
                type: RuntimeEventType.toolUse.rawValue,
                correlationID: correlationID,
                data: toolData
            )

        case .toolComplete:
            journalOutputDeltaIfNeeded(for: session)
            let toolInvocation = completePendingToolInvocation(
                sessionID: session.id,
                turnID: session.currentTurnID,
                toolName: event.toolName
            )
            let resultMetadata = RuntimeToolEventMetadata.inferResult(
                toolName: event.toolName,
                message: event.message
            )
            var toolResultData: [String: String] = [
                "tool": event.toolName,
                "success": resultMetadata.success ? "true" : "false"
            ]
            if let file = toolInvocation?.file {
                toolResultData["file"] = file
            }
            if let durationMs = toolInvocation.map({ max(0, Int(Date().timeIntervalSince($0.startedAt) * 1000)) }) {
                toolResultData["duration_ms"] = "\(durationMs)"
            }
            if let exitCode = resultMetadata.exitCode {
                toolResultData["exit_code"] = "\(exitCode)"
            }
            if let error = resultMetadata.error {
                toolResultData["error"] = error
            }
            if let preview = resultMetadata.outputPreview {
                toolResultData["output_preview"] = preview
            }
            session.journal.append(
                sessionID: session.id,
                turnID: session.currentTurnID,
                type: RuntimeEventType.toolResult.rawValue,
                correlationID: toolInvocation?.correlationID,
                data: toolResultData
            )

        case .permissionRequest:
            if session.currentTurnID == nil, session.canAcceptTurn {
                _ = session.startTurn(prompt: event.message)
            }
            journalOutputDeltaIfNeeded(for: session)
            let canHandlePermission = session.currentTurnID != nil
                || session.state == .busy
                || session.state == .awaitingApproval
            if canHandlePermission {
                let toolCorrelationID = currentToolCorrelationID(sessionID: session.id, turnID: session.currentTurnID)
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
                        description: event.message,
                        correlationID: toolCorrelationID
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
                guard finalizeTurn(
                    session: session,
                    summary: event.message,
                    terminalOutput: output,
                    source: "provider_response_complete",
                    emitWaitingInputNotification: session.backend.name.lowercased() != "claude"
                ) != nil else {
                    Log.error("RuntimeSessionManager: completeTurn rejected for session \(session.id)")
                    return
                }
            }

        case .sessionEnd:
            session.transition(.tabClosed)
            cleanupTranscriptReader(for: session)
            clearSessionEventTracking(sessionID: session.id)
            moveToStopped(session)

        case .userPrompt:
            if session.shouldSuppressProviderUserPromptEcho(prompt: event.message) {
                return
            }
            if session.currentTurnID == nil, session.canAcceptTurn {
                _ = session.startTurn(prompt: event.message)
            }
            session.journalUserInput(prompt: event.message)

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

    @discardableResult
    func reconcileTurnIfTerminalSettled(sessionID: String, source: String) -> Bool {
        guard let session = session(id: sessionID),
              session.state == .busy,
              session.currentTurnID != nil else {
            return false
        }

        let output = captureOutput(for: session)
        guard finalizeTurn(
            session: session,
            summary: nil,
            terminalOutput: output,
            source: source,
            emitWaitingInputNotification: false
        ) != nil else {
            return false
        }

        Log.info("RuntimeSessionManager: reconciled busy turn for session \(session.id) via \(source)")
        return true
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

        if let normalizedClaudeSessionID {
            let target = TabTarget(
                tool: "Claude",
                directory: event.cwd,
                sessionID: normalizedClaudeSessionID
            )
            let result = tabAttribution.resolve(target: target, policy: .requireSessionMatch)
            if case let .matched(exactTabID, _) = result,
               let exactSession = sessionForTab(exactTabID) {
                associateClaudeSessionID(
                    normalizedClaudeSessionID,
                    withRuntimeSessionID: exactSession.id
                )
                Log.info(
                    "RuntimeSessionManager: resolved Claude session \(normalizedClaudeSessionID) via exact tab \(exactTabID)"
                )
                return exactSession
            }
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

    /// Short-TTL de-dup cache for failed adoption attempts. Avoids log spam on
    /// bursty events within a brief window but never permanently locks out —
    /// a later event for the same session/cwd always retries once the cooldown
    /// elapses. The old permanent-giveup cache pinned tabs to stale provider
    /// identities when disambiguation failed even once.
    private var recentlyFailedAdoptions: [String: Date] = [:]

    /// How long to suppress retry logs for a given cache key after a failure.
    private static let adoptionRetryCooldown: TimeInterval = 3.0

    /// Second tier: chronic-orphan tracking. A session ID that has failed
    /// adoption repeatedly across at least
    /// `chronicOrphanSuppressionDuration` and at least
    /// `chronicOrphanSuppressionThreshold` attempts is genuinely orphaned
    /// (process exited, tab was closed long ago, stale event backlog,
    /// etc.). Log warnings forever for such sessions are pure noise, so
    /// we emit one "permanently suppressing" line and then go quiet for
    /// the rest of the process lifetime. A single `resetAdoptionCache`
    /// call (e.g. on window refresh) clears both tiers so subsequent
    /// retries can log again.
    private struct ChronicOrphanTracking {
        let firstSeenAt: Date
        var failureCount: Int
        var suppressionLogged: Bool
    }

    private var chronicOrphanTracking: [String: ChronicOrphanTracking] = [:]

    private static let chronicOrphanSuppressionThreshold = 6
    private static let chronicOrphanSuppressionDuration: TimeInterval = 60.0

    /// Clear the failed adoption cache so new tabs can be discovered.
    func resetAdoptionCache() {
        lock.lock()
        defer { lock.unlock() }
        recentlyFailedAdoptions.removeAll()
        chronicOrphanTracking.removeAll()
    }

    func shouldSkipAdoptionByCooldown(_ cacheKey: String, now: Date = Date()) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let last = recentlyFailedAdoptions[cacheKey] else { return false }
        return now.timeIntervalSince(last) < Self.adoptionRetryCooldown
    }

    func recordAdoptionFailure(_ cacheKey: String, now: Date = Date()) {
        lock.lock()
        defer { lock.unlock() }
        recentlyFailedAdoptions[cacheKey] = now
    }

    /// Returns a tri-state describing how the caller should log a chronic
    /// adoption failure for `sessionID`:
    ///   - `.log` — below the suppression threshold; emit the normal
    ///     "no tab match" warning.
    ///   - `.logSuppressionMarker` — crossing the threshold for the first
    ///     time; emit a distinct "permanently suppressing" line so the
    ///     operator knows further retries on this session will be silent.
    ///   - `.suppress` — already past the threshold; emit nothing.
    ///
    /// `sessionID` is expected to be a non-empty trimmed string; pass
    /// the same value you'd embed in the log (the `normalizedClaudeSessionID`).
    enum ChronicOrphanLogDecision {
        case log
        case logSuppressionMarker
        case suppress
    }

    /// Compact "no tab match" diagnostic line. Factored out so the log
    /// string is identical regardless of which log-decision branch emits
    /// it (normal vs. suppression-marker path).
    private func emitNoTabMatchWarning(sessionID: String, cwd: String) {
        let aiTabs = listAITabs()
        let withSession = aiTabs.filter { !($0.sessionID?.isEmpty ?? true) }
        let samplePrefixes = withSession
            .prefix(6)
            .compactMap { $0.sessionID.map { String($0.prefix(8)) } }
            .joined(separator: ",")
        Log.warn(
            "RuntimeSessionManager: no tab match for Claude session=\(sessionID) cwd=\(cwd) " +
                "aiTabs=\(aiTabs.count) withSessionID=\(withSession.count) knownSessionPrefixes=[\(samplePrefixes)]"
        )
    }

    func decideChronicOrphanLog(sessionID: String, now: Date = Date()) -> ChronicOrphanLogDecision {
        lock.lock()
        defer { lock.unlock() }
        let tracking: ChronicOrphanTracking
        if let existing = chronicOrphanTracking[sessionID] {
            tracking = ChronicOrphanTracking(
                firstSeenAt: existing.firstSeenAt,
                failureCount: existing.failureCount + 1,
                suppressionLogged: existing.suppressionLogged
            )
        } else {
            tracking = ChronicOrphanTracking(firstSeenAt: now, failureCount: 1, suppressionLogged: false)
        }
        let elapsed = now.timeIntervalSince(tracking.firstSeenAt)
        let isPastThreshold = tracking.failureCount >= Self.chronicOrphanSuppressionThreshold
            && elapsed >= Self.chronicOrphanSuppressionDuration
        let updated = ChronicOrphanTracking(
            firstSeenAt: tracking.firstSeenAt,
            failureCount: tracking.failureCount,
            suppressionLogged: tracking.suppressionLogged || isPastThreshold
        )
        chronicOrphanTracking[sessionID] = updated
        if isPastThreshold {
            return tracking.suppressionLogged ? .suppress : .logSuppressionMarker
        }
        return .log
    }

    /// Try to adopt an unknown Claude Code session from a monitor event.
    /// Resolves the tab by matching session ID or cwd to existing tabs. When
    /// multiple tabs share a cwd without a discriminating session ID, the live
    /// process tree is consulted — picking the tab whose shell is actually
    /// running a Claude process. Failures use a short-TTL cooldown rather than
    /// a permanent cache so new tabs can adopt later events.
    private func tryAdoptFromEvent(_ event: ClaudeCodeEvent) -> RuntimeSession? {
        guard !event.cwd.isEmpty else { return nil }

        let normalizedClaudeSessionID = normalizeClaudeSessionID(event.sessionId)
        let cacheKey = normalizedClaudeSessionID ?? "cwd:\(event.cwd)"

        if shouldSkipAdoptionByCooldown(cacheKey) { return nil }

        let tabID = stampedClaudeTabID(from: event.tabID) ?? resolveAdoptionTabID(
            sessionID: normalizedClaudeSessionID,
            cwd: event.cwd,
            cacheKey: cacheKey
        )
        guard let tabID else { return nil }

        let backend = ClaudeCodeBackend()
        let session = adoptSession(tabID: tabID, backend: backend, cwd: event.cwd)
        if let normalizedClaudeSessionID {
            associateClaudeSessionID(normalizedClaudeSessionID, withRuntimeSessionID: session.id)
        }
        Log.info("RuntimeSessionManager: auto-adopted session \(session.id) for cwd=\(event.cwd)")
        return session
    }

    private func stampedClaudeTabID(from rawTabID: String) -> UUID? {
        let trimmed = rawTabID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tabID = UUID(uuidString: trimmed), tabExistsLocked(tabID) else {
            return nil
        }
        return tabID
    }

    /// Resolves which tab to bind a hook-event session to using TabAttribution
    /// policies. Falls back to the live process tree on `.ambiguous` because
    /// the pure resolver can't see which shell actually has claude running.
    private func resolveAdoptionTabID(
        sessionID: String?,
        cwd: String,
        cacheKey: String
    ) -> UUID? {
        let target = TabTarget(tool: "Claude", directory: cwd, sessionID: sessionID)

        if sessionID != nil {
            // Authoritative: caller knows the session id, the tab should
            // already have it in its routing snapshot.
            let result = tabAttribution.resolve(target: target, policy: .requireSessionMatch)
            switch result {
            case let .matched(tabID, _):
                return tabID
            case .ambiguous, .refused, .auditTrail:
                // Should not happen for `.requireSessionMatch`/`.audit`, but
                // treat as no-match for adoption purposes.
                break
            case .noMatch:
                break
            }
        }

        // First-event-binding fallback: only adopt UNBOUND Claude tabs whose
        // cwd matches. This is the path that legitimately binds a brand-new
        // session to the tab that just spawned it.
        let bindResult = tabAttribution.resolve(target: target, policy: .bindUnboundByDirectory)
        switch bindResult {
        case let .matched(tabID, _):
            return tabID
        case let .ambiguous(candidates, _):
            // Pure resolver can't choose — consult live process tree to pick
            // the tab whose shell actually has claude running.
            if let disambiguated = TerminalControlService.shared
                .disambiguateClaudeTabsByProcessTree(candidates: candidates) {
                return disambiguated
            }
            recordAdoptionFailure(cacheKey)
            Log.warn(
                "RuntimeSessionManager: ambiguous Claude tabs for cwd=\(cwd) — " +
                    "process-tree disambiguation found 0 or >1 candidates"
            )
            return nil
        case .refused:
            // bindUnboundByDirectory refuses when all matching tabs are
            // already bound — exactly the external-claude leak signature.
            recordAdoptionFailure(cacheKey)
            if let sessionID {
                emitChronicOrphanLogIfNeeded(sessionID: sessionID, cwd: cwd)
            }
            return nil
        case .noMatch:
            recordAdoptionFailure(cacheKey)
            if let sessionID {
                emitChronicOrphanLogIfNeeded(sessionID: sessionID, cwd: cwd)
            } else {
                Log.warn(
                    "RuntimeSessionManager: no Claude tab matches cwd=\(cwd) for sessionless adoption"
                )
            }
            return nil
        case .auditTrail:
            return nil
        }
    }

    private func emitChronicOrphanLogIfNeeded(sessionID: String, cwd: String) {
        let decision = decideChronicOrphanLog(sessionID: sessionID)
        switch decision {
        case .suppress:
            break
        case .log:
            emitNoTabMatchWarning(sessionID: sessionID, cwd: cwd)
        case .logSuppressionMarker:
            emitNoTabMatchWarning(sessionID: sessionID, cwd: cwd)
            Log.warn(
                "RuntimeSessionManager: permanently suppressing further 'no tab match' warnings for Claude session=\(sessionID) — " +
                    "crossed \(Self.chronicOrphanSuppressionThreshold)-failure threshold over \(Int(Self.chronicOrphanSuppressionDuration))s. " +
                    "Session is likely orphaned (process exited, tab closed). resetAdoptionCache() clears suppression."
            )
        }
    }

    struct AITabSummary {
        let tabID: UUID
        let cwd: String
        let provider: String?
        let sessionID: String?
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
                  let uuid = controlService.resolveControlPlaneTabID(tabIDStr) else {
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
        let result = controlService.tabOutput(
            tabID: session.tabID.uuidString,
            lines: max(FeatureSettings.shared.scrollbackLines, 5000),
            source: "pty_log"
        )
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? String else {
            return nil
        }
        return output
    }

    @discardableResult
    private func finalizeTurn(
        session: RuntimeSession,
        summary: String?,
        terminalOutput: String?,
        source: String,
        emitWaitingInputNotification: Bool
    ) -> RuntimeSession.TurnCompletionResult? {
        let turnIDForOutput = session.currentTurnID
        journalOutputDeltaIfNeeded(for: session)
        guard let result = session.completeTurn(summary: summary, terminalOutput: terminalOutput) else {
            return nil
        }
        clearTurnScopedTracking(sessionID: session.id, turnID: turnIDForOutput)

        if source != "provider_response_complete" {
            session.journal.append(
                sessionID: session.id,
                turnID: turnIDForOutput,
                type: RuntimeEventType.turnReconciled.rawValue,
                data: [
                    "source": source,
                    "exit_reason": result.exitReason.rawValue
                ]
            )
        }

        if emitWaitingInputNotification {
            let waitingInputMessage: String
            if let summary, !summary.isEmpty {
                waitingInputMessage = summary
            } else {
                waitingInputMessage = "\(session.backend.name) is waiting for your input."
            }
            emitNotification(
                session: session,
                type: "waiting_input",
                message: waitingInputMessage
            )
        }

        recordTurnCompletionSideEffects(
            session: session,
            turnID: turnIDForOutput,
            result: result
        )
        return result
    }

    private func recordTurnCompletionSideEffects(
        session: RuntimeSession,
        turnID: String?,
        result: RuntimeSession.TurnCompletionResult
    ) {
        let crossedCostThresholds = session.consumeCrossedCostThresholds(FeatureSettings.shared.runtimeCostThresholdsUSD)
        for threshold in crossedCostThresholds {
            session.journal.append(
                sessionID: session.id,
                turnID: turnID,
                type: RuntimeEventType.costThreshold.rawValue,
                data: [
                    "threshold_usd": String(format: "%.2f", threshold),
                    "estimated_cost_usd": String(format: "%.6f", result.estimatedCostUSD ?? 0)
                ]
            )
        }

        TelemetryRecorder.shared.updateLiveMetrics(
            tabID: session.tabID.uuidString,
            model: session.config.model,
            tokenUsage: result.cumulativeUsage,
            turnCount: session.turnCount,
            costUSD: result.estimatedCostUSD,
            tokenUsageSource: .transcriptDelta,
            tokenUsageState: result.cumulativeUsage.hasAnyTokens ? .estimated : .missing,
            costSource: result.estimatedCostUSD != nil ? .estimated : .unavailable,
            costState: result.estimatedCostUSD != nil ? .estimated : .missing
        )

        if result.exitReason != .success {
            let typeStr = result.exitReason == .contextLimit ? "context_limit" : "failed"
            emitNotification(session: session, type: typeStr, message: "Exit: \(result.exitReason.rawValue)")
        }
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
            NotificationServices.current?.manager.notify(for: event)
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
        if tokens.input > 0 || tokens.output > 0 || tokens.cacheCreation > 0 || tokens.cacheRead > 0 || tokens.reasoningOutput > 0 {
            session.addTokens(
                input: tokens.input,
                output: tokens.output,
                cacheCreation: tokens.cacheCreation,
                cacheRead: tokens.cacheRead,
                reasoningOutput: tokens.reasoningOutput
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
        RuntimeToolEventMetadata.extractFilePath(
            toolName: event.toolName,
            message: event.message,
            cwd: event.cwd
        )
    }

    // MARK: - Private

    private func registerPendingToolInvocation(
        sessionID: String,
        turnID: String,
        toolName: String,
        file: String?,
        argsSummary: String?
    ) -> String {
        let correlationID = UUID().uuidString
        let invocation = PendingToolInvocation(
            turnID: turnID,
            correlationID: correlationID,
            toolName: toolName,
            file: file,
            argsSummary: argsSummary,
            startedAt: Date()
        )
        lock.lock()
        let existing = pendingToolInvocations[sessionID] ?? []
        pendingToolInvocations[sessionID] = existing.filter { $0.turnID == turnID } + [invocation]
        lock.unlock()
        return correlationID
    }

    private func completePendingToolInvocation(sessionID: String, turnID: String?, toolName: String) -> PendingToolInvocation? {
        lock.lock()
        defer { lock.unlock() }

        guard var invocations = pendingToolInvocations[sessionID], !invocations.isEmpty else {
            return nil
        }

        if let turnID {
            invocations.removeAll { $0.turnID != turnID }
        }
        guard !invocations.isEmpty else {
            pendingToolInvocations.removeValue(forKey: sessionID)
            return nil
        }

        let index = invocations.firstIndex { $0.toolName == toolName } ?? 0
        let invocation = invocations.remove(at: index)
        if invocations.isEmpty {
            pendingToolInvocations.removeValue(forKey: sessionID)
        } else {
            pendingToolInvocations[sessionID] = invocations
        }
        return invocation
    }

    private func currentToolCorrelationID(sessionID: String, turnID: String?) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let turnID else { return nil }
        return pendingToolInvocations[sessionID]?.last(where: { $0.turnID == turnID })?.correlationID
    }

    private func journalOutputDeltaIfNeeded(for session: RuntimeSession) {
        guard let turnID = session.currentTurnID,
              let output = captureOutput(for: session),
              !output.isEmpty else {
            return
        }

        lock.lock()
        var state = outputJournalStates[session.id]
            ?? OutputJournalState(turnID: turnID, emittedCharacterCount: 0, nextChunkIndex: 0)
        if state.turnID != turnID || output.count < state.emittedCharacterCount {
            state = OutputJournalState(turnID: turnID, emittedCharacterCount: 0, nextChunkIndex: 0)
        }

        let emittedCount = min(state.emittedCharacterCount, output.count)
        let delta = String(output.dropFirst(emittedCount))
        guard !delta.isEmpty else {
            outputJournalStates[session.id] = state
            lock.unlock()
            return
        }

        let chunks = chunkStrings(delta, maxLength: outputChunkPreviewLimit)
        let startingChunkIndex = state.nextChunkIndex
        state.emittedCharacterCount = output.count
        state.nextChunkIndex += chunks.count
        outputJournalStates[session.id] = state
        lock.unlock()

        for (index, chunk) in chunks.enumerated() {
            session.journal.append(
                sessionID: session.id,
                turnID: turnID,
                type: RuntimeEventType.outputChunk.rawValue,
                data: [
                    "turn_id": turnID,
                    "chunk_index": "\(startingChunkIndex + index)",
                    "output": chunk
                ]
            )
        }
    }

    private func chunkStrings(_ text: String, maxLength: Int) -> [String] {
        guard maxLength > 0, !text.isEmpty else { return [] }
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            let end = text.index(start, offsetBy: maxLength, limitedBy: text.endIndex) ?? text.endIndex
            chunks.append(String(text[start ..< end]))
            start = end
        }
        return chunks
    }

    private func clearTurnScopedTracking(sessionID: String, turnID: String?) {
        lock.lock()
        pendingToolInvocations.removeValue(forKey: sessionID)
        if let turnID, outputJournalStates[sessionID]?.turnID == turnID {
            outputJournalStates.removeValue(forKey: sessionID)
        }
        lock.unlock()
    }

    private func clearSessionEventTracking(sessionID: String) {
        lock.lock()
        pendingToolInvocations.removeValue(forKey: sessionID)
        outputJournalStates.removeValue(forKey: sessionID)
        lock.unlock()
    }

    private func moveToStopped(_ session: RuntimeSession) {
        var externalSessionID: String?
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
            externalSessionID = claudeSessionID
        }
        pendingToolInvocations.removeValue(forKey: session.id)
        outputJournalStates.removeValue(forKey: session.id)
        recentlyStopped[session.id] = (session, Date())
        lock.unlock()

        Task { @MainActor in
            NotificationServices.current?.executor.cancelPendingStyleWork(
                tabID: session.tabID,
                sessionID: externalSessionID
            )
        }

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
        pendingToolInvocations.removeAll()
        outputJournalStates.removeAll()
        recentlyFailedAdoptions.removeAll()
        chronicOrphanTracking.removeAll()
        lock.unlock()
    }
}
