import Foundation
import AppKit
import Chau7Core
import Combine
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
        icon: "ellipsis.circle"
    )

    static let error = TabNotificationStyle(
        titleColor: .red,
        isBold: true,
        icon: "exclamationmark.triangle.fill",
        iconColor: .red
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
        iconColor: .yellow
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

    var displayTitle: String {
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
            return "Editor"
        }
        return "Shell"
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

    init(appModel: AppModel, splitController: SplitPaneController, id: UUID = UUID(), createdAt: Date = Date()) {
        self.id = id
        self.splitController = splitController
        self.createdAt = createdAt
    }

    /// Propagates this tab's UUID to the split controller and all current terminal
    /// sessions so events carry a deterministic tabID for the TabResolver fast-path.
    /// Must be called after the tab's `id` is finalized (i.e. after init or restore).
    mutating func stampOwnerTabID() {
        splitController.ownerTabID = id
        let tabID = id
        for (_, session) in splitController.terminalSessions {
            session.ownerTabID = tabID
            // Wire permission-resolved callback to clear persistent tab border
            session.onPermissionResolved = {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(
                        name: Notification.Name("com.chau7.clearPersistentTabStyle"),
                        object: tabID
                    )
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

    init(
        paneID: String,
        directory: String,
        scrollbackContent: String?,
        aiResumeCommand: String?,
        aiProvider: String?,
        aiSessionId: String?,
        lastOutputAt: Date? = nil
    ) {
        self.paneID = paneID
        self.directory = directory
        self.scrollbackContent = scrollbackContent
        self.aiResumeCommand = aiResumeCommand
        self.aiProvider = aiProvider
        self.aiSessionId = aiSessionId
        self.lastOutputAt = lastOutputAt
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

    static let userDefaultsKey = "com.chau7.savedTabState"
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
/// - Note: Thread Safety - @Published properties must be modified on main thread.
///   All methods assume main thread execution.
final class OverlayTabsModel: ObservableObject { // swiftlint:disable:this type_body_length
    @Published var tabs: [OverlayTab]
    @Published var selectedTabID: UUID
    @Published var isSearchVisible = false
    @Published var searchQuery = ""
    @Published var searchResults: [String] = []
    @Published var searchMatchCount = 0
    @Published var isCaseSensitive = false // Issue #23 fix
    @Published var isRegexSearch = false
    @Published var isSemanticSearch = false
    @Published var searchError: String?
    @Published var isRenameVisible = false
    @Published var renameText = ""
    @Published var renameColor: TabColor = .blue
    @Published var suspendedTabIDs: Set<UUID> = []

    // MARK: - Tab Switch Optimization State

    /// Previous tab index for directional animation
    @Published var previousTabIndex = 0
    /// Whether the terminal content is ready to display (for snapshot swap)
    @Published var isTerminalReady = true
    /// Generation counter for isTerminalReady — prevents stale asyncAfter
    /// callbacks from clobbering the state after rapid tab switches.
    private var terminalReadyGeneration: UInt64 = 0
    /// Set of tab IDs currently being pre-warmed (on hover)
    private var prewarmingTabIDs: Set<UUID> = []

    // MARK: - Tab Bar Recovery

    /// Tab hit-test ranges for right-click context menu (populated by SwiftUI preference changes).
    /// Each entry maps a tab UUID to its global x-range (minX, maxX) in the window.
    var tabHitTestFrames: [(tabID: UUID, minX: CGFloat, maxX: CGFloat)] = []

    /// Token to force SwiftUI to re-render the tab bar when incremented
    @Published var tabBarRefreshToken = 0
    /// Last reported rendered tab count from the view (for watchdog)
    /// -1 means the view hasn't reported yet (avoids false positive on startup)
    var lastReportedRenderedCount: Int = -1
    /// Last reported tab bar size (for visibility-based recovery)
    var lastReportedTabBarSize: CGSize = .zero
    /// Timestamp of last preference update from the view (for staleness detection)
    private var lastPreferenceUpdateTime = Date()
    /// How long without a preference update before considering the view stale
    private let stalenessThreshold: TimeInterval = 20.0
    private let refreshCooldown: TimeInterval = 10.0
    private var lastForcedRefreshAt: Date = .distantPast
    private var watchdogRecoveryCount = 0
    private var watchdogSkipCount = 0
    private var lastWatchdogSummaryAt = Date()
    private var lastWatchdogReason = ""
    /// Timer for watchdog that checks tab bar health
    private var tabBarWatchdogTimer: DispatchSourceTimer?
    /// Counter to limit consecutive watchdog refresh attempts
    private var watchdogRefreshAttempts = 0
    /// Minimum acceptable tab bar width per tab (for visibility detection)
    private let minWidthPerTab: CGFloat = 30
    /// Tracks whether the tab bar is expected to be visible
    private var isTabBarVisible = true
    private var lastTabBarVisibilityLogAt: Date = .distantPast

    // F13: Broadcast Input
    @Published var isBroadcastMode = false
    @Published var broadcastExcludedTabIDs: Set<UUID> = []

    // F16: Clipboard History
    @Published var isClipboardHistoryVisible = false

    // F17: Bookmarks
    @Published var isBookmarkListVisible = false

    // F21: Snippets
    @Published var isSnippetManagerVisible = false

    // Hover Card
    @Published var hoverCardTabID: UUID?
    @Published var hoverCardAnchorX: CGFloat = 0
    private var hoverCardTimer: DispatchWorkItem?
    private var hoverCardDismissTimer: DispatchWorkItem?

    // Task Lifecycle (v1.1)
    @Published var currentCandidate: TaskCandidate?
    @Published var currentTask: TrackedTask?
    @Published var isTaskAssessmentVisible = false

    // Reopen Closed Tab (Cmd+Shift+T)
    /// LIFO stack of recently closed tabs (max 10, in-memory only)
    private var closedTabStack: [ClosedTabEntry] = []
    private let maxClosedTabs = 10

    /// Whether there are any closed tabs available to reopen
    var canReopenClosedTab: Bool {
        !closedTabStack.isEmpty
    }

    private var taskCancellables: Set<AnyCancellable> = []
    private var repoGroupCancellables: [UUID: AnyCancellable] = [:]
    private var repoGroupModeCancellable: AnyCancellable?
    private var renameTabID: UUID?
    private var renameOriginalTitle = ""
    private var renameOriginalColor: TabColor = .blue
    private var suspendWorkItems: [UUID: DispatchWorkItem] = [:]
    private var liveRenderExemptTabIDs: Set<UUID> = []
    /// Per-pane token for restore-time resume prefills.
    /// Prevents stale delayed retries from writing outdated commands.
    private var latestRestoreResumeTokenByPaneID: [UUID: String] = [:]
    private var isRenderSuspensionEnabled = false
    // Reduced from 5.0s to 2.0s — combined with CVDisplayLink pausing, this
    // means background tabs stop rendering 3 seconds sooner, saving significant CPU.
    private var renderSuspensionDelay: TimeInterval = 5.0
    private var needsFreshTabOnShow = false
    private var isDiagnosticsLoggingEnabled = false
    // Auto-save timer moved to AppDelegate for coordinated multi-window saves.
    /// Last archived snapshot fingerprint to avoid writing duplicate archive files.
    private var lastArchivedTabStateFingerprint: Int?
    /// Minimum time between archived snapshots unless we're terminating.
    private var lastArchivedTabStateAt: Date = .distantPast
    /// CTO notification observer tokens (stored for cleanup in deinit)
    private var ctoModeObserver: NSObjectProtocol?
    private var ctoFlagObserver: NSObjectProtocol?
    private var renderSuspensionObserver: NSObjectProtocol?
    private var persistentStyleObserver: NSObjectProtocol?
    private var suspensionDebounceItem: DispatchWorkItem?
    private var lastObservedTokenOptimizationMode: TokenOptimizationMode = FeatureSettings.shared.tokenOptimizationMode

    weak var overlayWindow: NSWindow?
    var onCloseLastTab: (() -> Void)?

    private let appModel: AppModel
    private struct RestorableTabsPayload {
        let tabs: [OverlayTab]
        let selectedID: UUID
        let rawStates: [SavedTabState]
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
        if let restoredPayload {
            for (index, state) in restoredPayload.rawStates.enumerated() where index < tabs.count {
                restoreTabState(for: tabs[index], state: state)
            }
        }

        // Observe permission-resolved to clear persistent red borders
        persistentStyleObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("com.chau7.clearPersistentTabStyle"),
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let tabID = notification.object as? UUID else { return }
            self?.clearPersistentStyle(for: tabID)
        }

        // Setup task lifecycle observers (v1.1)
        setupTaskObservers()

        // Repo grouping: subscribe to mode changes and initial auto-group
        setupRepoGrouping()

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

        // CTO: refresh tab bar when a session's flag state changes (e.g. AI detected)
        self.ctoFlagObserver = NotificationCenter.default.addObserver(
            forName: .ctoFlagRecalculated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.objectWillChange.send()
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
                // Note: don't call objectWillChange.send() here — @Published
                // properties in updateSuspensionState already trigger it when
                // suspendedTabIDs changes. Extra sends cause redundant rebuilds.
            }
            suspensionDebounceItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: item)
        }
    }

    deinit {
        Log.warn("OverlayTabsModel deinit — tabs=\(tabs.count) pid=\(ProcessInfo.processInfo.processIdentifier)")
        stopTabBarWatchdog()
        if let ctoModeObserver { NotificationCenter.default.removeObserver(ctoModeObserver) }
        if let ctoFlagObserver { NotificationCenter.default.removeObserver(ctoFlagObserver) }
        if let renderSuspensionObserver { NotificationCenter.default.removeObserver(renderSuspensionObserver) }
        if let persistentStyleObserver { NotificationCenter.default.removeObserver(persistentStyleObserver) }
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
                let resumeMetadata = resolveResumeMetadata(
                    for: session, directory: dir, outputHint: scrollback, claimedSessionIds: claimedSessionIds
                )
                let resumeCommand = Self.buildAIResumeCommand(
                    provider: resumeMetadata?.provider, sessionId: resumeMetadata?.sessionId
                )
                if let sessionId = resumeMetadata?.sessionId { claimedSessionIds.insert(sessionId) }

                paneStates.append(SavedTerminalPaneState(
                    paneID: paneID.uuidString,
                    directory: dir,
                    scrollbackContent: scrollback,
                    aiResumeCommand: resumeCommand,
                    aiProvider: resumeMetadata?.provider,
                    aiSessionId: resumeMetadata?.sessionId,
                    lastOutputAt: Self.normalizedResumeReferenceDate(session.lastOutputDate)
                ))
            }

            let primaryDirectory = terminalSessions.first?.1.currentDirectory
                ?? tab.session?.currentDirectory
                ?? TerminalSessionModel.defaultStartDirectory()

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
                repoGroupID: tab.repoGroupID
            ))
        }
        return states
    }

    /// Captures a snapshot of a tab about to be closed and pushes it onto the
    /// closed-tab stack. Must be called BEFORE `closeAllSessions()` kills the shell,
    /// because we need the live scrollback buffer and active app name.
    private func captureClosedTabSnapshot(tab: OverlayTab, at index: Int) {
        let maxLines = FeatureSettings.shared.restoredScrollbackLines
        let terminalSessions = tab.splitController.terminalSessions

        var paneStates: [SavedTerminalPaneState] = []
        for (paneID, session) in terminalSessions {
            let dir = session.currentDirectory
            let scrollback = Self.captureScrollback(from: session, maxLines: maxLines)
            let resumeMetadata = resolveResumeMetadata(
                for: session,
                directory: dir,
                outputHint: scrollback
            )
            let resumeCommand = Self.buildAIResumeCommand(
                provider: resumeMetadata?.provider,
                sessionId: resumeMetadata?.sessionId
            )

            paneStates.append(SavedTerminalPaneState(
                paneID: paneID.uuidString,
                directory: dir,
                scrollbackContent: scrollback,
                aiResumeCommand: resumeCommand,
                aiProvider: resumeMetadata?.provider,
                aiSessionId: resumeMetadata?.sessionId,
                lastOutputAt: Self.normalizedResumeReferenceDate(session.lastOutputDate)
            ))
        }

        let primaryDirectory = terminalSessions.first?.1.currentDirectory
            ?? tab.session?.currentDirectory
            ?? TerminalSessionModel.defaultStartDirectory()
        let primaryScrollback = paneStates.first?.scrollbackContent
        let primaryResumeCommand = paneStates.first?.aiResumeCommand

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
            repoGroupID: tab.repoGroupID
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

    private func resolveResumeMetadata(
        for session: TerminalSessionModel,
        directory: String,
        outputHint: String?,
        claimedSessionIds: Set<String> = []
    ) -> (provider: String, sessionId: String)? {
        let referenceDate = Self.normalizedResumeReferenceDate(session.lastOutputDate)
        let detectedApp = Self.detectAIAppName(fromOutput: outputHint)
        let resumeAppName = session.aiDisplayAppName ?? detectedApp

        if let resolved = Self.resolveAIResumeMetadata(
            appName: resumeAppName,
            directory: directory,
            outputHint: outputHint,
            explicitAIProvider: session.effectiveAIProvider,
            explicitAISessionId: session.effectiveAISessionId,
            referenceDate: referenceDate,
            claimedSessionIds: claimedSessionIds
        ) {
            return resolved
        }

        let inferredProvider = Self.normalizedAIProvider(from: resumeAppName)
        guard inferredProvider == "codex" || session.effectiveAIProvider == "codex" else {
            return nil
        }

        let observedCandidates = appModel.codexHistoryEntries.suffix(64).compactMap { entry -> CodexSessionResolver.Candidate? in
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
            Log.info(
                """
                saveTabState: unresolved Codex resume metadata \
                dir=\(directory) explicitSession=\(session.effectiveAISessionId ?? "nil") \
                observedCandidates=\(observedCandidates.count) filtered=\(filteredCandidates.count)
                """
            )
            return nil
        }

        Log.trace("saveTabState: recovered Codex resume metadata from observed history for dir=\(directory)")
        return (provider: "codex", sessionId: sessionId)
    }

    /// Build a resume command for an AI session running in the given directory.
    /// Returns nil if no resumable session is found.
    private static func buildAIResumeCommand(appName: String?, directory: String, outputHint: String? = nil) -> String? {
        guard let resolved = resolveAIResumeMetadata(
            appName: appName,
            directory: directory,
            outputHint: outputHint
        ) else {
            return nil
        }
        return buildAIResumeCommand(provider: resolved.provider, sessionId: resolved.sessionId)
    }

    private static func buildAIResumeCommand(
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

    private static func buildAIResumeCommand(provider: String?, sessionId: String?) -> String? {
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

    private static func resolveAIResumeMetadataFromSavedState(
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

    private static func normalizedResumeReferenceDate(_ value: Date) -> Date? {
        return value == .distantPast ? nil : value
    }

    private static func normalizedResumeReferenceDate(_ value: Date?) -> Date? {
        guard let value else { return nil }
        return value == .distantPast ? nil : value
    }

    private static func resolveAIResumeMetadata(
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
                return nil
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

    private static func aiResumeProviderCandidates(
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

    private static func resolvedAIResumeMetadata(
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

    // MARK: - Session Finder Registry

    private static var sessionFinderLock = NSLock()
    private static var sessionFinders: [String: (String, Date?, Set<String>) -> String?] = [:]

    static func registerSessionFinder(
        forProviderKey key: String,
        finder: @escaping (String, Date?, Set<String>) -> String?
    ) {
        sessionFinderLock.lock()
        defer { sessionFinderLock.unlock() }
        sessionFinders[key] = finder
    }

    private static func findAIResumeSessionId(
        for provider: String,
        directory: String,
        referenceDate: Date?,
        claimedSessionIds: Set<String> = []
    ) -> String? {
        sessionFinderLock.lock()
        let finder = sessionFinders[provider]
        sessionFinderLock.unlock()
        return finder?(directory, referenceDate, claimedSessionIds)
    }

    private static func normalizedAIProvider(from value: String?) -> String? {
        guard let value else { return nil }
        return AIResumeParser.normalizeProviderName(value)
    }

    static func normalizeAISessionId(_ sessionId: String?) -> String? {
        guard let sessionId else { return nil }
        let trimmed = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard AIResumeParser.isValidSessionId(trimmed) else { return nil }
        return trimmed
    }

    static func findClaudeSessionId(
        forDirectory directory: String,
        referenceDate: Date? = nil,
        claimedSessionIds: Set<String> = []
    ) -> String? {
        let canonicalDirectory = normalizedSessionDirectory(directory)
        guard !canonicalDirectory.isEmpty else { return nil }

        let matches = ClaudeCodeMonitor.shared
            .sessionCandidates(forDirectory: canonicalDirectory)
            .compactMap { candidate -> (sessionId: String, touchedAt: Date)? in
                guard let normalizedSessionId = normalizeAISessionId(candidate.sessionId) else {
                    return nil
                }
                guard !claimedSessionIds.contains(normalizedSessionId) else { return nil }
                return (sessionId: normalizedSessionId, touchedAt: candidate.lastActivity)
            }

        guard !matches.isEmpty else { return nil }

        if let chosen = AIResumeParser.bestSessionMatch(candidates: matches, referenceDate: referenceDate) {
            if matches.count > 1 {
                Log.trace(
                    "findClaudeSessionId: selected sessionId=\(chosen) from \(matches.count) candidates for dir=\(canonicalDirectory)"
                )
            }
            return chosen
        }

        Log.warn("findClaudeSessionId: multiple session candidates for dir=\(canonicalDirectory); skipping to avoid cross-tab contamination")
        return nil
    }

    private static func detectAIAppName(fromOutput output: String?) -> String? {
        guard let output else { return nil }
        return CommandDetection.detectAppFromOutput(output)
    }

    private static func normalizedSessionDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        let expanded = RuntimeIsolation.expandTilde(in: trimmed)
        return URL(fileURLWithPath: expanded).standardized.path
    }

    private static func isSameSessionDirectory(_ lhs: String, as rhs: String) -> Bool {
        let left = normalizedSessionDirectory(lhs)
        let right = normalizedSessionDirectory(rhs)
        guard !left.isEmpty, !right.isEmpty else { return false }
        return left == right || left.hasPrefix(right + "/")
    }

    private static func isValidSessionId(_ id: String) -> Bool {
        AIResumeParser.isValidSessionId(id)
    }

    /// Find the most recent Codex session ID for a given directory.
    /// Scans ~/.codex/sessions/ day directories for session files whose
    /// cwd matches the given directory. Caps total file reads to avoid
    /// blocking the main thread.
    static func findCodexSessionId(
        forDirectory dir: String,
        referenceDate: Date? = nil,
        claimedSessionIds: Set<String> = []
    ) -> String? {
        let fm = FileManager.default
        let sessionsDir = RuntimeIsolation.urlInHome(".codex/sessions", fileManager: fm)

        // Filter helper: only include entries that look like date components (digits only)
        let isDateComponent = { (name: String) -> Bool in
            !name.isEmpty && name.allSatisfy(\.isNumber)
        }

        // Collect year/month/day directories, sorted most-recent-first
        guard let years = try? fm.contentsOfDirectory(atPath: sessionsDir.path) else { return nil }
        var dayDirs: [URL] = []
        for year in years.filter(isDateComponent).sorted().reversed() {
            let yearURL = sessionsDir.appendingPathComponent(year)
            guard let months = try? fm.contentsOfDirectory(atPath: yearURL.path) else { continue }
            for month in months.filter(isDateComponent).sorted().reversed() {
                let monthURL = yearURL.appendingPathComponent(month)
                guard let days = try? fm.contentsOfDirectory(atPath: monthURL.path) else { continue }
                for day in days.filter(isDateComponent).sorted().reversed() {
                    dayDirs.append(monthURL.appendingPathComponent(day))
                }
            }
        }

        // Scan the 7 most recent day directories, capping total file reads
        var filesRead = 0
        var parsedLines = 0
        var matches: [(sessionId: String, touchedAt: Date)] = []
        let maxFileReads = 30
        for dayDir in dayDirs.prefix(7) {
            guard let files = try? fm.contentsOfDirectory(atPath: dayDir.path) else { continue }
            // Sort files reverse-alphabetically (most recent timestamp first)
            let jsonlFiles = files.filter { $0.hasSuffix(".jsonl") }.sorted().reversed()
            for file in jsonlFiles {
                guard filesRead < maxFileReads else { return nil }
                filesRead += 1
                let filePath = dayDir.appendingPathComponent(file).path
                guard let firstLine = readFirstLine(atPath: filePath) else { continue }
                parsedLines += 1
                // Parse session_meta to extract cwd and id
                if let (sessionCwd, sessionId) = parseCodexSessionMeta(firstLine),
                   Self.isSameSessionDirectory(dir, as: sessionCwd),
                   !claimedSessionIds.contains(sessionId) {
                    let touchedAt = (try? FileManager.default.attributesOfItem(atPath: filePath)[.modificationDate] as? Date) ?? Date.distantPast
                    matches.append((sessionId: sessionId, touchedAt: touchedAt))
                }
            }
        }

        if matches.isEmpty {
            if filesRead == 0 {
                Log.warn("findCodexSessionId: no .jsonl files found in recent directories for dir=\(dir)")
            } else if parsedLines == 0 {
                Log.warn("findCodexSessionId: no readable first lines found while scanning \(filesRead) files for dir=\(dir)")
            } else {
                Log.trace("findCodexSessionId: scanned \(filesRead) files without finding a session_meta match for dir=\(dir)")
            }
            return nil
        }

        if let chosen = AIResumeParser.bestSessionMatch(candidates: matches, referenceDate: referenceDate) {
            if matches.count > 1 {
                Log.trace("findCodexSessionId: selected sessionId=\(chosen) from \(matches.count) candidates using activity hint for dir=\(dir)")
            }
            return chosen
        }

        Log.warn("findCodexSessionId: multiple session candidates for dir=\(dir); skipping to avoid cross-tab contamination")
        return nil
    }

    /// Read just the first line of a file without loading the entire contents.
    private static func readFirstLine(atPath path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        // Large JSONL session files can exceed small read buffers due embedded
        // instructions/context, so read until the first newline (or a safe cap).
        let chunkSize = 4096
        let maxLineBytes = 262_144
        var buffer = Data()

        while buffer.count < maxLineBytes {
            let chunk = handle.readData(ofLength: chunkSize)
            guard !chunk.isEmpty else { break }
            buffer.append(chunk)

            if let newlineIndex = buffer.firstIndex(of: 10) {
                buffer = Data(buffer.prefix(upTo: newlineIndex))
                break
            }

            if buffer.count >= maxLineBytes {
                Log.warn(
                    """
                    findCodexSessionId: first line exceeded cap while reading \
                    \"\(path)\" (bufferBytes=\(buffer.count), cap=\(maxLineBytes))
                    """
                )
                break
            }
        }

        guard !buffer.isEmpty else { return nil }

        return readFirstLine(from: buffer)
    }

    static func readFirstLine(from data: Data, maxBytes: Int = 262_144) -> String? {
        guard data.count <= maxBytes else {
            return nil
        }

        guard !data.isEmpty else { return nil }

        if let newlineIndex = data.firstIndex(of: 10) {
            return String(decoding: data[..<newlineIndex], as: UTF8.self)
        }

        return String(decoding: data, as: UTF8.self)
    }

    /// Parse the first line of a Codex session file (session_meta JSON)
    /// to extract the cwd and session ID.
    private static func parseCodexSessionMeta(_ line: String) -> (cwd: String, id: String)? {
        guard let data = line.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String, type == "session_meta",
              let payload = json["payload"] as? [String: Any],
              let cwd = payload["cwd"] as? String,
              let id = payload["id"] as? String else {
            return nil
        }
        let normalizedCwd = cwd.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedId = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedCwd.isEmpty, AIResumeParser.isValidSessionId(normalizedId) else {
            return nil
        }
        return (normalizedCwd, normalizedId)
    }

    private static func captureScrollback(from session: TerminalSessionModel?, maxLines: Int) -> String? {
        guard maxLines > 0, let session, let data = session.captureRemoteSnapshot() else {
            return nil
        }

        let text = String(decoding: data, as: UTF8.self)
        var lines = text.components(separatedBy: "\n")

        // Strip trailing empty lines — the terminal buffer includes blank lines below
        // the cursor, which can otherwise pollute restore output.
        while let last = lines.last, last.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.removeLast()
        }

        if lines.isEmpty {
            return nil
        }

        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }

        var restored = lines.joined(separator: "\n")
        if restored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        // Cap total size to avoid UserDefaults bloat (500KB per tab max)
        if restored.utf8.count > 500_000 {
            let reducedLineCount = max(1, maxLines / 2)
            restored = restored.components(separatedBy: "\n").suffix(reducedLineCount).joined(separator: "\n")
        }

        return restored
    }

    private static func shellSafeSingleQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static let restoreDelaySeconds: TimeInterval = 0.8
    private static let resumeCommandDelaySeconds: TimeInterval = 0.6
    private static let resumeCommandRetryDelaySeconds: TimeInterval = 0.5
    private static let resumeCommandMaxRetryDelay: TimeInterval = 4.0
    private static let resumeCommandMaxAttempts = 16

    private static func paneStateMap(from states: [SavedTerminalPaneState]?) -> [UUID: SavedTerminalPaneState] {
        guard let states else { return [:] }
        var map: [UUID: SavedTerminalPaneState] = [:]
        for state in states {
            guard let uuid = UUID(uuidString: state.paneID) else { continue }
            map[uuid] = state
        }
        return map
    }

    /// Restores tabs from saved state. Returns nil if no saved state exists
    /// or if decoding fails.
    private static func restoreSavedTabs(appModel: AppModel) -> RestorableTabsPayload? {
        guard let data = UserDefaults.standard.data(forKey: SavedTabState.userDefaultsKey) else {
            return restoreSavedTabsFromBackups(appModel: appModel)
        }
        archiveImportedTabStateIfNeeded(data)
        // Clear saved state immediately so a crash during restoration
        // doesn't cause an infinite crash loop
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)

        if let payload = decodeRestorableTabs(from: data, appModel: appModel) {
            return payload
        }
        return restoreSavedTabsFromBackups(appModel: appModel)
    }

    /// Decode from pre-decoded states (multi-window restore — avoids UserDefaults round-trip).
    private static func decodeRestorableTabs(fromStates states: [SavedTabState], appModel: AppModel) -> RestorableTabsPayload? {
        guard !states.isEmpty else { return nil }
        // Re-encode to reuse the existing decode path (the processing after
        // JSON decode is non-trivial and not worth duplicating).
        guard let data = try? JSONEncoder().encode(states) else { return nil }
        return decodeRestorableTabs(from: data, appModel: appModel)
    }

    private static func decodeRestorableTabs(from data: Data, appModel: AppModel) -> RestorableTabsPayload? {
        guard let states = try? JSONDecoder().decode([SavedTabState].self, from: data),
              !states.isEmpty else {
            return nil
        }

        let colors = TabColor.allCases
        var restoredTabs: [OverlayTab] = []
        var selectedID: UUID?
        var fallbackSelectedIndex: Int?
        var persistedStates: [SavedTabState] = []

        for (i, state) in states.enumerated() {
            if selectedID == nil, let selected = Self.validatedUUID(from: state.selectedTabID) {
                selectedID = selected
            } else if state.selectedTabID != nil {
                Log.warn("restoreSavedTabs: multiple selected tab markers found in state; using first match")
            }

            let controller = Self.buildRestorableController(
                appModel: appModel,
                splitLayout: state.splitLayout,
                focusedPaneID: state.focusedPaneID,
                paneStates: state.paneStates
            )

            let restoredTabID = Self.validatedUUID(from: state.tabID) ?? UUID()
            let restoredCreatedAt: Date
            if let iso = state.createdAt,
               let parsed = DateFormatters.iso8601.date(from: iso) {
                restoredCreatedAt = parsed
            } else {
                restoredCreatedAt = Date()
            }
            var tab = OverlayTab(appModel: appModel, splitController: controller, id: restoredTabID, createdAt: restoredCreatedAt)
            tab.customTitle = state.customTitle
            tab.color = TabColor(rawValue: state.color) ?? colors[i % colors.count]
            tab.stampOwnerTabID()

            // Restore per-tab token optimization override
            if let overrideRaw = state.tokenOptOverride,
               let override = TabTokenOptOverride(rawValue: overrideRaw) {
                tab.tokenOptOverride = override
                // Sync to session so activeAppName.didSet uses the restored value
                tab.session?.tokenOptOverride = override
            }

            // Restore repo group membership
            tab.repoGroupID = state.repoGroupID

            if state.selectedIndex != nil {
                if fallbackSelectedIndex == nil {
                    fallbackSelectedIndex = i
                }
            }

            restoredTabs.append(tab)
            persistedStates.append(state)
        }

        guard !restoredTabs.isEmpty else { return nil }
        let fallbackSelectedID = fallbackSelectedIndex.flatMap { index in
            index < restoredTabs.count ? restoredTabs[index].id : nil
        }

        let finalSelectedID: UUID
        if let explicit = selectedID, restoredTabs.contains(where: { $0.id == explicit }) {
            finalSelectedID = explicit
        } else if let explicit = selectedID {
            if fallbackSelectedID != nil {
                Log.warn("restoreSavedTabs: explicit selected tab ID \(explicit) not found; falling back to legacy marker")
            } else {
                Log.warn("restoreSavedTabs: explicit selected tab ID \(explicit) not found; falling back to first tab")
            }
            finalSelectedID = fallbackSelectedID ?? restoredTabs[0].id
        } else {
            finalSelectedID = fallbackSelectedID ?? restoredTabs[0].id
        }

        if selectedID == nil, finalSelectedID != fallbackSelectedID, fallbackSelectedIndex == nil {
            Log.warn("restoreSavedTabs: falling back to first tab because no explicit or legacy selected marker was found")
        }

        return RestorableTabsPayload(
            tabs: restoredTabs,
            selectedID: finalSelectedID,
            rawStates: persistedStates
        )
    }

    private static func restoreSavedTabsFromBackups(appModel: AppModel) -> RestorableTabsPayload? {
        for url in tabStateRestoreCandidateURLs() {
            guard let data = try? Data(contentsOf: url) else { continue }
            guard let payload = decodeRestorableTabs(from: data, appModel: appModel) else { continue }
            Log.info("Restored \(payload.tabs.count) tab(s) from backup file \(url.lastPathComponent)")
            return payload
        }
        return nil
    }

    func persistTabStateBackups(data: Data, reason: TabStateSaveReason) {
        do {
            try Self.writeLatestTabStateBackup(data)
            if shouldArchiveTabStateBackup(data: data, reason: reason) {
                try Self.writeArchivedTabStateBackup(data, reason: reason)
                lastArchivedTabStateFingerprint = data.hashValue
                lastArchivedTabStateAt = Date()
            }
        } catch {
            Log.warn("Failed to persist tab state backup [\(reason.rawValue)]: \(error)")
        }
    }

    private func shouldArchiveTabStateBackup(data: Data, reason: TabStateSaveReason) -> Bool {
        if reason == .termination || reason == .restoreSource {
            return true
        }
        let fingerprint = data.hashValue
        guard lastArchivedTabStateFingerprint != fingerprint else { return false }
        return Date().timeIntervalSince(lastArchivedTabStateAt) >= 300
    }

    private static func archiveImportedTabStateIfNeeded(_ data: Data) {
        do {
            try writeLatestTabStateBackup(data)
            try writeArchivedTabStateBackup(data, reason: .restoreSource)
        } catch {
            Log.warn("Failed to archive imported tab state: \(error)")
        }
    }

    private static func tabStateBackupRootURL() -> URL? {
        RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("TabStateBackups", isDirectory: true)
    }

    private static func ensureTabStateBackupDirectories() throws -> (root: URL, archive: URL) {
        guard let root = tabStateBackupRootURL() else {
            throw NSError(domain: "Chau7.TabStateBackup", code: 1, userInfo: [NSLocalizedDescriptionKey: "Could not resolve tab state backup directory"])
        }
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        try FileManager.default.createDirectory(at: archive, withIntermediateDirectories: true)
        return (root, archive)
    }

    private static func writeLatestTabStateBackup(_ data: Data) throws {
        let urls = try ensureTabStateBackupDirectories()
        let latest = urls.root.appendingPathComponent("latest.json")
        try data.write(to: latest, options: .atomic)
    }

    private static func writeArchivedTabStateBackup(_ data: Data, reason: TabStateSaveReason) throws {
        let urls = try ensureTabStateBackupDirectories()
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        let name = String(format: "%013lld-%@.json", millis, reason.rawValue)
        let archiveURL = urls.archive.appendingPathComponent(name)
        try data.write(to: archiveURL, options: .atomic)
        try pruneArchivedTabStateBackups(in: urls.archive)
    }

    private static func pruneArchivedTabStateBackups(in archiveURL: URL) throws {
        let fileManager = FileManager.default
        let contents = try fileManager.contentsOfDirectory(
            at: archiveURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        let jsonFiles = contents.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        let cutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)

        for url in jsonFiles.dropFirst(120) {
            try? fileManager.removeItem(at: url)
        }

        for url in jsonFiles.prefix(120) {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modifiedAt = values?.contentModificationDate, modifiedAt < cutoff {
                try? fileManager.removeItem(at: url)
            }
        }
    }

    private static func tabStateRestoreCandidateURLs() -> [URL] {
        guard let root = tabStateBackupRootURL() else { return [] }
        let latest = root.appendingPathComponent("latest.json")
        let archive = root.appendingPathComponent("archive", isDirectory: true)
        let archiveFiles = (try? FileManager.default.contentsOfDirectory(
            at: archive,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent } ?? []

        if FileManager.default.fileExists(atPath: latest.path) {
            return archiveFiles + [latest]
        }
        return archiveFiles
    }

    private static func validatedUUID(from raw: String?) -> UUID? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return UUID(uuidString: raw)
    }

    private static func buildRestorableController(
        appModel: AppModel,
        splitLayout: SavedSplitNode?,
        focusedPaneID: String?,
        paneStates: [SavedTerminalPaneState]?
    ) -> SplitPaneController {
        guard let splitLayout else {
            let fallbackController = SplitPaneController(appModel: appModel)
            if let focusedPaneID, let focusID = UUID(uuidString: focusedPaneID) {
                fallbackController.setFocusedPane(focusID)
            }
            return fallbackController
        }

        let stateByPaneID = paneStateMap(from: paneStates)
        let focusedUUID = focusedPaneID.flatMap(UUID.init)
        let root = SplitNode.fromSavedNode(splitLayout, appModel: appModel, paneStates: stateByPaneID)
        return SplitPaneController(appModel: appModel, root: root, focusedPaneID: focusedUUID)
    }

    private func restoreTabState(for tab: OverlayTab, state: SavedTabState) {
        let targetTabID = tab.id
        let terminalSessions = tab.splitController.terminalSessions
        Log.info("restoreTabState: scheduled for tab=\(targetTabID), panes=\(terminalSessions.count)")
        guard !terminalSessions.isEmpty else { return }

        // Keep the restored focus for the active terminal pane (or fallback to
        // first terminal if an editor pane was serialized).
        if let restoredFocus = state.focusedPaneID.flatMap(UUID.init),
           tab.splitController.root.paneType(for: restoredFocus) == .terminal {
            tab.splitController.setFocusedPane(restoredFocus)
        }

        let paneStatesByID = Self.paneStateMap(from: state.paneStates)
        var paneStatesToRestore = paneStatesByID

        // Backward compatibility: legacy single-pane save has no per-pane states.
        if paneStatesByID.isEmpty, let firstPaneID = terminalSessions.first?.0 {
            paneStatesToRestore[firstPaneID] = SavedTerminalPaneState(
                paneID: firstPaneID.uuidString,
                directory: state.directory,
                scrollbackContent: state.scrollbackContent,
                aiResumeCommand: state.aiResumeCommand,
                aiProvider: state.aiProvider,
                aiSessionId: state.aiSessionId
            )
        }

        if paneStatesToRestore.count == 1,
           let firstEntry = paneStatesToRestore.first {
            let firstPane = firstEntry.value
            if firstPane.aiProvider == nil, firstPane.aiSessionId == nil {
                let legacyCommand = firstPane.aiResumeCommand ?? state.aiResumeCommand
                paneStatesToRestore[firstEntry.key] = SavedTerminalPaneState(
                    paneID: firstPane.paneID,
                    directory: firstPane.directory,
                    scrollbackContent: firstPane.scrollbackContent,
                    aiResumeCommand: legacyCommand,
                    aiProvider: firstPane.aiProvider ?? state.aiProvider,
                    aiSessionId: firstPane.aiSessionId ?? state.aiSessionId,
                    lastOutputAt: firstPane.lastOutputAt
                )
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.restoreDelaySeconds) { [weak self] in
            guard let self else { return }
            guard let restoredTab = tabs.first(where: { $0.id == targetTabID }) else {
                Log.warn("restoreTabState: tab no longer exists for id=\(targetTabID)")
                return
            }

            let currentSessions = restoredTab.splitController.terminalSessions
            guard !currentSessions.isEmpty else {
                Log.warn("restoreTabState: tab \(targetTabID) has no terminal sessions")
                return
            }

            let restoredFocus = state.focusedPaneID.flatMap(UUID.init)
            let activePaneID: UUID = if let restoredFocus,
                                        restoredTab.splitController.root.paneType(for: restoredFocus) == .terminal {
                restoredFocus
            } else {
                restoredTab.splitController.focusedTerminalSessionID() ?? currentSessions[0].0
            }

            if restoredTab.splitController.root.paneType(for: activePaneID) == .terminal {
                restoredTab.splitController.setFocusedPane(activePaneID)
            }

            var resolvedPaneStates: [UUID: SavedTerminalPaneState] = [:]
            for (paneID, session) in currentSessions {
                let paneState = paneStatesToRestore[paneID] ?? SavedTerminalPaneState(
                    paneID: paneID.uuidString,
                    directory: session.currentDirectory,
                    scrollbackContent: nil,
                    aiResumeCommand: nil,
                    aiProvider: nil,
                    aiSessionId: nil,
                    lastOutputAt: nil
                )
                let shouldUseLegacyTabFallback = paneStatesByID.isEmpty && currentSessions.count == 1
                let fallbackProvider = shouldUseLegacyTabFallback ? state.aiProvider : nil
                let fallbackSessionId = shouldUseLegacyTabFallback ? state.aiSessionId : nil

                let resolvedMetadata = Self.resolveAIResumeMetadataFromSavedState(
                    paneState: paneState,
                    fallbackAIProvider: fallbackProvider,
                    fallbackAISessionId: fallbackSessionId
                )
                let resolvedCommand = Self.buildAIResumeCommand(
                    provider: resolvedMetadata?.provider,
                    sessionId: resolvedMetadata?.sessionId
                )

                session.restoreAIMetadata(
                    provider: resolvedMetadata?.provider,
                    sessionId: resolvedMetadata?.sessionId
                )

                let effectivePaneState = SavedTerminalPaneState(
                    paneID: paneState.paneID,
                    directory: paneState.directory,
                    scrollbackContent: paneState.scrollbackContent,
                    aiResumeCommand: resolvedCommand ?? Self.normalizedResumeCommand(paneState.aiResumeCommand),
                    aiProvider: resolvedMetadata?.provider,
                    aiSessionId: resolvedMetadata?.sessionId,
                    lastOutputAt: paneState.lastOutputAt
                )
                resolvedPaneStates[paneID] = effectivePaneState
                paneStatesToRestore[paneID] = effectivePaneState
            }

            let normalizedResumeCommands = resolvedPaneStates.compactMap { paneID, paneState -> (UUID, String)? in
                guard let candidate = Self.normalizedResumeCommand(paneState.aiResumeCommand) else {
                    return nil
                }
                return (paneID, candidate)
            }
            let resumeTarget = normalizedResumeCommands.first(where: { $0.0 == activePaneID })
            if resumeTarget == nil {
                Log.info("restoreTabState: no resume command candidate found for tab=\(targetTabID)")
            }

            let restoreToken = UUID().uuidString
            for (paneID, session) in currentSessions {
                let effectivePaneState = resolvedPaneStates[paneID] ?? SavedTerminalPaneState(
                    paneID: paneID.uuidString,
                    directory: session.currentDirectory,
                    scrollbackContent: nil,
                    aiResumeCommand: nil,
                    aiProvider: nil,
                    aiSessionId: nil,
                    lastOutputAt: nil
                )

                var commands: [String] = []
                if let scrollback = effectivePaneState.scrollbackContent,
                   !scrollback.isEmpty,
                   let data = scrollback.data(using: .utf8) {

                    let tempFile = NSTemporaryDirectory() + "chau7_restore_\(restoreToken)_\(paneID.uuidString).txt"
                    do {
                        try data.write(to: URL(fileURLWithPath: tempFile))
                        let escapedTemp = Self.shellSafeSingleQuote(tempFile)
                        commands.append("cat \(escapedTemp) && rm -f \(escapedTemp)")
                    } catch {
                        Log.warn("Failed to write scrollback restore file: \(error)")
                    }
                }

                if !effectivePaneState.directory.isEmpty {
                    commands.append("cd \(Self.shellSafeSingleQuote(effectivePaneState.directory))")
                }

                if !commands.isEmpty {
                    session.sendOrQueueInput(commands.joined(separator: " && ") + "\n")
                }

                if let (resumePaneID, resumeCommand) = resumeTarget,
                   resumePaneID == paneID {
                    Log.info("restoreTabState: scheduling resume command for tab=\(targetTabID) pane=\(paneID)")
                    latestRestoreResumeTokenByPaneID[paneID] = restoreToken
                    scheduleResumeCommand(
                        command: resumeCommand,
                        targetTabID: targetTabID,
                        paneID: paneID,
                        restoreToken: restoreToken,
                        remainingAttempts: Self.resumeCommandMaxAttempts,
                        delay: Self.resumeCommandDelaySeconds
                    )
                }
            }
        }
    }

    private func scheduleResumeCommand(
        command: String,
        targetTabID: UUID,
        paneID: UUID,
        restoreToken: String,
        remainingAttempts: Int,
        delay: TimeInterval = 0
    ) {
        guard remainingAttempts > 0 else {
            // Last resort: queue the command so the session's own retry logic
            // can deliver it when the terminal becomes ready (e.g. tab unsuspends).
            if let tab = tabs.first(where: { $0.id == targetTabID }),
               let session = tab.splitController.root.findSession(id: paneID) {
                session.prefillInput(command)
                Log.warn("restoreTabState: retries exhausted, queued prefill for tab=\(targetTabID) pane=\(paneID)")
            } else {
                Log.warn("restoreTabState: retries exhausted, tab/pane gone for tab=\(targetTabID) pane=\(paneID)")
            }
            latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard latestRestoreResumeTokenByPaneID[paneID] == restoreToken else {
                Log.trace("restoreTabState: skipping stale resume prefill for tab=\(targetTabID) pane=\(paneID)")
                return
            }

            guard let restoredTab = tabs.first(where: { $0.id == targetTabID }) else {
                Log.warn("restoreTabState: cannot send resume command for missing tab=\(targetTabID)")
                latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
                return
            }

            guard let reResolvedSession = restoredTab.splitController.root.findSession(id: paneID) else {
                Log.warn("restoreTabState: cannot find pane=\(paneID) for tab=\(targetTabID)")
                latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
                return
            }

            if !reResolvedSession.canPrefillInput() {
                let hasView = reResolvedSession.existingRustTerminalView != nil

                // No view means this tab is outside the nearby rendering range.
                // Delegate to the session's pending prefill mechanism which will
                // deliver the command when the view is eventually created via
                // attachRustTerminal → flushPendingPrefillInputIfReady.
                if !hasView {
                    reResolvedSession.prefillInput(command)
                    latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
                    Log.info("restoreTabState: no view for tab=\(targetTabID) pane=\(paneID), queued session-level prefill")
                    return
                }

                let nextDelay = min(delay + Self.resumeCommandRetryDelaySeconds, Self.resumeCommandMaxRetryDelay)
                Log.warn(
                    """
                    restoreTabState: resume command not ready for tab=\(targetTabID) pane=\(paneID) \
                    (loading=\(reResolvedSession.isShellLoading), atPrompt=\(reResolvedSession.isAtPrompt), \
                    status=\(reResolvedSession.status), hasView=\(hasView)); \
                    retry in \(String(format: "%.2f", nextDelay))s
                    """
                )
                scheduleResumeCommand(
                    command: command,
                    targetTabID: targetTabID,
                    paneID: paneID,
                    restoreToken: restoreToken,
                    remainingAttempts: remainingAttempts - 1,
                    delay: nextDelay
                )
                return
            }

            // Prefill the command in the active terminal so user can confirm with Enter.
            reResolvedSession.prefillInput(command)
            latestRestoreResumeTokenByPaneID.removeValue(forKey: paneID)
            Log.info("restoreTabState: resume command prefilling for tab=\(targetTabID) pane=\(paneID)")
        }
    }

    private static func normalizedResumeCommand(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard isSafeResumeCommand(trimmed) else { return nil }
        return trimmed
    }

    private static func isSafeResumeCommand(_ command: String) -> Bool {
        if let sessionId = command.extractResumeSessionId(prefix: "claude --resume ") {
            return isValidSessionId(sessionId)
        }
        if let sessionId = command.extractResumeSessionId(prefix: "codex resume ") {
            return isValidSessionId(sessionId)
        }
        return false
    }

    var selectedTab: OverlayTab? {
        tabs.first { $0.id == selectedTabID }
    }

    func notificationTabTitle(for target: TabTarget) -> String? {
        TabResolver.resolve(target, in: tabs)?.displayTitle
    }

    var overlayWorkspaceIdentifier: String? {
        if let repoRoot = SnippetManager.shared.activeRepoRoot {
            return repoRoot
        }
        return selectedTab?.session?.currentDirectory
    }

    var hasActiveOverlay: Bool {
        isSearchVisible
            || isRenameVisible
            || isClipboardHistoryVisible
            || isBookmarkListVisible
            || isSnippetManagerVisible
    }

    private func updateSnippetContextForSelection() {
        if let tab = selectedTab, let session = tab.session {
            SnippetManager.shared.updateContextPath(session.currentDirectory)
        }
    }

    private func inheritedStartDirectory() -> String? {
        guard FeatureSettings.shared.newTabsUseCurrentDirectory else { return nil }
        guard let current = selectedTab?.session?.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines),
              !current.isEmpty else {
            return nil
        }
        let resolved = TerminalSessionModel.resolveStartDirectory(current)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return resolved
    }

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
            self.updateSuspensionState()
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

    // MARK: - Tab Switch Optimization: Snapshot Capture

    /// Captures a screenshot of the current terminal view for instant display during tab switch
    private func captureCurrentTabSnapshot() {
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
    private func cleanupDistantSnapshots(currentIndex: Int) {
        for i in 0 ..< tabs.count {
            if abs(i - currentIndex) > 2 {
                tabs[i].cachedSnapshot = nil
            }
        }
    }

    // MARK: - Tab Switch Optimization: Pre-warm on Hover

    /// Pre-warms a tab by canceling its suspension early (called on hover)
    /// This gives the terminal time to update before the user clicks
    func prewarmTab(id: UUID) {
        guard id != selectedTabID else { return }
        guard !prewarmingTabIDs.contains(id) else { return }

        prewarmingTabIDs.insert(id)
        cancelSuspension(for: id)
        suspendedTabIDs.remove(id)

        Log.trace("Pre-warming tab \(id) on hover")

        // Clear prewarm state after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.prewarmingTabIDs.remove(id)
        }
    }

    /// Called when hover exits a tab - re-schedules suspension if not selected
    func cancelPrewarm(id: UUID) {
        guard id != selectedTabID else { return }
        prewarmingTabIDs.remove(id)

        // Re-schedule suspension after a short delay if still not selected
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, id != selectedTabID else { return }
            scheduleSuspension(for: id)
        }
    }

    func newTab(selectNewTab: Bool = true) {
        dispatchPrecondition(condition: .onQueue(.main))
        Log.trace("newTab: creating new tab, current tabs.count=\(tabs.count)")
        needsFreshTabOnShow = false
        var tab = OverlayTab(appModel: appModel)
        let colors = TabColor.allCases
        if !colors.isEmpty {
            tab.color = colors[tabs.count % colors.count]
        }
        tab.stampOwnerTabID()
        if let directory = inheritedStartDirectory() {
            tab.session?.updateCurrentDirectory(directory)
        }

        // Insert based on settings
        let position = FeatureSettings.shared.newTabPosition
        if position == "after", let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: currentIndex + 1)
            Log.trace("newTab: inserted at index \(currentIndex + 1), tabs.count=\(tabs.count)")
        } else {
            tabs.append(tab)
            Log.trace("newTab: appended, tabs.count=\(tabs.count)")
        }

        // Set up repo grouping for the new tab
        setupRepoGroupingForTab(tab)

        // Reset rendered count so the watchdog doesn't see a stale count vs new expected
        lastReportedRenderedCount = -1
        lastPreferenceUpdateTime = Date()

        if selectNewTab {
            selectedTabID = tab.id
            Log.trace("newTab: selectedTabID=\(tab.id)")
            focusSelected()
            updateSnippetContextForSelection()
        } else {
            tab.session?.setAutoFocusOnAttach(false)
            Log.trace("newTab: created background tab \(tab.id)")
        }
        updateSuspensionState()
        if isSearchVisible {
            refreshSearch()
        }

        // CTO: defer flag file creation until first prompt to avoid optimizer
        // overhead during shell init scripts (NVM, compinit, etc.).
        tab.session?.markCTOFlagDeferred(mode: FeatureSettings.shared.tokenOptimizationMode)

        // Emit tab_opened event if enabled
        if FeatureSettings.shared.appEventConfig.notifyOnTabOpen {
            appModel.recordEvent(
                source: .app,
                type: "tab_opened",
                tool: "App",
                message: "New tab opened (total: \(tabs.count))",
                notify: true
            )
        }
    }

    func newTab(at directory: String, selectNewTab: Bool = true) {
        needsFreshTabOnShow = false
        var tab = OverlayTab(appModel: appModel)
        let colors = TabColor.allCases
        if !colors.isEmpty {
            tab.color = colors[tabs.count % colors.count]
        }
        tab.stampOwnerTabID()

        // Set the starting directory for the new tab (triggers git status refresh)
        tab.session?.updateCurrentDirectory(directory)
        tab.session?.markCTOFlagDeferred(mode: FeatureSettings.shared.tokenOptimizationMode)

        // Insert based on settings
        let position = FeatureSettings.shared.newTabPosition
        if position == "after", let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: currentIndex + 1)
        } else {
            tabs.append(tab)
        }

        if selectNewTab {
            selectedTabID = tab.id
            focusSelected()
            updateSnippetContextForSelection()
        } else {
            tab.session?.setAutoFocusOnAttach(false)
            Log.trace("newTab(at:): created background tab \(tab.id) at \(directory)")
        }
        updateSuspensionState()
        if isSearchVisible {
            refreshSearch()
        }

        // Emit tab_opened event if enabled
        if FeatureSettings.shared.appEventConfig.notifyOnTabOpen {
            appModel.recordEvent(
                source: .app,
                type: "tab_opened",
                tool: "App",
                message: "New tab opened at \(directory) (total: \(tabs.count))",
                notify: true
            )
        }
    }

    func closeCurrentTab() {
        Log.info("closeCurrentTab called. selectedTabID=\(selectedTabID), tabs.count=\(tabs.count)")
        closeTab(id: selectedTabID)
    }

    /// Check if a tab has any running process (not idle or exited)
    /// Returns the count of running processes across all split panes
    private func countRunningProcesses(in tab: OverlayTab) -> Int {
        var count = 0
        for session in tab.splitController.root.allSessions {
            switch session.status {
            case .running, .waitingForInput, .stuck:
                count += 1
            case .idle, .exited:
                continue
            }
        }
        return count
    }

    private func tabHasRunningProcess(_ tab: OverlayTab) -> Bool {
        return countRunningProcesses(in: tab) > 0
    }

    /// Show confirmation dialog before closing tab. Returns true if user confirms.
    /// - Parameters:
    ///   - runningProcessCount: Number of running processes in the tab
    ///   - isLastTab: Whether this is the last tab (will be replaced, not closed)
    ///   - willCloseWindow: Whether closing will close the window entirely
    ///   - isAlwaysWarnMode: Whether we're warning due to "always warn" setting (shows suppression option)
    /// Ask the user whether to also close the window when closing the last tab.
    /// Returns true if the user wants to close the window.
    private func confirmCloseLastTab() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("alert.closeLastTab.title", "This is the last tab")
        alert.informativeText = L("alert.closeLastTab.message", "Do you want to close the window, or keep it open with a new tab?")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("alert.closeLastTab.closeWindow", "Close Window"))
        alert.addButton(withTitle: L("alert.closeLastTab.newTab", "New Tab"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmTabClose(
        runningProcessCount: Int,
        isLastTab: Bool,
        willCloseWindow: Bool,
        isAlwaysWarnMode: Bool
    ) -> Bool {
        let alert = NSAlert()
        let hasRunningProcess = runningProcessCount > 0

        if hasRunningProcess {
            // Title based on process count
            if runningProcessCount == 1 {
                alert.messageText = L("alert.closeTab.runningProcess.title", "Close tab with running process?")
            } else {
                alert.messageText = L("alert.closeTab.runningProcesses.title", "Close tab with \(runningProcessCount) running processes?")
            }

            // Message based on what will happen
            if isLastTab, !willCloseWindow {
                // Last tab with keepWindow behavior - tab is replaced
                if runningProcessCount == 1 {
                    alert.informativeText = L(
                        "alert.closeTab.runningProcess.replace.message",
                        "This tab has a running process. The process will be terminated and a new tab will open."
                    )
                } else {
                    alert.informativeText = L(
                        "alert.closeTab.runningProcesses.replace.message",
                        "This tab has \(runningProcessCount) running processes. All processes will be terminated and a new tab will open."
                    )
                }
            } else if willCloseWindow {
                // Last tab with closeWindow behavior
                if runningProcessCount == 1 {
                    alert.informativeText = L(
                        "alert.closeTab.runningProcess.closeWindow.message",
                        "This tab has a running process. The process will be terminated and the window will close."
                    )
                } else {
                    alert.informativeText = L(
                        "alert.closeTab.runningProcesses.closeWindow.message",
                        "This tab has \(runningProcessCount) running processes. All processes will be terminated and the window will close."
                    )
                }
            } else {
                // Normal close (multiple tabs exist)
                if runningProcessCount == 1 {
                    alert.informativeText = L(
                        "alert.closeTab.runningProcess.message",
                        "This tab has a running process. Closing it will terminate the process."
                    )
                } else {
                    alert.informativeText = L(
                        "alert.closeTab.runningProcesses.message",
                        "This tab has \(runningProcessCount) running processes. Closing it will terminate all processes."
                    )
                }
            }
        } else {
            // No running process - only shown when "always warn" is enabled
            alert.messageText = L("alert.closeTab.confirm.title", "Close this tab?")
            if isLastTab, !willCloseWindow {
                alert.informativeText = L(
                    "alert.closeTab.confirm.replace.message",
                    "This is the last tab. A new tab will be created."
                )
            } else if willCloseWindow {
                alert.informativeText = L(
                    "alert.closeTab.confirm.closeWindow.message",
                    "This is the last tab. The window will be closed."
                )
            } else {
                alert.informativeText = L(
                    "alert.closeTab.confirm.message",
                    "Are you sure you want to close this tab?"
                )
            }
        }

        alert.alertStyle = .warning
        alert.addButton(withTitle: L("button.closeTab", "Close Tab"))
        alert.addButton(withTitle: L("button.cancel", "Cancel"))

        // Show "Don't ask again" only for the "always warn" mode (not for running process warnings)
        if isAlwaysWarnMode, !hasRunningProcess {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = L("alert.closeTab.dontAskAgain", "Don't ask again")
        }

        let result = alert.runModal()

        // If user checked "Don't ask again", disable the setting
        if alert.suppressionButton?.state == .on {
            FeatureSettings.shared.alwaysWarnOnTabClose = false
        }

        return result == .alertFirstButtonReturn
    }

    func closeTab(id: UUID, skipWarning: Bool = false) {
        dispatchPrecondition(condition: .onQueue(.main))
        dismissHoverCard()
        Log.info("closeTab called with id=\(id). tabs.count=\(tabs.count)")
        guard let initialIndex = tabs.firstIndex(where: { $0.id == id }) else {
            Log.warn("closeTab: tab with id=\(id) not found!")
            return
        }

        let tab = tabs[initialIndex]
        let settings = FeatureSettings.shared
        let runningProcessCount = countRunningProcesses(in: tab)
        let hasRunningProcess = runningProcessCount > 0
        let isLastTab = tabs.count == 1

        // Handle last tab: prompt user or silently replace (skipWarning)
        if isLastTab {
            let closeWindow = skipWarning ? false : confirmCloseLastTab()
            guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }

            // Clean up per-tab state before replacing
            if let sessionID = tabs[idx].session?.tabIdentifier {
                CommandHistoryManager.shared.removeTab(sessionID)
                CTOFlagManager.removeFlag(sessionID: sessionID)
                CTORuntimeMonitor.shared.untrackSession(sessionID)
            }

            let dir = inheritedStartDirectory()
            tabs[idx].splitController.root.closeAllSessions()
            if closeWindow {
                Log.info("closeTab: last tab - user chose to close window")
                tabs[idx] = makeFreshTab(inheritedDirectory: dir)
                selectedTabID = tabs[idx].id
                needsFreshTabOnShow = false
                onCloseLastTab?()
            } else {
                Log.info("closeTab: last tab - replacing with fresh tab")
                let newTab = makeFreshTab(inheritedDirectory: dir)
                tabs[idx] = newTab
                selectedTabID = newTab.id
            }
            return
        }

        // Non-last tabs: check if we need a warning dialog
        let warnForProcess = settings.warnOnCloseWithRunningProcess && hasRunningProcess
        let warnAlways = settings.alwaysWarnOnTabClose
        let shouldWarn = !skipWarning && (warnForProcess || warnAlways)

        if shouldWarn {
            let confirmed = confirmTabClose(
                runningProcessCount: runningProcessCount,
                isLastTab: false,
                willCloseWindow: false,
                isAlwaysWarnMode: warnAlways && !warnForProcess
            )
            guard confirmed else {
                Log.info("closeTab: user cancelled close for tab \(id)")
                return
            }
        }

        // Re-validate after modal: tabs may have changed while dialog was shown
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            Log.warn("closeTab: tab \(id) no longer exists after confirmation dialog")
            return
        }
        let isLastTabNow = tabs.count == 1

        // inheritedDirectory not needed — last tab is handled in the early-return block above
        Log.info("closeTab: found tab at index=\(index)")
        if isRenameVisible {
            clearRenameState(shouldFocus: false)
        }

        // Snapshot tab state BEFORE killing the shell (scrollback is gone after close).
        // Use initialIndex (captured before the modal dialog) so reopening restores
        // to the original position even if other tabs were closed while the dialog was open.
        captureClosedTabSnapshot(tab: tabs[index], at: initialIndex)

        // Clean up per-tab command history
        if let sessionID = tabs[index].session?.tabIdentifier {
            CommandHistoryManager.shared.removeTab(sessionID)
            // CTO: remove flag file for closed tab
            let hadCTOFlag = CTOFlagManager.removeFlag(sessionID: sessionID)
            if hadCTOFlag,
               let session = tabs[index].session {
                let isAI = session.activeAppName != nil
                CTORuntimeMonitor.shared.recordDecision(
                    sessionID: sessionID,
                    mode: FeatureSettings.shared.tokenOptimizationMode,
                    override: tabs[index].tokenOptOverride,
                    isAIActive: isAI,
                    previousState: true,
                    nextState: false,
                    changed: true,
                    reason: decisionReason(
                        mode: FeatureSettings.shared.tokenOptimizationMode,
                        override: tabs[index].tokenOptOverride,
                        isAIActive: isAI
                    )
                )
            }
            CTORuntimeMonitor.shared.untrackSession(sessionID)
        }

        // Close all sessions in the split pane tree (not just primary)
        tabs[index].splitController.root.closeAllSessions()

        if isLastTabNow {
            // Last tab was already handled above (early return with prompt)
            Log.warn("closeTab: unexpected last-tab fallthrough")
            return
        } else {
            // Multiple tabs - just remove this one
            Log.info("closeTab: removing tab at index=\(index), tabs.count before=\(tabs.count)")
            cleanupRepoGroupingForTab(id)
            tabs.remove(at: index)
            // Reset the rendered count so the watchdog doesn't compare the stale
            // pre-close count against the new (smaller) expected count.  The next
            // preference update from the re-rendered tab bar will set it correctly.
            lastReportedRenderedCount = -1
            lastPreferenceUpdateTime = Date()
            Log.info("closeTab: tabs.count after=\(tabs.count)")

            if selectedTabID == id {
                // Prefer the tab that was to the left (index - 1), falling back to index 0
                let newIndex = min(max(0, index - 1), tabs.count - 1)
                selectedTabID = tabs[newIndex].id
                Log.info("closeTab: selected new tab at index=\(newIndex), id=\(selectedTabID)")
            } else if !tabs.contains(where: { $0.id == selectedTabID }) {
                // Safety: selectedTabID references a non-existent tab (should never happen, but recover)
                Log.warn("closeTab: selectedTabID \(selectedTabID) not found in tabs — recovering")
                selectedTabID = tabs[max(0, min(index, tabs.count - 1))].id
            }

            // Unsuspend the newly selected tab so its terminal view is available for focus
            cancelSuspension(for: selectedTabID)
            if suspendedTabIDs.remove(selectedTabID) != nil {
                Log.info("closeTab: unsuspended newly selected tab \(selectedTabID)")
            }
        }

        // Ensure terminal is visible (recover from stuck isTerminalReady=false)
        isTerminalReady = true

        focusSelected()

        // Schedule a retry of focusSelected() after a short delay, in case the terminal
        // view from an unsuspended tab hasn't been attached yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.focusSelected()
        }
        updateSuspensionState()
        updateSnippetContextForSelection()
        if isSearchVisible {
            refreshSearch()
        }

        // Emit tab_closed event if enabled
        if FeatureSettings.shared.appEventConfig.notifyOnTabClose {
            appModel.recordEvent(
                source: .app,
                type: "tab_closed",
                tool: "App",
                message: "Tab closed (remaining: \(tabs.count))",
                notify: true
            )
        }

        Log.info("closeTab completed. tabs.count=\(tabs.count)")
    }

    func closeAllSessionsForTermination() {
        dispatchPrecondition(condition: .onQueue(.main))
        for tab in tabs {
            for session in tab.splitController.root.allSessions {
                session.closeSessionForTermination()
            }
        }
    }

    func closeOtherTabs() {
        guard tabs.count > 1 else { return }
        let currentID = selectedTabID
        let otherTabs = tabs.filter { $0.id != currentID }
        let settings = FeatureSettings.shared

        // Count tabs and total processes
        let totalToClose = otherTabs.count
        var totalProcessCount = 0
        var tabsWithProcesses = 0
        for tab in otherTabs {
            let count = countRunningProcesses(in: tab)
            if count > 0 {
                tabsWithProcesses += 1
                totalProcessCount += count
            }
        }

        // Check if we need to show a warning
        let warnForProcess = settings.warnOnCloseWithRunningProcess && totalProcessCount > 0
        let warnAlways = settings.alwaysWarnOnTabClose
        let shouldWarn = warnForProcess || warnAlways

        if shouldWarn {
            let alert = NSAlert()
            if totalProcessCount > 0 {
                alert.messageText = L("alert.closeOtherTabs.title", "Close \(totalToClose) tabs?")
                // Build informative message with process details
                let processInfo: String
                if totalProcessCount == 1 {
                    processInfo = L(
                        "alert.closeOtherTabs.process.singular",
                        "1 running process will be terminated."
                    )
                } else if tabsWithProcesses == 1 {
                    processInfo = L(
                        "alert.closeOtherTabs.processes.oneTab",
                        "\(totalProcessCount) running processes in 1 tab will be terminated."
                    )
                } else {
                    processInfo = L(
                        "alert.closeOtherTabs.processes.multipleTabs",
                        "\(totalProcessCount) running processes across \(tabsWithProcesses) tabs will be terminated."
                    )
                }
                alert.informativeText = processInfo
            } else {
                alert.messageText = L("alert.closeOtherTabs.confirm.title", "Close \(totalToClose) tabs?")
                alert.informativeText = L("alert.closeOtherTabs.confirm.message", "Are you sure you want to close all other tabs?")
            }
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("button.closeTabs", "Close Tabs"))
            alert.addButton(withTitle: L("button.cancel", "Cancel"))

            // Show "Don't ask again" only for "always warn" mode without running processes
            if warnAlways, totalProcessCount == 0 {
                alert.showsSuppressionButton = true
                alert.suppressionButton?.title = L("alert.closeTab.dontAskAgain", "Don't ask again")
            }

            let result = alert.runModal()

            // If user checked "Don't ask again", disable the setting
            if alert.suppressionButton?.state == .on {
                FeatureSettings.shared.alwaysWarnOnTabClose = false
            }

            guard result == .alertFirstButtonReturn else {
                Log.info("closeOtherTabs: user cancelled")
                return
            }
        }

        // Re-validate after modal: tabs may have changed while dialog was shown
        guard tabs.contains(where: { $0.id == currentID }) else {
            Log.warn("closeOtherTabs: selected tab \(currentID) no longer exists after confirmation dialog")
            return
        }

        // Re-compute other tabs based on current state
        let currentOtherTabs = tabs.filter { $0.id != currentID }
        guard !currentOtherTabs.isEmpty else {
            Log.info("closeOtherTabs: no other tabs to close after re-validation")
            return
        }

        // Snapshot each tab BEFORE killing its shell (reverse order so
        // Cmd+Shift+T restores the rightmost closed tab first)
        for tab in currentOtherTabs.reversed() {
            if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
                captureClosedTabSnapshot(tab: tab, at: idx)
            }
        }

        // Close all sessions in all tabs except current one
        for tab in currentOtherTabs {
            if let sessionID = tab.session?.tabIdentifier {
                CTORuntimeMonitor.shared.untrackSession(sessionID)
            }
            tab.splitController.root.closeAllSessions()
        }

        tabs = tabs.filter { $0.id == currentID }
        Log.info("Closed all other tabs, keeping \(currentID)")
    }

    /// Reopens the most recently closed tab, restoring its title, color, directory,
    /// scrollback content, and AI resume command. Inserts at the original position
    /// (clamped to current tab count). Matches browser Cmd+Shift+T behavior.
    func reopenClosedTab() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard let entry = closedTabStack.popLast() else {
            Log.info("reopenClosedTab: stack is empty")
            return
        }

        let state = entry.state
        let insertIndex = min(entry.originalIndex, tabs.count)
        let controller = Self.buildRestorableController(
            appModel: appModel,
            splitLayout: state.splitLayout,
            focusedPaneID: state.focusedPaneID,
            paneStates: state.paneStates
        )

        var tab = OverlayTab(appModel: appModel, splitController: controller)
        tab.customTitle = state.customTitle
        tab.color = TabColor(rawValue: state.color) ?? .blue
        tab.stampOwnerTabID()
        if let overrideRaw = state.tokenOptOverride,
           let override = TabTokenOptOverride(rawValue: overrideRaw) {
            tab.tokenOptOverride = override
            tab.session?.tokenOptOverride = override
        }

        tabs.insert(tab, at: insertIndex)
        selectedTabID = tab.id

        restoreTabState(for: tab, state: state)

        Log.info("reopenClosedTab: restored \"\(tab.displayTitle)\" at index \(insertIndex) (stack remaining: \(closedTabStack.count))")

        tabBarRefreshToken += 1
    }

    func selectNextTab() {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            Log.trace("selectNextTab: skipped (tabs.count=\(tabs.count))")
            return
        }
        let nextIndex = (index + 1) % tabs.count
        Log.trace("selectNextTab: \(index) -> \(nextIndex), tabs.count=\(tabs.count)")
        let targetID = tabs[nextIndex].id
        selectedTabID = targetID

        // Ensure terminal is visible (recover from stuck isTerminalReady=false)
        isTerminalReady = true

        // Unsuspend target tab so its terminal view is available for focus
        cancelSuspension(for: targetID)
        if suspendedTabIDs.remove(targetID) != nil {
            Log.info("selectNextTab: unsuspended tab \(targetID)")
        }

        focusSelected()
        updateSuspensionState()
        updateSnippetContextForSelection()
        if isSearchVisible {
            refreshSearch()
        }
    }

    func selectPreviousTab() {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            Log.trace("selectPreviousTab: skipped (tabs.count=\(tabs.count))")
            return
        }
        let prevIndex = (index - 1 + tabs.count) % tabs.count
        Log.trace("selectPreviousTab: \(index) -> \(prevIndex), tabs.count=\(tabs.count)")
        let targetID = tabs[prevIndex].id
        selectedTabID = targetID

        // Ensure terminal is visible (recover from stuck isTerminalReady=false)
        isTerminalReady = true

        // Unsuspend target tab so its terminal view is available for focus
        cancelSuspension(for: targetID)
        if suspendedTabIDs.remove(targetID) != nil {
            Log.info("selectPreviousTab: unsuspended tab \(targetID)")
        }

        focusSelected()
        updateSuspensionState()
        updateSnippetContextForSelection()
        if isSearchVisible {
            refreshSearch()
        }
    }

    func focusSelected() {
        ensureFreshTabIfNeeded()
        guard let window = overlayWindow else { return }
        guard let tab = selectedTab else { return }

        // Always focus a terminal pane when switching tabs.
        if let terminalID = tab.splitController.focusedTerminalSessionID() {
            tab.splitController.focusedPaneID = terminalID
            if let focusedSession = tab.splitController.root.findSession(id: terminalID) {
                focusedSession.focusTerminal(in: window)
                return
            }
        }

        tab.displaySession?.focusTerminal(in: window)
    }

    private func ensureFreshTabIfNeeded() {
        guard needsFreshTabOnShow else { return }
        needsFreshTabOnShow = false
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }

        let newTab = makeFreshTab(inheritedDirectory: nil)
        tabs[index] = newTab
        selectedTabID = newTab.id
        updateSnippetContextForSelection()
    }

    private func makeFreshTab(inheritedDirectory: String?) -> OverlayTab {
        var newTab = OverlayTab(appModel: appModel)
        if let firstColor = TabColor.allCases.first {
            newTab.color = firstColor
        }
        newTab.stampOwnerTabID()
        if let inheritedDirectory {
            newTab.session?.updateCurrentDirectory(inheritedDirectory)
        }
        return newTab
    }

    func selectTab(number: Int) {
        let index = max(0, number - 1)
        guard index < tabs.count else { return }
        let targetID = tabs[index].id
        if selectedTabID == targetID {
            // Already on this tab — just re-focus the terminal (handles the case
            // where focus moved to a non-terminal UI element like the search bar)
            isTerminalReady = true
            focusSelected()
            return
        }
        // Reuse canonical tab selection path so side effects stay consistent
        // (notification clear, hover-card dismissal, snapshot/focus behavior).
        selectTab(id: targetID)
    }

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
    func setNotificationStyle(_ style: TabNotificationStyle?, for tabID: UUID? = nil) {
        dispatchPrecondition(condition: .onQueue(.main))
        let targetID = tabID ?? selectedTabID
        guard let index = tabs.firstIndex(where: { $0.id == targetID }) else { return }

        // Don't apply notification styling to the tab the user is already looking at —
        // the style is meant to draw attention to background tabs. Clearing (nil) always applies.
        if style != nil, targetID == selectedTabID {
            Log.trace("Skipping notification style for active tab \(targetID)")
            return
        }

        tabs[index].notificationStyle = style
        if let style {
            let desc = style.icon ?? "border/color"
            Log.info("Tab notification style set: \(desc) for tab \(targetID)")
        } else {
            Log.info("Tab notification style cleared for tab \(targetID)")
        }
    }

    /// Sets a notification style on the tab associated with a terminal session
    func setNotificationStyle(_ style: TabNotificationStyle?, forSession session: TerminalSessionModel) {
        guard let tab = tabs.first(where: { $0.session === session }) else { return }
        setNotificationStyle(style, for: tab.id)
    }

    /// Clears persistent notification style (e.g., permission red border) when
    /// the session resumes after a permission answer.
    func clearPersistentStyle(for tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              tabs[index].notificationStyle?.persistent == true else { return }
        tabs[index].notificationStyle = nil
        Log.info("Persistent tab style cleared for tab \(tabID) (permission resolved)")
    }

    /// Clears notification style from a tab
    func clearNotificationStyle(for tabID: UUID? = nil) {
        setNotificationStyle(nil, for: tabID)
    }

    /// Applies a notification style to a tab based on tool name (used by notification action system)
    @discardableResult
    func applyNotificationStyle(for target: TabTarget, stylePreset: String, config: [String: String]) -> UUID? {
        dispatchPrecondition(condition: .onQueue(.main))

        guard let tab = resolveTab(for: target) else {
            Log.info("applyNotificationStyle: No tab found matching tool '\(target.tool)'")
            return nil
        }

        let style: TabNotificationStyle? = stylePreset == "clear"
            ? nil
            : buildNotificationStyle(preset: stylePreset, config: config)

        setNotificationStyle(style, for: tab.id)
        return tab.id
    }

    /// Builds a TabNotificationStyle from preset and config
    private func buildNotificationStyle(preset: String, config: [String: String]) -> TabNotificationStyle {
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
    private func colorFromString(_ colorName: String) -> Color {
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
    private func resolveTab(for target: TabTarget) -> OverlayTab? {
        if let tabID = target.tabID {
            return tabs.first(where: { $0.id == tabID })
        }
        return TabResolver.resolve(target, in: tabs)
    }

    /// Finds the tab matching the target and selects it.
    func focusTab(for target: TabTarget) {
        guard let tab = resolveTab(for: target) else {
            Log.info("focusTab: No tab found for '\(target.tool)'")
            return
        }
        selectTab(id: tab.id)
    }

    /// Sets a badge on the tab matching the target via the unified TabNotificationStyle.
    func setBadge(for target: TabTarget, text: String, color: String) {
        guard let tab = resolveTab(for: target) else {
            Log.info("setBadge: No tab found for '\(target.tool)'")
            return
        }
        var style = tab.notificationStyle ?? TabNotificationStyle()
        style.badgeText = text
        style.badgeColor = colorFromString(color)
        setNotificationStyle(style, for: tab.id)
        Log.info("setBadge: Set badge '\(text)' on tab for '\(target.tool)'")
    }

    /// Inserts a snippet by ID into the tab matching the target.
    func insertSnippet(id snippetId: String, for target: TabTarget, autoExecute: Bool) {
        guard let entry = SnippetManager.shared.entries.first(where: { $0.snippet.id == snippetId }) else {
            Log.warn("insertSnippet: Snippet '\(snippetId)' not found")
            return
        }
        if let tab = resolveTab(for: target) {
            selectTab(id: tab.id)
        }
        insertSnippet(entry)
        Log.info("insertSnippet: Inserted snippet '\(snippetId)' for tool '\(target.tool)'")
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
        // Also trigger objectWillChange to ensure all observers update
        objectWillChange.send()

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
        // 3. Trigger SwiftUI re-render
        objectWillChange.send()

        // 4. Re-focus
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
        // Prevent duplicate timers
        guard tabBarWatchdogTimer == nil else {
            Log.info("TabBar watchdog: already running, skipping start")
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 3.0, repeating: 3.0)
        timer.setEventHandler { [weak self] in
            self?.checkTabBarHealth()
        }
        timer.resume()
        tabBarWatchdogTimer = timer
        Log.info("TabBar watchdog: started")
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

    /// Remove a tab from this model and return it (for transfer to another window).
    func detachTab(id: UUID) -> OverlayTab? {
        guard let index = tabs.firstIndex(where: { $0.id == id }), tabs.count > 1 else { return nil }
        let tab = tabs[index]
        tabs.remove(at: index)
        suspendedTabIDs.remove(id)
        if selectedTabID == id {
            let newIndex = min(max(0, index - 1), tabs.count - 1)
            selectedTabID = tabs[newIndex].id
        }
        return tab
    }

    /// Remove all tabs in a repo group and return them (for transfer to another window).
    /// Returns empty if the group is not found or would leave the model with no tabs.
    func detachGroup(repoGroupID: String) -> [OverlayTab] {
        let groupTabs = tabs.filter { $0.repoGroupID == repoGroupID }
        guard !groupTabs.isEmpty, groupTabs.count < tabs.count else { return [] }
        let groupIDs = Set(groupTabs.map(\.id))
        tabs.removeAll { groupIDs.contains($0.id) }
        for id in groupIDs { suspendedTabIDs.remove(id) }
        if groupIDs.contains(selectedTabID) {
            selectedTabID = tabs.first?.id ?? UUID()
        }
        return groupTabs
    }

    /// Suspend rendering for tabs idle 10+ minutes, but only if render suspension
    /// is enabled. The idle dropdown (visual grouping) works independently — tabs
    /// appear in the dropdown based on lastActivityDate, without stopping rendering.
    private func suspendIdleTabs() {
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
    private func idleTabCount() -> Int {
        let threshold = FeatureSettings.shared.idleTabThresholdSeconds
        let now = Date()
        return tabs.filter { tab in
            guard let session = tab.displaySession ?? tab.session,
                  tab.id != selectedTabID else { return false }
            return now.timeIntervalSince(session.lastActivityDate) > threshold
        }.count
    }

    private func checkTabBarHealth() {
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
        }
    }

    private func emitWatchdogSummaryIfNeeded(now: Date) {
        let elapsed = now.timeIntervalSince(lastWatchdogSummaryAt)
        guard elapsed >= 60 else { return }
        Log.info("TabBar watchdog summary: refreshes=\(watchdogRecoveryCount) skips=\(watchdogSkipCount) lastReason=\(lastWatchdogReason)")
        watchdogRecoveryCount = 0
        watchdogSkipCount = 0
        lastWatchdogSummaryAt = now
    }

    private func shouldCheckTabBarHealth() -> Bool {
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
            // Only clear search for current tab, not all tabs (Issue #7 fix)
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
            // Pass case sensitivity setting (Issue #23 fix)
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
        // which is wasteful when just moving to the next match (Issue #12 fix)
    }

    func previousMatch() {
        selectedTab?.session?.previousMatch()
        // Note: Don't call refreshSearch() here (Issue #12 fix)
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

        // Notify SwiftUI of the change. No toolbar recreation needed for rename -
        // objectWillChange should be sufficient for normal property updates.
        objectWillChange.send()
    }

    func cancelRename() {
        clearRenameState(shouldFocus: true)
    }

    private func clearRenameState(shouldFocus: Bool) {
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

    private func updateSuspensionState() {
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

    private func scheduleSuspension(for id: UUID) {
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

    private func shouldKeepLiveRenderingInBackground(for tab: OverlayTab) -> Bool {
        tab.splitController.terminalSessions.contains { _, session in
            session.shouldKeepLiveRenderingInBackground
        }
    }

    private func tabRenderSuspensionSummary(_ tab: OverlayTab) -> String {
        let summaries = tab.splitController.terminalSessions.map { paneID, session in
            "pane=\(paneID) \(session.renderSuspensionDebugSummary)"
        }
        if summaries.isEmpty {
            return "no-terminal-sessions"
        }
        return summaries.joined(separator: " | ")
    }

    private func cancelSuspension(for id: UUID) {
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

    private func startHoverCardDismissTimer() {
        hoverCardDismissTimer?.cancel()
        let item = DispatchWorkItem { [weak self] in
            self?.stopProcessMonitoring(forTabID: self?.hoverCardTabID)
            self?.hoverCardTabID = nil
        }
        hoverCardDismissTimer = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    private func startProcessMonitoring(forTabID id: UUID?) {
        guard let id, let session = tabs.first(where: { $0.id == id })?.session else { return }
        session.startProcessMonitoring()
    }

    private func stopProcessMonitoring(forTabID id: UUID?) {
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

    private func setupRepoGrouping() {
        // Observe mode changes
        repoGroupModeCancellable = FeatureSettings.shared.$repoGroupingMode
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newMode in
                self?.handleRepoGroupingModeChange(newMode)
            }

        // Set initial state
        if FeatureSettings.shared.repoGroupingMode == .auto {
            applyAutoGroupingToAllTabs()
        }
    }

    private func handleRepoGroupingModeChange(_ mode: RepoGroupingMode) {
        switch mode {
        case .off:
            for i in tabs.indices { tabs[i].repoGroupID = nil }
            repoGroupCancellables.removeAll()
        case .auto:
            applyAutoGroupingToAllTabs()
        case .manual:
            // Keep existing groups, stop auto-updates
            repoGroupCancellables.removeAll()
        }
    }

    private func applyAutoGroupingToAllTabs() {
        repoGroupCancellables.removeAll()
        for i in tabs.indices {
            tabs[i].repoGroupID = tabs[i].session?.gitRootPath
            if let session = tabs[i].session {
                observeGitRootForAutoGrouping(tabID: tabs[i].id, session: session)
            }
        }
    }

    private func observeGitRootForAutoGrouping(tabID: UUID, session: TerminalSessionModel) {
        let cancellable = session.$gitRootPath
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newRoot in
                guard let self,
                      FeatureSettings.shared.repoGroupingMode == .auto,
                      let idx = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
                self.tabs[idx].repoGroupID = newRoot
            }
        repoGroupCancellables[tabID] = cancellable
    }

    /// Called when a new tab is added — subscribe if in auto mode.
    func setupRepoGroupingForTab(_ tab: OverlayTab) {
        guard FeatureSettings.shared.repoGroupingMode == .auto,
              let session = tab.session else { return }
        if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[idx].repoGroupID = session.gitRootPath
        }
        observeGitRootForAutoGrouping(tabID: tab.id, session: session)
    }

    /// Called when a tab is closed — clean up subscription.
    func cleanupRepoGroupingForTab(_ tabID: UUID) {
        repoGroupCancellables.removeValue(forKey: tabID)
    }

    // Manual mode actions
    func addTabToRepoGroup(tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }),
              let root = tabs[idx].session?.gitRootPath else { return }
        tabs[idx].repoGroupID = root
    }

    func removeTabFromRepoGroup(tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        tabs[idx].repoGroupID = nil
    }

    func groupAllSameRepo(asTab tabID: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == tabID }),
              let root = tabs[idx].session?.gitRootPath else { return }
        for i in tabs.indices {
            if tabs[i].session?.gitRootPath == root {
                tabs[i].repoGroupID = root
            }
        }
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

            // Observe pending candidates
            ipc.$pendingCandidates
                .receive(on: DispatchQueue.main)
                .sink { [weak self] candidates in
                    guard let self else { return }
                    updateCurrentCandidate(from: candidates)
                }
                .store(in: &taskCancellables)

            // Observe active tasks
            ipc.$activeTasks
                .receive(on: DispatchQueue.main)
                .sink { [weak self] tasks in
                    guard let self else { return }
                    updateCurrentTask(from: tasks)
                }
                .store(in: &taskCancellables)
        }
    }

    private func updateCurrentCandidate(from candidates: [String: TaskCandidate]) {
        guard let session = selectedTab?.session else {
            currentCandidate = nil
            return
        }
        currentCandidate = candidates[session.tabIdentifier]
    }

    private func updateCurrentTask(from tasks: [String: TrackedTask]) {
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

private extension String {
    func extractResumeSessionId(prefix: String) -> String? {
        guard hasPrefix(prefix) else { return nil }
        let suffix = String(dropFirst(prefix.count))
        return suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : suffix
    }
}
