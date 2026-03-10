import Foundation
import Chau7Core

/// Stateless tab-routing logic extracted from OverlayTabsModel.
/// Follows the `CodexSessionResolver` pattern — caseless enum with static methods.
/// Not `@MainActor` — all inputs are passed as parameters so callers don't need
/// to cross actor boundaries. The `ClaudeCodeMonitor.shared` access in the Claude
/// fallback tier is fine because it's a thread-safe singleton.
enum TabResolver {

    /// Resolves which tab a notification event should target.
    /// When `target.tabID` is provided and found, returns the exact tab immediately (fast-path).
    /// Otherwise falls through 5 match tiers: brand → title → deep scan → Claude cwd fallback.
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
        if !brandMatches.isEmpty { return disambiguate(brandMatches, directory: target.directory) }

        // 2) Match on tab chrome title
        let titleMatches = tabs.filter { matchesCandidate($0.displayTitle) }
        if !titleMatches.isEmpty { return disambiguate(titleMatches, directory: target.directory) }

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
        if !deepMatches.isEmpty { return disambiguate(deepMatches, directory: target.directory) }

        // 4) Claude-specific fallback: correlate tabs by cwd against live
        // Claude monitor sessions and pick the most recently active one.
        if candidates.contains("claude") {
            let bestByCwd = tabs.compactMap { tab -> (tab: OverlayTab, lastActivity: Date)? in
                var activities: [Date] = []
                for pair in tab.splitController.terminalSessions {
                    let session = pair.1
                    let dir = session.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !dir.isEmpty else { continue }
                    let sessionCandidates = ClaudeCodeMonitor.shared.sessionCandidates(forDirectory: dir)
                    if let lastActivity = sessionCandidates.map({ $0.lastActivity }).max() {
                        activities.append(lastActivity)
                    }
                }
                let bestActivity = activities.max()
                guard let bestActivity else { return nil }
                return (tab: tab, lastActivity: bestActivity)
            }
            .max(by: { $0.lastActivity < $1.lastActivity })?.tab

            if let bestByCwd {
                Log.info("TabResolver: resolved '\(target.tool)' via Claude cwd fallback to tab=\(bestByCwd.id)")
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
    /// Includes common aliases (e.g. "claude" ↔ "claude code").
    static func toolMatchCandidates(for tool: String) -> [String] {
        guard let normalized = normalizedToolLabel(tool) else { return [] }

        var candidates: [String] = [normalized]
        var seen = Set(candidates)

        func append(_ value: String) {
            guard seen.insert(value).inserted else { return }
            candidates.append(value)
        }

        switch normalized {
        case "claude":
            append("claude code")
        case "codex":
            append("openai codex")
        default:
            break
        }

        return candidates
    }

    // MARK: - Private

    /// When a directory hint is available, narrow a set of matching tabs
    /// to the one whose session cwd best matches the event directory.
    /// Falls back to most recently created tab for deterministic ordering.
    private static func disambiguate(_ matches: [OverlayTab], directory: String?) -> OverlayTab? {
        guard matches.count > 1 else { return matches.first }

        // Try directory-based disambiguation when a hint is available
        if let dir = directory?.trimmingCharacters(in: .whitespacesAndNewlines),
           !dir.isEmpty {
            let normalized = URL(fileURLWithPath: dir).standardized.path
            if let dirMatch = matches.first(where: { tab in
                tab.splitController.terminalSessions.contains { _, session in
                    let cwd = URL(fileURLWithPath: session.currentDirectory).standardized.path
                    return cwd == normalized || cwd.hasPrefix(normalized + "/")
                }
            }) {
                return dirMatch
            }
        }

        // Deterministic fallback: most recently created tab
        Log.info("TabResolver: \(matches.count) ambiguous matches, using most recent tab")
        return matches.sorted(by: { $0.createdAt > $1.createdAt }).first
    }
}
