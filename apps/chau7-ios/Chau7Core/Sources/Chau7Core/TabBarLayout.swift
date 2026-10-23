import Foundation
import CoreGraphics

public struct TabBarLayoutTab: Equatable {
    public let id: UUID
    public let repoGroupID: String?

    public init(id: UUID, repoGroupID: String?) {
        self.id = id
        self.repoGroupID = repoGroupID
    }
}

public enum TabBarLayoutItem: Equatable {
    case idleTabs
    case repoGroupTag(repoGroupID: String, firstTabID: UUID)
    case tab(UUID)
    case newTabButton
}

public enum TabBarLayout {
    public static func visibleTabs(
        from tabs: [TabBarLayoutTab],
        idleTabIDs: Set<UUID>
    ) -> [TabBarLayoutTab] {
        guard !idleTabIDs.isEmpty else { return tabs }
        return tabs.filter { !idleTabIDs.contains($0.id) }
    }

    public static func displayItems(
        for tabs: [TabBarLayoutTab],
        idleTabIDs: Set<UUID>
    ) -> [TabBarLayoutItem] {
        let visibleTabs = visibleTabs(from: tabs, idleTabIDs: idleTabIDs)
        guard !visibleTabs.isEmpty else { return [] }

        var items: [TabBarLayoutItem] = []
        if visibleTabs.count != tabs.count {
            items.append(.idleTabs)
        }

        var currentGroupID: String?
        for tab in visibleTabs {
            if let repoGroupID = tab.repoGroupID {
                if repoGroupID != currentGroupID {
                    items.append(.repoGroupTag(repoGroupID: repoGroupID, firstTabID: tab.id))
                    currentGroupID = repoGroupID
                }
            } else {
                currentGroupID = nil
            }
            items.append(.tab(tab.id))
        }

        items.append(.newTabButton)
        return items
    }

    public static func fallbackHitTestTabID(
        atX pointX: CGFloat,
        totalWidth: CGFloat,
        tabs: [TabBarLayoutTab],
        idleTabIDs: Set<UUID>
    ) -> UUID? {
        let items = displayItems(for: tabs, idleTabIDs: idleTabIDs)
        guard !items.isEmpty, totalWidth > 0 else { return nil }

        let itemWidth = totalWidth / CGFloat(items.count)
        guard itemWidth > 0 else { return nil }

        let maxX = max(0, totalWidth - .leastNonzeroMagnitude)
        let clampedX = min(max(0, pointX), maxX)
        let rawIndex = min(items.count - 1, Int(clampedX / itemWidth))

        switch items[rawIndex] {
        case .idleTabs, .newTabButton:
            return nil
        case .tab(let tabID):
            return tabID
        case .repoGroupTag(_, let firstTabID):
            return firstTabID
        }
    }

    public static func coalescedOrder(
        groupIDs: [String?],
        targetGroupID: String
    ) -> [Int] {
        let originalOrder = Array(groupIDs.indices)
        guard let anchorIndex = groupIDs.firstIndex(where: { $0 == targetGroupID }) else {
            return originalOrder
        }

        let movedIndices = originalOrder.filter { index in
            groupIDs[index] == targetGroupID && index != anchorIndex
        }
        guard !movedIndices.isEmpty else { return originalOrder }

        var remaining = originalOrder.filter { !movedIndices.contains($0) }
        guard let insertionIndex = remaining.firstIndex(of: anchorIndex) else {
            return originalOrder
        }

        remaining.insert(contentsOf: movedIndices, at: insertionIndex + 1)
        return remaining
    }
}
