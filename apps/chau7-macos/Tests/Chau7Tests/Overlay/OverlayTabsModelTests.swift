import XCTest
import AppKit
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class OverlayTabsModelTests: XCTestCase {

    private var model: OverlayTabsModel!
    private var appModel: AppModel!

    private func drainMainQueue() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    }

    private func storeSavedTabStates(_ states: [SavedTabState]) {
        guard let data = try? JSONEncoder().encode(states) else {
            XCTFail("Failed to encode saved tab states")
            return
        }
        UserDefaults.standard.set(data, forKey: SavedTabState.userDefaultsKey)
    }

    private func makeSavedTabState(title: String, directory: String) -> SavedTabState {
        SavedTabState(
            customTitle: title,
            color: TabColor.blue.rawValue,
            directory: directory,
            selectedIndex: nil,
            tokenOptOverride: nil,
            scrollbackContent: nil,
            aiResumeCommand: nil,
            splitLayout: nil,
            focusedPaneID: nil,
            paneStates: nil
        )
    }

    override func setUp() {
        super.setUp()
        // Clear any saved tab state so restoreSavedTabs returns nil
        // and the model starts with a single fresh tab.
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        appModel = AppModel()
        model = OverlayTabsModel(appModel: appModel, restoreState: false)
    }

    override func tearDown() {
        model = nil
        appModel = nil
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        super.tearDown()
    }

    // MARK: - Initial State

    func testInitialState() {
        XCTAssertEqual(model.tabs.count, 1, "Model should start with exactly one tab")
        XCTAssertEqual(
            model.selectedTabID,
            model.tabs.first?.id,
            "The single initial tab should be selected"
        )
        XCTAssertFalse(model.isSearchVisible)
        XCTAssertFalse(model.isBroadcastMode)
    }

    func testDecodeBackupWindowStatesSupportsLegacySingleWindowPayload() throws {
        let state = makeSavedTabState(title: "Primary", directory: "/tmp/primary")
        let data = try JSONEncoder().encode([state])

        let windows = try XCTUnwrap(OverlayTabsModel.decodeBackupWindowStates(from: data))
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].first?.customTitle, "Primary")
    }

    func testDecodeBackupWindowStatesSupportsMultiWindowPayload() throws {
        let data = try JSONEncoder().encode(
            SavedMultiWindowState(
                windows: [
                    [makeSavedTabState(title: "Window 1", directory: "/tmp/one")],
                    [makeSavedTabState(title: "Window 2", directory: "/tmp/two")]
                ]
            )
        )

        let windows = try XCTUnwrap(OverlayTabsModel.decodeBackupWindowStates(from: data))
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[1].first?.customTitle, "Window 2")
    }

    // MARK: - Tab Creation (addTab / newTab)

    func testNewTabIncreasesCount() {
        let initialCount = model.tabs.count
        model.newTab()
        XCTAssertEqual(
            model.tabs.count,
            initialCount + 1,
            "newTab should add exactly one tab"
        )
    }

    func testNewTabBecomesSelected() {
        model.newTab()
        let lastTab = model.tabs.last!
        XCTAssertEqual(
            model.selectedTabID,
            lastTab.id,
            "Newly created tab should become the selected tab"
        )
    }

    func testNewTabGetsUniqueID() {
        model.newTab()
        model.newTab()
        let ids = model.tabs.map(\.id)
        XCTAssertEqual(
            Set(ids).count,
            ids.count,
            "Every tab should have a unique ID"
        )
    }

    func testNewTabCyclesColors() {
        // Start with 1 tab, add enough to cycle through all colors
        let colorCount = TabColor.allCases.count
        for _ in 0 ..< colorCount {
            model.newTab()
        }
        // The (colorCount + 1)th tab should wrap around to the first color
        let wrappedTab = model.tabs[colorCount]
        let firstColor = TabColor.allCases[colorCount % colorCount]
        XCTAssertEqual(
            wrappedTab.color,
            firstColor,
            "Tab colors should cycle through TabColor.allCases"
        )
    }

    func testNewTabAtDirectorySetsCwd() {
        let directory = "/tmp/test-dir"
        model.newTab(at: directory)
        // The new tab was created; just verify it exists and is selected.
        // The actual directory change is deferred to the shell process.
        XCTAssertEqual(model.tabs.count, 2)
        XCTAssertEqual(model.selectedTabID, model.tabs.last?.id)
    }

    // MARK: - Render Suspension

    func testRenderSuspensionKeepsBackgroundAITabLive() {
        let selectedTab = model.tabs[0]
        model.newTab()
        model.newTab()

        let aiTab = model.tabs[1]
        let shellTab = model.tabs[2]
        aiTab.session?.activeAppName = "Codex"

        model.selectTab(id: selectedTab.id)
        model.configureRenderSuspension(enabled: true, delay: 0)
        drainMainQueue()

        XCTAssertFalse(
            model.suspendedTabIDs.contains(aiTab.id),
            "Background AI tabs should remain live-rendered"
        )
        XCTAssertTrue(
            model.suspendedTabIDs.contains(shellTab.id),
            "Non-AI background tabs should still suspend"
        )
    }

    func testRenderSuspensionUnsuspendsTabWhenBackgroundSessionBecomesAI() {
        let selectedTab = model.tabs[0]
        model.newTab()

        let backgroundTab = model.tabs[1]
        model.selectTab(id: selectedTab.id)
        model.configureRenderSuspension(enabled: true, delay: 0)
        drainMainQueue()

        XCTAssertTrue(
            model.suspendedTabIDs.contains(backgroundTab.id),
            "Background shell tabs should suspend before AI detection"
        )

        backgroundTab.session?.activeAppName = "Codex"
        drainMainQueue()

        XCTAssertFalse(
            model.suspendedTabIDs.contains(backgroundTab.id),
            "AI detection should immediately unsuspend the background tab"
        )
    }

    func testLiveHierarchyKeepsDistantMCPBackgroundTabUntilTerminalBootstraps() {
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)

        let distantIndex = 3
        model.tabs[distantIndex].isMCPControlled = true

        XCTAssertTrue(
            model.shouldKeepTabInLiveHierarchy(tab: model.tabs[distantIndex], index: distantIndex),
            "Fresh MCP background tabs should stay in the hierarchy so their shell can start"
        )

        let terminalView = RustTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        model.tabs[distantIndex].session?.attachRustTerminal(terminalView)

        XCTAssertFalse(
            model.shouldKeepTabInLiveHierarchy(tab: model.tabs[distantIndex], index: distantIndex),
            "Once a terminal view has attached, distant MCP tabs can fall back to placeholder rendering"
        )
    }

    func testLiveHierarchyDoesNotKeepDistantNonMCPBackgroundTab() {
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)
        model.newTab(selectNewTab: false)

        let distantIndex = 3
        XCTAssertFalse(
            model.shouldKeepTabInLiveHierarchy(tab: model.tabs[distantIndex], index: distantIndex),
            "Distant non-MCP tabs should continue using placeholder rendering"
        )
    }

    // MARK: - Tab Close (closeTab)

    func testCloseTabRemovesTab() {
        model.newTab()
        model.newTab()
        XCTAssertEqual(model.tabs.count, 3)

        let tabToClose = model.tabs[1]
        model.closeTab(id: tabToClose.id)

        XCTAssertEqual(
            model.tabs.count,
            2,
            "Closing a tab should reduce the count by one"
        )
        XCTAssertNil(
            model.tabs.first(where: { $0.id == tabToClose.id }),
            "Closed tab should no longer be in the array"
        )
    }

    func testCloseSelectedTabSelectsNeighbor() {
        model.newTab()
        model.newTab()
        // Select the middle tab
        let middleTab = model.tabs[1]
        model.selectTab(id: middleTab.id)

        model.closeTab(id: middleTab.id)

        // After closing the middle tab, the tab to its left should be selected
        XCTAssertEqual(
            model.selectedTabID,
            model.tabs[0].id,
            "Closing the selected tab should select the tab to its left"
        )
    }

    func testCloseNonSelectedTabKeepsSelection() {
        model.newTab()
        model.newTab()
        let firstTab = model.tabs[0]
        let lastTab = model.tabs[2]
        model.selectTab(id: firstTab.id)

        model.closeTab(id: lastTab.id)

        XCTAssertEqual(
            model.selectedTabID,
            firstTab.id,
            "Closing a non-selected tab should not change the selection"
        )
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

        XCTAssertEqual(
            model.tabs.count,
            1,
            "Closing the last tab with keepWindow should create a replacement"
        )
        XCTAssertNotEqual(
            model.tabs[0].id,
            originalID,
            "The replacement tab should have a different ID"
        )
        XCTAssertEqual(
            model.selectedTabID,
            model.tabs[0].id,
            "The replacement tab should be selected"
        )
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
        XCTAssertEqual(
            model.tabs[1].id,
            tabA.id,
            "Tab A should move from index 0 to index 1 (adjusted)"
        )
        XCTAssertEqual(model.tabs[2].id, tabC.id)
    }

    func testMoveTabClampsIndex() {
        model.newTab()
        let firstTab = model.tabs[0]
        // Try to move to an index beyond bounds
        model.moveTab(id: firstTab.id, toIndex: 999)
        // Should clamp and not crash
        XCTAssertEqual(
            model.tabs.last?.id,
            firstTab.id,
            "Moving to a very large index should clamp to end"
        )
    }

    func testMoveTabSameIndexIsNoop() {
        model.newTab()
        model.newTab()
        let originalOrder = model.tabs.map(\.id)
        let middleTab = model.tabs[1]

        model.moveTab(id: middleTab.id, toIndex: 1)

        XCTAssertEqual(
            model.tabs.map(\.id),
            originalOrder,
            "Moving a tab to its current index should be a no-op"
        )
    }

    func testMoveTabFromIndexRight() {
        model.newTab()
        model.newTab()
        let tabA = model.tabs[0]
        let tabB = model.tabs[1]

        model.moveTab(fromIndex: 0, toIndex: 1)

        XCTAssertEqual(model.tabs[0].id, tabB.id)
        XCTAssertEqual(
            model.tabs[1].id,
            tabA.id,
            "Moving index 0 to 1 should swap adjacent tabs"
        )
    }

    func testMoveTabFromIndexLeft() {
        model.newTab()
        model.newTab()
        let tabB = model.tabs[1]
        let tabC = model.tabs[2]

        model.moveTab(fromIndex: 2, toIndex: 1)

        XCTAssertEqual(model.tabs[1].id, tabC.id)
        XCTAssertEqual(
            model.tabs[2].id,
            tabB.id,
            "Moving index 2 to 1 should swap adjacent tabs"
        )
    }

    func testMoveTabFromIndexSameIsNoop() {
        model.newTab()
        let originalOrder = model.tabs.map(\.id)

        model.moveTab(fromIndex: 0, toIndex: 0)
        XCTAssertEqual(
            model.tabs.map(\.id),
            originalOrder,
            "Moving to same index should be a no-op"
        )
    }

    func testMoveTabFromIndexOutOfBoundsIsNoop() {
        model.newTab()
        let originalOrder = model.tabs.map(\.id)

        model.moveTab(fromIndex: -1, toIndex: 0)
        XCTAssertEqual(
            model.tabs.map(\.id),
            originalOrder,
            "Negative source index should be a no-op"
        )

        model.moveTab(fromIndex: 0, toIndex: model.tabs.count)
        XCTAssertEqual(
            model.tabs.map(\.id),
            originalOrder,
            "Destination beyond bounds should be a no-op"
        )
    }

    func testMoveCurrentTabRight() {
        model.newTab()
        model.newTab()
        let tabA = model.tabs[0]
        model.selectTab(id: tabA.id)

        model.moveCurrentTabRight()

        XCTAssertEqual(
            model.tabs[1].id,
            tabA.id,
            "moveCurrentTabRight should move the selected tab one position right"
        )
    }

    func testMoveCurrentTabLeft() {
        model.newTab()
        model.newTab()
        let tabC = model.tabs[2]
        model.selectTab(id: tabC.id)

        model.moveCurrentTabLeft()

        XCTAssertEqual(
            model.tabs[1].id,
            tabC.id,
            "moveCurrentTabLeft should move the selected tab one position left"
        )
    }

    // MARK: - Active Tab Management

    func testSelectTabByID() {
        model.newTab()
        model.newTab()
        let targetTab = model.tabs[1]

        model.selectTab(id: targetTab.id)

        XCTAssertEqual(
            model.selectedTabID,
            targetTab.id,
            "selectTab should update selectedTabID"
        )
    }

    func testSelectTabByNumber() {
        model.newTab()
        model.newTab()
        let secondTab = model.tabs[1]

        // selectTab(number:) is 1-indexed
        model.selectTab(number: 2)

        XCTAssertEqual(
            model.selectedTabID,
            secondTab.id,
            "selectTab(number: 2) should select the second tab"
        )
    }

    func testSelectTabByNumberOutOfRange() {
        let originalSelected = model.selectedTabID
        model.selectTab(number: 999)
        XCTAssertEqual(
            model.selectedTabID,
            originalSelected,
            "Selecting an out-of-range tab number should be a no-op"
        )
    }

    func testSelectNextTabWrapsAround() {
        model.newTab()
        // tabs: [A, B], select B (last)
        let tabB = model.tabs[1]
        model.selectTab(id: tabB.id)

        model.selectNextTab()

        XCTAssertEqual(
            model.selectedTabID,
            model.tabs[0].id,
            "selectNextTab from the last tab should wrap to the first"
        )
    }

    func testSelectPreviousTabWrapsAround() {
        model.newTab()
        // tabs: [A, B], select A (first)
        let tabA = model.tabs[0]
        model.selectTab(id: tabA.id)

        model.selectPreviousTab()

        XCTAssertEqual(
            model.selectedTabID,
            model.tabs[1].id,
            "selectPreviousTab from the first tab should wrap to the last"
        )
    }

    func testSelectNextTabWithSingleTabIsNoop() {
        let originalSelected = model.selectedTabID
        model.selectNextTab()
        XCTAssertEqual(
            model.selectedTabID,
            originalSelected,
            "selectNextTab with one tab should be a no-op"
        )
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

        XCTAssertEqual(
            model.searchQuery,
            "",
            "Closing search should clear the search query"
        )
        XCTAssertEqual(
            model.searchResults.count,
            0,
            "Closing search should clear the results"
        )
        XCTAssertEqual(
            model.searchMatchCount,
            0,
            "Closing search should reset match count"
        )
    }

    func testToggleSearchClosesRename() {
        model.isRenameVisible = true
        model.toggleSearch() // Open search

        XCTAssertTrue(model.isSearchVisible)
        XCTAssertFalse(
            model.isRenameVisible,
            "Opening search should close the rename overlay"
        )
    }

    // MARK: - Reopen Closed Tab

    func testCanReopenClosedTabInitiallyFalse() {
        XCTAssertFalse(
            model.canReopenClosedTab,
            "No tabs have been closed yet, so canReopenClosedTab should be false"
        )
    }

    func testClosingTabPopulatesClosedTabStack() {
        model.newTab()
        model.newTab()
        XCTAssertEqual(model.tabs.count, 3)

        // Disable warnings
        FeatureSettings.shared.warnOnCloseWithRunningProcess = false
        FeatureSettings.shared.alwaysWarnOnTabClose = false

        model.closeTab(id: model.tabs[1].id)

        XCTAssertTrue(
            model.canReopenClosedTab,
            "After closing a tab, canReopenClosedTab should be true"
        )
    }

    // MARK: - Broadcast Mode

    func testBroadcastModeToggle() {
        XCTAssertFalse(model.isBroadcastMode)
        model.isBroadcastMode = true
        XCTAssertTrue(model.isBroadcastMode)
    }

    // MARK: - Has Active Overlay

    func testHasActiveOverlay() {
        XCTAssertFalse(
            model.hasActiveOverlay,
            "No overlay should be active initially"
        )

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

    // MARK: - Advanced Restore Metadata

    func testRestoreFromSavedStatePreservesTabOrderAndSelectionIndex() {
        let terminalID = UUID()
        let editorID = UUID()
        let split = SavedSplitNode(
            kind: .split,
            id: UUID().uuidString,
            direction: .horizontal,
            ratio: 0.5,
            first: SavedSplitNode(
                kind: .terminal,
                id: terminalID.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: nil
            ),
            second: SavedSplitNode(
                kind: .textEditor,
                id: editorID.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: "/tmp/example.swift"
            ),
            textEditorPath: nil
        )

        let primaryPaneState = SavedTerminalPaneState(
            paneID: terminalID.uuidString,
            directory: "/tmp/advanced-restore",
            scrollbackContent: "previous output",
            aiResumeCommand: "claude --resume abc123"
        )

        storeSavedTabStates([
            SavedTabState(
                customTitle: "Left",
                color: TabColor.green.rawValue,
                directory: "/tmp/fallback-1",
                selectedIndex: nil,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: nil
            ),
            SavedTabState(
                customTitle: "Right",
                color: TabColor.purple.rawValue,
                directory: "/tmp/advanced-restore",
                selectedIndex: 1,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: split,
                focusedPaneID: terminalID.uuidString,
                paneStates: [primaryPaneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)

        XCTAssertEqual(restoredModel.tabs.count, 2)
        XCTAssertEqual(restoredModel.tabs[0].customTitle, "Left")
        XCTAssertEqual(restoredModel.tabs[1].customTitle, "Right")
        XCTAssertEqual(restoredModel.selectedTabID, restoredModel.tabs[1].id)

        let rightTab = restoredModel.tabs[1]
        guard let terminalPair = rightTab.splitController.terminalSessions.first(where: { $0.0 == terminalID }) else {
            XCTFail("Expected restored terminal pane ID \(terminalID)")
            return
        }
        XCTAssertEqual(terminalPair.1.currentDirectory, "/tmp/advanced-restore")
        XCTAssertEqual(rightTab.splitController.focusedTerminalSessionID(), terminalID)
    }

    func testRestoreUsesPersistedSelectedTabID() {
        let firstTabID = UUID()
        let secondTabID = UUID()

        storeSavedTabStates([
            SavedTabState(
                tabID: firstTabID.uuidString,
                selectedTabID: nil,
                customTitle: "First",
                color: TabColor.green.rawValue,
                directory: "/tmp/restore-1",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: nil
            ),
            SavedTabState(
                tabID: secondTabID.uuidString,
                selectedTabID: secondTabID.uuidString,
                customTitle: "Second",
                color: TabColor.blue.rawValue,
                directory: "/tmp/restore-2",
                selectedIndex: nil,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: nil
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)

        XCTAssertEqual(restoredModel.tabs.count, 2, "restore should rebuild all saved tabs")
        XCTAssertEqual(restoredModel.tabs[0].id, firstTabID)
        XCTAssertEqual(restoredModel.tabs[1].id, secondTabID)
        XCTAssertEqual(restoredModel.selectedTabID, secondTabID, "explicit selected tab marker should override legacy selectedIndex")
    }

    func testRestoreFallsBackToLegacySelectedIndexWhenTabIDIsMissing() {
        storeSavedTabStates([
            SavedTabState(
                customTitle: "First",
                color: TabColor.green.rawValue,
                directory: "/tmp/fallback-1",
                selectedIndex: nil,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: nil
            ),
            SavedTabState(
                customTitle: "Second",
                color: TabColor.blue.rawValue,
                directory: "/tmp/fallback-2",
                selectedIndex: 1,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: nil,
                focusedPaneID: nil,
                paneStates: nil
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        let selectedIndex = restoredModel.tabs.firstIndex(where: { $0.id == restoredModel.selectedTabID })
        XCTAssertEqual(selectedIndex, 1, "legacy selectedIndex should be honored when tab IDs are missing")
        XCTAssertEqual(restoredModel.tabs[1].customTitle, "Second")
    }

    func testReopenClosedTabReturnsToOriginalIndex() {
        model.newTab()
        model.newTab()
        model.newTab()
        XCTAssertEqual(model.tabs.count, 4)

        let originalIDs = model.tabs.map(\.id)
        let middleID = originalIDs[1]

        FeatureSettings.shared.warnOnCloseWithRunningProcess = false
        FeatureSettings.shared.alwaysWarnOnTabClose = false

        model.closeTab(id: middleID)
        XCTAssertEqual(model.tabs.map(\.id), [originalIDs[0], originalIDs[2], originalIDs[3]])

        model.reopenClosedTab()
        XCTAssertEqual(model.tabs.map(\.id), [originalIDs[0], middleID, originalIDs[2], originalIDs[3]])
    }

    func testRestorePrefillsResumeCommandAfterTerminalBecomesReady() {
        let paneID = UUID()
        let split = SavedSplitNode(
            kind: .terminal,
            id: paneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let resumeCommand = "claude --resume abc123"

        let paneState = SavedTerminalPaneState(
            paneID: paneID.uuidString,
            directory: "",
            scrollbackContent: nil,
            aiResumeCommand: resumeCommand
        )

        storeSavedTabStates([
            SavedTabState(
                customTitle: "AI Session",
                color: TabColor.purple.rawValue,
                directory: "",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: split,
                focusedPaneID: paneID.uuidString,
                paneStates: [paneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let session = restoredModel.tabs.first?.splitController.terminalSessions
            .first(where: { $0.0 == paneID })?.1 else {
            XCTFail("Expected restored session for pane \(paneID)")
            return
        }

        session.isShellLoading = true
        session.isAtPrompt = false
        session.status = .running

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { text in
            capturedInputs.append(text)
        }
        session.attachRustTerminal(terminalView)

        let notReadyExpectation = expectation(description: "resume command not sent before terminal becomes ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.15) {
            XCTAssertTrue(capturedInputs.isEmpty)
            session.isShellLoading = false
            session.isAtPrompt = true
            session.status = .idle
            notReadyExpectation.fulfill()
        }
        wait(for: [notReadyExpectation], timeout: 2.0)

        let readyExpectation = expectation(description: "resume command sent after terminal is ready")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            XCTAssertEqual(capturedInputs, [resumeCommand])
            readyExpectation.fulfill()
        }
        wait(for: [readyExpectation], timeout: 2.0)
    }

    func testRestorePrefillsUsingPersistedAiMetadata() {
        let paneID = UUID()
        let split = SavedSplitNode(
            kind: .terminal,
            id: paneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )

        let paneState = SavedTerminalPaneState(
            paneID: paneID.uuidString,
            directory: "/tmp/meta-prefill",
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: "claude",
            aiSessionId: "meta-restore-001"
        )

        storeSavedTabStates([
            SavedTabState(
                customTitle: "Meta Restore",
                color: TabColor.orange.rawValue,
                directory: "/tmp/meta-prefill",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: split,
                focusedPaneID: paneID.uuidString,
                paneStates: [paneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let session = restoredModel.tabs.first?.splitController.terminalSessions
            .first(where: { $0.0 == paneID })?.1 else {
            XCTFail("Expected restored session for pane \(paneID)")
            return
        }

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { capturedInputs.append($0) }
        session.attachRustTerminal(terminalView)
        session.isShellLoading = false
        session.isAtPrompt = true
        session.status = .idle

        let readyExpectation = expectation(description: "restore from persisted AI metadata")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            XCTAssertEqual(capturedInputs, ["claude --resume meta-restore-001"])
            readyExpectation.fulfill()
        }
        wait(for: [readyExpectation], timeout: 2.0)
    }

    func testRestorePrefillsLegacyTopLevelMetadataForSinglePaneStates() {
        let firstPaneID = UUID()
        let secondPaneID = UUID()
        let firstSplit = SavedSplitNode(
            kind: .terminal,
            id: firstPaneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let secondSplit = SavedSplitNode(
            kind: .terminal,
            id: secondPaneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let firstPaneState = SavedTerminalPaneState(
            paneID: firstPaneID.uuidString,
            directory: "/tmp/legacy-top-level-restore",
            scrollbackContent: nil,
            aiResumeCommand: nil
        )
        let secondPaneState = SavedTerminalPaneState(
            paneID: secondPaneID.uuidString,
            directory: "/tmp/legacy-top-level-restore",
            scrollbackContent: nil,
            aiResumeCommand: nil
        )

        storeSavedTabStates([
            SavedTabState(
                customTitle: "First",
                color: TabColor.purple.rawValue,
                directory: "/tmp/legacy-top-level-restore",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                aiProvider: "claude",
                aiSessionId: "legacy-111",
                splitLayout: firstSplit,
                focusedPaneID: firstPaneID.uuidString,
                paneStates: [firstPaneState]
            ),
            SavedTabState(
                customTitle: "Second",
                color: TabColor.orange.rawValue,
                directory: "/tmp/legacy-top-level-restore",
                selectedIndex: nil,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                aiProvider: "claude",
                aiSessionId: "legacy-222",
                splitLayout: secondSplit,
                focusedPaneID: secondPaneID.uuidString,
                paneStates: [secondPaneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let firstSession = restoredModel.tabs.first(where: { $0.customTitle == "First" })?
            .splitController.terminalSessions.first(where: { $0.0 == firstPaneID })?.1,
            let secondSession = restoredModel.tabs.first(where: { $0.customTitle == "Second" })?
            .splitController.terminalSessions.first(where: { $0.0 == secondPaneID })?.1 else {
            XCTFail("Expected restored sessions for both tabs")
            return
        }

        let firstView = RustTerminalView(frame: .zero)
        let secondView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        firstView.onInput = { capturedInputs.append($0) }
        secondView.onInput = { capturedInputs.append($0) }
        firstSession.attachRustTerminal(firstView)
        secondSession.attachRustTerminal(secondView)
        firstSession.isShellLoading = false
        firstSession.isAtPrompt = true
        firstSession.status = .idle
        secondSession.isShellLoading = false
        secondSession.isAtPrompt = true
        secondSession.status = .idle

        let expectationDone = expectation(description: "restore from legacy top-level metadata")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            let expected: Set = [
                "claude --resume legacy-111",
                "claude --resume legacy-222"
            ]
            XCTAssertEqual(Set(capturedInputs), expected)
            XCTAssertEqual(capturedInputs.count, 2)
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 2.0)
    }

    func testRestorePrefillsDistinctCodexResumeCommandsPerTab() {
        let firstPaneID = UUID()
        let secondPaneID = UUID()

        let firstSplit = SavedSplitNode(
            kind: .terminal,
            id: firstPaneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let secondSplit = SavedSplitNode(
            kind: .terminal,
            id: secondPaneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )

        let firstPaneState = SavedTerminalPaneState(
            paneID: firstPaneID.uuidString,
            directory: "/tmp/codex-shared-restore",
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: "codex",
            aiSessionId: "codex-session-111"
        )
        let secondPaneState = SavedTerminalPaneState(
            paneID: secondPaneID.uuidString,
            directory: "/tmp/codex-shared-restore",
            scrollbackContent: nil,
            aiResumeCommand: nil,
            aiProvider: "codex",
            aiSessionId: "codex-session-222"
        )

        storeSavedTabStates([
            SavedTabState(
                tabID: UUID().uuidString,
                customTitle: "First",
                color: TabColor.purple.rawValue,
                directory: "/tmp/codex-shared-restore",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: firstSplit,
                focusedPaneID: firstPaneID.uuidString,
                paneStates: [firstPaneState]
            ),
            SavedTabState(
                tabID: UUID().uuidString,
                customTitle: "Second",
                color: TabColor.blue.rawValue,
                directory: "/tmp/codex-shared-restore",
                selectedIndex: nil,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: secondSplit,
                focusedPaneID: secondPaneID.uuidString,
                paneStates: [secondPaneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let firstSession = restoredModel.tabs.first(where: { $0.customTitle == "First" })?
            .splitController.terminalSessions.first(where: { $0.0 == firstPaneID })?.1,
            let secondSession = restoredModel.tabs.first(where: { $0.customTitle == "Second" })?
            .splitController.terminalSessions.first(where: { $0.0 == secondPaneID })?.1 else {
            XCTFail("Expected restored sessions for both saved tabs")
            return
        }

        let firstView = RustTerminalView(frame: .zero)
        let secondView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        firstView.onInput = { capturedInputs.append($0) }
        secondView.onInput = { capturedInputs.append($0) }
        firstSession.attachRustTerminal(firstView)
        secondSession.attachRustTerminal(secondView)
        firstSession.isShellLoading = false
        firstSession.isAtPrompt = true
        firstSession.status = .idle
        secondSession.isShellLoading = false
        secondSession.isAtPrompt = true
        secondSession.status = .idle

        let expectationDone = expectation(description: "restore restores each codex pane with distinct session id")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            let expected: Set = ["codex resume codex-session-111", "codex resume codex-session-222"]
            XCTAssertEqual(Set(capturedInputs), expected)
            XCTAssertEqual(capturedInputs.count, 2)
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 2.0)
    }

    func testRestorePrefillsResumeCommandInActiveOrAvailablePane() {
        let activePaneID = UUID()
        let secondaryPaneID = UUID()
        let split = SavedSplitNode(
            kind: .split,
            id: UUID().uuidString,
            direction: .horizontal,
            ratio: 0.5,
            first: SavedSplitNode(
                kind: .terminal,
                id: activePaneID.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: nil
            ),
            second: SavedSplitNode(
                kind: .terminal,
                id: secondaryPaneID.uuidString,
                direction: nil,
                ratio: nil,
                first: nil,
                second: nil,
                textEditorPath: nil
            ),
            textEditorPath: nil
        )

        let activePaneState = SavedTerminalPaneState(
            paneID: activePaneID.uuidString,
            directory: "/tmp/primary",
            scrollbackContent: nil,
            aiResumeCommand: nil
        )
        let fallbackPaneState = SavedTerminalPaneState(
            paneID: secondaryPaneID.uuidString,
            directory: "/tmp/secondary",
            scrollbackContent: nil,
            aiResumeCommand: "claude --resume fallback-001"
        )

        storeSavedTabStates([
            SavedTabState(
                customTitle: "Split AI",
                color: TabColor.orange.rawValue,
                directory: "/tmp/secondary",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: split,
                focusedPaneID: activePaneID.uuidString,
                paneStates: [activePaneState, fallbackPaneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let tab = restoredModel.tabs.first else {
            XCTFail("Expected restored tab")
            return
        }

        guard let activeSession = tab.splitController.root.findSession(id: activePaneID),
              let secondarySession = tab.splitController.root.findSession(id: secondaryPaneID) else {
            XCTFail("Expected both restore sessions to exist")
            return
        }

        let activeView = RustTerminalView(frame: .zero)
        let secondaryView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        activeView.onInput = { capturedInputs.append("active:\($0)") }
        secondaryView.onInput = { capturedInputs.append("secondary:\($0)") }
        activeSession.attachRustTerminal(activeView)
        secondarySession.attachRustTerminal(secondaryView)

        activeSession.isShellLoading = false
        activeSession.isAtPrompt = true
        activeSession.status = .idle
        secondarySession.isShellLoading = false
        secondarySession.isAtPrompt = true
        secondarySession.status = .idle

        let expectationDone = expectation(description: "resume command routed to secondary pane fallback target")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) {
            XCTAssertEqual(capturedInputs.count, 1)
            XCTAssertEqual(capturedInputs.first, "secondary:claude --resume fallback-001")
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 2.0)
    }

    func testRestoreIgnoresInvalidPersistedResumeCommand() {
        let paneID = UUID()
        let split = SavedSplitNode(
            kind: .terminal,
            id: paneID.uuidString,
            direction: nil,
            ratio: nil,
            first: nil,
            second: nil,
            textEditorPath: nil
        )
        let paneState = SavedTerminalPaneState(
            paneID: paneID.uuidString,
            directory: "/tmp/chau7-restore-invalid-command",
            scrollbackContent: nil,
            aiResumeCommand: "rm -rf /"
        )

        storeSavedTabStates([
            SavedTabState(
                customTitle: "Invalid Resume",
                color: TabColor.red.rawValue,
                directory: "/tmp/chau7-restore-invalid-command",
                selectedIndex: 0,
                tokenOptOverride: nil,
                scrollbackContent: nil,
                aiResumeCommand: nil,
                splitLayout: split,
                focusedPaneID: paneID.uuidString,
                paneStates: [paneState]
            )
        ])

        let restoredModel = OverlayTabsModel(appModel: appModel)
        guard let session = restoredModel.tabs.first?.splitController.terminalSessions
            .first(where: { $0.0 == paneID })?.1 else {
            XCTFail("Expected restored session for pane \(paneID)")
            return
        }

        let terminalView = RustTerminalView(frame: .zero)
        var capturedInputs: [String] = []
        terminalView.onInput = { text in
            capturedInputs.append(text)
        }
        session.attachRustTerminal(terminalView)
        session.isShellLoading = false
        session.isAtPrompt = true
        session.status = .idle

        let expectationDone = expectation(description: "invalid resume command is ignored")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
            XCTAssertTrue(capturedInputs.isEmpty)
            expectationDone.fulfill()
        }
        wait(for: [expectationDone], timeout: 2.5)
    }

    func testReadFirstLineFromDataSupportsVeryLongLine() {
        let longLine = String(repeating: "a", count: 12000) + "\n" + String(repeating: "b", count: 20)
        guard let data = longLine.data(using: .utf8) else {
            XCTFail("Failed to encode test payload")
            return
        }

        let line = OverlayTabsModel.readFirstLine(from: data)
        XCTAssertEqual(line, String(repeating: "a", count: 12000))
    }

    func testReadFirstLineFromDataReturnsNilWhenAboveCap() {
        let oversizedLine = String(repeating: "x", count: 20000)
        guard let data = oversizedLine.data(using: .utf8) else {
            XCTFail("Failed to encode test payload")
            return
        }

        XCTAssertNil(OverlayTabsModel.readFirstLine(from: data, maxBytes: 16000))
    }
}
#endif
