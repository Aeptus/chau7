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

    private static func normalizedLabel(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
