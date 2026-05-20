import Foundation

/// Explicit policy for attributing an incoming AI event to a tab.
///
/// Today four routing entrypoints implemented subtly different policies in
/// scattered code (TabRoutingIndex.resolve, TabResolver.resolve,
/// RuntimeSessionManager.resolveClaudeTabID, _resolveClaudeTabBySessionID).
/// Today's leak chain — external Terminal.app Claude sessions getting
/// attributed to Chau7 tabs — exploited the directory-only fallback in
/// several of those paths. Naming each policy explicitly closes that whole
/// class of "the resolver guessed wrong" bug.
public enum AttributionPolicy: Equatable, Sendable {
    /// Caller has a tabID stamped by a trusted source (the CHAU7_TAB_ID hook).
    /// Verify the tab exists in the snapshot; never substitute another tab.
    case trustStampedTabID

    /// Caller has a sessionID that should map exactly to one tab's
    /// effectiveAISessionID. No fallback to directory/recency heuristics —
    /// those are the leak shapes.
    case requireSessionMatch

    /// First-event binding: bind a new sessionID to an unbound tab when the
    /// event's cwd uniquely matches one tab AND that tab has sessionID == nil.
    /// An already-bound tab matching by cwd is the external-claude leak
    /// signature: refuse.
    case bindUnboundByDirectory

    /// Audit-only: return every candidate with its match reasons. Doesn't
    /// pick a winner. For debug / diagnostics.
    case audit
}

public enum AttributionResult: Equatable, Sendable {
    case matched(UUID, signal: AttributionSignal)
    case ambiguous(candidates: [UUID], reason: String)
    case refused(reason: String)
    case noMatch
    case auditTrail([AuditCandidate])
}

public enum AttributionSignal: String, Equatable, Sendable {
    case stampedTabID
    case sessionMatchExact
    case sessionMatchExactDirectoryRanked
    case directoryUnboundUnique
}

public struct AuditCandidate: Equatable, Sendable {
    public let tabID: UUID
    public let provider: String?
    public let sessionID: String?
    public let cwd: String?
    public let reasons: [String]

    public init(
        tabID: UUID,
        provider: String?,
        sessionID: String?,
        cwd: String?,
        reasons: [String]
    ) {
        self.tabID = tabID
        self.provider = provider
        self.sessionID = sessionID
        self.cwd = cwd
        self.reasons = reasons
    }
}

/// Unified tab-attribution resolver. One entry point, one policy enum, one
/// snapshot of `TabRouteRecord`s. Pure: no UI dependencies; runs anywhere.
public final class TabAttribution {
    private let snapshotProvider: () -> [TabRouteRecord]

    public init(snapshotProvider: @escaping () -> [TabRouteRecord]) {
        self.snapshotProvider = snapshotProvider
    }

    public func resolve(target: TabTarget, policy: AttributionPolicy) -> AttributionResult {
        let snapshot = snapshotProvider()
        switch policy {
        case .trustStampedTabID:
            return resolveTrustStampedTabID(target: target, snapshot: snapshot)
        case .requireSessionMatch:
            return resolveRequireSessionMatch(target: target, snapshot: snapshot)
        case .bindUnboundByDirectory:
            return resolveBindUnboundByDirectory(target: target, snapshot: snapshot)
        case .audit:
            return resolveAudit(target: target, snapshot: snapshot)
        }
    }

    // MARK: - Per-policy

    private func resolveTrustStampedTabID(
        target: TabTarget,
        snapshot: [TabRouteRecord]
    ) -> AttributionResult {
        guard let tabID = target.tabID else {
            return .refused(reason: "trustStampedTabID policy requires target.tabID")
        }
        return snapshot.contains { $0.tabID == tabID }
            ? .matched(tabID, signal: .stampedTabID)
            : .refused(reason: "stamped tabID \(tabID) not present in snapshot")
    }

    private func resolveRequireSessionMatch(
        target: TabTarget,
        snapshot: [TabRouteRecord]
    ) -> AttributionResult {
        guard let sessionID = Self.normalizedSessionID(target.sessionID) else {
            return .refused(reason: "requireSessionMatch policy requires target.sessionID")
        }
        let matches = snapshot.filter { record in
            Self.normalizedSessionID(record.sessionID) == sessionID
        }
        guard !matches.isEmpty else { return .noMatch }

        let toolLabels = Self.normalizedToolLabels(for: target.tool)
        let toolPool = matches.filter { record in
            !Self.recordToolLabels(record).isDisjoint(with: toolLabels)
        }
        let providerPool = toolPool.isEmpty ? matches : toolPool

        if let unique = Self.uniqueTabID(from: providerPool) {
            return .matched(unique, signal: .sessionMatchExact)
        }

        let directoryPool = Self.recordsBestMatchingDirectory(
            providerPool,
            directory: target.directory
        )
        let finalPool = directoryPool.isEmpty ? providerPool : directoryPool
        if let unique = Self.uniqueTabID(from: finalPool) {
            return .matched(
                unique,
                signal: directoryPool.isEmpty
                    ? .sessionMatchExact
                    : .sessionMatchExactDirectoryRanked
            )
        }
        let tabIDs = Array(Set(finalPool.map(\.tabID)))
        return .ambiguous(
            candidates: tabIDs,
            reason: "sessionID matched \(tabIDs.count) tabs; directory tiebreak inconclusive"
        )
    }

    private func resolveBindUnboundByDirectory(
        target: TabTarget,
        snapshot: [TabRouteRecord]
    ) -> AttributionResult {
        guard let directory = Self.normalizedPath(target.directory) else {
            return .refused(reason: "bindUnboundByDirectory policy requires target.directory")
        }
        let toolLabels = Self.normalizedToolLabels(for: target.tool)
        guard !toolLabels.isEmpty else {
            return .refused(reason: "bindUnboundByDirectory policy requires target.tool")
        }

        let toolMatches = snapshot.filter { record in
            !Self.recordToolLabels(record).isDisjoint(with: toolLabels)
        }
        guard !toolMatches.isEmpty else { return .noMatch }

        // Only consider tabs whose session is currently unbound. An already-
        // bound tab matching by directory is the external-claude leak
        // signature.
        let unboundTabIDs = Set(
            toolMatches
                .filter { Self.normalizedSessionID($0.sessionID) == nil }
                .map(\.tabID)
        )
        let boundTabIDsInDirectory = Set(
            toolMatches
                .filter { Self.normalizedSessionID($0.sessionID) != nil }
                .map(\.tabID)
        )

        let unboundRecords = toolMatches.filter { unboundTabIDs.contains($0.tabID) }
        let ranked = Self.recordsBestMatchingDirectory(unboundRecords, directory: directory)
        guard !ranked.isEmpty else {
            if !boundTabIDsInDirectory.isEmpty {
                return .refused(
                    reason: "all directory matches for \(target.tool) are already bound — refusing to steal"
                )
            }
            return .noMatch
        }

        if let unique = Self.uniqueTabID(from: ranked) {
            return .matched(unique, signal: .directoryUnboundUnique)
        }
        let candidates = Array(Set(ranked.map(\.tabID)))
        return .ambiguous(
            candidates: candidates,
            reason: "multiple unbound \(target.tool) tabs in directory"
        )
    }

    private func resolveAudit(
        target: TabTarget,
        snapshot: [TabRouteRecord]
    ) -> AttributionResult {
        let sessionID = Self.normalizedSessionID(target.sessionID)
        let directory = Self.normalizedPath(target.directory)
        let toolLabels = Self.normalizedToolLabels(for: target.tool)

        let candidates: [AuditCandidate] = snapshot.map { record in
            var reasons: [String] = []
            if let tabID = target.tabID, tabID == record.tabID {
                reasons.append("tabID matches")
            }
            if let sessionID, Self.normalizedSessionID(record.sessionID) == sessionID {
                reasons.append("sessionID matches")
            }
            if !Self.recordToolLabels(record).isDisjoint(with: toolLabels) {
                reasons.append("tool matches")
            }
            if let directory,
               let candidatePath = Self.normalizedPath(record.directory)
               ?? Self.normalizedPath(record.repoRoot),
               let rank = DirectoryPathMatcher.bidirectionalPrefixRank(
                   targetPath: directory,
                   candidatePath: candidatePath
               ) {
                reasons.append("directory rank=\(rank)")
            }
            if Self.normalizedSessionID(record.sessionID) == nil {
                reasons.append("unbound")
            }
            return AuditCandidate(
                tabID: record.tabID,
                provider: record.provider,
                sessionID: record.sessionID,
                cwd: record.directory,
                reasons: reasons
            )
        }
        return .auditTrail(candidates)
    }

    // MARK: - Helpers (duplicated from TabRoutingIndex for C1; consolidated in C4)

    private static func normalizedSessionID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedPath(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardized.path
    }

    private static func normalizedLabel(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func normalizedToolLabels(for tool: String) -> Set<String> {
        TabRoutingIndex.normalizedToolLabels(for: tool)
    }

    private static func recordToolLabels(_ record: TabRouteRecord) -> Set<String> {
        var labels = Set<String>()
        for value in [record.provider, record.displayName, record.activeAppName, record.title] {
            guard let normalized = normalizedLabel(value) else { continue }
            labels.insert(normalized)
            if let provider = AIResumeParser.normalizeProviderName(normalized) {
                labels.insert(provider)
            }
        }
        return labels
    }

    private static func recordsBestMatchingDirectory(
        _ candidates: [TabRouteRecord],
        directory: String?
    ) -> [TabRouteRecord] {
        guard let normalizedTarget = normalizedPath(directory) else { return [] }
        let ranked = candidates.compactMap { record -> (record: TabRouteRecord, rank: Int)? in
            guard let candidatePath = normalizedPath(record.directory) ?? normalizedPath(record.repoRoot),
                  let rank = DirectoryPathMatcher.bidirectionalPrefixRank(
                      targetPath: normalizedTarget,
                      candidatePath: candidatePath
                  ) else {
                return nil
            }
            return (record, rank)
        }
        guard let bestRank = ranked.map(\.rank).min() else { return [] }
        return ranked.filter { $0.rank == bestRank }.map(\.record)
    }

    private static func uniqueTabID(from records: [TabRouteRecord]) -> UUID? {
        let grouped = Dictionary(grouping: records, by: \.tabID)
        guard !grouped.isEmpty else { return nil }
        if grouped.count == 1 {
            return grouped.keys.first
        }

        let ranked = grouped.map { tabID, recs -> (tabID: UUID, displayRank: Int, activity: Date) in
            let displayRank = recs.contains(where: \.isDisplaySession) ? 0 : 1
            let activity = recs.map(\.lastActivity).max() ?? .distantPast
            return (tabID, displayRank, activity)
        }.sorted { lhs, rhs in
            if lhs.displayRank != rhs.displayRank {
                return lhs.displayRank < rhs.displayRank
            }
            return lhs.activity > rhs.activity
        }

        guard let best = ranked.first else { return nil }
        let ties = ranked.filter {
            $0.displayRank == best.displayRank && $0.activity == best.activity
        }
        return ties.count == 1 ? best.tabID : nil
    }
}
