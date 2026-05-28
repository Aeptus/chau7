import Chau7Core
import Foundation

/// AI resume metadata resolution for `OverlayTabsModel`. Six concerns:
///
///   1. **Live-session resolution** — `resolveResumeMetadata` walks the
///      registered session-finder registry and the Codex history fallback
///      to determine `(provider, sessionId)` for a live `TerminalSessionModel`.
///      Mutates the session's restore metadata when a better match is
///      discovered (W3.27 will split this into pure-resolve + explicit-attach).
///
///   2. **Save-time persistence helpers** — `persistedAIResumeMetadata` and
///      `persistedAISessionIdentity` produce the `(provider, sessionId,
///      sessionIdSource)` tuple persisted into `SavedTerminalPaneState` /
///      `SavedTabState` for cross-tab dedup via `claimedSessionIds`.
///
///   3. **Restore-time sanitization** —
///      `sanitizeRestoredAIResumeOwnership(states:)` is the post-decode
///      pass run by `OverlayTabsModel.init` that deduplicates session IDs
///      across all restored tabs/panes (older saves predate the
///      uniqueness invariant).
///
///   4. **Resume-command construction** — `buildAIResumeCommand` (4
///      overloads) routes through `AIToolRegistry.allTools` to produce
///      `claude --resume <id>` / `codex resume <id>` strings. Used by
///      both the save and restore paths.
///
///   5. **Provider-candidate ordering** — `aiResumeProviderCandidates`
///      and `resolveAIResumeMetadata` decide which provider to try
///      first when the live session lacks an explicit one.
///
///   6. **Repo identity helpers** — `persistedRepoIdentity` overloads +
///      `PersistedRepoIdentity` struct + `normalizedSavedRepoField`.
///      Co-located here because the AI-resume capture path needs the
///      repo identity per pane; not strictly AI-resume domain, but
///      moving them separately would split a tightly coupled unit.
///
/// Most of the cluster is `static` and pure — the instance methods
/// (`resolveResumeMetadata`, `persistedAIResumeMetadata`,
/// `persistedAISessionIdentity`) are the only members that depend on
/// model state (`appModel.codexHistoryEntries`,
/// `codexResumeFallbackCache`). A future extraction (tracked as the
/// "AIResumeMetadataResolver as standalone struct" follow-up) can
/// promote those three to a real type independent of `OverlayTabsModel`.
extension OverlayTabsModel {

    /// Resolves Codex/Claude resume metadata for a live `TerminalSessionModel`.
    ///
    /// **Side effects** — by default the function mutates two things:
    ///   1. `session.restoreAIMetadata(...)` is called when the resolver
    ///      discovers a sessionId that disagrees with the session's stored
    ///      identity (self-correcting state for Codex sessions whose metadata
    ///      drifted from the on-disk history).
    ///   2. `self.codexResumeFallbackCache[ObjectIdentifier(session)]` is
    ///      written/refreshed to memoize the fallback resolution path.
    ///
    /// Pass `applySessionMutations: false` to skip (1) — useful for callers
    /// that want pure resolution without side-effecting the live session
    /// (e.g. test verification, exploratory queries, MCP read-only paths).
    /// The cache memoization in (2) is always applied because skipping it
    /// would force every call to redo the Codex history scan, which is the
    /// expensive part this method is designed to amortize.
    func resolveResumeMetadata(
        for session: TerminalSessionModel,
        directory: String,
        outputHint: String?,
        claimedSessionIds: Set<String> = [],
        applySessionMutations: Bool = true
    ) -> (provider: String, sessionId: String)? {
        let referenceDate = Self.normalizedResumeReferenceDate(session.lastOutputDate)
        let detectedApp = Self.detectAIAppName(fromOutput: outputHint)
        let resumeAppName = session.aiDisplayAppName ?? detectedApp
        let explicitProvider = Self.explicitResumeProvider(for: session)
        let explicitSessionId = Self.explicitResumeSessionId(for: session)
        let hasClaimedExplicitCodexSession = explicitProvider == "codex"
            && explicitSessionId.map { claimedSessionIds.contains($0) } == true

        if let resolved = Self.resolveAIResumeMetadata(
            appName: resumeAppName,
            directory: directory,
            outputHint: outputHint,
            explicitAIProvider: explicitProvider,
            explicitAISessionId: explicitSessionId,
            referenceDate: referenceDate,
            claimedSessionIds: claimedSessionIds
        ) {
            if explicitProvider == "codex",
               explicitSessionId != resolved.sessionId {
                if applySessionMutations {
                    session.restoreAIMetadata(provider: resolved.provider, sessionId: resolved.sessionId)
                    Log.info(
                        "saveTabState: replaced Codex resume metadata sessionId=\(explicitSessionId ?? "nil") with \(resolved.sessionId)"
                    )
                } else {
                    Log.trace(
                        "resolveResumeMetadata[pure]: would replace Codex sessionId=\(explicitSessionId ?? "nil") with \(resolved.sessionId) (mutation skipped)"
                    )
                }
            }
            return resolved
        }

        let inferredProvider = Self.normalizedAIProvider(from: resumeAppName)
        guard inferredProvider == "codex" || explicitProvider == "codex" else {
            return nil
        }

        let recentHistoryEntries = Array(appModel.codexHistoryEntries.suffix(64))
        let fallbackSignature = CodexResumeFallbackSignature(
            directory: directory,
            explicitSessionId: explicitSessionId,
            referenceTimestamp: referenceDate?.timeIntervalSince1970,
            claimedSessionFingerprint: Self.sessionIDFingerprint(claimedSessionIds),
            claimedSessionCount: claimedSessionIds.count,
            historyFingerprint: Self.codexHistoryFingerprint(recentHistoryEntries)
        )
        let stableFallbackSignature = StableCodexResumeFallbackSignature(
            directory: directory,
            explicitSessionId: explicitSessionId,
            referenceTimestamp: referenceDate?.timeIntervalSince1970,
            claimedSessionFingerprint: fallbackSignature.claimedSessionFingerprint,
            claimedSessionCount: fallbackSignature.claimedSessionCount
        )
        let cacheKey = ObjectIdentifier(session)
        if let cached = codexResumeFallbackCache[cacheKey],
           cached.signature == fallbackSignature {
            return cached.metadata
        }
        if explicitProvider == "codex",
           let explicitSessionId,
           let cached = codexResumeFallbackCache[cacheKey],
           cached.stableSignature == stableFallbackSignature,
           cached.metadata?.provider == "codex",
           cached.metadata?.sessionId == explicitSessionId {
            return cached.metadata
        }

        let observedCandidates = recentHistoryEntries.compactMap { entry -> CodexSessionResolver.Candidate? in
            let observedAt = Date(timeIntervalSince1970: entry.timestamp)
            guard let metadata = CodexSessionResolver.metadata(
                forSessionID: entry.sessionId,
                referenceDate: observedAt
            ) else {
                return nil
            }
            return CodexSessionResolver.Candidate(
                sessionId: metadata.sessionId,
                cwd: metadata.cwd,
                touchedAt: observedAt
            )
        }

        let filteredCandidates = observedCandidates.filter { !claimedSessionIds.contains($0.sessionId) }

        guard let sessionId = CodexSessionResolver.bestMatchingSessionID(
            forDirectory: directory,
            referenceDate: referenceDate,
            candidates: filteredCandidates
        ) else {
            let logMessage =
                """
                saveTabState: unresolved Codex resume metadata \
                dir=\(directory) explicitSession=\(session.effectiveAISessionId ?? "nil") \
                observedCandidates=\(observedCandidates.count) filtered=\(filteredCandidates.count)
                """
            if filteredCandidates.isEmpty {
                Log.trace(logMessage)
            } else {
                Log.info(logMessage)
            }
            if let explicitSessionId,
               explicitProvider == "codex",
               !claimedSessionIds.contains(explicitSessionId) {
                let preservedExplicit = (provider: "codex", sessionId: explicitSessionId)
                codexResumeFallbackCache[cacheKey] = CachedCodexResumeFallback(
                    signature: fallbackSignature,
                    stableSignature: stableFallbackSignature,
                    metadata: preservedExplicit
                )
                Log.info(
                    "saveTabState: preserving explicit Codex resume metadata sessionId=\(explicitSessionId) for dir=\(directory) despite unresolved replacement"
                )
                return preservedExplicit
            }
            if hasClaimedExplicitCodexSession {
                let retainedExplicit = explicitSessionId.map { (provider: "codex", sessionId: $0) }
                codexResumeFallbackCache[cacheKey] = CachedCodexResumeFallback(
                    signature: fallbackSignature,
                    stableSignature: stableFallbackSignature,
                    metadata: retainedExplicit
                )
                Log.info(
                    "saveTabState: retaining claimed Codex resume metadata sessionId=\(explicitSessionId ?? "nil") for dir=\(directory)"
                )
                return retainedExplicit
            }
            codexResumeFallbackCache[cacheKey] = CachedCodexResumeFallback(
                signature: fallbackSignature,
                stableSignature: stableFallbackSignature,
                metadata: nil
            )
            return nil
        }

        if explicitSessionId != sessionId || explicitProvider != "codex" {
            if applySessionMutations {
                session.restoreAIMetadata(provider: "codex", sessionId: sessionId)
            } else {
                Log.trace(
                    "resolveResumeMetadata[pure]: would attach Codex sessionId=\(sessionId) (mutation skipped)"
                )
            }
        }
        codexResumeFallbackCache[cacheKey] = CachedCodexResumeFallback(
            signature: fallbackSignature,
            stableSignature: stableFallbackSignature,
            metadata: (provider: "codex", sessionId: sessionId)
        )
        Log.trace("saveTabState: recovered Codex resume metadata from observed history for dir=\(directory)")
        return (provider: "codex", sessionId: sessionId)
    }

    private static func explicitResumeProvider(for session: TerminalSessionModel) -> String? {
        normalizedAIProvider(from: session.lastAIProvider)
    }

    private static func explicitResumeSessionId(for session: TerminalSessionModel) -> String? {
        normalizeAISessionId(session.lastAISessionId)
    }

    /// Builds the `AIResumeOwnership.Metadata` for save-time persistence.
    ///
    /// **Side effect** — when the explicit session ID is sanitized away
    /// (because it conflicts with `claimedSessionIds`), the function calls
    /// `session.restoreAIMetadata(provider:, sessionId: nil)` to clear the
    /// session's stored sessionId. This keeps the live session in sync with
    /// what gets persisted.
    ///
    /// Pass `applySessionMutations: false` to skip the mutation — the
    /// returned `Metadata` is unchanged, only the live-session sync is
    /// suppressed. Useful for pure-query callers.
    func persistedAIResumeMetadata(
        from session: TerminalSessionModel,
        resolvedResumeMetadata: (provider: String, sessionId: String)?,
        claimedSessions: Set<AIResumeOwnership.ClaimedSession> = [],
        applySessionMutations: Bool = true
    ) -> AIResumeOwnership.Metadata {
        if let resolvedResumeMetadata {
            return AIResumeOwnership.Metadata(
                provider: resolvedResumeMetadata.provider,
                sessionId: resolvedResumeMetadata.sessionId
            )
        }

        let explicitProvider = Self.explicitResumeProvider(for: session)
        let explicitSessionId = Self.explicitResumeSessionId(for: session)
        let preserved = AIResumeOwnership.sanitizeForPersistence(
            provider: explicitProvider,
            sessionId: explicitSessionId,
            claimedSessions: claimedSessions
        )
        if explicitSessionId != nil,
           preserved.sessionId == nil,
           explicitProvider == preserved.provider {
            if applySessionMutations {
                session.restoreAIMetadata(provider: preserved.provider, sessionId: nil)
            } else {
                Log.trace(
                    "persistedAIResumeMetadata[pure]: would clear sessionId=\(explicitSessionId ?? "nil") (mutation skipped)"
                )
            }
        }
        return preserved
    }

    func persistedAISessionIdentity(
        from session: TerminalSessionModel,
        claimedSessions: Set<AIResumeOwnership.ClaimedSession> = []
    ) -> (provider: String?, sessionId: String?, sessionIdSource: AISessionIdentitySource?) {
        let effectiveProvider = Self.normalizedAIProvider(from: session.effectiveAIProvider ?? session.lastAIProvider)
        let effectiveSessionId = Self.normalizePersistedAISessionId(
            session.effectiveAISessionId,
            source: session.effectiveAISessionIdentitySource
        )
        let sanitized = AIResumeOwnership.sanitizeForPersistence(
            provider: effectiveProvider,
            sessionId: effectiveSessionId,
            claimedSessions: claimedSessions
        )
        let persistedSource: AISessionIdentitySource?
        if sanitized.sessionId == nil {
            persistedSource = nil
        } else {
            persistedSource = session.effectiveAISessionIdentitySource
        }
        return (
            provider: sanitized.provider ?? effectiveProvider,
            sessionId: sanitized.sessionId,
            sessionIdSource: persistedSource
        )
    }

    private struct RestoredResumeCandidate {
        let provider: String
        let sessionId: String
        let sessionIdSource: AISessionIdentitySource?
        let command: String?
    }

    private struct SanitizedRestoredResume {
        let provider: String?
        let sessionId: String?
        let sessionIdSource: AISessionIdentitySource?
        let command: String?
        let resumeDirectory: String?
    }

    private static func appendCommandCandidate(
        _ command: String?,
        to candidates: inout [RestoredResumeCandidate]
    ) {
        guard let command = normalizedResumeCommand(command),
              let metadata = AIResumeParser.extractMetadata(from: command) else {
            return
        }
        candidates.append(RestoredResumeCandidate(
            provider: metadata.provider,
            sessionId: metadata.sessionId,
            sessionIdSource: .explicit,
            command: command
        ))
    }

    private static func appendFieldCandidate(
        provider: String?,
        sessionId: String?,
        source: AISessionIdentitySource?,
        to candidates: inout [RestoredResumeCandidate]
    ) {
        guard let normalizedProvider = normalizedAIProvider(from: provider),
              let normalizedSessionId = normalizePersistedAISessionId(sessionId, source: source) else {
            return
        }
        candidates.append(RestoredResumeCandidate(
            provider: normalizedProvider,
            sessionId: normalizedSessionId,
            sessionIdSource: source ?? .explicit,
            command: nil
        ))
    }

    private static func restoredResumeCandidates(
        aiResumeCommand: String?,
        agentLaunchCommand: String?,
        aiProvider: String?,
        aiSessionId: String?,
        aiSessionIdSource: AISessionIdentitySource?,
        fallbackAIProvider: String? = nil,
        fallbackAISessionId: String? = nil,
        fallbackAISessionIdSource: AISessionIdentitySource? = nil
    ) -> [RestoredResumeCandidate] {
        var candidates: [RestoredResumeCandidate] = []
        appendCommandCandidate(aiResumeCommand, to: &candidates)
        appendCommandCandidate(agentLaunchCommand, to: &candidates)
        appendFieldCandidate(
            provider: aiProvider,
            sessionId: aiSessionId,
            source: aiSessionIdSource,
            to: &candidates
        )
        appendFieldCandidate(
            provider: fallbackAIProvider,
            sessionId: fallbackAISessionId,
            source: fallbackAISessionIdSource,
            to: &candidates
        )

        var seen = Set<String>()
        return candidates.filter { candidate in
            let key = "\(candidate.provider):\(candidate.sessionId)"
            return seen.insert(key).inserted
        }
    }

    private static func sanitizeRestoredResumeCandidate(
        _ candidate: RestoredResumeCandidate,
        directory: String,
        claimedSessions: Set<AIResumeOwnership.ClaimedSession>,
        fileManager: FileManager,
        environment: [String: String]
    ) -> SanitizedRestoredResume? {
        let sanitized = AIResumeOwnership.sanitizeForPersistence(
            provider: candidate.provider,
            sessionId: candidate.sessionId,
            claimedSessions: claimedSessions
        )
        guard let provider = sanitized.provider,
              let sessionId = sanitized.sessionId else {
            return nil
        }

        let resumeDirectory: String?
        if provider == "claude" {
            if candidate.sessionIdSource == .synthetic {
                resumeDirectory = nil
            } else {
                guard restoredClaudeTranscriptExists(
                    sessionId: sessionId,
                    directory: directory,
                    fileManager: fileManager,
                    environment: environment
                ) else {
                    Log.warn(
                        "sanitizeRestoredAIResumeOwnership: dropping unrestorable Claude metadata session=\(sessionId.prefix(8)) dir=\(directory)"
                    )
                    return nil
                }
                resumeDirectory = ClaudeSessionResolver.restoreDirectory(
                    forSessionID: sessionId,
                    savedDirectory: directory,
                    fileManager: fileManager,
                    environment: environment
                )
            }
        } else {
            resumeDirectory = nil
        }

        let command = buildAIResumeCommand(provider: provider, sessionId: sessionId)
            ?? candidate.command
        return SanitizedRestoredResume(
            provider: provider,
            sessionId: sessionId,
            sessionIdSource: candidate.sessionIdSource,
            command: command,
            resumeDirectory: resumeDirectory
        )
    }

    private static func sanitizeRestoredResumeCandidates(
        _ candidates: [RestoredResumeCandidate],
        directory: String,
        claimedSessions: Set<AIResumeOwnership.ClaimedSession>,
        fileManager: FileManager,
        environment: [String: String]
    ) -> SanitizedRestoredResume {
        for candidate in candidates {
            if let sanitized = sanitizeRestoredResumeCandidate(
                candidate,
                directory: directory,
                claimedSessions: claimedSessions,
                fileManager: fileManager,
                environment: environment
            ) {
                return sanitized
            }
        }
        return SanitizedRestoredResume(
            provider: nil,
            sessionId: nil,
            sessionIdSource: nil,
            command: nil,
            resumeDirectory: nil
        )
    }

    static func resolveRestoreDirectoryForMetadata(
        provider: String?,
        sessionId: String?,
        savedDirectory: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard provider == "claude",
              let sessionId else {
            return nil
        }
        return ClaudeSessionResolver.restoreDirectory(
            forSessionID: sessionId,
            savedDirectory: savedDirectory,
            fileManager: fileManager,
            environment: environment
        )
    }

    private static func validateRestoredClaudeMetadata(
        provider: String,
        sessionId: String,
        sessionIdSource: AISessionIdentitySource?,
        directory: String,
        fileManager: FileManager,
        environment: [String: String]
    ) -> Bool {
        guard provider == "claude" else { return true }
        guard sessionIdSource != .synthetic else { return true }
        guard restoredClaudeTranscriptExists(
            sessionId: sessionId,
            directory: directory,
            fileManager: fileManager,
            environment: environment
        ) else {
            Log.warn(
                "sanitizeRestoredAIResumeOwnership: dropping unrestorable Claude metadata session=\(sessionId.prefix(8)) dir=\(directory)"
            )
            return false
        }
        return true
    }

    static func restoredClaudeTranscriptExists(
        sessionId: String,
        directory: String,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        guard let normalizedSessionId = normalizeAISessionId(sessionId) else { return false }
        return ClaudeSessionResolver.hasRestorableTranscript(
            sessionId: normalizedSessionId,
            savedDirectory: directory,
            fileManager: fileManager,
            environment: environment
        )
    }

    static func sanitizeRestoredAIResumeOwnership(
        states: [SavedTabState],
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [SavedTabState] {
        var claimedSessions = Set<AIResumeOwnership.ClaimedSession>()

        return states.map { state in
            let sanitizedPaneStates = state.paneStates?.map { paneState -> SavedTerminalPaneState in
                let sanitizedPane = sanitizeRestoredResumeCandidates(
                    restoredResumeCandidates(
                        aiResumeCommand: paneState.aiResumeCommand,
                        agentLaunchCommand: paneState.agentLaunchCommand,
                        aiProvider: paneState.aiProvider,
                        aiSessionId: paneState.aiSessionId,
                        aiSessionIdSource: paneState.aiSessionIdSource
                    ),
                    directory: paneState.directory,
                    claimedSessions: claimedSessions,
                    fileManager: fileManager,
                    environment: environment
                )
                if let sessionId = sanitizedPane.sessionId, let provider = sanitizedPane.provider {
                    claimedSessions.insert(
                        AIResumeOwnership.ClaimedSession(provider: provider, sessionId: sessionId)
                    )
                }

                return SavedTerminalPaneState(
                    paneID: paneState.paneID,
                    directory: paneState.directory,
                    scrollbackContent: paneState.scrollbackContent,
                    aiResumeCommand: sanitizedPane.command,
                    aiResumeDirectory: sanitizedPane.resumeDirectory,
                    aiProvider: sanitizedPane.provider,
                    aiSessionId: sanitizedPane.sessionId,
                    aiSessionIdSource: sanitizedPane.sessionIdSource,
                    lastOutputAt: paneState.lastOutputAt,
                    lastInputAt: paneState.lastInputAt,
                    knownRepoRoot: paneState.knownRepoRoot,
                    knownGitBranch: paneState.knownGitBranch,
                    lastStatus: paneState.lastStatus,
                    agentLaunchCommand: paneState.agentLaunchCommand,
                    agentStartedAt: paneState.agentStartedAt,
                    lastExitCode: paneState.lastExitCode,
                    lastExitAt: paneState.lastExitAt
                )
            }

            let sanitizedTopLevel = sanitizeRestoredResumeCandidates(
                restoredResumeCandidates(
                    aiResumeCommand: state.aiResumeCommand,
                    agentLaunchCommand: state.agentLaunchCommand,
                    aiProvider: state.aiProvider,
                    aiSessionId: state.aiSessionId,
                    aiSessionIdSource: state.aiSessionIdSource
                ),
                directory: state.directory,
                claimedSessions: claimedSessions,
                fileManager: fileManager,
                environment: environment
            )
            if let sessionId = sanitizedTopLevel.sessionId, let provider = sanitizedTopLevel.provider {
                claimedSessions.insert(
                    AIResumeOwnership.ClaimedSession(provider: provider, sessionId: sessionId)
                )
            }

            return SavedTabState(
                tabID: state.tabID,
                selectedTabID: state.selectedTabID,
                customTitle: state.customTitle,
                color: state.color,
                directory: state.directory,
                selectedIndex: state.selectedIndex,
                tokenOptOverride: state.tokenOptOverride,
                scrollbackContent: state.scrollbackContent,
                aiResumeCommand: sanitizedTopLevel.command,
                aiProvider: sanitizedTopLevel.provider,
                aiSessionId: sanitizedTopLevel.sessionId,
                aiSessionIdSource: sanitizedTopLevel.sessionIdSource,
                splitLayout: state.splitLayout,
                focusedPaneID: state.focusedPaneID,
                paneStates: sanitizedPaneStates,
                createdAt: state.createdAt,
                repoGroupID: state.repoGroupID,
                knownRepoRoot: state.knownRepoRoot,
                knownGitBranch: state.knownGitBranch,
                lastInputAt: state.lastInputAt,
                lastStatus: state.lastStatus,
                agentLaunchCommand: state.agentLaunchCommand,
                agentStartedAt: state.agentStartedAt,
                lastExitCode: state.lastExitCode,
                lastExitAt: state.lastExitAt,
                commandBlocks: state.commandBlocks
            )
        }
    }

    struct PersistedRepoIdentity {
        let rootPath: String
        let branch: String?
    }

    static func persistedRepoIdentity(
        for session: TerminalSessionModel,
        directory: String,
        fallbackRoot: String? = nil
    ) -> PersistedRepoIdentity? {
        let directRoot = normalizedSavedRepoField(session.gitRootPath) ?? normalizedSavedRepoField(fallbackRoot)
        let storeIdentity = KnownRepoIdentityStore.shared.resolveIdentity(forPath: directory)
            ?? directRoot.flatMap { KnownRepoIdentityStore.shared.identity(forRootPath: $0) }
        guard let rootPath = directRoot ?? normalizedSavedRepoField(storeIdentity?.rootPath) else {
            return nil
        }
        let branch = normalizedSavedRepoField(session.gitBranch) ?? normalizedSavedRepoField(storeIdentity?.lastKnownBranch)
        return PersistedRepoIdentity(rootPath: rootPath, branch: branch)
    }

    static func persistedRepoIdentity(from paneState: SavedTerminalPaneState) -> PersistedRepoIdentity? {
        guard let rootPath = normalizedSavedRepoField(paneState.knownRepoRoot) else {
            return nil
        }
        return PersistedRepoIdentity(
            rootPath: rootPath,
            branch: normalizedSavedRepoField(paneState.knownGitBranch)
        )
    }

    static func normalizedSavedRepoField(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Build a resume command for an AI session running in the given directory.
    /// Returns nil if no resumable session is found.
    static func buildAIResumeCommand(appName: String?, directory: String, outputHint: String? = nil) -> String? {
        guard let resolved = resolveAIResumeMetadata(
            appName: appName,
            directory: directory,
            outputHint: outputHint
        ) else {
            return nil
        }
        return buildAIResumeCommand(provider: resolved.provider, sessionId: resolved.sessionId)
    }

    static func buildAIResumeCommand(
        appName: String?,
        directory: String,
        outputHint: String? = nil,
        aiProvider: String?,
        aiSessionId: String?,
        referenceDate: Date? = nil
    ) -> String? {
        guard let resolved = resolveAIResumeMetadata(
            appName: appName,
            directory: directory,
            outputHint: outputHint,
            explicitAIProvider: aiProvider,
            explicitAISessionId: aiSessionId,
            referenceDate: referenceDate
        ) else {
            return nil
        }
        return buildAIResumeCommand(provider: resolved.provider, sessionId: resolved.sessionId)
    }

    static func buildAIResumeCommand(provider: String?, sessionId: String?) -> String? {
        buildAIResumeCommand(provider: provider, sessionId: sessionId, sessionIdSource: nil)
    }

    static func buildAIResumeCommand(
        provider: String?,
        sessionId: String?,
        sessionIdSource: AISessionIdentitySource?
    ) -> String? {
        if sessionIdSource == .synthetic {
            return nil
        }
        guard let provider = normalizedAIProvider(from: provider),
              let sessionId = normalizeAISessionId(sessionId) else {
            return nil
        }

        guard let tool = AIToolRegistry.allTools.first(where: { $0.resumeProviderKey == provider }) else {
            // Provider normalized cleanly and we have a valid session ID,
            // but the tool isn't in our registry at all. Log once per
            // unique provider so users can see why their resume didn't
            // fire on a CLI we haven't wired up.
            Self.logResumeUnsupportedOnce(provider: provider, reason: "tool_not_in_registry")
            return nil
        }
        guard let format = tool.resumeFormat else {
            // Tool is known but has no resumeFormat configured — this
            // matches providers where we intentionally haven't added a
            // resume command format (e.g. some CLIs have no --resume
            // equivalent). Surface it so adding a new provider without
            // wiring resume is obvious.
            Self.logResumeUnsupportedOnce(provider: provider, reason: "no_resume_format")
            return nil
        }
        return format.buildCommand(sessionId: sessionId)
    }

    private static var loggedUnsupportedResumeProviders: Set<String> = []
    private static let loggedUnsupportedResumeProvidersLock = NSLock()
    private static func logResumeUnsupportedOnce(provider: String, reason: String) {
        loggedUnsupportedResumeProvidersLock.lock()
        let alreadyLogged = loggedUnsupportedResumeProviders.contains(provider)
        if !alreadyLogged {
            loggedUnsupportedResumeProviders.insert(provider)
        }
        loggedUnsupportedResumeProvidersLock.unlock()
        if !alreadyLogged {
            Log.info("buildAIResumeCommand: resume unsupported for provider=\(provider) reason=\(reason)")
        }
    }

    static func resolveAIResumeMetadataFromSavedState(
        paneState: SavedTerminalPaneState,
        fallbackAIProvider: String?,
        fallbackAISessionId: String?,
        fallbackAISessionIdSource: AISessionIdentitySource? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (provider: String, sessionId: String, sessionIdSource: AISessionIdentitySource?)? {
        let candidates = restoredResumeCandidates(
            aiResumeCommand: paneState.aiResumeCommand,
            agentLaunchCommand: paneState.agentLaunchCommand,
            aiProvider: paneState.aiProvider,
            aiSessionId: paneState.aiSessionId,
            aiSessionIdSource: paneState.aiSessionIdSource,
            fallbackAIProvider: fallbackAIProvider,
            fallbackAISessionId: fallbackAISessionId,
            fallbackAISessionIdSource: fallbackAISessionIdSource
        )
        for candidate in candidates {
            guard validateRestoredClaudeMetadata(
                provider: candidate.provider,
                sessionId: candidate.sessionId,
                sessionIdSource: candidate.sessionIdSource,
                directory: paneState.directory,
                fileManager: fileManager,
                environment: environment
            ) else {
                continue
            }
            return (
                provider: candidate.provider,
                sessionId: candidate.sessionId,
                sessionIdSource: candidate.sessionIdSource
            )
        }
        return nil
    }

    static func normalizedResumeReferenceDate(_ value: Date) -> Date? {
        return value == .distantPast ? nil : value
    }

    static func normalizedResumeReferenceDate(_ value: Date?) -> Date? {
        guard let value else { return nil }
        return value == .distantPast ? nil : value
    }

    static func codexHistoryFingerprint(_ entries: [HistoryEntry]) -> Int {
        var hasher = Hasher()
        hasher.combine(entries.count)
        if let first = entries.first {
            hasher.combine(first.sessionId)
            hasher.combine(first.timestamp.bitPattern)
        }
        if let last = entries.last {
            hasher.combine(last.sessionId)
            hasher.combine(last.timestamp.bitPattern)
        }
        for entry in entries.suffix(8) {
            hasher.combine(entry.sessionId)
            hasher.combine(entry.timestamp.bitPattern)
        }
        return hasher.finalize()
    }

    static func sessionIDFingerprint(_ sessionIds: Set<String>) -> Int {
        var hasher = Hasher()
        hasher.combine(sessionIds.count)
        for sessionId in sessionIds.sorted() {
            hasher.combine(sessionId)
        }
        return hasher.finalize()
    }

    static func resolveAIResumeMetadata(
        appName: String?,
        directory: String,
        outputHint: String? = nil,
        explicitAIProvider: String? = nil,
        explicitAISessionId: String? = nil,
        referenceDate: Date? = nil,
        claimedSessionIds: Set<String> = []
    ) -> (provider: String, sessionId: String)? {
        let canonicalDirectory = normalizedSessionDirectory(directory)
        let explicitProvider = normalizedAIProvider(from: explicitAIProvider)
        let explicitSessionId = normalizeAISessionId(explicitAISessionId)
        let liveProviderHint = aiResumeProviderCandidates(
            appName: appName,
            outputHint: outputHint,
            explicitProvider: nil
        ).first

        if let explicitProvider {
            if let resolved = resolvedAIResumeMetadata(
                provider: explicitProvider,
                sessionId: explicitSessionId,
                directory: canonicalDirectory,
                referenceDate: referenceDate,
                claimedSessionIds: claimedSessionIds
            ) {
                return resolved
            }

            // If we already have an explicit provider for a pane but no matching session
            // can be found in that provider/directory, avoid guessing another provider.
            // This keeps restore metadata deterministic and prevents cross-tab bleed-through.
            if explicitSessionId == nil {
                if liveProviderHint == nil || liveProviderHint == explicitProvider {
                    return nil
                }
            }
        }

        let inferredProviders = aiResumeProviderCandidates(
            appName: appName,
            outputHint: outputHint,
            explicitProvider: explicitProvider
        )
        for candidateProvider in inferredProviders {
            if let sessionId = findAIResumeSessionId(
                for: candidateProvider,
                directory: canonicalDirectory,
                referenceDate: referenceDate,
                claimedSessionIds: claimedSessionIds
            ) {
                return (provider: candidateProvider, sessionId: sessionId)
            }
        }

        return nil
    }

    static func aiResumeProviderCandidates(
        appName: String?,
        outputHint: String?,
        explicitProvider: String?
    ) -> [String] {
        var providers: [String] = []
        var seenProviders = Set<String>()

        func appendProvider(_ value: String?) {
            guard let provider = value, !provider.isEmpty else { return }
            guard seenProviders.insert(provider).inserted else { return }
            providers.append(provider)
        }

        if let appNameProvider = appName?.trimmingCharacters(in: .whitespacesAndNewlines) {
            appendProvider(normalizedAIProvider(from: appNameProvider))
        }

        if let hint = outputHint {
            appendProvider(
                CommandDetection.detectAppFromOutput(hint)
                    .flatMap { normalizedAIProvider(from: $0) }
                    .flatMap { outputProvider in
                        if outputProvider == explicitProvider { return nil }
                        return outputProvider
                    }
            )
        }

        appendProvider(explicitProvider)

        return providers
    }

    static func resolvedAIResumeMetadata(
        provider: String?,
        sessionId: String?,
        directory: String,
        referenceDate: Date?,
        claimedSessionIds: Set<String> = []
    ) -> (provider: String, sessionId: String)? {
        if let provider, let sessionId {
            guard !claimedSessionIds.contains(sessionId) else {
                Log.info("resolveAIResumeMetadata: explicit sessionId=\(sessionId) already claimed by another tab, skipping")
                return nil
            }
            Log.trace("resolveAIResumeMetadata: using explicit session metadata provider=\(provider), sessionId=\(sessionId)")
            return (provider: provider, sessionId: sessionId)
        }

        guard !directory.isEmpty,
              let provider,
              let foundSessionId = findAIResumeSessionId(
                  for: provider,
                  directory: directory,
                  referenceDate: referenceDate,
                  claimedSessionIds: claimedSessionIds
              ) else {
            return nil
        }
        return (provider: provider, sessionId: foundSessionId)
    }
}
