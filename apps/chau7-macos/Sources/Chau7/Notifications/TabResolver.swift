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
            for cmd in toolDef.commandNames { append(cmd) }
            // Include output patterns that double as display labels
            for pattern in toolDef.outputPatterns { append(pattern) }
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

        // 2) Try directory-based disambiguation when a hint is available
        if let dir = target.directory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            let normalized = URL(fileURLWithPath: dir).standardized.path
            if let dirMatch = matches.first(where: { tab in
                tab.splitController.terminalSessions.contains { _, session in
                    let cwd = URL(fileURLWithPath: session.currentDirectory).standardized.path
                    return cwd == normalized
                        || cwd.hasPrefix(normalized + "/")
                        || normalized.hasPrefix(cwd + "/")
                }
            }) {
                return dirMatch
            }
        }

        // 3) Deterministic fallback: most recently created tab
        Log.info("TabResolver: \(matches.count) ambiguous matches, using most recent tab")
        return matches.sorted(by: { $0.createdAt > $1.createdAt }).first
    }
}
