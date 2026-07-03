import XCTest
@testable import Chau7

/// The extracted tab behavior + tab display + hover card store against an
/// isolated UserDefaults suite.
final class TabDisplaySettingsStoreTests: XCTestCase {

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "TabDisplaySettingsStoreTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testFreshStoreUsesDefaults() {
        let store = TabDisplaySettingsStore(defaults: defaults)
        XCTAssertEqual(store.lastTabCloseBehavior, .keepWindow)
        XCTAssertEqual(store.newTabPosition, "end")
        XCTAssertTrue(store.newTabsUseCurrentDirectory)
        XCTAssertTrue(store.alwaysShowTabBar)
        XCTAssertFalse(store.alwaysShowToolbarInFullscreen)
        XCTAssertTrue(store.warnOnCloseWithRunningProcess)
        XCTAssertFalse(store.alwaysWarnOnTabClose)
        XCTAssertTrue(store.groupIdleTabs)
        XCTAssertEqual(store.idleTabThresholdMinutes, 10)
        XCTAssertEqual(store.tabSwitchShortcutMode, .commandNumber)
        XCTAssertTrue(store.showTabIcons)
        XCTAssertTrue(store.showTabPath)
        // Regression guard: the git indicator defaults to visible.
        XCTAssertTrue(store.showTabGitIndicator)
        XCTAssertTrue(store.showTabCTOIndicator)
        XCTAssertTrue(store.allowTabCTOToggle)
        XCTAssertTrue(store.showTabBroadcastIndicator)
        XCTAssertFalse(store.customTitleOnly)
        XCTAssertTrue(store.hoverCardShowDirectory)
        XCTAssertTrue(store.hoverCardShowGitBranch)
        XCTAssertFalse(store.hoverCardShowShellIntegration)
        XCTAssertTrue(store.hoverCardShowDevServer)
        XCTAssertTrue(store.hoverCardShowLastCommand)
        XCTAssertTrue(store.hoverCardShowAISession)
        XCTAssertTrue(store.hoverCardShowRepoStats)
        XCTAssertTrue(store.hoverCardShowProcesses)
        XCTAssertFalse(store.hoverCardShowTokenOptimization)
        XCTAssertFalse(store.hoverCardShowBroadcast)
        XCTAssertTrue(store.hoverCardShowConflicts)
        XCTAssertTrue(store.hoverCardShowNotificationState)
        XCTAssertTrue(store.hoverCardShowFooter)
    }

    func testMutationsPersistAndReload() {
        let store = TabDisplaySettingsStore(defaults: defaults)
        store.lastTabCloseBehavior = .closeWindow
        store.newTabPosition = "after"
        store.newTabsUseCurrentDirectory = false
        store.alwaysShowTabBar = false
        store.alwaysShowToolbarInFullscreen = true
        store.warnOnCloseWithRunningProcess = false
        store.alwaysWarnOnTabClose = true
        store.groupIdleTabs = false
        store.idleTabThresholdMinutes = 25
        store.tabSwitchShortcutMode = .both
        store.showTabIcons = false
        store.showTabPath = false
        store.showTabGitIndicator = false
        store.showTabCTOIndicator = false
        store.allowTabCTOToggle = false
        store.showTabBroadcastIndicator = false
        store.customTitleOnly = true
        store.hoverCardShowDirectory = false
        store.hoverCardShowShellIntegration = true
        store.hoverCardShowTokenOptimization = true
        store.hoverCardShowFooter = false

        let reloaded = TabDisplaySettingsStore(defaults: defaults)
        XCTAssertEqual(reloaded.lastTabCloseBehavior, .closeWindow)
        XCTAssertEqual(reloaded.newTabPosition, "after")
        XCTAssertFalse(reloaded.newTabsUseCurrentDirectory)
        XCTAssertFalse(reloaded.alwaysShowTabBar)
        XCTAssertTrue(reloaded.alwaysShowToolbarInFullscreen)
        XCTAssertFalse(reloaded.warnOnCloseWithRunningProcess)
        XCTAssertTrue(reloaded.alwaysWarnOnTabClose)
        XCTAssertFalse(reloaded.groupIdleTabs)
        XCTAssertEqual(reloaded.idleTabThresholdMinutes, 25)
        XCTAssertEqual(reloaded.tabSwitchShortcutMode, .both)
        XCTAssertFalse(reloaded.showTabIcons)
        XCTAssertFalse(reloaded.showTabPath)
        XCTAssertFalse(reloaded.showTabGitIndicator)
        XCTAssertFalse(reloaded.showTabCTOIndicator)
        XCTAssertFalse(reloaded.allowTabCTOToggle)
        XCTAssertFalse(reloaded.showTabBroadcastIndicator)
        XCTAssertTrue(reloaded.customTitleOnly)
        XCTAssertFalse(reloaded.hoverCardShowDirectory)
        XCTAssertTrue(reloaded.hoverCardShowShellIntegration)
        XCTAssertTrue(reloaded.hoverCardShowTokenOptimization)
        XCTAssertFalse(reloaded.hoverCardShowFooter)
        // Untouched members keep their loader defaults.
        XCTAssertTrue(reloaded.hoverCardShowGitBranch)
        XCTAssertFalse(reloaded.hoverCardShowBroadcast)
    }

    func testResetToDefaultsMatchesFreshStore() {
        let store = TabDisplaySettingsStore(defaults: defaults)
        store.lastTabCloseBehavior = .closeWindow
        store.newTabPosition = "after"
        store.newTabsUseCurrentDirectory = false
        store.alwaysShowTabBar = false
        store.alwaysShowToolbarInFullscreen = true
        store.warnOnCloseWithRunningProcess = false
        store.alwaysWarnOnTabClose = true
        store.groupIdleTabs = false
        store.idleTabThresholdMinutes = 3
        store.tabSwitchShortcutMode = .functionKey
        store.showTabIcons = false
        store.showTabGitIndicator = false
        store.customTitleOnly = true
        store.hoverCardShowDirectory = false
        store.hoverCardShowShellIntegration = true
        store.hoverCardShowFooter = false

        store.resetToDefaults()

        let fresh = TabDisplaySettingsStore(defaults: defaults)
        XCTAssertEqual(store.lastTabCloseBehavior, fresh.lastTabCloseBehavior)
        XCTAssertEqual(store.newTabPosition, fresh.newTabPosition)
        XCTAssertEqual(store.newTabsUseCurrentDirectory, fresh.newTabsUseCurrentDirectory)
        XCTAssertEqual(store.alwaysShowTabBar, fresh.alwaysShowTabBar)
        XCTAssertEqual(store.alwaysShowToolbarInFullscreen, fresh.alwaysShowToolbarInFullscreen)
        XCTAssertEqual(store.warnOnCloseWithRunningProcess, fresh.warnOnCloseWithRunningProcess)
        XCTAssertEqual(store.alwaysWarnOnTabClose, fresh.alwaysWarnOnTabClose)
        XCTAssertEqual(store.groupIdleTabs, fresh.groupIdleTabs)
        XCTAssertEqual(store.idleTabThresholdMinutes, fresh.idleTabThresholdMinutes)
        XCTAssertEqual(store.tabSwitchShortcutMode, fresh.tabSwitchShortcutMode)
        XCTAssertEqual(store.showTabIcons, fresh.showTabIcons)
        XCTAssertEqual(store.showTabGitIndicator, fresh.showTabGitIndicator)
        XCTAssertTrue(store.showTabGitIndicator)
        XCTAssertEqual(store.customTitleOnly, fresh.customTitleOnly)
        XCTAssertEqual(store.hoverCardShowDirectory, fresh.hoverCardShowDirectory)
        XCTAssertEqual(store.hoverCardShowShellIntegration, fresh.hoverCardShowShellIntegration)
        XCTAssertEqual(store.hoverCardShowFooter, fresh.hoverCardShowFooter)
    }
}
