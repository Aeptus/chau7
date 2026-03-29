import Foundation
import Chau7Core

/// Stateless tab-routing logic extracted from OverlayTabsModel.
/// Follows the `CodexSessionResolver` pattern — caseless enum with static methods.
/// Not `@MainActor` — all inputs are passed as parameters so callers don't need
/// to cross actor boundaries. CWD resolvers accessed in the fallback tier are
/// registered by tool monitors at startup via `registerCWDResolver`.
enum TabResolver {

    // MARK: - CWD Resolver Registry

    /// Closure type: given a directory path, return the most recent session
    /// activity date for that tool in that directory, or nil if none found.
    typealias CWDResolver = (String) -> Date?

    private static let resolverLock = NSLock()
    private static var cwdResolvers: [String: CWDResolver] = [:]
    private static let ambiguityLogLock = NSLock()
    private static var ambiguityLogState: [String: (lastLoggedAt: Date, suppressedCount: Int)] = [:]
    private static let ambiguityLogInterval: TimeInterval = 30

    /// Register a CWD-based session resolver for a tool's provider key.
    /// Called by tool monitors during setup (e.g. in `start()` or a static
    /// initializer).  TabResolver itself never references specific monitors.
    static func registerCWDResolver(forProviderKey key: String, resolver: @escaping CWDResolver) {
        resolverLock.lock()
        defer { resolverLock.unlock() }
        cwdResolvers[key] = resolver
    }

    // MARK: - Resolution

    /// Resolves which tab a notification event should target.
    /// When `target.tabID` is provided and found, returns the exact tab immediately (fast-path).
    /// Otherwise falls through 4 match tiers: brand → title → deep scan → cwd fallback.
    static func resolve(_ target: TabTarget, in tabs: [OverlayTab]) -> OverlayTab? {
        // Fast-path: exact tab ID match
        if let tabID = target.tabID, let exactTab = tabs.first(where: { $0.id == tabID }) {
            return exactTab
        }

        let candidates = toolMatchCandidates(for: target.tool)

        // Session IDs are the strongest cross-tool identity signal we have for
        // history-monitor events. Resolve them before broader tool-label scans.
        if let exactSessionMatch = exactSessionMatch(for: target, candidates: candidates, in: tabs) {
            return exactSessionMatch
        }

        guard !candidates.isEmpty else { return nil }

        func matchesCandidate(_ rawName: String?) -> Bool {
            guard let normalized = normalizedToolLabel(rawName) else { return false }
            return candidates.contains(normalized)
        }

        // 1) Fast exact match on focused session branding
        let brandMatches = tabs.filter { matchesCandidate($0.displaySession?.aiDisplayAppName) }
        if !brandMatches.isEmpty { return disambiguate(brandMatches, target: target) }

        // 2) Match on tab chrome title
        let titleMatches = tabs.filter { matchesCandidate($0.displayTitle) }
        if !titleMatches.isEmpty { return disambiguate(titleMatches, target: target) }

        // 3) Deep scan every terminal session in each tab
        let deepMatches = tabs.filter { tab in
            tab.splitController.terminalSessions.contains { _, session in
                if matchesCandidate(session.aiDisplayAppName) { return true }
                if matchesCandidate(session.activeAppName) { return true }
                if let provider = AIResumeParser.normalizeProviderName(session.lastAIProvider ?? ""),
                   candidates.contains(provider) {
                    return true
                }
                return false
            }
        }
        if !deepMatches.isEmpty { return disambiguate(deepMatches, target: target) }

        // 4) CWD fallback: correlate tabs by cwd against a registered session
        // resolver for this tool and pick the most recently active one.
        if let cwdResolver = registeredResolver(for: candidates) {
            let bestByCwd = tabs.compactMap { tab -> (tab: OverlayTab, lastActivity: Date)? in
                var activities: [Date] = []
                for pair in tab.splitController.terminalSessions {
                    let session = pair.1
                    let dir = session.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !dir.isEmpty else { continue }
                    if let lastActivity = cwdResolver(dir) {
                        activities.append(lastActivity)
                    }
                }
                let bestActivity = activities.max()
                guard let bestActivity else { return nil }
                return (tab: tab, lastActivity: bestActivity)
            }
            .max(by: { $0.lastActivity < $1.lastActivity })?.tab

            if let bestByCwd {
                Log.info("TabResolver: resolved '\(target.tool)' via cwd fallback to tab=\(bestByCwd.id)")
                return bestByCwd
            }
        }

        return nil
    }

    // MARK: - Helpers

    /// Normalizes a tool/app label for case-insensitive comparison, using the
    /// AI provider name mapper when available.
    static func normalizedToolLabel(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        if let provider = AIResumeParser.normalizeProviderName(trimmed) {
            return provider
        }
        return trimmed
    }

    /// Builds a set of candidate strings to match against tab labels.
    /// Derives all aliases from `AIToolRegistry` so adding a new tool is a
    /// single edit to the registry — no changes needed here.
    static func toolMatchCandidates(for tool: String) -> [String] {
        guard let normalized = normalizedToolLabel(tool) else { return [] }

        var candidates: [String] = [normalized]
        var seen = Set(candidates)

        func append(_ value: String) {
            let lowered = value.lowercased()
            guard seen.insert(lowered).inserted else { return }
            candidates.append(lowered)
        }

        // Find the matching tool definition and pull in all its known names
        if let toolDef = AIToolRegistry.allTools.first(where: { def in
            def.displayName.lowercased() == normalized
                || def.commandNames.contains(normalized)
                || def.resumeProviderKey == normalized
        }) {
            append(toolDef.displayName)
            if let key = toolDef.resumeProviderKey { append(key) }
            for cmd in toolDef.commandNames {
                append(cmd)
            }
            // Include output patterns that double as display labels
            for pattern in toolDef.outputPatterns {
                append(pattern)
            }
        }

        return candidates
    }

    // MARK: - Private

    /// Looks up the registered CWD resolver for the tool matching the given
    /// candidates.  Returns nil if no resolver is registered for this tool.
    private static func registeredResolver(for candidates: [String]) -> CWDResolver? {
        // Find the provider key for the tool
        let providerKey: String? = candidates.lazy.compactMap { candidate in
            AIToolRegistry.allTools.first { def in
                def.displayName.lowercased() == candidate
                    || def.commandNames.contains(candidate)
                    || def.resumeProviderKey == candidate
            }?.resumeProviderKey
        }.first

        guard let providerKey else { return nil }

        resolverLock.lock()
        defer { resolverLock.unlock() }
        return cwdResolvers[providerKey]
    }

    private static func exactSessionMatch(
        for target: TabTarget,
        candidates: [String],
        in tabs: [OverlayTab]
    ) -> OverlayTab? {
        guard let sessionID = target.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionID.isEmpty else {
            return nil
        }

        let rankedMatches = tabs.compactMap { tab -> (tab: OverlayTab, providerRank: Int)? in
            let matchingSessions = tab.splitController.terminalSessions.compactMap { _, session -> TerminalSessionModel? in
                session.effectiveAISessionId == sessionID ? session : nil
            }
            guard !matchingSessions.isEmpty else { return nil }

            let providerMatches = matchingSessions.contains { session in
                sessionMatchesCandidates(session, candidates: candidates)
            }
            return (tab: tab, providerRank: providerMatches ? 0 : 1)
        }
        guard !rankedMatches.isEmpty else { return nil }

        let bestRank = rankedMatches.map(\.providerRank).min() ?? 0
        let bestMatches = rankedMatches
            .filter { $0.providerRank == bestRank }
            .map(\.tab)

        if bestMatches.count == 1 {
            Log.info("TabResolver: resolved via exact sessionID=\(sessionID.prefix(8)) → tab=\(bestMatches[0].id)")
            return bestMatches[0]
        }

        if let dir = target.directory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            let normalized = URL(fileURLWithPath: dir).standardized.path
            let rankedByDirectory = bestMatches.compactMap { tab -> (tab: OverlayTab, rank: Int)? in
                let ranks = tab.splitController.terminalSessions.compactMap { _, session in
                    directoryMatchRank(targetDirectory: normalized, sessionDirectory: session.currentDirectory)
                }
                guard let rank = ranks.min() else { return nil }
                return (tab: tab, rank: rank)
            }

            if let bestDirectoryRank = rankedByDirectory.map(\.rank).min() {
                let directoryMatches = rankedByDirectory
                    .filter { $0.rank == bestDirectoryRank }
                    .map(\.tab)
                if directoryMatches.count == 1 {
                    Log.info("TabResolver: resolved via sessionID+directory=\(sessionID.prefix(8)) → tab=\(directoryMatches[0].id)")
                    return directoryMatches[0]
                }
                if let bestByActivity = directoryMatches.max(by: { a, b in
                    tabLastActivityDate(a) < tabLastActivityDate(b)
                }) {
                    Log.info("TabResolver: resolved via sessionID+activity=\(sessionID.prefix(8)) → tab=\(bestByActivity.id)")
                    return bestByActivity
                }
            }
        }

        if let bestByActivity = bestMatches.max(by: { a, b in
            tabLastActivityDate(a) < tabLastActivityDate(b)
        }) {
            Log.info("TabResolver: resolved via sessionID+activity=\(sessionID.prefix(8)) → tab=\(bestByActivity.id)")
            return bestByActivity
        }

        return nil
    }

    /// When a session ID or directory hint is available, narrow a set of matching
    /// tabs to the one whose session best matches the event.
    /// Falls back to most recently created tab for deterministic ordering.
    ///
    /// Resolution order:
    /// 1. Session ID — exact match against `TerminalSessionModel.effectiveAISessionId`
    /// 2. Directory — bidirectional prefix match (tab cwd inside event dir or vice versa)
    /// 3. Most recently created tab (deterministic fallback)
    private static func disambiguate(_ matches: [OverlayTab], target: TabTarget) -> OverlayTab? {
        guard matches.count > 1 else { return matches.first }

        // 1) Session ID disambiguation: exact match on AI session identity
        if let sessionID = target.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sessionID.isEmpty {
            if let sessionMatch = matches.first(where: { tab in
                tab.splitController.terminalSessions.contains { _, session in
                    session.effectiveAISessionId == sessionID
                }
            }) {
                Log.info("TabResolver: disambiguated via sessionID=\(sessionID.prefix(8)) → tab=\(sessionMatch.id)")
                return sessionMatch
            }
        }

        // 2) Directory-based disambiguation: find tabs matching the event's directory.
        //    If multiple match, prefer the most recently active one.
        if let dir = target.directory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            let normalized = URL(fileURLWithPath: dir).standardized.path
            let rankedMatches = matches.compactMap { tab -> (tab: OverlayTab, rank: Int)? in
                let ranks = tab.splitController.terminalSessions.compactMap { _, session in
                    directoryMatchRank(targetDirectory: normalized, sessionDirectory: session.currentDirectory)
                }
                guard let rank = ranks.min() else { return nil }
                return (tab: tab, rank: rank)
            }

            if let bestRank = rankedMatches.map(\.rank).min() {
                let dirMatches = rankedMatches
                    .filter { $0.rank == bestRank }
                    .map(\.tab)

                if dirMatches.count == 1 {
                    return dirMatches[0]
                }
                if dirMatches.count > 1 {
                    let best = dirMatches.max(by: { a, b in
                        let aDate = tabLastActivityDate(a)
                        let bDate = tabLastActivityDate(b)
                        return aDate < bDate
                    })
                    if let best {
                        let scope = bestRank == 0 ? "dir+activity exact" : "dir+activity related"
                        Log.info("TabResolver: disambiguated via \(scope) (\(normalized.suffix(20))) → tab=\(best.id)")
                        return best
                    }
                }
            }
        }

        // 3) Deterministic fallback: most recently active tab
        let best = matches.max(by: { a, b in
            let aDate = tabLastActivityDate(a)
            let bDate = tabLastActivityDate(b)
            return aDate < bDate
        })
        logAmbiguousFallback(target: target, matchesCount: matches.count)
        return best
    }

    private static func tabLastActivityDate(_ tab: OverlayTab) -> Date {
        let sessionDates = tab.splitController.terminalSessions.map { _, session in
            session.lastActivityDate
        }
        return sessionDates.max() ?? tab.createdAt
    }

    private static func directoryMatchRank(targetDirectory: String, sessionDirectory: String) -> Int? {
        DirectoryPathMatcher.bidirectionalPrefixRank(
            targetPath: targetDirectory,
            candidatePath: sessionDirectory
        )
    }

    private static func sessionMatchesCandidates(_ session: TerminalSessionModel, candidates: [String]) -> Bool {
        guard !candidates.isEmpty else { return true }

        let labels = [
            normalizedToolLabel(session.aiDisplayAppName),
            normalizedToolLabel(session.activeAppName),
            normalizedToolLabel(session.effectiveAIProvider),
            normalizedToolLabel(session.lastAIProvider)
        ]

        return labels.compactMap { $0 }.contains { candidates.contains($0) }
    }

    private static func logAmbiguousFallback(target: TabTarget, matchesCount: Int) {
        let tool = normalizedToolLabel(target.tool) ?? target.tool.lowercased()
        let directory = target.directory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
        let sessionID = target.sessionID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "-"
        let key = "\(tool)|\(directory)|\(sessionID)|\(matchesCount)"
        let now = Date()

        var logLine: String?
        ambiguityLogLock.lock()
        if var state = ambiguityLogState[key],
           now.timeIntervalSince(state.lastLoggedAt) < ambiguityLogInterval {
            state.suppressedCount += 1
            ambiguityLogState[key] = state
        } else {
            let suppressedCount = ambiguityLogState[key]?.suppressedCount ?? 0
            ambiguityLogState[key] = (lastLoggedAt: now, suppressedCount: 0)
            if suppressedCount > 0 {
                logLine = "TabResolver: \(matchesCount) ambiguous matches, using most recently active tab (suppressed \(suppressedCount) similar)"
            } else {
                logLine = "TabResolver: \(matchesCount) ambiguous matches, using most recently active tab"
            }
        }
        ambiguityLogLock.unlock()

        if let logLine {
            Log.info(logLine)
        }
    }
}
