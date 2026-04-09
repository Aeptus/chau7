import Foundation
import AppKit
import Chau7Core
import SwiftUI

// MARK: - Tab Notification Styling

/// Visual styling that can be applied to a tab via the notification system.
/// Use this to indicate states like "waiting for input", "error occurred", "task complete", etc.
struct TabNotificationStyle: Equatable {
    /// Override color for the tab title (nil = use default)
    var titleColor: Color?

    /// Make the title italic (e.g., for "waiting" states)
    var isItalic = false

    /// Make the title bold (e.g., for "attention needed")
    var isBold = false

    /// Subtle pulse animation to draw attention
    var shouldPulse = false

    /// Optional icon to show (SF Symbol name)
    var icon: String?

    /// Icon color (nil = inherit from titleColor or default)
    var iconColor: Color?

    /// Border color for the tab (nil = no border)
    var borderColor: Color?

    /// Border width (default 0 = no border)
    var borderWidth: CGFloat = 0

    /// Border dash pattern (nil = solid, e.g. [4, 3] = dotted)
    var borderDash: [CGFloat]?

    /// Badge text overlay (e.g., "!", "3") — nil = no badge
    var badgeText: String?

    /// Badge color (defaults to red)
    var badgeColor: Color = .red

    /// When true, the style persists even when the tab is selected.
    /// Used for permission requests that need attention until resolved.
    var persistent = false

    /// Predefined styles for common states
    static let waiting = TabNotificationStyle(
        titleColor: .orange,
        isItalic: true,
        shouldPulse: true,
        icon: "ellipsis.circle",
        borderColor: .orange,
        borderWidth: 1.5
    )

    static let error = TabNotificationStyle(
        titleColor: .red,
        isBold: true,
        icon: "exclamationmark.triangle.fill",
        iconColor: .red,
        borderColor: .red,
        borderWidth: 1.5
    )

    static let success = TabNotificationStyle(
        titleColor: .green,
        icon: "checkmark.circle.fill",
        iconColor: .green
    )

    static let attention = TabNotificationStyle(
        titleColor: .yellow,
        isBold: true,
        shouldPulse: true,
        icon: "bell.fill",
        iconColor: .yellow,
        borderColor: .yellow,
        borderWidth: 1.5
    )
}

struct OverlayTab: Identifiable, Equatable {
    let id: UUID
    let splitController: SplitPaneController
    let createdAt: Date
    var customTitle: String?
    var color: TabColor = .blue
    var autoColor: TabColor? // F05: Auto-assigned color based on AI model
    var isManualColorOverride = false
    var lastCommand: LastCommandInfo? // F20: Last command tracking
    var bookmarks: [BookmarkManager.Bookmark] = [] // F17: Bookmarks

    // MARK: - MCP Control

    /// Whether this tab was created by an MCP client.
    var isMCPControlled = false

    // MARK: - Token Optimization (CTO) Per-Tab Override

    /// Per-tab override for token optimization. Defaults to `.default` which
    /// follows the global mode. Users can force-on or force-off per tab.
    var tokenOptOverride: TabTokenOptOverride = .default

    // MARK: - Notification Styling

    /// Active notification style for this tab (nil = default appearance)
    var notificationStyle: TabNotificationStyle?

    // MARK: - Repo Grouping

    /// Repo group membership. nil = ungrouped.
    /// Value is the canonical git root path (e.g. "/Users/me/repos/Chau7").
    var repoGroupID: String?
    /// Whether repo group membership was inherited from another tab and should
    /// be dropped if the tab's actual git root diverges.
    var hasInheritedRepoGroup = false

    /// Display name derived from repo group path (e.g. "Chau7")
    var repoGroupName: String? {
        guard let path = repoGroupID else { return nil }
        return URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Tab Switch Optimization: Cached Snapshot

    /// Cached screenshot of terminal content for instant visual feedback during tab switch
    var cachedSnapshot: NSImage?
    /// Last known cursor position for cursor-first rendering
    var lastCursorPosition: CGPoint = .zero
    /// Last known prompt text for cursor placeholder
    var lastPromptText = ""

    /// The primary terminal session (first terminal in split tree)
    var session: TerminalSessionModel? {
        splitController.primarySession
    }

    /// Session shown in tab chrome, based on current split focus.
    /// Keeps tab metadata and icons aligned with what the user currently sees.
    var displaySession: TerminalSessionModel? {
        splitController.focusedSession ?? splitController.primarySession
    }

    init(appModel: AppModel) {
        self.id = UUID()
        self.splitController = SplitPaneController(appModel: appModel)
        self.createdAt = Date()
    }

    /// Init with a pre-built split controller (for dashboard tabs).
    init(appModel: AppModel, splitController: SplitPaneController) {
        self.id = UUID()
        self.splitController = splitController
        self.createdAt = Date()
    }

    /// Whether this tab is a multi-agent dashboard (no terminal).
    var isDashboard: Bool {
        if case .dashboard = splitController.root { return true }
        return false
    }

    var displayTitle: String {
        if isDashboard { return customTitle ?? "Overview" }
        if let customTitle, !customTitle.isEmpty {
            return customTitle
        }
        if let activeName = displaySession?.aiDisplayAppName, !activeName.isEmpty {
            return activeName
        }
        if let devName = session?.devServer?.name,
           devName.compare("Vite", options: .caseInsensitive) == .orderedSame {
            return devName
        }
        // If no terminals exist, show "Editor" instead of "Shell"
        if splitController.root.allTerminalIDs.isEmpty {
            return L("tab.editor", "Editor")
        }
        return L("tab.shell", "Shell")
    }

    /// Returns the effective tab color - auto color if enabled and detected, otherwise manual color
    var effectiveColor: TabColor {
        if isManualColorOverride {
            return color
        }
        if FeatureSettings.shared.isAutoTabThemeEnabled, let auto = autoColor {
            return auto
        }
        return color
    }

    /// F20: Badge text for last command (duration + exit status)
    var commandBadge: String? {
        guard FeatureSettings.shared.isLastCommandBadgeEnabled else { return nil }
        return lastCommand?.badgeText
    }

    /// Whether CTO (token optimization) is currently active on this tab.
    var isTokenOptActive: Bool {
        let mode = FeatureSettings.shared.tokenOptimizationMode
        let isAI = displaySession?.aiDisplayAppName != nil
        return shouldBeActive(mode: mode, override: tokenOptOverride, isAIActive: isAI)
    }

    /// Visual state for optimizer tab badge: nil = hidden, true = active override, false = inactive override.
    /// Only non-nil when this tab deviates from its mode's default behavior.
    var optimizerOverrideState: Bool? {
        let mode = FeatureSettings.shared.tokenOptimizationMode
        switch mode {
        case .off: return nil
        case .allTabs: return tokenOptOverride == .forceOff ? false : nil
        case .manual: return tokenOptOverride == .forceOn ? true : nil
        case .aiOnly:
            switch tokenOptOverride {
            case .forceOn: return true
            case .forceOff: return false
            case .default: return nil
            }
        }
    }

    static func == (lhs: OverlayTab, rhs: OverlayTab) -> Bool {
        lhs.id == rhs.id
            && lhs.isMCPControlled == rhs.isMCPControlled
            && lhs.tokenOptOverride == rhs.tokenOptOverride
            && lhs.notificationStyle == rhs.notificationStyle
            && lhs.repoGroupID == rhs.repoGroupID
            && lhs.hasInheritedRepoGroup == rhs.hasInheritedRepoGroup
    }

    // MARK: - Split Pane Operations

    func splitHorizontally() {
        splitController.splitWithTerminal(direction: .horizontal)
    }

    func splitVertically() {
        splitController.splitWithTerminal(direction: .vertical)
    }

    func openTextEditor(filePath: String? = nil) {
        splitController.splitWithTextEditor(direction: .horizontal, filePath: filePath)
    }

    func closeFocusedPane() {
        splitController.closeFocusedPane()
    }

    func focusNextPane() {
        splitController.focusNextPane()
    }

    func focusPreviousPane() {
        splitController.focusPreviousPane()
    }

    func appendSelectionToEditor(_ text: String) {
        splitController.appendSelectionToEditor(text)
    }

    func openFilePreview(filePath: String? = nil) {
        if let path = filePath {
            splitController.openFilePreview(path: path)
        } else {
            splitController.splitWithFilePreview(direction: .horizontal)
        }
    }

    func openDiffViewer(filePath: String, directory: String, mode: DiffMode = .workingTree) {
        splitController.openDiffViewer(filePath: filePath, directory: directory, mode: mode)
    }

    func openRepositoryPane(directory: String) {
        splitController.openRepositoryPane(directory: directory)
    }

    func toggleTextEditor(filePath: String? = nil) {
        splitController.toggleTextEditor(filePath: filePath)
    }

    func toggleFilePreview(filePath: String? = nil) {
        splitController.toggleFilePreview(filePath: filePath)
    }

    func toggleRepositoryPane(directory: String) {
        splitController.toggleRepositoryPane(directory: directory)
    }

    init(appModel: AppModel, splitController: SplitPaneController, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.splitController = splitController
        self.createdAt = createdAt
    }

    /// Propagates this tab's UUID to the split controller and all current terminal
    /// sessions so events carry a deterministic tabID for the TabResolver fast-path.
    /// Must be called after the tab's `id` is finalized (i.e. after init or restore).
    mutating func stampOwnerTabID() {
        let tabID = id
        splitController.ownerTabID = tabID
        splitController.terminalSessionConfigurator = { session in
            session.ownerTabID = tabID
            session.onPermissionResolved = {
                DispatchQueue.main.async {
                    _ = TerminalControlService.shared.clearPersistentNotificationStyleAcrossWindows(tabID: tabID)
                }
            }
        }
    }
}

// MARK: - Tab State Persistence

struct SavedTerminalPaneState: Codable {
    let paneID: String
    let directory: String
    let scrollbackContent: String? // last N lines of terminal output
    let aiResumeCommand: String? // e.g. "claude --resume abc123"
    let aiProvider: String?
    let aiSessionId: String?
    let lastOutputAt: Date?
    let knownRepoRoot: String?
    let knownGitBranch: String?

    init(
        paneID: String,
        directory: String,
        scrollbackContent: String?,
        aiResumeCommand: String?,
        aiProvider: String? = nil,
        aiSessionId: String? = nil,
        lastOutputAt: Date? = nil,
        knownRepoRoot: String? = nil,
        knownGitBranch: String? = nil
    ) {
        self.paneID = paneID
        self.directory = directory
        self.scrollbackContent = scrollbackContent
        self.aiResumeCommand = aiResumeCommand
        self.aiProvider = aiProvider
        self.aiSessionId = aiSessionId
        self.lastOutputAt = lastOutputAt
        self.knownRepoRoot = knownRepoRoot
        self.knownGitBranch = knownGitBranch
    }
}

/// Lightweight Codable snapshot of a tab's restorable state.
/// Captures working directory, title, color, and the last N lines of
/// terminal scrollback so the user has context when tabs are restored.
struct SavedTabState: Codable {
    let tabID: String? // Persisted overlay tab ID
    let selectedTabID: String? // Explicit selected marker for stable restore
    let customTitle: String?
    let color: String // TabColor.rawValue
    let directory: String
    let selectedIndex: Int? // non-nil only for the selected tab
    let tokenOptOverride: String? // TabTokenOptOverride.rawValue (nil = .default for backwards compat)
    let scrollbackContent: String? // backward compatibility (legacy single-pane restore)
    let aiResumeCommand: String? // backward compatibility (legacy single-pane restore)
    let aiProvider: String?
    let aiSessionId: String?
    let splitLayout: SavedSplitNode? // split tree including editor panes
    let focusedPaneID: String? // persisted focused pane ID
    let paneStates: [SavedTerminalPaneState]?
    let createdAt: String? // ISO8601 encoded, nil for legacy saves
    let repoGroupID: String? // repo grouping membership, nil = ungrouped
    let knownRepoRoot: String?
    let knownGitBranch: String?

    static let userDefaultsKey = "com.chau7.savedTabState"

    init(
        tabID: String? = nil,
        selectedTabID: String? = nil,
        customTitle: String?,
        color: String,
        directory: String,
        selectedIndex: Int?,
        tokenOptOverride: String?,
        scrollbackContent: String?,
        aiResumeCommand: String?,
        aiProvider: String? = nil,
        aiSessionId: String? = nil,
        splitLayout: SavedSplitNode?,
        focusedPaneID: String?,
        paneStates: [SavedTerminalPaneState]?,
        createdAt: String? = nil,
        repoGroupID: String? = nil,
        knownRepoRoot: String? = nil,
        knownGitBranch: String? = nil
    ) {
        self.tabID = tabID
        self.selectedTabID = selectedTabID
        self.customTitle = customTitle
        self.color = color
        self.directory = directory
        self.selectedIndex = selectedIndex
        self.tokenOptOverride = tokenOptOverride
        self.scrollbackContent = scrollbackContent
        self.aiResumeCommand = aiResumeCommand
        self.aiProvider = aiProvider
        self.aiSessionId = aiSessionId
        self.splitLayout = splitLayout
        self.focusedPaneID = focusedPaneID
        self.paneStates = paneStates
        self.createdAt = createdAt
        self.repoGroupID = repoGroupID
        self.knownRepoRoot = knownRepoRoot
        self.knownGitBranch = knownGitBranch
    }
}

/// Multi-window save format: each entry is one window's tab states.
struct SavedMultiWindowState: Codable {
    static let userDefaultsKey = "com.chau7.savedMultiWindowState"
    let windows: [[SavedTabState]]
}

enum TabStateSaveReason: String {
    case autosave
    case termination
    case manual
    case restoreSource = "restore-source"
}

/// In-memory record of a closed tab, enabling "Reopen Closed Tab" (Cmd+Shift+T).
/// Wraps the existing `SavedTabState` with positional + temporal metadata.
/// Not persisted to disk — the stack resets on app quit, matching browser behavior.
struct ClosedTabEntry {
    let state: SavedTabState
    let originalIndex: Int
    let closedAt: Date
}

/// Manages terminal tabs, search, and broadcast mode for the overlay window.
/// - Note: Thread Safety - observed properties must be modified on main thread.
///   All methods assume main thread execution.
@Observable
final class OverlayTabsModel {
    static var lastArchivedMultiWindowTabStateFingerprint: Int?
    static var lastArchivedMultiWindowTabStateAt: Date = .distantPast

    var tabs: [OverlayTab] {
        didSet { onTabsChanged?() }
    }

    var selectedTabID: UUID {
        didSet {
            if activeDashboardGroupID != nil { activeDashboardGroupID = nil }
            onSelectedTabIDChanged?()
        }
    }

    /// When set, the content area shows the agent dashboard for this repo group.
    var activeDashboardGroupID: String?
    private var dashboardModels: [String: AgentDashboardModel] = [:]

    func dashboardModel(for repoGroupID: String) -> AgentDashboardModel {
        if let existing = dashboardModels[repoGroupID] { return existing }
        let model = AgentDashboardModel(repoGroupID: repoGroupID)
        model.onSwitchToTab = { [weak self] tabID in
            self?.activeDashboardGroupID = nil
            self?.selectTab(id: tabID)
        }
        dashboardModels[repoGroupID] = model
        return model
    }

    var isSearchVisible = false
    var searchQuery = ""
    var searchResults: [String] = []
    var searchMatchCount = 0
    var isCaseSensitive = false
    var isRegexSearch = false
    var isSemanticSearch = false
    var searchError: String?
    var isRenameVisible = false
    var renameText = ""
    var renameColor: TabColor = .blue
    var suspendedTabIDs: Set<UUID> = []

    // MARK: - Tab Switch Optimization State

    /// Previous tab index for directional animation
    var previousTabIndex = 0
    /// Whether the terminal content is ready to display (for snapshot swap)
    var isTerminalReady = true
    /// Generation counter for isTerminalReady — prevents stale asyncAfter
    /// callbacks from clobbering the state after rapid tab switches.
    @ObservationIgnored var terminalReadyGeneration: UInt64 = 0
    /// Set of tab IDs currently being pre-warmed (on hover)
    @ObservationIgnored var prewarmingTabIDs: Set<UUID> = []

    // MARK: - Tab Bar Recovery

    /// Tab hit-test ranges for right-click context menu (populated by SwiftUI preference changes).
    /// Each entry maps a tab UUID to its global x-range (minX, maxX) in the window.
    @ObservationIgnored var tabHitTestFrames: [(tabID: UUID, minX: CGFloat, maxX: CGFloat)] = []

    /// Group bracket hit-test ranges for right-click and drag (populated by SwiftUI preferences).
    /// Each entry maps a repoGroupID to its global x-range.
    @ObservationIgnored var groupBracketHitTestFrames: [(repoGroupID: String, minX: CGFloat, maxX: CGFloat)] = []

    /// Token to force SwiftUI to re-render the tab bar when incremented
    var tabBarRefreshToken = 0
    /// Last reported rendered tab count from the view (for watchdog)
    /// -1 means the view hasn't reported yet (avoids false positive on startup)
    @ObservationIgnored var lastReportedRenderedCount: Int = -1
    /// Last reported tab bar size (for visibility-based recovery)
    @ObservationIgnored var lastReportedTabBarSize: CGSize = .zero
    /// Timestamp of last preference update from the view (for staleness detection)
    @ObservationIgnored var lastPreferenceUpdateTime = Date()
    /// How long without a preference update before considering the view stale
    @ObservationIgnored let stalenessThreshold: TimeInterval = 20.0
    @ObservationIgnored let refreshCooldown: TimeInterval = 10.0
    @ObservationIgnored var lastForcedRefreshAt: Date = .distantPast
    @ObservationIgnored var watchdogRecoveryCount = 0
    @ObservationIgnored var watchdogSkipCount = 0
    @ObservationIgnored var lastWatchdogSummaryAt = Date()
    @ObservationIgnored var lastWatchdogReason = ""
    /// Timer for watchdog that checks tab bar health
    @ObservationIgnored var tabBarWatchdogTimer: DispatchSourceTimer?
    @ObservationIgnored var consecutiveHealthyChecks = 0
    /// Counter to limit consecutive watchdog refresh attempts
    @ObservationIgnored var watchdogRefreshAttempts = 0
    /// Minimum acceptable tab bar width per tab (for visibility detection)
    @ObservationIgnored let minWidthPerTab: CGFloat = 30
    /// Last reported tab bar frame in global coordinates for cross-window tab drops.
    @ObservationIgnored var tabBarDropFrame: CGRect = .zero
    /// Tracks whether the tab bar is expected to be visible
    @ObservationIgnored var isTabBarVisible = true
    @ObservationIgnored var lastTabBarVisibilityLogAt: Date = .distantPast

    // F13: Broadcast Input
    var isBroadcastMode = false
    var broadcastExcludedTabIDs: Set<UUID> = []

    // F16: Clipboard History
    var isClipboardHistoryVisible = false

    // F17: Bookmarks
    var isBookmarkListVisible = false

    // F21: Snippets
    var isSnippetManagerVisible = false

    // Hover Card
    var hoverCardTabID: UUID?
    var hoverCardAnchorX: CGFloat = 0
    @ObservationIgnored var hoverCardTimer: DispatchWorkItem?
    @ObservationIgnored var hoverCardDismissTimer: DispatchWorkItem?

    // Task Lifecycle (v1.1)
    var currentCandidate: TaskCandidate?
    var currentTask: TrackedTask?
    var isTaskAssessmentVisible = false

    // Reopen Closed Tab (Cmd+Shift+T)
    /// LIFO stack of recently closed tabs (max 10, in-memory only)
    @ObservationIgnored var closedTabStack: [ClosedTabEntry] = []
    @ObservationIgnored let maxClosedTabs = 10

    /// Whether there are any closed tabs available to reopen
    var canReopenClosedTab: Bool {
        !closedTabStack.isEmpty
    }

    // Git root path observation is now handled via session.onGitRootPathChanged callbacks
    @ObservationIgnored var renameTabID: UUID?
    @ObservationIgnored var renameOriginalTitle = ""
    @ObservationIgnored var renameOriginalColor: TabColor = .blue
    @ObservationIgnored var suspendWorkItems: [UUID: DispatchWorkItem] = [:]
    @ObservationIgnored var liveRenderExemptTabIDs: Set<UUID> = []
    /// Per-pane token for restore-time resume prefills.
    /// Prevents stale delayed retries from writing outdated commands.
    @ObservationIgnored var latestRestoreResumeTokenByPaneID: [UUID: String] = [:]
    @ObservationIgnored var isRenderSuspensionEnabled = false
    // Reduced from 5.0s to 2.0s — combined with CVDisplayLink pausing, this
    // means background tabs stop rendering 3 seconds sooner, saving significant CPU.
    @ObservationIgnored var renderSuspensionDelay: TimeInterval = 5.0
    @ObservationIgnored var needsFreshTabOnShow = false
    @ObservationIgnored var isDiagnosticsLoggingEnabled = false
    /// Auto-save timer moved to AppDelegate for coordinated multi-window saves.
    /// Last archived snapshot fingerprint to avoid writing duplicate archive files.
    @ObservationIgnored var lastArchivedTabStateFingerprint: Int?
    /// Minimum time between archived snapshots unless we're terminating.
    @ObservationIgnored var lastArchivedTabStateAt: Date = .distantPast
    /// CTO notification observer tokens (stored for cleanup in deinit)
    @ObservationIgnored var ctoModeObserver: NSObjectProtocol?
    @ObservationIgnored var renderSuspensionObserver: NSObjectProtocol?
    @ObservationIgnored var suspensionDebounceItem: DispatchWorkItem?
    @ObservationIgnored var lastObservedTokenOptimizationMode: TokenOptimizationMode = FeatureSettings.shared.tokenOptimizationMode
    @ObservationIgnored var codexResumeFallbackCache: [ObjectIdentifier: CachedCodexResumeFallback] = [:]

    /// Callback invoked when `tabs` changes — used by RemoteControlManager
    @ObservationIgnored var onTabsChanged: (() -> Void)?
    /// Callback invoked when `selectedTabID` changes — used by RemoteControlManager
    @ObservationIgnored var onSelectedTabIDChanged: (() -> Void)?

    @ObservationIgnored weak var overlayWindow: NSWindow?
    @ObservationIgnored var onCloseLastTab: (() -> Void)?

    @ObservationIgnored let appModel: AppModel
    struct RestorableTabsPayload {
        let tabs: [OverlayTab]
        let selectedID: UUID
        let rawStates: [SavedTabState]
    }

    struct CodexResumeFallbackSignature: Equatable {
        let directory: String
        let explicitSessionId: String?
        let referenceTimestamp: TimeInterval?
        let claimedSessionFingerprint: Int
        let claimedSessionCount: Int
        let historyFingerprint: Int
    }

    struct StableCodexResumeFallbackSignature: Equatable {
        let directory: String
        let explicitSessionId: String?
        let referenceTimestamp: TimeInterval?
        let claimedSessionFingerprint: Int
        let claimedSessionCount: Int
    }

    struct CachedCodexResumeFallback {
        let signature: CodexResumeFallbackSignature
        let stableSignature: StableCodexResumeFallbackSignature?
        let metadata: (provider: String, sessionId: String)?
    }

    /// When `restoreState` is false, the model starts with a single fresh tab
    /// instead of loading saved state from disk. Used for Cmd+N new windows.
    /// When `restoringStates` is provided, those pre-decoded states are used
    /// directly instead of reading from UserDefaults (for multi-window restore).
    init(appModel: AppModel, restoreState: Bool = true, restoringStates: [SavedTabState]? = nil) {
        self.appModel = appModel
        let restoredPayload: RestorableTabsPayload?
        if let states = restoringStates {
            restoredPayload = Self.decodeRestorableTabs(fromStates: states, appModel: appModel)
        } else {
            restoredPayload = restoreState ? Self.restoreSavedTabs(appModel: appModel) : nil
        }
        let sanitizedRestoredStates = restoredPayload.map { payload in
            Self.sanitizeRestoredAIResumeOwnership(states: payload.rawStates)
        }

        if let restoredPayload {
            self.tabs = restoredPayload.tabs
            self.selectedTabID = restoredPayload.selectedID
            Log.info("Restored \(restoredPayload.tabs.count) tab(s) from saved state")
        } else {
            // Fallback: create a single fresh tab
            var first = OverlayTab(appModel: appModel)
            if let firstColor = TabColor.allCases.first {
                first.color = firstColor
            }
            first.stampOwnerTabID()
            self.tabs = [first]
            self.selectedTabID = first.id
        }

        // Apply persisted terminal state (scrollback + resume command) after the
        // instance is fully initialized.
        if let sanitizedRestoredStates {
            for (index, state) in sanitizedRestoredStates.enumerated() where index < tabs.count {
                restoreTabState(for: tabs[index], state: state)
            }
        }

        // Setup task lifecycle observers (v1.1)
        setupTaskObservers()

        // Repo grouping: subscribe to mode changes and initial auto-group
        setupRepoGrouping()

        // Coalesce restored groups so same-repo tabs are contiguous.
        // setupRepoGrouping only coalesces in .auto mode, but restored tabs
        // may have repoGroupIDs in any mode.
        if restoredPayload != nil {
            var seen = Set<String>()
            for tab in tabs {
                guard let gid = tab.repoGroupID, seen.insert(gid).inserted else { continue }
                coalesceGroup(repoGroupID: gid)
            }
        }

        // Start tab bar watchdog immediately (model-owned lifecycle)
        // This ensures the watchdog runs regardless of view lifecycle events
        DispatchQueue.main.async { [weak self] in
            self?.startTabBarWatchdog()
        }

        DispatchQueue.main.async { [weak self] in
            self?.isDiagnosticsLoggingEnabled = true
            self?.logVisualState(reason: "init")
        }

        // Per-window autosave removed — AppDelegate now coordinates multi-window saves
        // to avoid race conditions where each window overwrites the same UserDefaults key.

        // CTO: listen for global mode changes and recalculate all tab flags
        self.ctoModeObserver = NotificationCenter.default.addObserver(
            forName: .tokenOptimizationModeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let previousMode = lastObservedTokenOptimizationMode
            let mode = FeatureSettings.shared.tokenOptimizationMode
            self.lastObservedTokenOptimizationMode = mode
            CTORuntimeMonitor.shared.recordModeChanged(from: previousMode, to: mode)
            recalculateAllCTOFlags()
            // Also setup/teardown wrappers when mode changes at runtime
            if mode == .off {
                CTOManager.shared.teardown()
            } else {
                CTOManager.shared.setup()
            }
        }

        self.renderSuspensionObserver = NotificationCenter.default.addObserver(
            forName: .terminalSessionRenderSuspensionStateChanged,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            guard let session = note.object as? TerminalSessionModel else { return }
            guard tabs.contains(where: { tab in
                tab.splitController.terminalSessions.contains { _, candidate in candidate === session }
            }) else { return }

            // Debounce: coalesce rapid state changes (e.g., spinner animations
            // updating activeAppName at ~1/sec) into a single evaluation.
            suspensionDebounceItem?.cancel()
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                Log.trace("renderSuspension: session state changed tabSession=\(session.tabIdentifier)")
                updateSuspensionState()
                // Note: with @Observable, property mutations auto-trigger
                // observation — no manual send needed.
            }
            self.suspensionDebounceItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
        }
    }

    deinit {
        Log.warn("OverlayTabsModel deinit — tabs=\(tabs.count) pid=\(ProcessInfo.processInfo.processIdentifier)")
        stopTabBarWatchdog()
        if let ctoModeObserver { NotificationCenter.default.removeObserver(ctoModeObserver) }
        if let renderSuspensionObserver { NotificationCenter.default.removeObserver(renderSuspensionObserver) }
    }

    // MARK: - Tab State Persistence

    /// Saves current tab state to disk backups. Does NOT write to UserDefaults —
    /// that is handled centrally by AppDelegate.saveAllWindowStates() to avoid
    /// multi-window race conditions.
    func saveTabState(reason: TabStateSaveReason = .manual) {
        let states = exportTabStates()
        guard !states.isEmpty else { return }
        do {
            let data = try JSONEncoder().encode(states)
            persistTabStateBackups(data: data, reason: reason)
            Log.trace("Saved \(states.count) tab state(s) to disk backup [\(reason.rawValue)]")
        } catch {
            Log.warn("Failed to save tab state: \(error)")
        }
    }

    /// Exports current tab states without persisting to disk.
    /// Used by AppDelegate to collect all windows' states for multi-window save.
    func exportTabStates() -> [SavedTabState] {
        let selectedID = selectedTabID
        let maxLines = FeatureSettings.shared.restoredScrollbackLines
        var states: [SavedTabState] = []
        var claimedSessionIds = Set<String>()

        for (i, tab) in tabs.enumerated() {
            let terminalSessions = tab.splitController.terminalSessions
            let isSelected = tab.id == selectedID
            let overrideRaw: String? = tab.tokenOptOverride == .default ? nil : tab.tokenOptOverride.rawValue

            var paneStates: [SavedTerminalPaneState] = []
            for (paneID, session) in terminalSessions {
                let dir = session.currentDirectory
                let scrollback = Self.captureScrollback(from: session, maxLines: maxLines)
                let knownRepoIdentity = Self.persistedRepoIdentity(
                    for: session,
                    directory: dir,
                    fallbackRoot: tab.repoGroupID
                )
                let resumeMetadata = resolveResumeMetadata(
                    for: session, directory: dir, outputHint: scrollback, claimedSessionIds: claimedSessionIds
                )
                let persistedMetadata = persistedAIResumeMetadata(
                    from: session,
                    resolvedResumeMetadata: resumeMetadata,
                    claimedSessionIds: claimedSessionIds
                )
                let resumeCommand = Self.buildAIResumeCommand(
                    provider: persistedMetadata.provider, sessionId: persistedMetadata.sessionId
                )
                if let sessionId = persistedMetadata.sessionId { claimedSessionIds.insert(sessionId) }

                paneStates.append(SavedTerminalPaneState(
                    paneID: paneID.uuidString,
                    directory: dir,
                    scrollbackContent: scrollback,
                    aiResumeCommand: resumeCommand,
                    aiProvider: persistedMetadata.provider,
                    aiSessionId: persistedMetadata.sessionId,
                    lastOutputAt: Self.normalizedResumeReferenceDate(session.lastOutputDate),
                    knownRepoRoot: knownRepoIdentity?.rootPath,
                    knownGitBranch: knownRepoIdentity?.branch
                ))
            }

            let primaryDirectory = terminalSessions.first?.1.currentDirectory
                ?? tab.session?.currentDirectory
                ?? TerminalSessionModel.defaultStartDirectory()
            let primaryKnownRepoIdentity = paneStates.first.flatMap(Self.persistedRepoIdentity(from:))
                ?? tab.session.flatMap {
                    Self.persistedRepoIdentity(
                        for: $0,
                        directory: primaryDirectory,
                        fallbackRoot: tab.repoGroupID
                    )
                }

            states.append(SavedTabState(
                tabID: tab.id.uuidString,
                selectedTabID: isSelected ? tab.id.uuidString : nil,
                customTitle: tab.customTitle,
                color: tab.color.rawValue,
                directory: primaryDirectory,
                selectedIndex: isSelected ? i : nil,
                tokenOptOverride: overrideRaw,
                scrollbackContent: paneStates.first?.scrollbackContent,
                aiResumeCommand: paneStates.first?.aiResumeCommand,
                aiProvider: paneStates.first?.aiProvider,
                aiSessionId: paneStates.first?.aiSessionId,
                splitLayout: tab.splitController.exportLayout(),
                focusedPaneID: tab.splitController.focusedTerminalSessionID()?.uuidString,
                paneStates: paneStates.isEmpty ? nil : paneStates,
                createdAt: DateFormatters.iso8601.string(from: tab.createdAt),
                repoGroupID: tab.repoGroupID,
                knownRepoRoot: primaryKnownRepoIdentity?.rootPath,
                knownGitBranch: primaryKnownRepoIdentity?.branch
            ))
        }
        return states
    }

    /// Captures a snapshot of a tab about to be closed and pushes it onto the
    /// closed-tab stack. Must be called BEFORE `closeAllSessions()` kills the shell,
    /// because we need the live scrollback buffer and active app name.
    func captureClosedTabSnapshot(tab: OverlayTab, at index: Int) {
        let maxLines = FeatureSettings.shared.restoredScrollbackLines
        let terminalSessions = tab.splitController.terminalSessions

        var paneStates: [SavedTerminalPaneState] = []
        for (paneID, session) in terminalSessions {
            let dir = session.currentDirectory
            let scrollback = Self.captureScrollback(from: session, maxLines: maxLines)
            let knownRepoIdentity = Self.persistedRepoIdentity(
                for: session,
                directory: dir,
                fallbackRoot: tab.repoGroupID
            )
            let resumeMetadata = resolveResumeMetadata(
                for: session,
                directory: dir,
                outputHint: scrollback
            )
            let persistedMetadata = persistedAIResumeMetadata(
                from: session,
                resolvedResumeMetadata: resumeMetadata
            )
            let resumeCommand = Self.buildAIResumeCommand(
                provider: persistedMetadata.provider,
                sessionId: persistedMetadata.sessionId
            )

            paneStates.append(SavedTerminalPaneState(
                paneID: paneID.uuidString,
                directory: dir,
                scrollbackContent: scrollback,
                aiResumeCommand: resumeCommand,
                aiProvider: persistedMetadata.provider,
                aiSessionId: persistedMetadata.sessionId,
                lastOutputAt: Self.normalizedResumeReferenceDate(session.lastOutputDate),
                knownRepoRoot: knownRepoIdentity?.rootPath,
                knownGitBranch: knownRepoIdentity?.branch
            ))
        }

        let primaryDirectory = terminalSessions.first?.1.currentDirectory
            ?? tab.session?.currentDirectory
            ?? TerminalSessionModel.defaultStartDirectory()
        let primaryScrollback = paneStates.first?.scrollbackContent
        let primaryResumeCommand = paneStates.first?.aiResumeCommand
        let primaryKnownRepoIdentity = paneStates.first.flatMap(Self.persistedRepoIdentity(from:))
            ?? tab.session.flatMap {
                Self.persistedRepoIdentity(
                    for: $0,
                    directory: primaryDirectory,
                    fallbackRoot: tab.repoGroupID
                )
            }

        let overrideRaw = tab.tokenOptOverride == .default ? nil : tab.tokenOptOverride.rawValue
        let state = SavedTabState(
            tabID: tab.id.uuidString,
            selectedTabID: nil,
            customTitle: tab.customTitle,
            color: tab.color.rawValue,
            directory: primaryDirectory,
            selectedIndex: nil,
            tokenOptOverride: overrideRaw,
            scrollbackContent: primaryScrollback,
            aiResumeCommand: primaryResumeCommand,
            aiProvider: paneStates.first?.aiProvider,
            aiSessionId: paneStates.first?.aiSessionId,
            splitLayout: tab.splitController.exportLayout(),
            focusedPaneID: tab.splitController.focusedTerminalSessionID()?.uuidString,
            paneStates: paneStates.isEmpty ? nil : paneStates,
            createdAt: DateFormatters.iso8601.string(from: tab.createdAt),
            repoGroupID: tab.repoGroupID,
            knownRepoRoot: primaryKnownRepoIdentity?.rootPath,
            knownGitBranch: primaryKnownRepoIdentity?.branch
        )

        closedTabStack.append(ClosedTabEntry(
            state: state,
            originalIndex: index,
            closedAt: Date()
        ))

        // Cap the stack
        if closedTabStack.count > maxClosedTabs {
            closedTabStack.removeFirst(closedTabStack.count - maxClosedTabs)
        }

        Log.info("Captured closed tab snapshot: \"\(tab.displayTitle)\" at index \(index) (stack size: \(closedTabStack.count))")
    }

    func resolveResumeMetadata(
        for session: TerminalSessionModel,
        directory: String,
        outputHint: String?,
        claimedSessionIds: Set<String> = []
    ) -> (provider: String, sessionId: String)? {
        let referenceDate = Self.normalizedResumeReferenceDate(session.lastOutputDate)
        let detectedApp = Self.detectAIAppName(fromOutput: outputHint)
        let resumeAppName = session.aiDisplayAppName ?? detectedApp
        let explicitProvider = Self.explicitResumeProvider(for: session)
        let explicitSessionId = Self.explicitResumeSessionId(for: session)
        let hasClaimedExplicitCodexSession = explicitProvider == "codex"
            && explicitSessionId.map { claimedSessionIds.contains($0) } == true

        if let resolved = Self.resolveAIResumeMetadata(
            appName: resumeAppName,
            directory: directory,
            outputHint: outputHint,
            explicitAIProvider: explicitProvider,
            explicitAISessionId: explicitSessionId,
            referenceDate: referenceDate,
            claimedSessionIds: claimedSessionIds
        ) {
            if explicitProvider == "codex",
               explicitSessionId != resolved.sessionId {
                session.restoreAIMetadata(provider: resolved.provider, sessionId: resolved.sessionId)
                Log.info(
                    "saveTabState: replaced Codex resume metadata sessionId=\(explicitSessionId ?? "nil") with \(resolved.sessionId)"
                )
            }
            return resolved
        }

        let inferredProvider = Self.normalizedAIProvider(from: resumeAppName)
        guard inferredProvider == "codex" || explicitProvider == "codex" else {
            return nil
        }

        let recentHistoryEntries = Array(appModel.codexHistoryEntries.suffix(64))
        let fallbackSignature = CodexResumeFallbackSignature(
            directory: directory,
            explicitSessionId: explicitSessionId,
            referenceTimestamp: referenceDate?.timeIntervalSince1970,
            claimedSessionFingerprint: Self.sessionIDFingerprint(claimedSessionIds),
            claimedSessionCount: claimedSessionIds.count,
            historyFingerprint: Self.codexHistoryFingerprint(recentHistoryEntries)
        )
        let stableFallbackSignature = StableCodexResumeFallbackSignature(
            directory: directory,
            explicitSessionId: explicitSessionId,
            referenceTimestamp: referenceDate?.timeIntervalSince1970,
            claimedSessionFingerprint: fallbackSignature.claimedSessionFingerprint,
            claimedSessionCount: fallbackSignature.claimedSessionCount
        )
        let cacheKey = ObjectIdentifier(session)
        if let cached = codexResumeFallbackCache[cacheKey],
           cached.signature == fallbackSignature {
            return cached.metadata
        }
        if explicitProvider == "codex",
           let explicitSessionId,
           let cached = codexResumeFallbackCache[cacheKey],
           cached.stableSignature == stableFallbackSignature,
           cached.metadata?.provider == "codex",
           cached.metadata?.sessionId == explicitSessionId {
            return cached.metadata
        }

        let observedCandidates = recentHistoryEntries.compactMap { entry -> CodexSessionResolver.Candidate? in
            let observedAt = Date(timeIntervalSince1970: entry.timestamp)
            guard let metadata = CodexSessionResolver.metadata(
                forSessionID: entry.sessionId,
                referenceDate: observedAt
            ) else {
                return nil
            }
            return CodexSessionResolver.Candidate(
                sessionId: metadata.sessionId,
                cwd: metadata.cwd,
                touchedAt: observedAt
            )
        }

        let filteredCandidates = observedCandidates.filter { !claimedSessionIds.contains($0.sessionId) }

        guard let sessionId = CodexSessionResolver.bestMatchingSessionID(
            forDirectory: directory,
            referenceDate: referenceDate,
            candidates: filteredCandidates
        ) else {
            let logMessage =
                """
                saveTabState: unresolved Codex resume metadata \
                dir=\(directory) explicitSession=\(session.effectiveAISessionId ?? "nil") \
                observedCandidates=\(observedCandidates.count) filtered=\(filteredCandidates.count)
                """
            if filteredCandidates.isEmpty {
                Log.trace(logMessage)
            } else {
                Log.info(logMessage)
            }
            if let explicitSessionId,
               explicitProvider == "codex",
               !claimedSessionIds.contains(explicitSessionId) {
                let preservedExplicit = (provider: "codex", sessionId: explicitSessionId)
                codexResumeFallbackCache[cacheKey] = CachedCodexResumeFallback(
                    signature: fallbackSignature,
                    stableSignature: stableFallbackSignature,
                    metadata: preservedExplicit
                )
                Log.info(
                    "saveTabState: preserving explicit Codex resume metadata sessionId=\(explicitSessionId) for dir=\(directory) despite unresolved replacement"
                )
                return preservedExplicit
            }
            if hasClaimedExplicitCodexSession {
                let retainedExplicit = explicitSessionId.map { (provider: "codex", sessionId: $0) }
                codexResumeFallbackCache[cacheKey] = CachedCodexResumeFallback(
                    signature: fallbackSignature,
                    stableSignature: stableFallbackSignature,
                    metadata: retainedExplicit
                )
                Log.info(
                    "saveTabState: retaining claimed Codex resume metadata sessionId=\(explicitSessionId ?? "nil") for dir=\(directory)"
                )
                return retainedExplicit
            }
            codexResumeFallbackCache[cacheKey] = CachedCodexResumeFallback(
                signature: fallbackSignature,
                stableSignature: stableFallbackSignature,
                metadata: nil
            )
            return nil
        }

        if explicitSessionId != sessionId || explicitProvider != "codex" {
            session.restoreAIMetadata(provider: "codex", sessionId: sessionId)
        }
        codexResumeFallbackCache[cacheKey] = CachedCodexResumeFallback(
            signature: fallbackSignature,
            stableSignature: stableFallbackSignature,
            metadata: (provider: "codex", sessionId: sessionId)
        )
        Log.trace("saveTabState: recovered Codex resume metadata from observed history for dir=\(directory)")
        return (provider: "codex", sessionId: sessionId)
    }

    private static func explicitResumeProvider(for session: TerminalSessionModel) -> String? {
        normalizedAIProvider(from: session.lastAIProvider)
    }

    private static func explicitResumeSessionId(for session: TerminalSessionModel) -> String? {
        normalizeAISessionId(session.lastAISessionId)
    }

    func persistedAIResumeMetadata(
        from session: TerminalSessionModel,
        resolvedResumeMetadata: (provider: String, sessionId: String)?,
        claimedSessionIds: Set<String> = []
    ) -> AIResumeOwnership.Metadata {
        if let resolvedResumeMetadata {
            return AIResumeOwnership.Metadata(
                provider: resolvedResumeMetadata.provider,
                sessionId: resolvedResumeMetadata.sessionId
            )
        }

        let explicitProvider = Self.explicitResumeProvider(for: session)
        let explicitSessionId = Self.explicitResumeSessionId(for: session)
        let preserved = AIResumeOwnership.sanitizeForPersistence(
            provider: explicitProvider,
            sessionId: explicitSessionId,
            claimedSessionIds: claimedSessionIds
        )
        if explicitSessionId != nil,
           preserved.sessionId == nil,
           explicitProvider == preserved.provider {
            session.restoreAIMetadata(provider: preserved.provider, sessionId: nil)
        }
        return preserved
    }

    static func sanitizeRestoredAIResumeOwnership(states: [SavedTabState]) -> [SavedTabState] {
        var claimedSessionIds = Set<String>()

        return states.map { state in
            let originalTopLevelCommand = normalizedResumeCommand(state.aiResumeCommand)
            let sanitizedPaneStates = state.paneStates?.map { paneState -> SavedTerminalPaneState in
                let commandMetadata = AIResumeParser.extractMetadata(
                    from: paneState.aiResumeCommand ?? ""
                )
                let sanitizedPane = AIResumeOwnership.sanitizeForPersistence(
                    provider: normalizedAIProvider(from: paneState.aiProvider) ?? commandMetadata?.provider,
                    sessionId: normalizeAISessionId(paneState.aiSessionId) ?? commandMetadata?.sessionId,
                    claimedSessionIds: claimedSessionIds
                )
                if let sessionId = sanitizedPane.sessionId {
                    claimedSessionIds.insert(sessionId)
                }

                let sanitizedCommand = sanitizedResumeCommand(
                    originalCommand: normalizedResumeCommand(paneState.aiResumeCommand),
                    originalCommandMetadata: commandMetadata,
                    sanitizedMetadata: sanitizedPane
                )

                return SavedTerminalPaneState(
                    paneID: paneState.paneID,
                    directory: paneState.directory,
                    scrollbackContent: paneState.scrollbackContent,
                    aiResumeCommand: sanitizedCommand,
                    aiProvider: sanitizedPane.provider,
                    aiSessionId: sanitizedPane.sessionId,
                    lastOutputAt: paneState.lastOutputAt,
                    knownRepoRoot: paneState.knownRepoRoot,
                    knownGitBranch: paneState.knownGitBranch
                )
            }

            let topLevelCommandMetadata = AIResumeParser.extractMetadata(
                from: state.aiResumeCommand ?? ""
            )
            let sanitizedTopLevel = AIResumeOwnership.sanitizeForPersistence(
                provider: normalizedAIProvider(from: state.aiProvider) ?? topLevelCommandMetadata?.provider,
                sessionId: normalizeAISessionId(state.aiSessionId) ?? topLevelCommandMetadata?.sessionId,
                claimedSessionIds: claimedSessionIds
            )
            if let sessionId = sanitizedTopLevel.sessionId {
                claimedSessionIds.insert(sessionId)
            }
            let sanitizedTopLevelCommand = sanitizedResumeCommand(
                originalCommand: originalTopLevelCommand,
                originalCommandMetadata: topLevelCommandMetadata,
                sanitizedMetadata: sanitizedTopLevel
            )

            return SavedTabState(
                tabID: state.tabID,
                selectedTabID: state.selectedTabID,
                customTitle: state.customTitle,
                color: state.color,
                directory: state.directory,
                selectedIndex: state.selectedIndex,
                tokenOptOverride: state.tokenOptOverride,
                scrollbackContent: state.scrollbackContent,
                aiResumeCommand: sanitizedTopLevelCommand,
                aiProvider: sanitizedTopLevel.provider,
                aiSessionId: sanitizedTopLevel.sessionId,
                splitLayout: state.splitLayout,
                focusedPaneID: state.focusedPaneID,
                paneStates: sanitizedPaneStates,
                createdAt: state.createdAt,
                repoGroupID: state.repoGroupID,
                knownRepoRoot: state.knownRepoRoot,
                knownGitBranch: state.knownGitBranch
            )
        }
    }

    private struct PersistedRepoIdentity {
        let rootPath: String
        let branch: String?
    }

    private static func persistedRepoIdentity(
        for session: TerminalSessionModel,
        directory: String,
        fallbackRoot: String? = nil
    ) -> PersistedRepoIdentity? {
        let directRoot = normalizedSavedRepoField(session.gitRootPath) ?? normalizedSavedRepoField(fallbackRoot)
        let storeIdentity = KnownRepoIdentityStore.shared.resolveIdentity(forPath: directory)
            ?? directRoot.flatMap { KnownRepoIdentityStore.shared.identity(forRootPath: $0) }
        guard let rootPath = directRoot ?? normalizedSavedRepoField(storeIdentity?.rootPath) else {
            return nil
        }
        let branch = normalizedSavedRepoField(session.gitBranch) ?? normalizedSavedRepoField(storeIdentity?.lastKnownBranch)
        return PersistedRepoIdentity(rootPath: rootPath, branch: branch)
    }

    private static func persistedRepoIdentity(from paneState: SavedTerminalPaneState) -> PersistedRepoIdentity? {
        guard let rootPath = normalizedSavedRepoField(paneState.knownRepoRoot) else {
            return nil
        }
        return PersistedRepoIdentity(
            rootPath: rootPath,
            branch: normalizedSavedRepoField(paneState.knownGitBranch)
        )
    }

    static func normalizedSavedRepoField(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func sanitizedResumeCommand(
        originalCommand: String?,
        originalCommandMetadata: AIResumeParser.ResumeMetadata?,
        sanitizedMetadata: AIResumeOwnership.Metadata
    ) -> String? {
        if let rebuilt = buildAIResumeCommand(
            provider: sanitizedMetadata.provider,
            sessionId: sanitizedMetadata.sessionId
        ) {
            return rebuilt
        }

        guard let originalCommand else { return nil }

        // Preserve legacy command-only metadata until restore-time resolution can
        // consume it. If sanitization removed the session identity because it was
        // already claimed elsewhere, drop the command too so duplicates still clear.
        if let originalCommandMetadata {
            if sanitizedMetadata.provider == originalCommandMetadata.provider,
               sanitizedMetadata.sessionId == originalCommandMetadata.sessionId {
                return originalCommand
            }
            return nil
        }

        return originalCommand
    }

    /// Build a resume command for an AI session running in the given directory.
    /// Returns nil if no resumable session is found.
    static func buildAIResumeCommand(appName: String?, directory: String, outputHint: String? = nil) -> String? {
        guard let resolved = resolveAIResumeMetadata(
            appName: appName,
            directory: directory,
            outputHint: outputHint
        ) else {
            return nil
        }
        return buildAIResumeCommand(provider: resolved.provider, sessionId: resolved.sessionId)
    }

    static func buildAIResumeCommand(
        appName: String?,
        directory: String,
        outputHint: String? = nil,
        aiProvider: String?,
        aiSessionId: String?,
        referenceDate: Date? = nil
    ) -> String? {
        guard let resolved = resolveAIResumeMetadata(
            appName: appName,
            directory: directory,
            outputHint: outputHint,
            explicitAIProvider: aiProvider,
            explicitAISessionId: aiSessionId,
            referenceDate: referenceDate
        ) else {
            return nil
        }
        return buildAIResumeCommand(provider: resolved.provider, sessionId: resolved.sessionId)
    }

    static func buildAIResumeCommand(provider: String?, sessionId: String?) -> String? {
        guard let provider = normalizedAIProvider(from: provider),
              let sessionId = normalizeAISessionId(sessionId) else {
            return nil
        }

        guard let tool = AIToolRegistry.allTools.first(where: { $0.resumeProviderKey == provider }),
              let format = tool.resumeFormat else {
            return nil
        }
        return format.buildCommand(sessionId: sessionId)
    }

    static func resolveAIResumeMetadataFromSavedState(
        paneState: SavedTerminalPaneState,
        fallbackAIProvider: String?,
        fallbackAISessionId: String?
    ) -> (provider: String, sessionId: String)? {
        let commandMetadata = AIResumeParser.extractMetadata(
            from: paneState.aiResumeCommand ?? ""
        )
        let resolvedProvider = normalizedAIProvider(from: paneState.aiProvider)
            ?? commandMetadata?.provider
            ?? normalizedAIProvider(from: fallbackAIProvider)
        let resolvedSessionId = normalizeAISessionId(paneState.aiSessionId)
            ?? commandMetadata?.sessionId
            ?? normalizeAISessionId(fallbackAISessionId)

        guard let resolvedProvider, let resolvedSessionId else {
            return nil
        }
        return (provider: resolvedProvider, sessionId: resolvedSessionId)
    }

    static func normalizedResumeReferenceDate(_ value: Date) -> Date? {
        return value == .distantPast ? nil : value
    }

    static func normalizedResumeReferenceDate(_ value: Date?) -> Date? {
        guard let value else { return nil }
        return value == .distantPast ? nil : value
    }

    static func codexHistoryFingerprint(_ entries: [HistoryEntry]) -> Int {
        var hasher = Hasher()
        hasher.combine(entries.count)
        if let first = entries.first {
            hasher.combine(first.sessionId)
            hasher.combine(first.timestamp.bitPattern)
        }
        if let last = entries.last {
            hasher.combine(last.sessionId)
            hasher.combine(last.timestamp.bitPattern)
        }
        for entry in entries.suffix(8) {
            hasher.combine(entry.sessionId)
            hasher.combine(entry.timestamp.bitPattern)
        }
        return hasher.finalize()
    }

    static func sessionIDFingerprint(_ sessionIds: Set<String>) -> Int {
        var hasher = Hasher()
        hasher.combine(sessionIds.count)
        for sessionId in sessionIds.sorted() {
            hasher.combine(sessionId)
        }
        return hasher.finalize()
    }

    static func resolveAIResumeMetadata(
        appName: String?,
        directory: String,
        outputHint: String? = nil,
        explicitAIProvider: String? = nil,
        explicitAISessionId: String? = nil,
        referenceDate: Date? = nil,
        claimedSessionIds: Set<String> = []
    ) -> (provider: String, sessionId: String)? {
        let canonicalDirectory = normalizedSessionDirectory(directory)
        let explicitProvider = normalizedAIProvider(from: explicitAIProvider)
        let explicitSessionId = normalizeAISessionId(explicitAISessionId)
        let liveProviderHint = aiResumeProviderCandidates(
            appName: appName,
            outputHint: outputHint,
            explicitProvider: nil
        ).first

        if let explicitProvider {
            if let resolved = resolvedAIResumeMetadata(
                provider: explicitProvider,
                sessionId: explicitSessionId,
                directory: canonicalDirectory,
                referenceDate: referenceDate,
                claimedSessionIds: claimedSessionIds
            ) {
                return resolved
            }

            // If we already have an explicit provider for a pane but no matching session
            // can be found in that provider/directory, avoid guessing another provider.
            // This keeps restore metadata deterministic and prevents cross-tab bleed-through.
            if explicitSessionId == nil {
                if liveProviderHint == nil || liveProviderHint == explicitProvider {
                    return nil
                }
            }
        }

        let inferredProviders = aiResumeProviderCandidates(
            appName: appName,
            outputHint: outputHint,
            explicitProvider: explicitProvider
        )
        for candidateProvider in inferredProviders {
            if let sessionId = findAIResumeSessionId(
                for: candidateProvider,
                directory: canonicalDirectory,
                referenceDate: referenceDate,
                claimedSessionIds: claimedSessionIds
            ) {
                return (provider: candidateProvider, sessionId: sessionId)
            }
        }

        return nil
    }

    static func aiResumeProviderCandidates(
        appName: String?,
        outputHint: String?,
        explicitProvider: String?
    ) -> [String] {
        var providers: [String] = []
        var seenProviders = Set<String>()

        func appendProvider(_ value: String?) {
            guard let provider = value, !provider.isEmpty else { return }
            guard seenProviders.insert(provider).inserted else { return }
            providers.append(provider)
        }

        if let appNameProvider = appName?.trimmingCharacters(in: .whitespacesAndNewlines) {
            appendProvider(normalizedAIProvider(from: appNameProvider))
        }

        if let hint = outputHint {
            appendProvider(
                CommandDetection.detectAppFromOutput(hint)
                    .flatMap { normalizedAIProvider(from: $0) }
                    .flatMap { outputProvider in
                        if outputProvider == explicitProvider { return nil }
                        return outputProvider
                    }
            )
        }

        appendProvider(explicitProvider)

        return providers
    }

    static func resolvedAIResumeMetadata(
        provider: String?,
        sessionId: String?,
        directory: String,
        referenceDate: Date?,
        claimedSessionIds: Set<String> = []
    ) -> (provider: String, sessionId: String)? {
        if let provider, let sessionId {
            guard !claimedSessionIds.contains(sessionId) else {
                Log.info("resolveAIResumeMetadata: explicit sessionId=\(sessionId) already claimed by another tab, skipping")
                return nil
            }
            Log.trace("resolveAIResumeMetadata: using explicit session metadata provider=\(provider), sessionId=\(sessionId)")
            return (provider: provider, sessionId: sessionId)
        }

        guard !directory.isEmpty,
              let provider,
              let foundSessionId = findAIResumeSessionId(
                  for: provider,
                  directory: directory,
                  referenceDate: referenceDate,
                  claimedSessionIds: claimedSessionIds
              ) else {
            return nil
        }
        return (provider: provider, sessionId: foundSessionId)
    }

    // Session Finder Registry → OverlayTabsModel+SessionFinder.swift

    func selectTab(id: UUID) {
        guard selectedTabID != id else { return }
        dismissHoverCard()
        LogEnhanced.tab("Switching tab", tabId: id, tabCount: tabs.count)

        // MARK: - Tab Switch Optimization: Capture state before switching

        // 1. Record previous tab index for directional animation
        let oldIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0

        // 2. Capture snapshot only when render suspension is enabled (tabs may
        //    have stale content). When suspension is off, tabs render continuously
        //    so the incoming view is already up-to-date — skip the expensive GPU readback.
        if isRenderSuspensionEnabled {
            captureCurrentTabSnapshot()
            isTerminalReady = false
        }

        // 4. Batch all state changes to minimize SwiftUI diff passes
        // Using direct assignment is faster than withTransaction for simple cases
        if isRenameVisible {
            clearRenameState(shouldFocus: false)
        }
        previousTabIndex = oldIndex
        selectedTabID = id

        // Clear notification style when switching to a tab (user acknowledged it),
        // unless the style is persistent (e.g., permission requests stay until resolved).
        if let index = tabs.firstIndex(where: { $0.id == id }),
           let style = tabs[index].notificationStyle, !style.persistent {
            tabs[index].notificationStyle = nil
        }

        // 5. Pre-cancel suspension before focus (optimization)
        cancelSuspension(for: id)
        if suspendedTabIDs.remove(id) != nil {
            logVisualState(reason: "selectTab: unsuspended selected tab")
        }

        focusSelected()
        updateSnippetContextForSelection()
        if isSearchVisible {
            refreshSearch()
        }

        // Defer non-critical work to after the tab switch completes.
        // These iterate collections or hit the file system — not needed for the
        // initial visual switch which should be as fast as possible.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            updateSuspensionState()
            MainActor.assumeIsolated {
                self.updateCurrentCandidate(from: ProxyIPCServer.shared.pendingCandidates)
                self.updateCurrentTask(from: ProxyIPCServer.shared.activeTasks)
                ConfigFileWatcher.shared.updateActiveDirectory(self.selectedTab?.session?.currentDirectory)
            }
        }

        // 6. Mark terminal as ready. When suspension is off, set immediately (no
        //    snapshot to display). When on, use a brief delay for the snapshot swap.
        if isRenderSuspensionEnabled {
            terminalReadyGeneration &+= 1
            let expectedGeneration = terminalReadyGeneration
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                guard let self, terminalReadyGeneration == expectedGeneration else { return }
                isTerminalReady = true
            }
        } else {
            isTerminalReady = true
        }
    }

    /// Handles a toolbar tab click. This dismisses the repo dashboard overlay
    /// even when the clicked tab is already selected.
    func handleTabBarSelection(id: UUID) {
        if activeDashboardGroupID != nil {
            activeDashboardGroupID = nil
        }
        guard selectedTabID != id else { return }
        selectTab(id: id)
    }

    // MARK: - Tab Switch Optimization: Snapshot Capture

    /// Captures a screenshot of the current terminal view for instant display during tab switch
    func captureCurrentTabSnapshot() {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            return
        }

        let snapshotView: NSView? = tabs[currentIndex].session?.existingRustTerminalView as NSView?
        if let terminalView = snapshotView {
            // Live capture from the terminal view
            guard let bitmapRep = terminalView.bitmapImageRepForCachingDisplay(in: terminalView.bounds) else {
                logVisualState(reason: "snapshot: skipped (no bitmap rep)")
                return
            }
            terminalView.cacheDisplay(in: terminalView.bounds, to: bitmapRep)

            let image = NSImage(size: terminalView.bounds.size)
            image.addRepresentation(bitmapRep)
            tabs[currentIndex].cachedSnapshot = image
            // Also cache on the session for when the view is torn down later
            tabs[currentIndex].session?.lastRenderedSnapshot = image
        } else if let cached = tabs[currentIndex].session?.lastRenderedSnapshot {
            // View is not in the hierarchy (distant-tab optimization removed it),
            // but we have a previously cached frame from the session.
            tabs[currentIndex].cachedSnapshot = cached
            Log.trace("snapshot: used session-cached frame for tab \(selectedTabID)")
        } else {
            logVisualState(reason: "snapshot: skipped (no terminal view, no cached frame)")
            return
        }

        // Also capture cursor position and prompt for cursor-first rendering
        if let session = tabs[currentIndex].session {
            tabs[currentIndex].lastPromptText = session.displayPath()
            // Cursor position would need terminal view support - using placeholder
            tabs[currentIndex].lastCursorPosition = CGPoint(x: 50, y: 20)
        }

        // Memory optimization: clear snapshots for distant tabs (keep only ± 2)
        cleanupDistantSnapshots(currentIndex: currentIndex)
    }

    /// Clears cached snapshots for tabs far from the current position to limit memory usage
    func cleanupDistantSnapshots(currentIndex: Int) {
        for i in 0 ..< tabs.count {
            if abs(i - currentIndex) > 2 {
                tabs[i].cachedSnapshot = nil
            }
        }
    }

    // Tab Switch Optimization → OverlayTabsModel+TabSwitchOptimization.swift

    // MARK: - Token Optimization (CTO) Per-Tab Control

    /// Toggles the token optimization override for a tab.
    /// Cycling depends on the global mode:
    /// - `allTabs`: default (on) -> forceOff -> default (on)
    /// - `aiOnly`: default -> forceOff -> forceOn -> default
    /// - `manual`: default (off) -> forceOn -> default (off)
    func toggleTokenOpt(for tabID: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        let mode = FeatureSettings.shared.tokenOptimizationMode
        guard mode != .off else { return }

        let current = tabs[index].tokenOptOverride
        let next: TabTokenOptOverride
        switch mode {
        case .off:
            return // Guarded above, but required for exhaustive switch
        case .allTabs:
            // Toggle: default (on) <-> forceOff
            next = (current == .default) ? .forceOff : .default
        case .aiOnly:
            // 3-state cycle: default -> forceOff -> forceOn -> default
            switch current {
            case .default: next = .forceOff
            case .forceOff: next = .forceOn
            case .forceOn: next = .default
            }
        case .manual:
            // Toggle: default (off) <-> forceOn
            next = (current == .default) ? .forceOn : .default
        }

        tabs[index].tokenOptOverride = next

        // Sync override to session so activeAppName.didSet can access it
        tabs[index].session?.tokenOptOverride = next

        // Recalculate flag file for this tab's session
        if let sessionID = tabs[index].session?.tabIdentifier {
            let isAI = tabs[index].session?.activeAppName != nil
            let decision = CTOFlagManager.recalculate(
                sessionID: sessionID,
                mode: mode,
                override: next,
                isAIActive: isAI
            )

            CTORuntimeMonitor.shared.recordDecision(
                sessionID: sessionID,
                mode: mode,
                override: next,
                isAIActive: isAI,
                previousState: decision.previousState,
                nextState: decision.nextState,
                changed: decision.changed,
                reason: decisionReason(
                    mode: mode,
                    override: next,
                    isAIActive: isAI
                )
            )
        }

        Log.info("CTO toggle: tab \(tabID) override changed to \(next.rawValue)")
    }

    /// Recalculates CTO flag files for all open tabs.
    /// Called when the global mode changes.
    func recalculateAllCTOFlags() {
        let mode = FeatureSettings.shared.tokenOptimizationMode
        if mode == .off {
            let removed = CTOFlagManager.removeAllFlags()
            CTORuntimeMonitor.shared.recordManagerBulkRemove(count: removed)
            return
        }

        for tab in tabs {
            guard let sessionID = tab.session?.tabIdentifier else { continue }
            guard let session = tab.session, !session.ctoFlagDeferred else {
                if let session = tab.session {
                    CTORuntimeMonitor.shared.recordDeferredSkip(
                        sessionID: session.tabIdentifier,
                        reason: "mode-change-before-first-prompt",
                        mode: mode,
                        override: tab.tokenOptOverride,
                        isAIActive: tab.session?.activeAppName != nil
                    )
                }
                continue
            }
            let isAI = tab.session?.activeAppName != nil
            let decision = CTOFlagManager.recalculate(
                sessionID: sessionID,
                mode: mode,
                override: tab.tokenOptOverride,
                isAIActive: isAI
            )
            CTORuntimeMonitor.shared.recordDecision(
                sessionID: sessionID,
                mode: mode,
                override: tab.tokenOptOverride,
                isAIActive: isAI,
                previousState: decision.previousState,
                nextState: decision.nextState,
                changed: decision.changed,
                reason: decisionReason(
                    mode: mode,
                    override: tab.tokenOptOverride,
                    isAIActive: isAI
                )
            )
        }
    }

    // MARK: - Tab Notification Styling

    /// Sets a notification style on a tab to indicate a state (waiting, error, etc.)
    /// - Parameters:
    ///   - style: The style to apply, or nil to clear
    ///   - tabID: The tab to style (defaults to selected tab)
    /// - Returns: `true` when the style state actually changed and was published.
    @discardableResult
    func setNotificationStyle(_ style: TabNotificationStyle?, for tabID: UUID? = nil) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))
        let targetID = tabID ?? selectedTabID
        guard let index = tabs.firstIndex(where: { $0.id == targetID }) else { return false }

        if tabs[index].notificationStyle == style {
            return false
        }

        tabs[index].notificationStyle = style
        if let style {
            let desc = style.icon ?? "border/color"
            Log.info("Tab notification style set: \(desc) for tab \(targetID)")
        } else {
            Log.info("Tab notification style cleared for tab \(targetID)")
        }
        return true
    }

    /// Sets a notification style on the tab associated with a terminal session
    func setNotificationStyle(_ style: TabNotificationStyle?, forSession session: TerminalSessionModel) {
        guard let tab = tabs.first(where: { tab in
            tab.splitController.terminalSessions.contains { _, candidate in candidate === session }
        }) else { return }
        _ = setNotificationStyle(style, for: tab.id)
    }

    /// Clears persistent notification style (e.g., permission red border) when
    /// the session resumes after a permission answer.
    func clearPersistentStyle(for tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].notificationStyle?.persistent == true else { return }
        tabs[index].notificationStyle = nil
        Log.info("Persistent tab style cleared for tab \(tabID) (permission resolved)")
    }

    @discardableResult
    func clearPersistentNotificationStyle(on tabID: UUID) -> Bool {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].notificationStyle?.persistent == true else { return false }
        clearPersistentStyle(for: tabID)
        return true
    }

    /// Clears notification style from a tab
    func clearNotificationStyle(for tabID: UUID? = nil) {
        setNotificationStyle(nil, for: tabID)
    }

    @discardableResult
    func applyNotificationStyle(to tabID: UUID, stylePreset: String, config: [String: String]) -> Bool {
        dispatchPrecondition(condition: .onQueue(.main))

        guard tabs.contains(where: { $0.id == tabID }) else {
            return false
        }

        let style: TabNotificationStyle? = stylePreset == "clear"
            ? nil
            : buildNotificationStyle(preset: stylePreset, config: config)

        return setNotificationStyle(style, for: tabID)
    }

    /// Builds a TabNotificationStyle from preset and config
    func buildNotificationStyle(preset: String, config: [String: String]) -> TabNotificationStyle {
        // Start with preset
        var style: TabNotificationStyle
        switch preset {
        case "waiting":
            style = .waiting
        case "error":
            style = .error
        case "success":
            style = .success
        case "attention":
            style = .attention
        case "custom":
            // Explicit custom: start blank, all fields come from config overrides below
            style = TabNotificationStyle()
        default:
            style = TabNotificationStyle()
        }

        // Apply custom overrides from config
        if let customColor = config["customColor"], !customColor.isEmpty {
            style.titleColor = colorFromString(customColor)
            style.iconColor = colorFromString(customColor)
        }

        // Allow explicit enable/disable of style features
        if let italic = config["italic"]?.lowercased() {
            style.isItalic = (italic == "true" || italic == "1")
        }

        if let bold = config["bold"]?.lowercased() {
            style.isBold = (bold == "true" || bold == "1")
        }

        if let pulse = config["pulse"]?.lowercased() {
            style.shouldPulse = (pulse == "true" || pulse == "1")
        }

        // Border configuration
        if let borderWidthStr = config["borderWidth"],
           let borderWidthDouble = Double(borderWidthStr),
           borderWidthDouble > 0 {
            style.borderWidth = CGFloat(borderWidthDouble)
            // Use customColor for border if specified, otherwise use titleColor
            if let customColor = config["customColor"], !customColor.isEmpty {
                style.borderColor = colorFromString(customColor)
            } else if let titleColor = style.titleColor {
                style.borderColor = titleColor
            } else {
                style.borderColor = .red // Default border color
            }
            // Border dash pattern
            switch config["borderStyle"]?.lowercased() {
            case "dotted":
                style.borderDash = [3, 3]
            case "dashed":
                style.borderDash = [6, 4]
            default:
                break // solid — nil dash
            }
        }

        if let persistentStr = config["persistent"]?.lowercased() {
            style.persistent = (persistentStr == "true" || persistentStr == "1")
        }

        return style
    }

    /// Converts color string to SwiftUI Color
    func colorFromString(_ colorName: String) -> Color {
        switch colorName.lowercased() {
        case "red": return .red
        case "orange": return .orange
        case "yellow": return .yellow
        case "green": return .green
        case "blue": return .blue
        case "purple": return .purple
        case "pink": return .pink
        default: return .primary
        }
    }

    // MARK: - Notification Action Handlers

    /// Resolve a tab from a target, preferring the pre-resolved tabID to avoid
    /// redundant TabResolver calls. Falls back to full resolution if no tabID.
    func resolveTab(for target: TabTarget) -> OverlayTab? {
        if let tabID = target.tabID {
            return tabs.first(where: { $0.id == tabID })
        }
        return TabResolver.resolve(target, in: tabs)
    }

    /// Finds the tab matching the target and selects it.
    @discardableResult
    func focusTab(id tabID: UUID) -> Bool {
        guard tabs.contains(where: { $0.id == tabID }) else {
            return false
        }
        selectTab(id: tabID)
        return true
    }

    func focusTab(for target: TabTarget) {
        guard let tab = resolveTab(for: target) else {
            Log.info("focusTab: No tab found for '\(target.tool)'")
            return
        }
        _ = focusTab(id: tab.id)
    }

    @discardableResult
    func setBadge(on tabID: UUID, text: String, color: String) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            return false
        }
        var style = tab.notificationStyle ?? TabNotificationStyle()
        style.badgeText = text
        style.badgeColor = colorFromString(color)
        return setNotificationStyle(style, for: tabID)
    }

    @discardableResult
    func insertSnippet(id snippetId: String, on tabID: UUID, autoExecute: Bool) -> Bool {
        guard let entry = SnippetManager.shared.entries.first(where: { $0.snippet.id == snippetId }) else {
            Log.warn("insertSnippet: Snippet '\(snippetId)' not found")
            return false
        }
        guard tabs.contains(where: { $0.id == tabID }) else {
            return false
        }
        _ = focusTab(id: tabID)
        insertSnippet(entry)
        Log.info("insertSnippet: Inserted snippet '\(snippetId)' for tab \(tabID)")
        return true
    }

    /// Returns true if the given target matches the currently selected tab.
    func isToolInSelectedTab(_ target: TabTarget) -> Bool {
        // Only suppress notifications when we CONFIDENTLY know the event's tab
        // is the selected tab. Without a tabID, the resolver's best guess could
        // match the selected tab simply because it's the most active — which would
        // suppress ALL notifications when Chau7 is focused.
        guard let tabID = target.tabID else { return false }
        return tabID == selectedTabID
    }

    // MARK: - Tab Bar Recovery

    /// Forces a complete re-render of the tab bar by incrementing the refresh token.
    /// Use this to recover from SwiftUI rendering issues where tabs disappear visually
    /// but remain accessible via keyboard shortcuts.
    func refreshTabBar() {
        dispatchPrecondition(condition: .onQueue(.main))
        let oldToken = tabBarRefreshToken
        tabBarRefreshToken += 1
        LogEnhanced.recovery("Forcing tab bar re-render", metadata: [
            "tabCount": String(tabs.count),
            "oldToken": String(oldToken),
            "newToken": String(tabBarRefreshToken),
            "lastRendered": String(lastReportedRenderedCount),
            "memory": String(format: "%.1fMB", PerfTracker.currentMemoryMB() ?? 0)
        ])
        // Recreate the toolbar entirely - this is the only reliable recovery when
        // the NSHostingView in the toolbar becomes stale after window hide/show cycles.
        // Direct manipulation of the hosting view causes crashes (EXC_BREAKPOINT).
        if let window = overlayWindow {
            TabBarToolbarDelegate.shared.recreateToolbar(for: window)
            TabBarToolbarDelegate.shared.updateToolbarItemSizing(for: window)
        }

        // NOTE: Do NOT reset lastPreferenceUpdateTime here.
        // Only real preference updates from the view should reset it.
        // This ensures watchdogRefreshAttempts properly increments to the
        // 3-attempt limit if recovery doesn't actually restore the view.

        // Log confirmation after state update
        Log.info("refreshTabBar: token updated \(oldToken) -> \(tabBarRefreshToken), tabs=\(tabs.count)")
    }

    // MARK: - Force Refresh Terminal

    /// Forces the selected tab's terminal view to re-render.
    /// Recovers from stuck isHidden, disabled Metal views, or stale display state.
    func forceRefreshSelectedTab() {
        dispatchPrecondition(condition: .onQueue(.main))

        // 1. Reset model-level gates
        isTerminalReady = true
        cancelSuspension(for: selectedTabID)
        suspendedTabIDs.remove(selectedTabID)

        guard let session = selectedTab?.session else {
            Log.warn("forceRefreshSelectedTab: no session for selectedTabID=\(selectedTabID)")
            return
        }

        // 2. Unhide and kick the Rust terminal view + Metal coordinator
        //    Hierarchy: UnifiedTerminalContainerView → RustTerminalContainerView → RustTerminalView
        if let rustView = session.existingRustTerminalView {
            rustView.isHidden = false
            rustView.notifyUpdateChanges = true
            rustView.needsDisplay = true
            rustView.setEventMonitoringEnabled(true)
            // Unhide container + Metal view
            if let container = rustView.superview as? RustTerminalContainerView {
                container.isHidden = false
                if let metalView = container.rustMetalCoordinator?.metalView {
                    metalView.isHidden = false
                    metalView.needsDisplay = true
                }
            }
            Log.info("forceRefreshSelectedTab: unhid Rust view + Metal for tab \(selectedTabID)")
        }
        // 3. Re-focus
        focusSelected()

        logVisualState(reason: "forceRefreshSelectedTab")
    }

    /// Called by the view to report how many tabs were actually rendered.
    /// Used by the watchdog to detect render failures.
    func reportRenderedTabCount(_ count: Int) {
        lastReportedRenderedCount = count
        lastPreferenceUpdateTime = Date()
    }

    /// Called by the view to report the tab bar's actual rendered size.
    /// Used for visibility-based recovery (detect invisible but "rendered" tabs).
    func reportTabBarSize(_ size: CGSize) {
        lastReportedTabBarSize = size
        lastPreferenceUpdateTime = Date()
        let now = Date()
        let expectedWidth = CGFloat(max(1, tabs.count)) * minWidthPerTab
        if now.timeIntervalSince(lastTabBarVisibilityLogAt) > 1.0,
           size.width <= 0 || size.height <= 0 || size.height < 10 || size.width < expectedWidth {
            lastTabBarVisibilityLogAt = now
            let window = overlayWindow
            let frameText = window.map { "windowFrame=\($0.frame.width)x\($0.frame.height) content=\($0.contentLayoutRect.width)x\($0.contentLayoutRect.height)" } ?? "window=none"
            Log.warn("Tab bar size report is suspicious: rendered=\(Int(size.width))x\(Int(size.height)), expectedWidth>=\(Int(expectedWidth)), tabs=\(tabs.count), \(frameText)")
        }
    }

    func reportTabBarDropFrame(_ frame: CGRect) {
        tabBarDropFrame = frame
        lastPreferenceUpdateTime = Date()
    }

    /// Updates visibility state for the tab bar (e.g., window hidden/shown).
    /// This prevents the watchdog from firing while the window is not visible.
    func noteTabBarVisibilityChanged(isVisible: Bool) {
        if isTabBarVisible != isVisible {
            let window = overlayWindow
            let frameText = window.map { "windowFrame=\($0.frame.width)x\($0.frame.height) visible=\($0.isVisible) occluded=\(!($0.occlusionState.contains(.visible)))" } ?? "window=none"
            let visibility = isVisible ? "visible" : "hidden"
            Log.trace("Tab bar visibility changed: \(visibility), tabs=\(tabs.count), refreshToken=\(tabBarRefreshToken), \(frameText)")
        }
        isTabBarVisible = isVisible
        watchdogRefreshAttempts = 0
        if isVisible {
            // Wait for real preference updates before watchdog checks resume.
            lastReportedRenderedCount = -1
            lastPreferenceUpdateTime = Date()
        }
    }

    /// Starts the tab bar watchdog timer.
    /// The watchdog periodically checks if the view is rendering all tabs.
    func startTabBarWatchdog() {
        guard tabBarWatchdogTimer == nil else { return }
        consecutiveHealthyChecks = 0
        scheduleWatchdog(interval: 3.0)
        Log.info("TabBar watchdog: started")
    }

    /// Reschedule the watchdog at a new interval.
    private func scheduleWatchdog(interval: TimeInterval) {
        tabBarWatchdogTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            self?.checkTabBarHealth()
        }
        timer.resume()
        tabBarWatchdogTimer = timer
    }

    /// Reset watchdog to fast interval (call on tab add/remove/switch).
    func resetWatchdogToFastInterval() {
        guard tabBarWatchdogTimer != nil else { return }
        consecutiveHealthyChecks = 0
        scheduleWatchdog(interval: 3.0)
    }

    /// Stops the tab bar watchdog timer.
    func stopTabBarWatchdog() {
        tabBarWatchdogTimer?.cancel()
        tabBarWatchdogTimer = nil
    }

    /// Manually force a tab into the idle dropdown by resetting its activity time.
    func forceTabIdle(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }), id != selectedTabID else { return }
        // Reset the session's last activity to distant past so it appears idle
        tabs[index].session?.resetActivityForIdleGrouping()
        suspendedTabIDs.insert(id)
        Log.info("Tab \(id) manually moved to idle")
    }

    /// Callback for moving a tab to another window. Wired by AppDelegate.
    var onMoveTabToWindow: ((UUID, Int) -> Void)?
    /// Callback for moving a repo group to another window. Wired by AppDelegate.
    var onMoveGroupToWindow: ((String, Int) -> Void)? // (repoGroupID, targetWindowIndex)
    /// Callback to refresh window titles on demand (for context menu). Wired by AppDelegate.
    var onRefreshWindowTitles: (() -> Void)?

    /// List of other windows for the "Move to Window" context menu.
    /// Populated by AppDelegate.
    var otherWindowTitles: [WindowMenuItem] = []

    struct WindowMenuItem: Identifiable {
        let id: Int // window index
        let title: String
    }

    /// Remove a tab from this model and return it for transfer to another window.
    /// If this is the last tab, leave the window empty and lazily recreate a fresh
    /// tab the next time the window is shown.
    func extractTabForWindowTransfer(id: UUID) -> OverlayTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let tab = tabs[index]
        tabs.remove(at: index)
        suspendedTabIDs.remove(id)
        if tabs.isEmpty {
            selectedTabID = UUID()
            needsFreshTabOnShow = true
        } else if selectedTabID == id {
            let newIndex = min(max(0, index - 1), tabs.count - 1)
            selectedTabID = tabs[newIndex].id
        }
        updateSnippetContextForSelection()
        return tab
    }

    /// Remove all tabs in a repo group and return them for transfer to another window.
    /// If this empties the source window, a fresh tab will be created lazily when
    /// the window is shown again.
    func extractGroupForWindowTransfer(repoGroupID: String) -> [OverlayTab] {
        let groupTabs = tabs.filter { $0.repoGroupID == repoGroupID }
        guard !groupTabs.isEmpty else { return [] }
        let groupIDs = Set(groupTabs.map(\.id))
        tabs.removeAll { groupIDs.contains($0.id) }
        for id in groupIDs {
            suspendedTabIDs.remove(id)
        }
        if tabs.isEmpty {
            selectedTabID = UUID()
            needsFreshTabOnShow = true
        } else if groupIDs.contains(selectedTabID) {
            selectedTabID = tabs.first?.id ?? UUID()
        }
        updateSnippetContextForSelection()
        return groupTabs
    }

    /// Suspend rendering for tabs idle 10+ minutes, but only if render suspension
    /// is enabled. The idle dropdown (visual grouping) works independently — tabs
    /// appear in the dropdown based on lastActivityDate, without stopping rendering.
    func suspendIdleTabs() {
        guard isRenderSuspensionEnabled else { return }
        let threshold = FeatureSettings.shared.idleTabThresholdSeconds
        let now = Date()
        for tab in tabs where tab.id != selectedTabID {
            guard let session = tab.displaySession ?? tab.session else { continue }
            let isIdle = now.timeIntervalSince(session.lastActivityDate) > threshold
            if isIdle, !suspendedTabIDs.contains(tab.id) {
                suspendedTabIDs.insert(tab.id)
            } else if !isIdle, suspendedTabIDs.contains(tab.id) {
                suspendedTabIDs.remove(tab.id)
            }
        }
    }

    /// Count tabs currently idle beyond the configured threshold (excluding the selected tab).
    func idleTabCount() -> Int {
        let threshold = FeatureSettings.shared.idleTabThresholdSeconds
        let now = Date()
        return tabs.filter { tab in
            guard let session = tab.displaySession ?? tab.session,
                  tab.id != selectedTabID else { return false }
            return now.timeIntervalSince(session.lastActivityDate) > threshold
        }.count
    }

    func checkTabBarHealth() {
        dispatchPrecondition(condition: .onQueue(.main))

        // Suspend rendering for idle tabs in the dropdown (saves GPU/CPU).
        // Resume happens in selectTab() when a tab is selected.
        if FeatureSettings.shared.groupIdleTabs {
            suspendIdleTabs()
        }

        guard shouldCheckTabBarHealth() else {
            watchdogRefreshAttempts = 0
            return
        }
        // When idle tabs are grouped in the dropdown, fewer tabs render in the bar.
        // Use visible count (total minus idle) to avoid false watchdog triggers.
        let idleCount = FeatureSettings.shared.groupIdleTabs ? idleTabCount() : 0
        let expected = tabs.count - idleCount
        let rendered = lastReportedRenderedCount
        let size = lastReportedTabBarSize
        let now = Date()

        // Skip check if view hasn't reported yet
        if rendered < 0 {
            return
        }

        var needsRecovery = false
        var reason = ""

        // Check 1: Zero rendered count
        if expected > 0, rendered == 0 {
            needsRecovery = true
            reason = "rendered=0, expected=\(expected)"
        }

        // Check 2: Tabs rendered but size is suspiciously small (visibility issue)
        // Only check if rendered count seems OK but size suggests invisibility
        if !needsRecovery, expected > 0, rendered > 0 {
            let minExpectedWidth = CGFloat(expected) * minWidthPerTab
            if size.width < minExpectedWidth || size.height < 10 {
                needsRecovery = true
                reason = "size too small: \(Int(size.width))x\(Int(size.height)), expected width >= \(Int(minExpectedWidth))"
            }
        }

        // Check 3: Rendered count significantly mismatched after a quiet period.
        // Allow ±2 tolerance to avoid false triggers during tab add/remove transitions
        // and idle tab grouping changes.
        if !needsRecovery, expected > 0, rendered > 0, abs(rendered - expected) > 2 {
            let timeSinceLastUpdate = now.timeIntervalSince(lastPreferenceUpdateTime)
            if timeSinceLastUpdate > stalenessThreshold {
                needsRecovery = true
                reason = "rendered mismatch: rendered=\(rendered), expected=\(expected), lastUpdate=\(Int(timeSinceLastUpdate))s"
            }
        }

        if needsRecovery {
            let timeSinceLastRefresh = now.timeIntervalSince(lastForcedRefreshAt)
            if timeSinceLastRefresh < refreshCooldown {
                watchdogSkipCount += 1
                lastWatchdogReason = reason
                Log.info("TabBar watchdog: skipping refresh (cooldown \(Int(refreshCooldown))s, reason=\(reason))")
                emitWatchdogSummaryIfNeeded(now: now)
                return
            }
            lastForcedRefreshAt = now
            watchdogRefreshAttempts += 1
            if watchdogRefreshAttempts <= 3 {
                watchdogRecoveryCount += 1
                lastWatchdogReason = reason
                Log.warn("TabBar watchdog: \(reason), attempt \(watchdogRefreshAttempts), forcing refresh")
                if let window = overlayWindow {
                    TabBarToolbarDelegate.shared.updateToolbarItemSizing(for: window)
                }
                refreshTabBar()
            } else if watchdogRefreshAttempts == 4 {
                Log.error("TabBar watchdog: refresh failed after 3 attempts, pausing retries for 60s")
            } else if watchdogRefreshAttempts >= 24 {
                // After ~60s pause (20 cycles × 3s), reset and try again.
                // The underlying issue may have resolved (e.g., window resized,
                // space switched, or hot-swapped binary with fix).
                watchdogRefreshAttempts = 0
                Log.info("TabBar watchdog: resetting attempt counter, will retry")
            }
            emitWatchdogSummaryIfNeeded(now: now)
        } else {
            watchdogRefreshAttempts = 0
            consecutiveHealthyChecks += 1
            // Slow down when everything is healthy
            if consecutiveHealthyChecks >= 3 {
                scheduleWatchdog(interval: 10.0)
            }
        }
    }

    func emitWatchdogSummaryIfNeeded(now: Date) {
        let elapsed = now.timeIntervalSince(lastWatchdogSummaryAt)
        guard elapsed >= 60 else { return }
        Log.info("TabBar watchdog summary: refreshes=\(watchdogRecoveryCount) skips=\(watchdogSkipCount) lastReason=\(lastWatchdogReason)")
        watchdogRecoveryCount = 0
        watchdogSkipCount = 0
        lastWatchdogSummaryAt = now
    }

    func shouldCheckTabBarHealth() -> Bool {
        guard isTabBarVisible else { return false }
        guard let window = overlayWindow else { return false }
        if !window.isVisible || window.isMiniaturized {
            return false
        }
        if #available(macOS 10.9, *) {
            if !window.occlusionState.contains(.visible) {
                return false
            }
        }
        return true
    }

    // MARK: - Tab Reordering

    func moveTab(id: UUID, toIndex: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let fromIndex = tabs.firstIndex(where: { $0.id == id }) else { return }
        let clampedIndex = max(0, min(toIndex, tabs.count))
        let adjustedIndex = clampedIndex > fromIndex ? clampedIndex - 1 : clampedIndex
        guard adjustedIndex != fromIndex else { return }
        let tab = tabs.remove(at: fromIndex)
        tabs.insert(tab, at: adjustedIndex)
        Log.info("Moved tab \(id) to index \(adjustedIndex)")
    }

    /// Moves a tab from one index to another. Used at drag-end for Chrome/Safari style reordering.
    func moveTab(fromIndex source: Int, toIndex destination: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard source != destination,
              source >= 0, source < tabs.count,
              destination >= 0, destination < tabs.count else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination)
        Log.info("Moved tab from index \(source) to \(destination)")
    }

    func moveCurrentTabRight() {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }),
              index < tabs.count - 1 else { return }
        tabs.swapAt(index, index + 1)
        Log.info("Moved tab right to index \(index + 1)")
    }

    func moveCurrentTabLeft() {
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }),
              index > 0 else { return }
        tabs.swapAt(index, index - 1)
        Log.info("Moved tab left to index \(index - 1)")
    }

    func showTabColorPicker() {
        // Open rename dialog which includes color picker
        beginRenameSelected()
    }

    func copyOrInterrupt() {
        selectedTab?.session?.copyOrInterrupt()
    }

    func paste() {
        selectedTab?.session?.paste()
    }

    func zoomIn() {
        selectedTab?.session?.zoomIn()
    }

    func zoomOut() {
        selectedTab?.session?.zoomOut()
    }

    func zoomReset() {
        selectedTab?.session?.zoomReset()
    }

    func toggleSearch() {
        isSearchVisible.toggle()
        logVisualState(reason: "toggleSearch: \(isSearchVisible)")
        if isSearchVisible {
            isRenameVisible = false
            isSnippetManagerVisible = false
            let defaults = FeatureSettings.shared
            isCaseSensitive = defaults.findCaseSensitiveDefault
            isRegexSearch = defaults.findRegexDefault
            isSemanticSearch = false
            searchError = nil
            refreshSearch()
        } else {
            searchQuery = ""
            searchResults = []
            searchMatchCount = 0
            searchError = nil
            isSemanticSearch = false
            // Only clear search for the current tab, not all tabs
            selectedTab?.session?.clearSearch()
            focusSelected()
        }
    }

    func refreshSearch() {
        guard !searchQuery.isEmpty else {
            searchResults = []
            searchMatchCount = 0
            searchError = nil
            selectedTab?.session?.clearSearch()
            return
        }
        guard let session = selectedTab?.session else { return }
        let result: TerminalSessionModel.SearchSummary
        if isSemanticSearch, FeatureSettings.shared.isSemanticSearchEnabled {
            result = session.updateSemanticSearch(
                query: searchQuery,
                maxMatches: 400,
                maxPreviewLines: 12
            )
        } else {
            // Pass case sensitivity setting to the search engine
            result = session.updateSearch(
                query: searchQuery,
                maxMatches: 400,
                maxPreviewLines: 12,
                caseSensitive: isCaseSensitive,
                regexEnabled: isRegexSearch
            )
        }
        searchResults = result.previewLines
        searchMatchCount = result.count
        searchError = result.error
    }

    func nextMatch() {
        selectedTab?.session?.nextMatch()
        // Note: Don't call refreshSearch() here - it recomputes all matches
        // which is wasteful when just moving to the next match
    }

    func previousMatch() {
        selectedTab?.session?.previousMatch()
        // Note: Don't call refreshSearch() here -- just move the highlight index
    }

    func beginRenameSelected() {
        guard let tab = selectedTab else { return }
        dismissHoverCard()
        isSearchVisible = false
        renameTabID = tab.id
        renameText = tab.displayTitle
        renameColor = tab.color
        renameOriginalTitle = renameText
        renameOriginalColor = renameColor
        isRenameVisible = true
        logVisualState(reason: "beginRenameSelected")
    }

    func beginRename(tabID: UUID) {
        selectTab(id: tabID)
        beginRenameSelected()
    }

    func commitRename() {
        guard let renameTabID,
              let index = tabs.firstIndex(where: { $0.id == renameTabID }) else {
            cancelRename()
            return
        }
        let trimmed = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let titleChanged = trimmed != renameOriginalTitle
        let colorChanged = renameColor != renameOriginalColor

        Log.info("Tab rename commit: tabID=\(renameTabID), titleChanged=\(titleChanged), colorChanged=\(colorChanged), newTitle=\"\(trimmed)\"")

        if trimmed.isEmpty {
            tabs[index].customTitle = nil
        } else if titleChanged {
            tabs[index].customTitle = trimmed
        }
        tabs[index].session?.tabTitleOverride = tabs[index].customTitle
        tabs[index].color = renameColor
        if colorChanged {
            tabs[index].autoColor = nil
            tabs[index].isManualColorOverride = true
        }
        clearRenameState(shouldFocus: true)

        // With @Observable, tab property mutations auto-trigger SwiftUI updates.
    }

    func cancelRename() {
        clearRenameState(shouldFocus: true)
    }

    func clearRenameState(shouldFocus: Bool) {
        isRenameVisible = false
        renameTabID = nil
        renameOriginalTitle = ""
        renameOriginalColor = renameColor
        logVisualState(reason: "renameCleared")
        if shouldFocus {
            focusSelected()
        }
    }

    // MARK: - Background Rendering Suspension

    func configureRenderSuspension(enabled: Bool, delay: TimeInterval) {
        isRenderSuspensionEnabled = enabled
        renderSuspensionDelay = max(0, delay)
        suspendWorkItems.values.forEach { $0.cancel() }
        suspendWorkItems.removeAll()
        updateSuspensionState()
        logVisualState(reason: "renderSuspension: enabled=\(enabled) delay=\(renderSuspensionDelay)")
    }

    func isTabSuspended(_ id: UUID) -> Bool {
        suspendedTabIDs.contains(id)
    }

    /// Fresh MCP tabs need a real terminal view at least once so background
    /// exec/input requests have a PTY to land on. Once a terminal view has
    /// attached, the retained Rust view keeps the session alive even if the tab
    /// later drops out of the visible hierarchy.
    func shouldKeepTabInLiveHierarchy(tab: OverlayTab, index: Int) -> Bool {
        let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0
        let isNearCurrent = abs(index - selectedIndex) <= 1
        let isNearPrevious = abs(index - previousTabIndex) <= 1
        if isNearCurrent || isNearPrevious {
            return true
        }

        guard tab.isMCPControlled else { return false }
        return tab.session?.existingRustTerminalView == nil
    }

    func updateSuspensionState() {
        let previousSuspended = suspendedTabIDs
        let validIDs = Set(tabs.map { $0.id })

        suspendWorkItems
            .filter { !validIDs.contains($0.key) }
            .forEach { $0.value.cancel() }
        suspendWorkItems = suspendWorkItems.filter { validIDs.contains($0.key) }
        suspendedTabIDs = suspendedTabIDs.intersection(validIDs)
        liveRenderExemptTabIDs = liveRenderExemptTabIDs.intersection(validIDs)

        guard isRenderSuspensionEnabled else {
            suspendWorkItems.values.forEach { $0.cancel() }
            suspendWorkItems.removeAll()
            suspendedTabIDs.removeAll()
            liveRenderExemptTabIDs.removeAll()
            if previousSuspended != suspendedTabIDs {
                logVisualState(reason: "renderSuspension: cleared")
            }
            return
        }

        // Selected tab should always be active.
        suspendedTabIDs.remove(selectedTabID)
        liveRenderExemptTabIDs.remove(selectedTabID)
        cancelSuspension(for: selectedTabID)

        for tab in tabs where tab.id != selectedTabID {
            if shouldKeepLiveRenderingInBackground(for: tab) {
                cancelSuspension(for: tab.id)
                let wasSuspended = suspendedTabIDs.remove(tab.id) != nil
                let becameExempt = liveRenderExemptTabIDs.insert(tab.id).inserted
                if wasSuspended || becameExempt {
                    Log.info(
                        "renderSuspension: keeping tab \(tab.id) live for AI activity (\(tabRenderSuspensionSummary(tab)))"
                    )
                }
                continue
            }

            if liveRenderExemptTabIDs.remove(tab.id) != nil {
                Log.info("renderSuspension: tab \(tab.id) returned to normal suspension (\(tabRenderSuspensionSummary(tab)))")
            }
            scheduleSuspension(for: tab.id)
        }

        if previousSuspended != suspendedTabIDs {
            logVisualState(reason: "renderSuspension: updated")
        }
    }

    func scheduleSuspension(for id: UUID) {
        guard !suspendedTabIDs.contains(id) else { return }
        guard suspendWorkItems[id] == nil else { return }
        guard let tab = tabs.first(where: { $0.id == id }) else { return }

        if shouldKeepLiveRenderingInBackground(for: tab) {
            let inserted = liveRenderExemptTabIDs.insert(id).inserted
            if inserted {
                Log.trace("renderSuspension: skipped scheduling for tab \(id) (\(tabRenderSuspensionSummary(tab)))")
            }
            return
        }

        let item = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.isRenderSuspensionEnabled else { return }
                guard self.selectedTabID != id else { return }
                guard let tab = self.tabs.first(where: { $0.id == id }) else { return }
                guard !self.shouldKeepLiveRenderingInBackground(for: tab) else {
                    let becameExempt = self.liveRenderExemptTabIDs.insert(id).inserted
                    if becameExempt {
                        Log.info(
                            "renderSuspension: cancelled at deadline for AI-active tab \(id) (\(self.tabRenderSuspensionSummary(tab)))"
                        )
                    }
                    self.suspendWorkItems.removeValue(forKey: id)
                    return
                }
                let inserted = self.suspendedTabIDs.insert(id).inserted
                self.suspendWorkItems.removeValue(forKey: id)
                if inserted {
                    Log.info("renderSuspension: suspended tab \(id) (\(self.tabRenderSuspensionSummary(tab)))")
                    self.logVisualState(reason: "renderSuspension: suspended tab \(id)")
                }
            }
        }
        suspendWorkItems[id] = item
        Log.trace("renderSuspension: scheduled tab \(id) in \(renderSuspensionDelay)s (\(tabRenderSuspensionSummary(tab)))")
        DispatchQueue.main.asyncAfter(deadline: .now() + renderSuspensionDelay, execute: item)
    }

    func shouldKeepLiveRenderingInBackground(for tab: OverlayTab) -> Bool {
        tab.splitController.terminalSessions.contains { _, session in
            session.shouldKeepLiveRenderingInBackground
        }
    }

    func tabRenderSuspensionSummary(_ tab: OverlayTab) -> String {
        let summaries = tab.splitController.terminalSessions.map { paneID, session in
            "pane=\(paneID) \(session.renderSuspensionDebugSummary)"
        }
        if summaries.isEmpty {
            return "no-terminal-sessions"
        }
        return summaries.joined(separator: " | ")
    }

    func cancelSuspension(for id: UUID) {
        if let item = suspendWorkItems[id] {
            item.cancel()
            suspendWorkItems.removeValue(forKey: id)
        }
    }

    // MARK: - F05: Auto Tab Themes by AI Model

    func updateAutoColor(for tabID: UUID, command: String) {
        guard FeatureSettings.shared.isAutoTabThemeEnabled else { return }
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        // Extract first word (command name)
        let firstWord = command.split(separator: " ").first?.lowercased() ?? ""
        let commandLowercased = command.lowercased()

        // Check against AI model mappings
        for (pattern, color) in FeatureSettings.aiModelColors {
            if firstWord.contains(pattern) {
                tabs[index].autoColor = color
                Log.trace("F05: Auto-colored tab for \(pattern) -> \(color)")
                return
            }
        }

        for rule in FeatureSettings.shared.customAIDetectionRules {
            let pattern = rule.pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !pattern.isEmpty else { continue }
            if commandLowercased.contains(pattern) || firstWord.contains(pattern) {
                tabs[index].autoColor = rule.tabColor
                Log.trace("F05: Auto-colored tab for custom pattern \(pattern) -> \(rule.tabColor)")
                return
            }
        }
    }

    // MARK: - F13: Broadcast Input

    func toggleBroadcast() {
        isBroadcastMode.toggle()
        if !isBroadcastMode {
            broadcastExcludedTabIDs.removeAll()
        }
        Log.info("F13: Broadcast mode \(isBroadcastMode ? "enabled" : "disabled")")
    }

    func toggleBroadcastExclusion(for tabID: UUID) {
        if broadcastExcludedTabIDs.contains(tabID) {
            broadcastExcludedTabIDs.remove(tabID)
        } else {
            broadcastExcludedTabIDs.insert(tabID)
        }
    }

    func broadcastInput(_ text: String) {
        guard isBroadcastMode else { return }

        for tab in tabs {
            // Skip excluded tabs
            guard !broadcastExcludedTabIDs.contains(tab.id) else { continue }
            // Skip current tab (it already received the input)
            guard tab.id != selectedTabID else { continue }

            // Send input to the tab's terminal session
            tab.session?.sendInput(text)
        }
    }

    // MARK: - F16: Clipboard History

    func toggleClipboardHistory() {
        isClipboardHistoryVisible.toggle()
        logVisualState(reason: "toggleClipboardHistory: \(isClipboardHistoryVisible)")
        if isClipboardHistoryVisible {
            isSearchVisible = false
            isRenameVisible = false
            isBookmarkListVisible = false
            isSnippetManagerVisible = false
        }
    }

    func pasteFromClipboardHistory(_ item: ClipboardHistoryManager.ClipboardItem) {
        ClipboardHistoryManager.shared.paste(item)
        isClipboardHistoryVisible = false
        paste() // Paste into terminal
    }

    // MARK: - F17: Bookmarks

    func toggleBookmarkList() {
        isBookmarkListVisible.toggle()
        logVisualState(reason: "toggleBookmarkList: \(isBookmarkListVisible)")
        if isBookmarkListVisible {
            isSearchVisible = false
            isRenameVisible = false
            isClipboardHistoryVisible = false
            isSnippetManagerVisible = false
        }
    }

    // MARK: - F21: Snippets

    func toggleSnippetManager() {
        guard FeatureSettings.shared.isSnippetsEnabled else { return }
        isSnippetManagerVisible.toggle()
        logVisualState(reason: "toggleSnippetManager: \(isSnippetManagerVisible)")
        if isSnippetManagerVisible {
            isSearchVisible = false
            isRenameVisible = false
            isClipboardHistoryVisible = false
            isBookmarkListVisible = false
            // Refresh snippet context from the active tab so repo snippets
            // are correct even if a background tab updated the context.
            updateSnippetContextForSelection()
        } else {
            // Focus terminal when snippet manager is closed
            focusSelected()
        }
    }

    // MARK: - Hover Card

    /// Called when the mouse enters a tab chip. Shows the hover card after a delay,
    /// or switches instantly if the card is already visible for another tab.
    func tabHoverBegan(id: UUID, anchorX: CGFloat) {
        hoverCardDismissTimer?.cancel()
        hoverCardDismissTimer = nil
        hoverCardTimer?.cancel()

        if hoverCardTabID != nil {
            // Card already visible — switch instantly: stop old, start new
            stopProcessMonitoring(forTabID: hoverCardTabID)
            hoverCardTabID = id
            hoverCardAnchorX = anchorX
            startProcessMonitoring(forTabID: id)
            return
        }

        let item = DispatchWorkItem { [weak self] in
            self?.hoverCardTabID = id
            self?.hoverCardAnchorX = anchorX
            self?.startProcessMonitoring(forTabID: id)
        }
        hoverCardTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Called when the mouse exits a tab chip. Starts a short dismiss delay
    /// so the user can move the mouse from the tab to the card.
    func tabHoverEnded(id: UUID) {
        hoverCardTimer?.cancel()
        hoverCardTimer = nil

        guard hoverCardTabID == id else { return }
        startHoverCardDismissTimer()
    }

    /// Called when the mouse enters the hover card body.
    func hoverCardMouseEntered() {
        hoverCardDismissTimer?.cancel()
        hoverCardDismissTimer = nil
    }

    /// Called when the mouse exits the hover card body.
    func hoverCardMouseExited() {
        startHoverCardDismissTimer()
    }

    /// Immediately hides the hover card (e.g. on tab select, close, rename, drag).
    func dismissHoverCard() {
        hoverCardTimer?.cancel()
        hoverCardTimer = nil
        hoverCardDismissTimer?.cancel()
        hoverCardDismissTimer = nil
        stopProcessMonitoring(forTabID: hoverCardTabID)
        hoverCardTabID = nil
    }

    func startHoverCardDismissTimer() {
        hoverCardDismissTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.stopProcessMonitoring(forTabID: self?.hoverCardTabID)
            self?.hoverCardTabID = nil
        }
        hoverCardDismissTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    func startProcessMonitoring(forTabID id: UUID?) {
        guard let id, let session = tabs.first(where: { $0.id == id })?.session else { return }
        session.startProcessMonitoring()
    }

    func stopProcessMonitoring(forTabID id: UUID?) {
        guard let id, let session = tabs.first(where: { $0.id == id })?.session else { return }
        session.stopProcessMonitoring()
    }

    func dismissOverlays() {
        dismissHoverCard()
        if isRenameVisible {
            cancelRename()
        }
        if isSearchVisible {
            toggleSearch()
        }
        if isClipboardHistoryVisible {
            toggleClipboardHistory()
        }
        if isBookmarkListVisible {
            toggleBookmarkList()
        }
        if isSnippetManagerVisible {
            toggleSnippetManager()
        }
    }

    func logVisualState(reason: String) {
        guard isDiagnosticsLoggingEnabled else { return }
        let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? -1
        let selectedSession = selectedTab?.displaySession
        let activeApp = selectedSession?.aiDisplayAppName ?? "nil"
        let displayPath = selectedSession?.displayPath() ?? ""
        let selectedSuspended = suspendedTabIDs.contains(selectedTabID)
        let overlayFlags = "search=\(isSearchVisible) rename=\(isRenameVisible) clipboard=\(isClipboardHistoryVisible) bookmarks=\(isBookmarkListVisible) snippets=\(isSnippetManagerVisible) candidate=\(currentCandidate != nil) task=\(currentTask != nil) assessment=\(isTaskAssessmentVisible)"
        Log
            .trace(
                "Overlay visual state (\(reason)): tabs=\(tabs.count) selectedIndex=\(selectedIndex) selectedID=\(selectedTabID) activeApp=\(activeApp) path=\(displayPath) terminalReady=\(isTerminalReady) suspended=\(suspendedTabIDs.count) selectedSuspended=\(selectedSuspended) renderSuspension=\(isRenderSuspensionEnabled) delay=\(renderSuspensionDelay) overlays[\(overlayFlags)]"
            )
    }

    func insertSnippet(_ entry: SnippetEntry) {
        guard let session = selectedTab?.session else { return }
        session.insertSnippet(entry)
        isSnippetManagerVisible = false
        // Focus terminal immediately after inserting snippet
        focusSelected()
    }

    /// Inserts a snippet with user-provided variable values
    func insertSnippetWithVariables(_ entry: SnippetEntry, variables: [SnippetInputVariable]) {
        guard let session = selectedTab?.session else { return }
        // Replace variables in snippet body with user values
        let modifiedBody = SnippetManager.replaceInputVariables(in: entry.snippet.body, with: variables)
        // Create modified snippet with replaced variables
        var modifiedSnippet = entry.snippet
        modifiedSnippet.body = modifiedBody
        let modifiedEntry = SnippetEntry(
            snippet: modifiedSnippet,
            source: entry.source,
            sourcePath: entry.sourcePath,
            isOverridden: entry.isOverridden,
            repoRoot: entry.repoRoot
        )
        session.insertSnippet(modifiedEntry)
        isSnippetManagerVisible = false
        focusSelected()
    }

    func addBookmark(label: String? = nil) {
        guard let tab = selectedTab else { return }
        guard FeatureSettings.shared.isBookmarksEnabled else { return }

        // Get current scroll position and line preview
        // This is a simplified version - would need terminal view access
        let scrollOffset = 0 // Would get from terminal
        let linePreview = "Bookmark at current position"

        BookmarkManager.shared.addBookmark(
            tabID: tab.id,
            scrollOffset: scrollOffset,
            linePreview: linePreview,
            label: label
        )
        Log.info("F17: Added bookmark for tab \(tab.id)")
    }

    func jumpToBookmark(_ bookmark: BookmarkManager.Bookmark) {
        // Select the tab if needed
        if selectedTabID != bookmark.tabID {
            selectTab(id: bookmark.tabID)
        }

        // Scroll to bookmark position
        // This would need terminal view access to scroll
        isBookmarkListVisible = false
        Log.info("F17: Jumped to bookmark at offset \(bookmark.scrollOffset)")
    }

    func getBookmarksForCurrentTab() -> [BookmarkManager.Bookmark] {
        return BookmarkManager.shared.getBookmarks(for: selectedTabID)
    }

    // MARK: - Repo Tab Grouping

    func setupRepoGrouping() {
        // Observe mode changes via didSet callback
        FeatureSettings.shared.onRepoGroupingModeChanged = { [weak self] newMode in
            self?.handleRepoGroupingModeChange(newMode)
        }

        // Set initial state
        if FeatureSettings.shared.repoGroupingMode == .auto {
            applyAutoGroupingToAllTabs()
        }
    }

    func handleRepoGroupingModeChange(_ mode: RepoGroupingMode) {
        switch mode {
        case .off:
            // Keep existing repoGroupIDs — tabBarSegments always renders them.
            // Only stop auto-update subscriptions.
            clearAllGitRootCallbacks()
        case .auto:
            applyAutoGroupingToAllTabs()
        case .manual:
            // Keep existing groups, stop auto-updates
            clearAllGitRootCallbacks()
        }
    }

    private func clearAllGitRootCallbacks() {
        for tab in tabs {
            tab.session?.onGitRootPathChanged = nil
        }
    }

    func applyAutoGroupingToAllTabs() {
        clearAllGitRootCallbacks()
        for i in tabs.indices {
            let fallbackRepoRoot = knownRepoRoot(for: tabs[i])
            tabs[i].repoGroupID = tabs[i].session?.gitRootPath
                ?? fallbackRepoRoot
                ?? tabs[i].repoGroupID
            tabs[i].hasInheritedRepoGroup = false
            if let session = tabs[i].session {
                observeGitRootForAutoGrouping(tabID: tabs[i].id, session: session)
            }
        }
        var seen = Set<String>()
        for tab in tabs {
            guard let repoGroupID = tab.repoGroupID, seen.insert(repoGroupID).inserted else { continue }
            coalesceGroup(repoGroupID: repoGroupID)
        }
    }

    func observeGitRootForAutoGrouping(tabID: UUID, session: TerminalSessionModel) {
        session.onGitRootPathChanged = { [weak self] newRoot in
            DispatchQueue.main.async {
                guard let self,
                      let idx = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }

                if FeatureSettings.shared.repoGroupingMode == .auto {
                    self.tabs[idx].repoGroupID = newRoot ?? self.knownRepoRoot(for: self.tabs[idx])
                    self.tabs[idx].hasInheritedRepoGroup = false
                    if let repoGroupID = self.tabs[idx].repoGroupID {
                        self.coalesceGroup(repoGroupID: repoGroupID)
                    }
                    return
                }

                if self.tabs[idx].hasInheritedRepoGroup,
                   self.tabs[idx].repoGroupID != newRoot {
                    self.tabs[idx].repoGroupID = nil
                    self.tabs[idx].hasInheritedRepoGroup = false
                }
            }
        }
    }

    /// Called when a new tab is added — always assign repoGroupID from gitRootPath
    /// and subscribe to future changes. The mode only controls whether the user sees
    /// grouping controls in settings, not whether tabs get tagged (since tabBarSegments
    /// always renders existing groups).
    func setupRepoGroupingForTab(_ tab: OverlayTab) {
        guard let session = tab.session else { return }
        if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
            if tabs[idx].repoGroupID == nil {
                tabs[idx].repoGroupID = session.gitRootPath ?? knownRepoRoot(for: tabs[idx])
            }
            let repoGroupID = tabs[idx].repoGroupID
            if let repoGroupID {
                coalesceGroup(repoGroupID: repoGroupID)
            }
        }
        observeGitRootForAutoGrouping(tabID: tab.id, session: session)
    }

    private func knownRepoRoot(for tab: OverlayTab) -> String? {
        guard let session = tab.session else {
            return nil
        }

        return KnownRepoRootResolver.resolve(
            currentDirectory: session.currentDirectory,
            preferredRepoRoot: tab.repoGroupID,
            recentRepoRoots: KnownRepoIdentityStore.shared.allRoots()
        )
    }

    func insertionIndexForNewTab(inheritingRepoGroupID inheritedRepoGroupID: String?) -> Int {
        if inheritedRepoGroupID != nil,
           let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            return currentIndex + 1
        }

        let position = FeatureSettings.shared.newTabPosition
        if position == "after",
           let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            return currentIndex + 1
        }
        return tabs.count
    }

    /// Called when a tab is closed — clean up subscription.
    func cleanupRepoGroupingForTab(_ tabID: UUID) {
        if let tab = tabs.first(where: { $0.id == tabID }) {
            tab.session?.onGitRootPathChanged = nil
        }
    }

    /// Manual mode actions
    func addTabToRepoGroup(tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }),
              let root = tabs[idx].session?.gitRootPath else { return }
        tabs[idx].repoGroupID = root
        tabs[idx].hasInheritedRepoGroup = false
        coalesceGroup(repoGroupID: root)
    }

    func removeTabFromRepoGroup(tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[idx].repoGroupID = nil
        tabs[idx].hasInheritedRepoGroup = false
    }

    /// Toggle the agent dashboard overlay for a repo group.
    /// Click group tag → show dashboard. Click again or click any tab → dismiss.
    func toggleDashboard(for repoGroupID: String) {
        if activeDashboardGroupID == repoGroupID {
            activeDashboardGroupID = nil
        } else {
            _ = dashboardModel(for: repoGroupID)
            activeDashboardGroupID = repoGroupID
        }
    }

    func groupAllSameRepo(asTab tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }),
              let root = tabs[idx].session?.gitRootPath else { return }
        for i in tabs.indices {
            if tabs[i].session?.gitRootPath == root {
                tabs[i].repoGroupID = root
                tabs[i].hasInheritedRepoGroup = false
            }
        }
        coalesceGroup(repoGroupID: root)
    }

    func coalesceGroup(repoGroupID: String) {
        let order = TabBarLayout.coalescedOrder(
            groupIDs: tabs.map(\.repoGroupID),
            targetGroupID: repoGroupID
        )
        guard order != Array(tabs.indices) else { return }
        tabs = order.map { tabs[$0] }
    }

    // MARK: - F02: Split Panes

    func splitCurrentTabHorizontally() {
        selectedTab?.splitHorizontally()
    }

    func splitCurrentTabVertically() {
        selectedTab?.splitVertically()
    }

    func openTextEditorInCurrentTab(filePath: String? = nil) {
        selectedTab?.openTextEditor(filePath: filePath)
    }

    func openFilePreviewInCurrentTab(filePath: String? = nil) {
        selectedTab?.openFilePreview(filePath: filePath)
    }

    func openDiffViewerInCurrentTab(filePath: String, directory: String, mode: DiffMode = .workingTree) {
        selectedTab?.openDiffViewer(filePath: filePath, directory: directory, mode: mode)
    }

    func openRepositoryPaneInCurrentTab(directory: String) {
        selectedTab?.openRepositoryPane(directory: directory)
    }

    func toggleTextEditorInCurrentTab(filePath: String? = nil) {
        selectedTab?.toggleTextEditor(filePath: filePath)
    }

    func toggleFilePreviewInCurrentTab(filePath: String? = nil) {
        selectedTab?.toggleFilePreview(filePath: filePath)
    }

    func toggleRepositoryPaneInCurrentTab(directory: String) {
        selectedTab?.toggleRepositoryPane(directory: directory)
    }

    func closeFocusedPaneInCurrentTab() {
        selectedTab?.closeFocusedPane()
    }

    func focusNextPaneInCurrentTab() {
        selectedTab?.focusNextPane()
    }

    func focusPreviousPaneInCurrentTab() {
        selectedTab?.focusPreviousPane()
    }

    func appendSelectionToEditorInCurrentTab() {
        guard let tab = selectedTab,
              let session = tab.session,
              let selection = session.getSelectedText(),
              !selection.isEmpty else {
            Log.warn("No text selected to append")
            return
        }
        tab.appendSelectionToEditor(selection)
    }

    // MARK: - F20: Last Command Tracking

    func commandStarted(for tabID: UUID, command: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        tabs[index].lastCommand = LastCommandInfo(
            command: command,
            startTime: Date(),
            endTime: nil,
            exitCode: nil
        )

        // F05: Also update auto color
        updateAutoColor(for: tabID, command: command)
    }

    func commandFinished(for tabID: UUID, exitCode: Int32) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        guard var cmd = tabs[index].lastCommand else { return }

        cmd.endTime = Date()
        cmd.exitCode = exitCode
        tabs[index].lastCommand = cmd

        Log.trace("F20: Command finished with code \(exitCode), duration: \(cmd.durationString)")
    }

    // MARK: - Task Lifecycle (v1.1)

    func setupTaskObservers() {
        MainActor.assumeIsolated {
            let ipc = ProxyIPCServer.shared

            // Observe pending candidates via didSet callback
            ipc.onPendingCandidatesChange = { [weak self] candidates in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateCurrentCandidate(from: candidates)
                }
            }

            // Observe active tasks via didSet callback
            ipc.onActiveTasksChange = { [weak self] tasks in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.updateCurrentTask(from: tasks)
                }
            }
        }
    }

    func updateCurrentCandidate(from candidates: [String: TaskCandidate]) {
        guard let session = selectedTab?.session else {
            currentCandidate = nil
            return
        }
        currentCandidate = candidates[session.tabIdentifier]
    }

    func updateCurrentTask(from tasks: [String: TrackedTask]) {
        guard let session = selectedTab?.session else {
            currentTask = nil
            return
        }
        currentTask = tasks[session.tabIdentifier]
    }

    func confirmTaskCandidate() {
        guard let candidate = currentCandidate,
              let session = selectedTab?.session else { return }

        Task {
            if let task = await ProxyManager.shared.startTask(
                tabId: session.tabIdentifier,
                taskName: nil,
                candidateId: candidate.id
            ) {
                await MainActor.run {
                    self.currentCandidate = nil
                    self.currentTask = task
                    Log.info("Task confirmed: \(task.name)")
                }
            } else {
                await MainActor.run {
                    Log.error("OverlayTabsModel: failed to confirm task candidate \(candidate.id)")
                }
            }
        }
    }

    func dismissTaskCandidate() {
        guard let candidate = currentCandidate,
              let session = selectedTab?.session else { return }

        Task {
            let dismissed = await ProxyManager.shared.dismissCandidate(
                tabId: session.tabIdentifier,
                candidateId: candidate.id
            )
            if dismissed {
                await MainActor.run {
                    self.currentCandidate = nil
                    Log.info("Task candidate dismissed")
                }
            } else {
                Log.error("OverlayTabsModel: failed to dismiss task candidate \(candidate.id)")
            }
        }
    }

    func showTaskAssessment() {
        guard currentTask != nil else { return }
        isTaskAssessmentVisible = true
    }

    func dismissTaskAssessment() {
        isTaskAssessmentVisible = false
    }

    func assessTask(approved: Bool, note: String?) {
        guard let task = currentTask else { return }

        Task {
            let success = await ProxyManager.shared.assessTask(
                taskId: task.id,
                approved: approved,
                note: note
            )
            if success {
                await MainActor.run {
                    self.isTaskAssessmentVisible = false
                    self.currentTask = nil
                    Log.info("Task assessed: \(approved ? "success" : "failed")")
                }
            } else {
                Log.error("OverlayTabsModel: failed to assess task \(task.id)")
            }
        }
    }
}

extension String {
    func extractResumeSessionId(prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        let suffix = String(dropFirst(prefix.count))
        return suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : suffix
    }
}
