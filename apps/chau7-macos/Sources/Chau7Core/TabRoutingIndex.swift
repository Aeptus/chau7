import Foundation

public struct TabRouteRecord: Equatable, Sendable {
    public let tabID: UUID
    public let paneID: UUID?
    public let title: String?
    public let directory: String?
    public let repoRoot: String?
    public let provider: String?
    public let displayName: String?
    public let activeAppName: String?
    public let sessionID: String?
    public let lastActivity: Date
    public let isDisplaySession: Bool

    public init(
        tabID: UUID,
        paneID: UUID? = nil,
        title: String? = nil,
        directory: String? = nil,
        repoRoot: String? = nil,
        provider: String? = nil,
        displayName: String? = nil,
        activeAppName: String? = nil,
        sessionID: String? = nil,
        lastActivity: Date = .distantPast,
        isDisplaySession: Bool = false
    ) {
        self.tabID = tabID
        self.paneID = paneID
        self.title = title
        self.directory = directory
        self.repoRoot = repoRoot
        self.provider = provider
        self.displayName = displayName
        self.activeAppName = activeAppName
        self.sessionID = sessionID
        self.lastActivity = lastActivity
        self.isDisplaySession = isDisplaySession
    }
}

public struct TabRoutingIndex: Equatable, Sendable {
    private let tabIDs: Set<UUID>
    private let records: [TabRouteRecord]
    private let recordsBySessionID: [String: [TabRouteRecord]]
    private let recordsByTabID: [UUID: [TabRouteRecord]]

    public init(records: [TabRouteRecord]) {
        self.records = records
        self.tabIDs = Set(records.map(\.tabID))
        var bySessionID: [String: [TabRouteRecord]] = [:]
        for record in records {
            guard let sessionID = Self.normalizedSessionID(record.sessionID) else { continue }
            bySessionID[sessionID, default: []].append(record)
        }
        self.recordsBySessionID = bySessionID
        self.recordsByTabID = Dictionary(grouping: records, by: \.tabID)
    }

    public func contains(tabID: UUID) -> Bool {
        tabIDs.contains(tabID)
    }

    public func records(for tabID: UUID) -> [TabRouteRecord] {
        recordsByTabID[tabID] ?? []
    }

    public func resolve(_ target: TabTarget, strictSession: Bool = false) -> UUID? {
        if let tabID = target.tabID, contains(tabID: tabID) {
            return tabID
        }

        guard let sessionID = Self.normalizedSessionID(target.sessionID) else {
            return strictSession ? nil : resolveWithoutSession(target)
        }

        guard let sessionRecords = recordsBySessionID[sessionID],
              !sessionRecords.isEmpty else {
            // A non-matching sessionID must not be worse than no sessionID. Some
            // tools (Codex notify hook) emit an opaque thread_id that lives in
            // a different identifier space than the tab's stored session id —
            // fall back to tool+directory routing rather than dropping.
            return strictSession ? nil : resolveWithoutSession(target)
        }

        return resolveSessionRecords(sessionRecords, target: target)
    }

    public static func normalizedToolLabels(for tool: String) -> Set<String> {
        guard let normalized = normalizedLabel(tool) else { return [] }

        var labels = Set<String>()
        labels.insert(normalized)

        if let toolDef = AIToolRegistry.allTools.first(where: { definition in
            definition.displayName.lowercased() == normalized
                || definition.commandNames.contains(normalized)
                || definition.resumeProviderKey == normalized
        }) {
            labels.insert(toolDef.displayName.lowercased())
            if let key = toolDef.resumeProviderKey {
                labels.insert(key)
            }
            for command in toolDef.commandNames {
                labels.insert(command.lowercased())
            }
            for pattern in toolDef.outputPatterns {
                labels.insert(pattern.lowercased())
            }
        }

        if let provider = AIResumeParser.normalizeProviderName(normalized) {
            labels.insert(provider)
        }

        return labels
    }

    public static func normalizedSessionID(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func resolveSessionRecords(_ sessionRecords: [TabRouteRecord], target: TabTarget) -> UUID? {
        let toolLabels = Self.normalizedToolLabels(for: target.tool)
        let providerMatches = sessionRecords.filter { record in
            !recordToolLabels(record).isDisjoint(with: toolLabels)
        }
        let providerPool = providerMatches.isEmpty ? sessionRecords : providerMatches
        let directoryPool = recordsBestMatchingDirectory(providerPool, directory: target.directory)
        let pool = directoryPool.isEmpty ? providerPool : directoryPool

        return uniqueBestTabID(from: pool)
    }

    private func resolveWithoutSession(_ target: TabTarget) -> UUID? {
        let toolLabels = Self.normalizedToolLabels(for: target.tool)
        guard !toolLabels.isEmpty else { return nil }

        let toolMatches = records.filter { record in
            !recordToolLabels(record).isDisjoint(with: toolLabels)
        }
        guard !toolMatches.isEmpty else { return nil }

        let directoryPool = recordsBestMatchingDirectory(toolMatches, directory: target.directory)
        let pool = directoryPool.isEmpty ? toolMatches : directoryPool
        return uniqueBestTabID(from: pool)
    }

    private func recordsBestMatchingDirectory(_ candidates: [TabRouteRecord], directory: String?) -> [TabRouteRecord] {
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

    private func uniqueBestTabID(from candidates: [TabRouteRecord]) -> UUID? {
        let grouped = Dictionary(grouping: candidates, by: \.tabID)
        guard !grouped.isEmpty else { return nil }
        if grouped.count == 1 {
            return grouped.keys.first
        }

        let ranked = grouped.map { tabID, records -> (tabID: UUID, displayRank: Int, activity: Date) in
            let displayRank = records.contains(where: \.isDisplaySession) ? 0 : 1
            let activity = records.map(\.lastActivity).max() ?? .distantPast
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

    private func recordToolLabels(_ record: TabRouteRecord) -> Set<String> {
        var labels = Set<String>()
        for value in [record.provider, record.displayName, record.activeAppName, record.title] {
            guard let normalized = Self.normalizedLabel(value) else { continue }
            labels.insert(normalized)
            if let provider = AIResumeParser.normalizeProviderName(normalized) {
                labels.insert(provider)
            }
        }
        return labels
    }

    private static func normalizedLabel(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func normalizedPath(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: trimmed).standardized.path
    }
}
