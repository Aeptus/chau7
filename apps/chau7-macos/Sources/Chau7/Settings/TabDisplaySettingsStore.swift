import Foundation

/// Owns the tab behavior + tab display + hover card settings domain: tab
/// close/creation behavior, tab bar visibility, close warnings, idle-tab
/// grouping, tab switch shortcuts, per-tab indicator visibility, and hover
/// card section toggles.
///
/// Extracted from `FeatureSettings` (which forwards) following the
/// store-behind-facade pattern of the other settings domains.
@Observable
final class TabDisplaySettingsStore {

    enum Keys {
        // Tab Behavior
        static let lastTabCloseBehavior = "tabs.lastTabCloseBehavior"
        static let newTabPosition = "tabs.newTabPosition"
        static let newTabsUseCurrentDirectory = "tabs.newTabsUseCurrentDirectory"
        static let alwaysShowTabBar = "tabs.alwaysShowTabBar"
        static let alwaysShowToolbarInFullscreen = "tabs.alwaysShowToolbarInFullscreen"
        static let warnOnCloseWithProcess = "tabs.warnOnCloseWithProcess"
        static let alwaysWarnOnTabClose = "tabs.alwaysWarnOnTabClose"
        static let groupIdleTabs = "tabs.groupIdleTabs"
        static let idleTabThresholdMinutes = "tabs.idleTabThresholdMinutes"
        static let tabSwitchShortcutMode = "tabs.tabSwitchShortcutMode"
        // Tab Display
        static let showTabIcons = "tabs.display.showIcons"
        static let showTabPath = "tabs.display.showPath"
        static let showTabGitIndicator = "tabs.display.showGitIndicator"
        static let showTabCTOIndicator = "tabs.display.showCTOIndicator"
        static let allowTabCTOToggle = "tabs.display.allowCTOToggle"
        static let showTabBroadcastIndicator = "tabs.display.showBroadcastIndicator"
        static let customTitleOnly = "tabs.display.customTitleOnly"
        // Hover Card Sections
        static let hoverCardShowDirectory = "hoverCard.showDirectory"
        static let hoverCardShowGitBranch = "hoverCard.showGitBranch"
        static let hoverCardShowShellIntegration = "hoverCard.showShellIntegration"
        static let hoverCardShowDevServer = "hoverCard.showDevServer"
        static let hoverCardShowLastCommand = "hoverCard.showLastCommand"
        static let hoverCardShowAISession = "hoverCard.showAISession"
        static let hoverCardShowRepoStats = "hoverCard.showRepoStats"
        static let hoverCardShowProcesses = "hoverCard.showProcesses"
        static let hoverCardShowTokenOptimization = "hoverCard.showTokenOptimization"
        static let hoverCardShowBroadcast = "hoverCard.showBroadcast"
        static let hoverCardShowConflicts = "hoverCard.showConflicts"
        static let hoverCardShowNotificationState = "hoverCard.showNotificationState"
        static let hoverCardShowFooter = "hoverCard.showFooter"
    }

    @ObservationIgnored private let defaults: UserDefaults

    // MARK: - Tab Behavior

    var lastTabCloseBehavior: LastTabCloseBehavior {
        didSet { defaults.set(lastTabCloseBehavior.rawValue, forKey: Keys.lastTabCloseBehavior) }
    }

    /// Where to insert new tabs: "end" or "after" (after current tab)
    var newTabPosition: String {
        didSet { defaults.set(newTabPosition, forKey: Keys.newTabPosition) }
    }

    /// When enabled, new tabs inherit the current tab's directory.
    var newTabsUseCurrentDirectory: Bool {
        didSet { defaults.set(newTabsUseCurrentDirectory, forKey: Keys.newTabsUseCurrentDirectory) }
    }

    var alwaysShowTabBar: Bool {
        didSet { defaults.set(alwaysShowTabBar, forKey: Keys.alwaysShowTabBar) }
    }

    /// When true, the toolbar stays visible in fullscreen (like Chrome's "Always Show Toolbar in Full Screen")
    var alwaysShowToolbarInFullscreen: Bool {
        didSet {
            defaults.set(alwaysShowToolbarInFullscreen, forKey: Keys.alwaysShowToolbarInFullscreen)
            NotificationCenter.default.post(name: .fullscreenToolbarSettingChanged, object: nil)
        }
    }

    /// When true, shows a warning dialog before closing a tab with a running process
    var warnOnCloseWithRunningProcess: Bool {
        didSet { defaults.set(warnOnCloseWithRunningProcess, forKey: Keys.warnOnCloseWithProcess) }
    }

    /// When true, always shows a warning dialog before closing any tab
    var alwaysWarnOnTabClose: Bool {
        didSet { defaults.set(alwaysWarnOnTabClose, forKey: Keys.alwaysWarnOnTabClose) }
    }

    /// Collect tabs idle for 10+ minutes into a dropdown at the start of the tab bar
    var groupIdleTabs: Bool {
        didSet { defaults.set(groupIdleTabs, forKey: Keys.groupIdleTabs) }
    }

    var idleTabThresholdMinutes: Int {
        didSet { defaults.set(idleTabThresholdMinutes, forKey: Keys.idleTabThresholdMinutes) }
    }

    /// Which keys jump to a tab by position (⌘1–9 vs F1–F12). Read live by
    /// AppDelegate's key monitor, so changes take effect on the next keystroke.
    var tabSwitchShortcutMode: TabSwitchShortcutMode {
        didSet {
            defaults.set(tabSwitchShortcutMode.rawValue, forKey: Keys.tabSwitchShortcutMode)
        }
    }

    // MARK: - Tab Display Customization

    /// Show AI product logos and dev server icons in tabs
    var showTabIcons: Bool {
        didSet { defaults.set(showTabIcons, forKey: Keys.showTabIcons) }
    }

    /// Show the working directory path next to the tab title
    var showTabPath: Bool {
        didSet { defaults.set(showTabPath, forKey: Keys.showTabPath) }
    }

    /// Show the git branch indicator in tabs
    var showTabGitIndicator: Bool {
        didSet { defaults.set(showTabGitIndicator, forKey: Keys.showTabGitIndicator) }
    }

    /// Show the CTO bolt icon in tabs (independent of CTO being enabled)
    var showTabCTOIndicator: Bool {
        didSet { defaults.set(showTabCTOIndicator, forKey: Keys.showTabCTOIndicator) }
    }

    /// Allow toggling per-tab CTO override directly from tab indicator clicks.
    /// Disable this to prevent accidental misclicks while still showing override state.
    var allowTabCTOToggle: Bool {
        didSet { defaults.set(allowTabCTOToggle, forKey: Keys.allowTabCTOToggle) }
    }

    /// Show the broadcast indicator in tabs
    var showTabBroadcastIndicator: Bool {
        didSet { defaults.set(showTabBroadcastIndicator, forKey: Keys.showTabBroadcastIndicator) }
    }

    /// When enabled, only the custom title is shown (hides all other tab elements
    /// except the close button). Has no effect on tabs without a custom title.
    var customTitleOnly: Bool {
        didSet { defaults.set(customTitleOnly, forKey: Keys.customTitleOnly) }
    }

    // MARK: - Hover Card Sections

    var hoverCardShowDirectory: Bool {
        didSet { defaults.set(hoverCardShowDirectory, forKey: Keys.hoverCardShowDirectory) }
    }

    var hoverCardShowGitBranch: Bool {
        didSet { defaults.set(hoverCardShowGitBranch, forKey: Keys.hoverCardShowGitBranch) }
    }

    var hoverCardShowShellIntegration: Bool {
        didSet { defaults.set(hoverCardShowShellIntegration, forKey: Keys.hoverCardShowShellIntegration) }
    }

    var hoverCardShowDevServer: Bool {
        didSet { defaults.set(hoverCardShowDevServer, forKey: Keys.hoverCardShowDevServer) }
    }

    var hoverCardShowLastCommand: Bool {
        didSet { defaults.set(hoverCardShowLastCommand, forKey: Keys.hoverCardShowLastCommand) }
    }

    var hoverCardShowAISession: Bool {
        didSet { defaults.set(hoverCardShowAISession, forKey: Keys.hoverCardShowAISession) }
    }

    var hoverCardShowRepoStats: Bool {
        didSet { defaults.set(hoverCardShowRepoStats, forKey: Keys.hoverCardShowRepoStats) }
    }

    var hoverCardShowProcesses: Bool {
        didSet { defaults.set(hoverCardShowProcesses, forKey: Keys.hoverCardShowProcesses) }
    }

    var hoverCardShowTokenOptimization: Bool {
        didSet { defaults.set(hoverCardShowTokenOptimization, forKey: Keys.hoverCardShowTokenOptimization) }
    }

    var hoverCardShowBroadcast: Bool {
        didSet { defaults.set(hoverCardShowBroadcast, forKey: Keys.hoverCardShowBroadcast) }
    }

    var hoverCardShowConflicts: Bool {
        didSet { defaults.set(hoverCardShowConflicts, forKey: Keys.hoverCardShowConflicts) }
    }

    var hoverCardShowNotificationState: Bool {
        didSet { defaults.set(hoverCardShowNotificationState, forKey: Keys.hoverCardShowNotificationState) }
    }

    var hoverCardShowFooter: Bool {
        didSet { defaults.set(hoverCardShowFooter, forKey: Keys.hoverCardShowFooter) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // Tab Close Behavior (NEW)
        if let behaviorRaw = defaults.string(forKey: Keys.lastTabCloseBehavior),
           let behavior = LastTabCloseBehavior(rawValue: behaviorRaw) {
            self.lastTabCloseBehavior = behavior
        } else {
            self.lastTabCloseBehavior = .keepWindow
        }
        self.newTabPosition = defaults.string(forKey: Keys.newTabPosition) ?? "end"
        self.newTabsUseCurrentDirectory = defaults.object(forKey: Keys.newTabsUseCurrentDirectory) as? Bool ?? true
        self.alwaysShowTabBar = defaults.object(forKey: Keys.alwaysShowTabBar) as? Bool ?? true
        self.alwaysShowToolbarInFullscreen = defaults.object(forKey: Keys.alwaysShowToolbarInFullscreen) as? Bool ?? false
        self.warnOnCloseWithRunningProcess = defaults.object(forKey: Keys.warnOnCloseWithProcess) as? Bool ?? true
        self.alwaysWarnOnTabClose = defaults.object(forKey: Keys.alwaysWarnOnTabClose) as? Bool ?? false
        self.groupIdleTabs = defaults.object(forKey: Keys.groupIdleTabs) as? Bool ?? true
        self.idleTabThresholdMinutes = defaults.object(forKey: Keys.idleTabThresholdMinutes) as? Int ?? 10
        if let raw = defaults.string(forKey: Keys.tabSwitchShortcutMode),
           let mode = TabSwitchShortcutMode(rawValue: raw) {
            self.tabSwitchShortcutMode = mode
        } else {
            self.tabSwitchShortcutMode = .commandNumber
        }

        // Tab Display (defaults: all visible)
        self.showTabIcons = defaults.object(forKey: Keys.showTabIcons) as? Bool ?? true
        self.showTabPath = defaults.object(forKey: Keys.showTabPath) as? Bool ?? true
        self.showTabGitIndicator = defaults.object(forKey: Keys.showTabGitIndicator) as? Bool ?? true
        self.showTabCTOIndicator = defaults.object(forKey: Keys.showTabCTOIndicator) as? Bool ?? true
        self.allowTabCTOToggle = defaults.object(forKey: Keys.allowTabCTOToggle) as? Bool ?? true
        self.showTabBroadcastIndicator = defaults.object(forKey: Keys.showTabBroadcastIndicator) as? Bool ?? true
        // Hover Card Sections (defaults: all visible)
        self.hoverCardShowDirectory = defaults.object(forKey: Keys.hoverCardShowDirectory) as? Bool ?? true
        self.hoverCardShowGitBranch = defaults.object(forKey: Keys.hoverCardShowGitBranch) as? Bool ?? true
        self.hoverCardShowShellIntegration = defaults.object(forKey: Keys.hoverCardShowShellIntegration) as? Bool ?? false
        self.hoverCardShowDevServer = defaults.object(forKey: Keys.hoverCardShowDevServer) as? Bool ?? true
        self.hoverCardShowLastCommand = defaults.object(forKey: Keys.hoverCardShowLastCommand) as? Bool ?? true
        self.hoverCardShowAISession = defaults.object(forKey: Keys.hoverCardShowAISession) as? Bool ?? true
        self.hoverCardShowRepoStats = defaults.object(forKey: Keys.hoverCardShowRepoStats) as? Bool ?? true
        self.hoverCardShowProcesses = defaults.object(forKey: Keys.hoverCardShowProcesses) as? Bool ?? true
        self.hoverCardShowTokenOptimization = defaults.object(forKey: Keys.hoverCardShowTokenOptimization) as? Bool ?? false
        self.hoverCardShowBroadcast = defaults.object(forKey: Keys.hoverCardShowBroadcast) as? Bool ?? false
        self.hoverCardShowConflicts = defaults.object(forKey: Keys.hoverCardShowConflicts) as? Bool ?? true
        self.hoverCardShowNotificationState = defaults.object(forKey: Keys.hoverCardShowNotificationState) as? Bool ?? true
        self.hoverCardShowFooter = defaults.object(forKey: Keys.hoverCardShowFooter) as? Bool ?? true
        self.customTitleOnly = defaults.object(forKey: Keys.customTitleOnly) as? Bool ?? false
    }

    /// Reset by deriving from the loader (single source of defaults).
    func resetToDefaults() {
        for key in [
            Keys.lastTabCloseBehavior, Keys.newTabPosition,
            Keys.newTabsUseCurrentDirectory, Keys.alwaysShowTabBar,
            Keys.alwaysShowToolbarInFullscreen, Keys.warnOnCloseWithProcess,
            Keys.alwaysWarnOnTabClose, Keys.groupIdleTabs,
            Keys.idleTabThresholdMinutes, Keys.tabSwitchShortcutMode,
            Keys.showTabIcons, Keys.showTabPath, Keys.showTabGitIndicator,
            Keys.showTabCTOIndicator, Keys.allowTabCTOToggle,
            Keys.showTabBroadcastIndicator, Keys.customTitleOnly,
            Keys.hoverCardShowDirectory, Keys.hoverCardShowGitBranch,
            Keys.hoverCardShowShellIntegration, Keys.hoverCardShowDevServer,
            Keys.hoverCardShowLastCommand, Keys.hoverCardShowAISession,
            Keys.hoverCardShowRepoStats, Keys.hoverCardShowProcesses,
            Keys.hoverCardShowTokenOptimization, Keys.hoverCardShowBroadcast,
            Keys.hoverCardShowConflicts, Keys.hoverCardShowNotificationState,
            Keys.hoverCardShowFooter
        ] {
            defaults.removeObject(forKey: key)
        }
        let fresh = TabDisplaySettingsStore(defaults: defaults)
        lastTabCloseBehavior = fresh.lastTabCloseBehavior
        newTabPosition = fresh.newTabPosition
        newTabsUseCurrentDirectory = fresh.newTabsUseCurrentDirectory
        alwaysShowTabBar = fresh.alwaysShowTabBar
        alwaysShowToolbarInFullscreen = fresh.alwaysShowToolbarInFullscreen
        warnOnCloseWithRunningProcess = fresh.warnOnCloseWithRunningProcess
        alwaysWarnOnTabClose = fresh.alwaysWarnOnTabClose
        groupIdleTabs = fresh.groupIdleTabs
        idleTabThresholdMinutes = fresh.idleTabThresholdMinutes
        tabSwitchShortcutMode = fresh.tabSwitchShortcutMode
        showTabIcons = fresh.showTabIcons
        showTabPath = fresh.showTabPath
        showTabGitIndicator = fresh.showTabGitIndicator
        showTabCTOIndicator = fresh.showTabCTOIndicator
        allowTabCTOToggle = fresh.allowTabCTOToggle
        showTabBroadcastIndicator = fresh.showTabBroadcastIndicator
        customTitleOnly = fresh.customTitleOnly
        hoverCardShowDirectory = fresh.hoverCardShowDirectory
        hoverCardShowGitBranch = fresh.hoverCardShowGitBranch
        hoverCardShowShellIntegration = fresh.hoverCardShowShellIntegration
        hoverCardShowDevServer = fresh.hoverCardShowDevServer
        hoverCardShowLastCommand = fresh.hoverCardShowLastCommand
        hoverCardShowAISession = fresh.hoverCardShowAISession
        hoverCardShowRepoStats = fresh.hoverCardShowRepoStats
        hoverCardShowProcesses = fresh.hoverCardShowProcesses
        hoverCardShowTokenOptimization = fresh.hoverCardShowTokenOptimization
        hoverCardShowBroadcast = fresh.hoverCardShowBroadcast
        hoverCardShowConflicts = fresh.hoverCardShowConflicts
        hoverCardShowNotificationState = fresh.hoverCardShowNotificationState
        hoverCardShowFooter = fresh.hoverCardShowFooter
    }
}
