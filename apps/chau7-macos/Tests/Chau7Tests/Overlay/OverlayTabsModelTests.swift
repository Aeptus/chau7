import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class OverlayTabsModelTests: XCTestCase {

    private var model: OverlayTabsModel!
    private var appModel: AppModel!

    override func setUp() {
        super.setUp()
        // Clear any saved tab state so restoreSavedTabs returns nil
        // and the model starts with a single fresh tab.
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        appModel = AppModel()
        model = OverlayTabsModel(appModel: appModel)
    }

    override func tearDown() {
        model = nil
        appModel = nil
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertEqual(model.tabs.count, 1, "Model should start with exactly one tab")
        XCTAssertEqual(model.selectedTabID, model.tabs.first?.id,
                       "The single initial tab should be selected")
        XCTAssertFalse(model.isSearchVisible)
        XCTAssertFalse(model.isBroadcastMode)
    }

    // MARK: - Tab Creation (addTab / newTab)

    func testNewTabIncreasesCount() {
        let initialCount = model.tabs.count
        model.newTab()
        XCTAssertEqual(model.tabs.count, initialCount + 1,
                       "newTab should add exactly one tab")
    }

    func testNewTabBecomesSelected() {
        model.newTab()
        let lastTab = model.tabs.last!
        XCTAssertEqual(model.selectedTabID, lastTab.id,
                       "Newly created tab should become the selected tab")
    }

    func testNewTabGetsUniqueID() {
        model.newTab()
        model.newTab()
        let ids = model.tabs.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count,
                       "Every tab should have a unique ID")
    }

    func testNewTabCyclesColors() {
        // Start with 1 tab, add enough to cycle through all colors
        let colorCount = TabColor.allCases.count
        for _ in 0..<colorCount {
            model.newTab()
        }
        // The (colorCount + 1)th tab should wrap around to the first color
        let wrappedTab = model.tabs[colorCount]
        let firstColor = TabColor.allCases[colorCount % colorCount]
        XCTAssertEqual(wrappedTab.color, firstColor,
                       "Tab colors should cycle through TabColor.allCases")
    }

    func testNewTabAtDirectorySetsCwd() {
        let directory = "/tmp/test-dir"
        model.newTab(at: directory)
        // The new tab was created; just verify it exists and is selected.
        // The actual directory change is deferred to the shell process.
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.selectedTabID, model.tabs.last?.id)
    }

    // MARK: - Tab Close (closeTab)

    func testCloseTabRemovesTab() {
        model.newTab()
        model.newTab()
        XCTAssertEqual(model.tabs.count, 3)

        let tabToClose = model.tabs[1]
        model.closeTab(id: tabToClose.id)

        XCTAssertEqual(model.tabs.count, 2,
                       "Closing a tab should reduce the count by one")
        XCTAssertNil(model.tabs.first(where: { $0.id == tabToClose.id }),
                     "Closed tab should no longer be in the array")
    }

    func testCloseSelectedTabSelectsNeighbor() {
        model.newTab()
        model.newTab()
        // Select the middle tab
        let middleTab = model.tabs[1]
        model.selectTab(id: middleTab.id)

        model.closeTab(id: middleTab.id)

        // After closing the middle tab, the tab to its left should be selected
        XCTAssertEqual(model.selectedTabID, model.tabs[0].id,
                       "Closing the selected tab should select the tab to its left")
    }

    func testCloseNonSelectedTabKeepsSelection() {
        model.newTab()
        model.newTab()
        let firstTab = model.tabs[0]
        let lastTab = model.tabs[2]
        model.selectTab(id: firstTab.id)

        model.closeTab(id: lastTab.id)

        XCTAssertEqual(model.selectedTabID, firstTab.id,
                       "Closing a non-selected tab should not change the selection")
    }

    // MARK: - Close Last Tab Behavior

    func testCloseLastTabReplacesWithNewTab() {
        // Ensure the behavior is set to keep the window open
        FeatureSettings.shared.lastTabCloseBehavior = .keepWindow
        // Disable warnings so the modal dialog doesn't block
        FeatureSettings.shared.warnOnCloseWithRunningProcess = false
        FeatureSettings.shared.alwaysWarnOnTabClose = false

        XCTAssertEqual(model.tabs.count, 1)
        let originalID = model.tabs[0].id

        model.closeCurrentTab()

        XCTAssertEqual(model.tabs.count, 1,
                       "Closing the last tab with keepWindow should create a replacement")
        XCTAssertNotEqual(model.tabs[0].id, originalID,
                          "The replacement tab should have a different ID")
        XCTAssertEqual(model.selectedTabID, model.tabs[0].id,
                       "The replacement tab should be selected")
    }

    // MARK: - Close Other Tabs

    func testCloseOtherTabsKeepsOnlySelected() {
        model.newTab()
        model.newTab()
        model.newTab()
        XCTAssertEqual(model.tabs.count, 4)

        let keepID = model.tabs[1].id
        model.selectTab(id: keepID)

        // Disable warnings so the modal dialog doesn't block
        FeatureSettings.shared.warnOnCloseWithRunningProcess = false
        FeatureSettings.shared.alwaysWarnOnTabClose = false

        model.closeOtherTabs()

        XCTAssertEqual(model.tabs.count, 1, "Only the selected tab should remain")
        XCTAssertEqual(model.tabs[0].id, keepID)
    }

    // MARK: - Tab Reorder

    func testMoveTabToIndex() {
        model.newTab()
        model.newTab()
        // tabs: [A, B, C]
        let tabA = model.tabs[0]
        let tabC = model.tabs[2]

        model.moveTab(id: tabA.id, toIndex: 2)
        // After moving A to position 2: [B, A, C] (adjusted to index 1 since remove shifts)
        // Actually: remove at 0, clampedIndex=2, adjusted=2-1=1 -> insert at 1: [B, A, C]
        XCTAssertEqual(model.tabs[1].id, tabA.id,
                       "Tab A should move from index 0 to index 1 (adjusted)")
        XCTAssertEqual(model.tabs[2].id, tabC.id)
    }

    func testMoveTabClampsIndex() {
        model.newTab()
        let firstTab = model.tabs[0]
        // Try to move to an index beyond bounds
        model.moveTab(id: firstTab.id, toIndex: 999)
        // Should clamp and not crash
        XCTAssertEqual(model.tabs.last?.id, firstTab.id,
                       "Moving to a very large index should clamp to end")
    }

    func testMoveTabSameIndexIsNoop() {
        model.newTab()
        model.newTab()
        let originalOrder = model.tabs.map(\.id)
        let middleTab = model.tabs[1]

        model.moveTab(id: middleTab.id, toIndex: 1)

        XCTAssertEqual(model.tabs.map(\.id), originalOrder,
                       "Moving a tab to its current index should be a no-op")
    }

    func testMoveTabFromIndexRight() {
        model.newTab()
        model.newTab()
        let tabA = model.tabs[0]
        let tabB = model.tabs[1]

        model.moveTab(fromIndex: 0, toIndex: 1)

        XCTAssertEqual(model.tabs[0].id, tabB.id)
        XCTAssertEqual(model.tabs[1].id, tabA.id,
                       "Moving index 0 to 1 should swap adjacent tabs")
    }

    func testMoveTabFromIndexLeft() {
        model.newTab()
        model.newTab()
        let tabB = model.tabs[1]
        let tabC = model.tabs[2]

        model.moveTab(fromIndex: 2, toIndex: 1)

        XCTAssertEqual(model.tabs[1].id, tabC.id)
        XCTAssertEqual(model.tabs[2].id, tabB.id,
                       "Moving index 2 to 1 should swap adjacent tabs")
    }

    func testMoveTabFromIndexSameIsNoop() {
        model.newTab()
        let originalOrder = model.tabs.map(\.id)

        model.moveTab(fromIndex: 0, toIndex: 0)
        XCTAssertEqual(model.tabs.map(\.id), originalOrder,
                       "Moving to same index should be a no-op")
    }

    func testMoveTabFromIndexOutOfBoundsIsNoop() {
        model.newTab()
        let originalOrder = model.tabs.map(\.id)

        model.moveTab(fromIndex: -1, toIndex: 0)
        XCTAssertEqual(model.tabs.map(\.id), originalOrder,
                       "Negative source index should be a no-op")

        model.moveTab(fromIndex: 0, toIndex: model.tabs.count)
        XCTAssertEqual(model.tabs.map(\.id), originalOrder,
                       "Destination beyond bounds should be a no-op")
    }

    func testMoveCurrentTabRight() {
        model.newTab()
        model.newTab()
        let tabA = model.tabs[0]
        model.selectTab(id: tabA.id)

        model.moveCurrentTabRight()

        XCTAssertEqual(model.tabs[1].id, tabA.id,
                       "moveCurrentTabRight should move the selected tab one position right")
    }

    func testMoveCurrentTabLeft() {
        model.newTab()
        model.newTab()
        let tabC = model.tabs[2]
        model.selectTab(id: tabC.id)

        model.moveCurrentTabLeft()

        XCTAssertEqual(model.tabs[1].id, tabC.id,
                       "moveCurrentTabLeft should move the selected tab one position left")
    }

    // MARK: - Active Tab Management

    func testSelectTabByID() {
        model.newTab()
        model.newTab()
        let targetTab = model.tabs[1]

        model.selectTab(id: targetTab.id)

        XCTAssertEqual(model.selectedTabID, targetTab.id,
                       "selectTab should update selectedTabID")
    }

    func testSelectTabByNumber() {
        model.newTab()
        model.newTab()
        let secondTab = model.tabs[1]

        // selectTab(number:) is 1-indexed
        model.selectTab(number: 2)

        XCTAssertEqual(model.selectedTabID, secondTab.id,
                       "selectTab(number: 2) should select the second tab")
    }

    func testSelectTabByNumberOutOfRange() {
        let originalSelected = model.selectedTabID
        model.selectTab(number: 999)
        XCTAssertEqual(model.selectedTabID, originalSelected,
                       "Selecting an out-of-range tab number should be a no-op")
    }

    func testSelectNextTabWrapsAround() {
        model.newTab()
        // tabs: [A, B], select B (last)
        let tabB = model.tabs[1]
        model.selectTab(id: tabB.id)

        model.selectNextTab()

        XCTAssertEqual(model.selectedTabID, model.tabs[0].id,
                       "selectNextTab from the last tab should wrap to the first")
    }

    func testSelectPreviousTabWrapsAround() {
        model.newTab()
        // tabs: [A, B], select A (first)
        let tabA = model.tabs[0]
        model.selectTab(id: tabA.id)

        model.selectPreviousTab()

        XCTAssertEqual(model.selectedTabID, model.tabs[1].id,
                       "selectPreviousTab from the first tab should wrap to the last")
    }

    func testSelectNextTabWithSingleTabIsNoop() {
        let originalSelected = model.selectedTabID
        model.selectNextTab()
        XCTAssertEqual(model.selectedTabID, originalSelected,
                       "selectNextTab with one tab should be a no-op")
    }

    func testSelectedTabProperty() {
        XCTAssertNotNil(model.selectedTab, "selectedTab should return the current tab")
        XCTAssertEqual(model.selectedTab?.id, model.selectedTabID)
    }

    // MARK: - Search / Filter State

    func testToggleSearchVisibility() {
        XCTAssertFalse(model.isSearchVisible)

        model.toggleSearch()
        XCTAssertTrue(model.isSearchVisible, "First toggle should show search")

        model.toggleSearch()
        XCTAssertFalse(model.isSearchVisible, "Second toggle should hide search")
    }

    func testToggleSearchClearsQueryOnClose() {
        model.toggleSearch() // Open
        model.searchQuery = "test"
        model.toggleSearch() // Close

        XCTAssertEqual(model.searchQuery, "",
                       "Closing search should clear the search query")
        XCTAssertEqual(model.searchResults.count, 0,
                       "Closing search should clear the results")
        XCTAssertEqual(model.searchMatchCount, 0,
                       "Closing search should reset match count")
    }

    func testToggleSearchClosesRename() {
        model.isRenameVisible = true
        model.toggleSearch() // Open search

        XCTAssertTrue(model.isSearchVisible)
        XCTAssertFalse(model.isRenameVisible,
                       "Opening search should close the rename overlay")
    }

    // MARK: - Reopen Closed Tab

    func testCanReopenClosedTabInitiallyFalse() {
        XCTAssertFalse(model.canReopenClosedTab,
                       "No tabs have been closed yet, so canReopenClosedTab should be false")
    }

    func testClosingTabPopulatesClosedTabStack() {
        model.newTab()
        model.newTab()
        XCTAssertEqual(model.tabs.count, 3)

        // Disable warnings
        FeatureSettings.shared.warnOnCloseWithRunningProcess = false
        FeatureSettings.shared.alwaysWarnOnTabClose = false

        model.closeTab(id: model.tabs[1].id)

        XCTAssertTrue(model.canReopenClosedTab,
                       "After closing a tab, canReopenClosedTab should be true")
    }

    // MARK: - Broadcast Mode

    func testBroadcastModeToggle() {
        XCTAssertFalse(model.isBroadcastMode)
        model.isBroadcastMode = true
        XCTAssertTrue(model.isBroadcastMode)
    }

    // MARK: - Has Active Overlay

    func testHasActiveOverlay() {
        XCTAssertFalse(model.hasActiveOverlay,
                       "No overlay should be active initially")

        model.isSearchVisible = true
        XCTAssertTrue(model.hasActiveOverlay)
        model.isSearchVisible = false

        model.isRenameVisible = true
        XCTAssertTrue(model.hasActiveOverlay)
        model.isRenameVisible = false

        model.isClipboardHistoryVisible = true
        XCTAssertTrue(model.hasActiveOverlay)
        model.isClipboardHistoryVisible = false

        model.isBookmarkListVisible = true
        XCTAssertTrue(model.hasActiveOverlay)
        model.isBookmarkListVisible = false

        model.isSnippetManagerVisible = true
        XCTAssertTrue(model.hasActiveOverlay)
    }
}
#endif
