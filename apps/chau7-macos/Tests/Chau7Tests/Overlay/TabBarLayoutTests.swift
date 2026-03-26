import XCTest
@testable import Chau7Core

final class TabBarLayoutTests: XCTestCase {
    func testDisplayItemsIncludeIdleDropdownAndPerRunGroupTags() {
        let firstGroupTab = UUID()
        let secondGroupTab = UUID()
        let splitGroupTab = UUID()
        let idleTab = UUID()
        let tabs = [
            TabBarLayoutTab(id: firstGroupTab, repoGroupID: "/tmp/repo-a"),
            TabBarLayoutTab(id: secondGroupTab, repoGroupID: "/tmp/repo-a"),
            TabBarLayoutTab(id: idleTab, repoGroupID: nil),
            TabBarLayoutTab(id: splitGroupTab, repoGroupID: "/tmp/repo-a")
        ]

        XCTAssertEqual(
            TabBarLayout.displayItems(for: tabs, idleTabIDs: [idleTab]),
            [
                .idleTabs,
                .repoGroupTag(repoGroupID: "/tmp/repo-a", firstTabID: firstGroupTab),
                .tab(firstGroupTab),
                .tab(secondGroupTab),
                .tab(splitGroupTab),
                .newTabButton
            ]
        )
    }

    func testFallbackHitTestReturnsFirstTabForGroupTagSlot() {
        let groupedTab = UUID()
        let hiddenIdleTab = UUID()
        let tabs = [
            TabBarLayoutTab(id: groupedTab, repoGroupID: "/tmp/repo-a"),
            TabBarLayoutTab(id: hiddenIdleTab, repoGroupID: nil)
        ]

        XCTAssertNil(
            TabBarLayout.fallbackHitTestTabID(
                atX: 25,
                totalWidth: 400,
                tabs: tabs,
                idleTabIDs: [hiddenIdleTab]
            )
        )
        XCTAssertEqual(
            TabBarLayout.fallbackHitTestTabID(
                atX: 125,
                totalWidth: 400,
                tabs: tabs,
                idleTabIDs: [hiddenIdleTab]
            ),
            groupedTab
        )
        XCTAssertEqual(
            TabBarLayout.fallbackHitTestTabID(
                atX: 225,
                totalWidth: 400,
                tabs: tabs,
                idleTabIDs: [hiddenIdleTab]
            ),
            groupedTab
        )
        XCTAssertNil(
            TabBarLayout.fallbackHitTestTabID(
                atX: 375,
                totalWidth: 400,
                tabs: tabs,
                idleTabIDs: [hiddenIdleTab]
            )
        )
    }

    func testCoalescedOrderMovesMatchingTabsNextToAnchor() {
        let groupIDs = ["/tmp/repo-a", nil, "/tmp/repo-a", "/tmp/repo-b", "/tmp/repo-a"]

        XCTAssertEqual(
            TabBarLayout.coalescedOrder(groupIDs: groupIDs, targetGroupID: "/tmp/repo-a"),
            [0, 2, 4, 1, 3]
        )
    }

    func testCoalescedOrderLeavesAlreadyContiguousGroupUntouched() {
        let groupIDs = [nil, "/tmp/repo-a", "/tmp/repo-a", "/tmp/repo-b"]

        XCTAssertEqual(
            TabBarLayout.coalescedOrder(groupIDs: groupIDs, targetGroupID: "/tmp/repo-a"),
            [0, 1, 2, 3]
        )
    }
}
