import Foundation

/// Only the fields displayed by the iPhone picker. Mac focus and input-pane
/// changes still reach the client, but cannot rebuild this presentation.
public struct RemoteTabPickerSnapshot: Equatable, Sendable {
    public struct Row: Equatable, Identifiable, Sendable {
        public let id: UInt32
        public let title: String
        public let projectName: String?
        public let branchName: String?
        public let aiProvider: String?
        public let isMCPControlled: Bool

        fileprivate init(_ tab: RemoteTabDescriptor) {
            self.id = tab.tabID
            self.title = tab.title
            self.projectName = Self.cleaned(tab.projectName)
            self.branchName = Self.cleaned(tab.branchName)
            self.aiProvider = Self.cleaned(tab.aiProvider)
            self.isMCPControlled = tab.isMCPControlled
        }

        private static func cleaned(_ value: String?) -> String? {
            guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        fileprivate func matches(_ query: String) -> Bool {
            [title, projectName, branchName, aiProvider, String(id)]
                .compactMap { $0 }
                .contains { $0.localizedStandardContains(query) }
        }
    }

    public struct Group: Equatable, Identifiable, Sendable {
        public let id: String
        public let title: String
        public let rows: [Row]
    }

    public let groups: [Group]
    public var tabIDs: [UInt32] {
        groups.flatMap { $0.rows.map(\.id) }
    }

    /// Reuses the app's existing alphabetical ordering. Grouping never uses
    /// activity or selection, so row positions remain stable as sessions run.
    public init(orderedTabs: [RemoteTabDescriptor]) {
        let rows = orderedTabs.map(Row.init)
        let byRepo = Dictionary(grouping: rows, by: \.projectName)
        let projects = byRepo.keys.compactMap { $0 }.sorted {
            let comparison = $0.localizedStandardCompare($1)
            return comparison == .orderedSame ? $0 < $1 : comparison == .orderedAscending
        }
        var groups = projects.map { project in
            Group(id: "repo:\(project)", title: project, rows: byRepo[project] ?? [])
        }
        if let ungrouped = byRepo[nil] {
            groups.append(Group(id: "ungrouped", title: "Other", rows: ungrouped))
        }
        self.groups = groups
    }

    public func filteredGroups(query: String) -> [Group] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return groups }
        return groups.compactMap { group in
            let rows = group.rows.filter { $0.matches(query) }
            return rows.isEmpty ? nil : Group(id: group.id, title: group.title, rows: rows)
        }
    }
}

/// Focus once when opening (including an inventory that arrives later), and
/// again only when the selected tab changes. Refreshes must not undo browsing.
public struct RemoteTabPickerFocus: Sendable {
    private var lastFocusedTabID: UInt32?

    public init() {}

    public mutating func target(activeTabID: UInt32, visibleTabIDs: [UInt32]) -> UInt32? {
        guard activeTabID != 0, visibleTabIDs.contains(activeTabID),
              activeTabID != lastFocusedTabID else { return nil }
        lastFocusedTabID = activeTabID
        return activeTabID
    }
}

/// A transport restart is not an authoritative empty inventory. Keep the
/// last list until the same Mac sends a replacement; explicit disconnect and
/// changing pairing must clear it so stale sessions cannot be selected.
public enum RemoteTabInventoryRetention {
    public static func shouldClear(
        previousPairing: RemotePairingPayload?,
        nextPairing: RemotePairingPayload?,
        discardingUserIntent: Bool
    ) -> Bool {
        discardingUserIntent || previousPairing != nextPairing
    }
}
