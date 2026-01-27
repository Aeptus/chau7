import Foundation
import AppKit
import Combine
import SwiftUI

// MARK: - Tab Notification Styling

/// Visual styling that can be applied to a tab via the notification system.
/// Use this to indicate states like "waiting for input", "error occurred", "task complete", etc.
struct TabNotificationStyle: Equatable {
    /// Override color for the tab title (nil = use default)
    var titleColor: Color? = nil

    /// Make the title italic (e.g., for "waiting" states)
    var isItalic: Bool = false

    /// Make the title bold (e.g., for "attention needed")
    var isBold: Bool = false

    /// Subtle pulse animation to draw attention
    var shouldPulse: Bool = false

    /// Optional icon to show (SF Symbol name)
    var icon: String? = nil

    /// Icon color (nil = inherit from titleColor or default)
    var iconColor: Color? = nil

    /// Border color for the tab (nil = no border)
    var borderColor: Color? = nil

    /// Border width (default 0 = no border)
    var borderWidth: CGFloat = 0

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
    var customTitle: String? = nil
    var color: TabColor = .blue
    var autoColor: TabColor? = nil  // F05: Auto-assigned color based on AI model
    var isManualColorOverride: Bool = false
    var lastCommand: LastCommandInfo? = nil  // F20: Last command tracking
    var bookmarks: [BookmarkManager.Bookmark] = []  // F17: Bookmarks

    // MARK: - Notification Styling
    /// Active notification style for this tab (nil = default appearance)
    var notificationStyle: TabNotificationStyle? = nil

    // MARK: - Tab Switch Optimization: Cached Snapshot
    /// Cached screenshot of terminal content for instant visual feedback during tab switch
    var cachedSnapshot: NSImage? = nil
    /// Last known cursor position for cursor-first rendering
    var lastCursorPosition: CGPoint = .zero
    /// Last known prompt text for cursor placeholder
    var lastPromptText: String = ""

    /// The primary terminal session (first terminal in split tree)
    var session: TerminalSessionModel? {
        splitController.primarySession
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
        if let activeName = session?.activeAppName, !activeName.isEmpty {
            return activeName
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

    static func == (lhs: OverlayTab, rhs: OverlayTab) -> Bool {
        lhs.id == rhs.id
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
}

/// Manages terminal tabs, search, and broadcast mode for the overlay window.
/// - Note: Thread Safety - @Published properties must be modified on main thread.
///   All methods assume main thread execution.
final class OverlayTabsModel: ObservableObject {
    @Published var tabs: [OverlayTab]
    @Published var selectedTabID: UUID
    @Published var isSearchVisible: Bool = false
    @Published var searchQuery: String = ""
    @Published var searchResults: [String] = []
    @Published var searchMatchCount: Int = 0
    @Published var isCaseSensitive: Bool = false  // Issue #23 fix
    @Published var isRegexSearch: Bool = false
    @Published var isSemanticSearch: Bool = false
    @Published var searchError: String? = nil
    @Published var isRenameVisible: Bool = false
    @Published var renameText: String = ""
    @Published var renameColor: TabColor = .blue
    @Published var suspendedTabIDs: Set<UUID> = []

    // MARK: - Tab Switch Optimization State
    /// Previous tab index for directional animation
    @Published var previousTabIndex: Int = 0
    /// Whether the terminal content is ready to display (for snapshot swap)
    @Published var isTerminalReady: Bool = true
    /// Set of tab IDs currently being pre-warmed (on hover)
    private var prewarmingTabIDs: Set<UUID> = []

    // MARK: - Tab Bar Recovery
    /// Token to force SwiftUI to re-render the tab bar when incremented
    @Published var tabBarRefreshToken: Int = 0
    /// Last reported rendered tab count from the view (for watchdog)
    /// -1 means the view hasn't reported yet (avoids false positive on startup)
    var lastReportedRenderedCount: Int = -1
    /// Last reported tab bar size (for visibility-based recovery)
    var lastReportedTabBarSize: CGSize = .zero
    /// Timestamp of last preference update from the view (for staleness detection)
    private var lastPreferenceUpdateTime: Date = Date()
    /// How long without a preference update before considering the view stale
    private let stalenessThreshold: TimeInterval = 5.0
    /// Timer for watchdog that checks tab bar health
    private var tabBarWatchdogTimer: DispatchSourceTimer?
    /// Counter to limit consecutive watchdog refresh attempts
    private var watchdogRefreshAttempts: Int = 0
    /// Minimum acceptable tab bar width per tab (for visibility detection)
    private let minWidthPerTab: CGFloat = 30

    // F13: Broadcast Input
    @Published var isBroadcastMode: Bool = false
    @Published var broadcastExcludedTabIDs: Set<UUID> = []

    // F16: Clipboard History
    @Published var isClipboardHistoryVisible: Bool = false

    // F17: Bookmarks
    @Published var isBookmarkListVisible: Bool = false

    // F21: Snippets
    @Published var isSnippetManagerVisible: Bool = false

    // Task Lifecycle (v1.1)
    @Published var currentCandidate: TaskCandidate? = nil
    @Published var currentTask: TrackedTask? = nil
    @Published var isTaskAssessmentVisible: Bool = false

    private var taskCancellables: Set<AnyCancellable> = []
    private var renameTabID: UUID? = nil
    private var renameOriginalTitle: String = ""
    private var renameOriginalColor: TabColor = .blue
    private var suspendWorkItems: [UUID: DispatchWorkItem] = [:]
    private var isRenderSuspensionEnabled = false
    private var renderSuspensionDelay: TimeInterval = 5.0
    private var needsFreshTabOnShow: Bool = false

    weak var overlayWindow: NSWindow?
    var onCloseLastTab: (() -> Void)?

    private let appModel: AppModel

    init(appModel: AppModel) {
        self.appModel = appModel
        var first = OverlayTab(appModel: appModel)
        if let firstColor = TabColor.allCases.first {
            first.color = firstColor
        }
        self.tabs = [first]
        self.selectedTabID = first.id

        // Setup task lifecycle observers (v1.1)
        setupTaskObservers()

        // Start tab bar watchdog immediately (model-owned lifecycle)
        // This ensures the watchdog runs regardless of view lifecycle events
        DispatchQueue.main.async { [weak self] in
            self?.startTabBarWatchdog()
        }
    }

    deinit {
        stopTabBarWatchdog()
    }

    var selectedTab: OverlayTab? {
        tabs.first { $0.id == selectedTabID }
    }

    func notificationTabTitle(forTool tool: String) -> String? {
        let trimmed = tool.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lowerTool = trimmed.lowercased()
        let matches = tabs.filter { tab in
            let display = tab.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let active = tab.session?.activeAppName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return display == lowerTool || active == lowerTool
        }
        let preferred = matches.first { $0.id == selectedTabID } ?? matches.first
        return preferred?.displayTitle
    }

    var overlayWorkspaceIdentifier: String? {
        if let repoRoot = SnippetManager.shared.repoRoot {
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
        LogEnhanced.tab("Switching tab", tabId: id, tabCount: tabs.count)

        // MARK: - Tab Switch Optimization: Capture state before switching
        // 1. Record previous tab index for directional animation
        let oldIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) ?? 0

        // 2. Capture snapshot of current terminal for instant visual feedback
        captureCurrentTabSnapshot()

        // 3. Signal that terminal needs time to render (for snapshot swap)
        isTerminalReady = false

        // 4. Batch all state changes to minimize SwiftUI diff passes
        // Using direct assignment is faster than withTransaction for simple cases
        if isRenameVisible {
            clearRenameState(shouldFocus: false)
        }
        previousTabIndex = oldIndex
        selectedTabID = id

        // 5. Pre-cancel suspension before focus (optimization)
        cancelSuspension(for: id)
        suspendedTabIDs.remove(id)

        focusSelected()
        updateSuspensionState()
        updateSnippetContextForSelection()
        if isSearchVisible {
            refreshSearch()
        }

        // Update task state for new tab (v1.1)
        MainActor.assumeIsolated {
            updateCurrentCandidate(from: ProxyIPCServer.shared.pendingCandidates)
            updateCurrentTask(from: ProxyIPCServer.shared.activeTasks)
        }

        // 6. Mark terminal as ready after a brief delay (allows snapshot to display first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
            self?.isTerminalReady = true
        }
    }

    // MARK: - Tab Switch Optimization: Snapshot Capture

    /// Captures a screenshot of the current terminal view for instant display during tab switch
    private func captureCurrentTabSnapshot() {
        guard let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabID }),
              let terminalView = tabs[currentIndex].session?.existingTerminalView else {
            return
        }

        // Capture the terminal view as an image
        guard let bitmapRep = terminalView.bitmapImageRepForCachingDisplay(in: terminalView.bounds) else {
            return
        }
        terminalView.cacheDisplay(in: terminalView.bounds, to: bitmapRep)

        let image = NSImage(size: terminalView.bounds.size)
        image.addRepresentation(bitmapRep)
        tabs[currentIndex].cachedSnapshot = image

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
        for i in 0..<tabs.count {
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
            guard let self, id != self.selectedTabID else { return }
            self.scheduleSuspension(for: id)
        }
    }

    func newTab() {
        dispatchPrecondition(condition: .onQueue(.main))
        Log.trace("newTab: creating new tab, current tabs.count=\(tabs.count)")
        needsFreshTabOnShow = false
        var tab = OverlayTab(appModel: appModel)
        let colors = TabColor.allCases
        if !colors.isEmpty {
            tab.color = colors[tabs.count % colors.count]
        }
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

        selectedTabID = tab.id
        Log.trace("newTab: selectedTabID=\(tab.id)")
        focusSelected()
        updateSuspensionState()
        updateSnippetContextForSelection()
        if isSearchVisible {
            refreshSearch()
        }

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

    func newTab(at directory: String) {
        needsFreshTabOnShow = false
        var tab = OverlayTab(appModel: appModel)
        let colors = TabColor.allCases
        if !colors.isEmpty {
            tab.color = colors[tabs.count % colors.count]
        }

        // Set the starting directory for the new tab (triggers git status refresh)
        tab.session?.updateCurrentDirectory(directory)

        // Insert based on settings
        let position = FeatureSettings.shared.newTabPosition
        if position == "after", let currentIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: currentIndex + 1)
        } else {
            tabs.append(tab)
        }

        selectedTabID = tab.id
        focusSelected()
        updateSuspensionState()
        updateSnippetContextForSelection()
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
            if isLastTab && !willCloseWindow {
                // Last tab with keepWindow behavior - tab is replaced
                if runningProcessCount == 1 {
                    alert.informativeText = L("alert.closeTab.runningProcess.replace.message",
                        "This tab has a running process. The process will be terminated and a new tab will open.")
                } else {
                    alert.informativeText = L("alert.closeTab.runningProcesses.replace.message",
                        "This tab has \(runningProcessCount) running processes. All processes will be terminated and a new tab will open.")
                }
            } else if willCloseWindow {
                // Last tab with closeWindow behavior
                if runningProcessCount == 1 {
                    alert.informativeText = L("alert.closeTab.runningProcess.closeWindow.message",
                        "This tab has a running process. The process will be terminated and the window will close.")
                } else {
                    alert.informativeText = L("alert.closeTab.runningProcesses.closeWindow.message",
                        "This tab has \(runningProcessCount) running processes. All processes will be terminated and the window will close.")
                }
            } else {
                // Normal close (multiple tabs exist)
                if runningProcessCount == 1 {
                    alert.informativeText = L("alert.closeTab.runningProcess.message",
                        "This tab has a running process. Closing it will terminate the process.")
                } else {
                    alert.informativeText = L("alert.closeTab.runningProcesses.message",
                        "This tab has \(runningProcessCount) running processes. Closing it will terminate all processes.")
                }
            }
        } else {
            // No running process - only shown when "always warn" is enabled
            alert.messageText = L("alert.closeTab.confirm.title", "Close this tab?")
            if isLastTab && !willCloseWindow {
                alert.informativeText = L("alert.closeTab.confirm.replace.message",
                    "This is the last tab. A new tab will be created.")
            } else if willCloseWindow {
                alert.informativeText = L("alert.closeTab.confirm.closeWindow.message",
                    "This is the last tab. The window will be closed.")
            } else {
                alert.informativeText = L("alert.closeTab.confirm.message",
                    "Are you sure you want to close this tab?")
            }
        }

        alert.alertStyle = .warning
        alert.addButton(withTitle: L("button.closeTab", "Close Tab"))
        alert.addButton(withTitle: L("button.cancel", "Cancel"))

        // Show "Don't ask again" only for the "always warn" mode (not for running process warnings)
        if isAlwaysWarnMode && !hasRunningProcess {
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

    func closeTab(id: UUID) {
        dispatchPrecondition(condition: .onQueue(.main))
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
        let willCloseWindow = isLastTab && settings.lastTabCloseBehavior == .closeWindow

        // Check if we need to show a warning dialog
        let warnForProcess = settings.warnOnCloseWithRunningProcess && hasRunningProcess
        let warnAlways = settings.alwaysWarnOnTabClose
        let shouldWarn = warnForProcess || warnAlways

        if shouldWarn {
            let confirmed = confirmTabClose(
                runningProcessCount: runningProcessCount,
                isLastTab: isLastTab,
                willCloseWindow: willCloseWindow,
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

        let inheritedDirectory = isLastTabNow ? inheritedStartDirectory() : nil
        Log.info("closeTab: found tab at index=\(index)")
        if isRenameVisible {
            clearRenameState(shouldFocus: false)
        }

        // Clean up per-tab command history
        if let sessionID = tabs[index].session?.tabIdentifier {
            CommandHistoryManager.shared.removeTab(sessionID)
        }

        // Close all sessions in the split pane tree (not just primary)
        tabs[index].splitController.root.closeAllSessions()

        if isLastTabNow {
            let behavior = FeatureSettings.shared.lastTabCloseBehavior
            if behavior == .closeWindow {
                Log.info("closeTab: last tab - closing window per settings")
                needsFreshTabOnShow = true
                onCloseLastTab?()
                return
            }
            // Last tab - create a fresh one instead of closing window
            Log.info("closeTab: last tab - creating fresh tab")
            var newTab = OverlayTab(appModel: appModel)
            if let firstColor = TabColor.allCases.first {
                newTab.color = firstColor
            }
            if let directory = inheritedDirectory {
                newTab.session?.updateCurrentDirectory(directory)
            }
            tabs[index] = newTab
            selectedTabID = newTab.id
            Log.info("closeTab: new tab created with id=\(newTab.id)")
        } else {
            // Multiple tabs - just remove this one
            Log.info("closeTab: removing tab at index=\(index), tabs.count before=\(tabs.count)")
            tabs.remove(at: index)
            Log.info("closeTab: tabs.count after=\(tabs.count)")

            if selectedTabID == id {
                let newIndex = min(index, tabs.count - 1)
                selectedTabID = tabs[newIndex].id
                Log.info("closeTab: selected new tab at index=\(newIndex), id=\(selectedTabID)")
            }
        }

        focusSelected()
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
                    processInfo = L("alert.closeOtherTabs.process.singular",
                        "1 running process will be terminated.")
                } else if tabsWithProcesses == 1 {
                    processInfo = L("alert.closeOtherTabs.processes.oneTab",
                        "\(totalProcessCount) running processes in 1 tab will be terminated.")
                } else {
                    processInfo = L("alert.closeOtherTabs.processes.multipleTabs",
                        "\(totalProcessCount) running processes across \(tabsWithProcesses) tabs will be terminated.")
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
            if warnAlways && totalProcessCount == 0 {
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

        // Close all sessions in all tabs except current one
        for tab in currentOtherTabs {
            tab.splitController.root.closeAllSessions()
        }

        tabs = tabs.filter { $0.id == currentID }
        Log.info("Closed all other tabs, keeping \(currentID)")
    }

    func selectNextTab() {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else {
            Log.trace("selectNextTab: skipped (tabs.count=\(tabs.count))")
            return
        }
        let nextIndex = (index + 1) % tabs.count
        Log.trace("selectNextTab: \(index) -> \(nextIndex), tabs.count=\(tabs.count)")
        selectedTabID = tabs[nextIndex].id
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
        selectedTabID = tabs[prevIndex].id
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

        // Always focus the terminal (shell) pane when switching tabs, not the text editor
        // Update focusedPaneID to the first terminal pane so the split view knows which pane is active
        if let firstTerminalID = tab.splitController.root.allTerminalIDs.first {
            tab.splitController.focusedPaneID = firstTerminalID
        }

        tab.session?.focusTerminal(in: window)
    }

    private func ensureFreshTabIfNeeded() {
        guard needsFreshTabOnShow else { return }
        needsFreshTabOnShow = false
        guard let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }

        var newTab = OverlayTab(appModel: appModel)
        if let firstColor = TabColor.allCases.first {
            newTab.color = firstColor
        }
        tabs[index] = newTab
        selectedTabID = newTab.id
        updateSnippetContextForSelection()
    }

    func selectTab(number: Int) {
        let index = max(0, number - 1)
        guard index < tabs.count else { return }
        selectedTabID = tabs[index].id
        focusSelected()
        updateSuspensionState()
        updateSnippetContextForSelection()
        if isSearchVisible {
            refreshSearch()
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
        tabs[index].notificationStyle = style
        Log.info("Tab notification style set: \(style?.icon ?? "cleared") for tab \(targetID)")
    }

    /// Sets a notification style on the tab associated with a terminal session
    func setNotificationStyle(_ style: TabNotificationStyle?, forSession session: TerminalSessionModel) {
        guard let tab = tabs.first(where: { $0.session === session }) else { return }
        setNotificationStyle(style, for: tab.id)
    }

    /// Clears notification style from a tab
    func clearNotificationStyle(for tabID: UUID? = nil) {
        setNotificationStyle(nil, for: tabID)
    }

    /// Clears notification styles from all tabs
    func clearAllNotificationStyles() {
        for i in tabs.indices {
            tabs[i].notificationStyle = nil
        }
    }

    /// Applies a notification style to a tab based on tool name (used by notification action system)
    /// - Parameters:
    ///   - tool: The tool/app name to match (e.g., "Codex", "Claude Code")
    ///   - stylePreset: Preset name ("waiting", "error", "success", "attention", "clear")
    ///   - config: Additional configuration (customColor, italic, bold, pulse)
    func applyNotificationStyle(forTool tool: String, stylePreset: String, config: [String: String]) {
        dispatchPrecondition(condition: .onQueue(.main))

        // Find tab matching the tool - prefer exact matches, fall back to contains
        let lowerTool = tool.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // First try exact match
        var matchedTab = tabs.first { tab in
            let display = tab.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let active = tab.session?.activeAppName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return display == lowerTool || active == lowerTool
        }

        // Fall back to contains match if no exact match
        if matchedTab == nil {
            matchedTab = tabs.first { tab in
                let display = tab.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let active = tab.session?.activeAppName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                return display.contains(lowerTool) || (active?.contains(lowerTool) == true)
            }
        }

        guard let tab = matchedTab else {
            Log.info("applyNotificationStyle: No tab found matching tool '\(tool)'")
            return
        }

        // Build the style
        let style: TabNotificationStyle?
        if stylePreset == "clear" {
            style = nil
        } else {
            style = buildNotificationStyle(preset: stylePreset, config: config)
        }

        setNotificationStyle(style, for: tab.id)
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
                style.borderColor = .red  // Default border color
            }
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
        }

        // NOTE: Do NOT reset lastPreferenceUpdateTime here.
        // Only real preference updates from the view should reset it.
        // This ensures watchdogRefreshAttempts properly increments to the
        // 3-attempt limit if recovery doesn't actually restore the view.

        // Log confirmation after state update
        Log.info("refreshTabBar: token updated \(oldToken) -> \(tabBarRefreshToken), tabs=\(tabs.count)")
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

    private func checkTabBarHealth() {
        dispatchPrecondition(condition: .onQueue(.main))
        let expected = tabs.count
        let rendered = lastReportedRenderedCount
        let size = lastReportedTabBarSize

        // Skip check if view hasn't reported yet
        if rendered < 0 {
            return
        }

        var needsRecovery = false
        var reason = ""

        // Check 1: Zero rendered count
        if expected > 0 && rendered == 0 {
            needsRecovery = true
            reason = "rendered=0, expected=\(expected)"
        }

        // Check 2: Tabs rendered but size is suspiciously small (visibility issue)
        // Only check if rendered count seems OK but size suggests invisibility
        if !needsRecovery && expected > 0 && rendered > 0 {
            let minExpectedWidth = CGFloat(expected) * minWidthPerTab
            if size.width < minExpectedWidth || size.height < 10 {
                needsRecovery = true
                reason = "size too small: \(Int(size.width))x\(Int(size.height)), expected width >= \(Int(minExpectedWidth))"
            }
        }

        // Check 3: Staleness - if preference updates stopped, the view may have disconnected
        // This catches cases where NSHostingView becomes stale and preference keys stop firing
        if !needsRecovery && expected > 0 {
            let timeSinceLastUpdate = Date().timeIntervalSince(lastPreferenceUpdateTime)
            if timeSinceLastUpdate > stalenessThreshold {
                needsRecovery = true
                reason = "stale: no preference update in \(Int(timeSinceLastUpdate))s (threshold: \(Int(stalenessThreshold))s)"
            }
        }

        if needsRecovery {
            watchdogRefreshAttempts += 1
            if watchdogRefreshAttempts <= 3 {
                Log.warn("TabBar watchdog: \(reason), attempt \(watchdogRefreshAttempts), forcing refresh")
                refreshTabBar()
            } else if watchdogRefreshAttempts == 4 {
                Log.error("TabBar watchdog: refresh failed after 3 attempts, stopping retries")
            }
        } else {
            watchdogRefreshAttempts = 0
        }
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

    /// Swaps a tab with its neighbor. Used for Chrome/Safari style live reordering.
    /// - Parameters:
    ///   - id: The tab ID to swap
    ///   - direction: Positive for right, negative for left (zero is ignored)
    func swapTabWithNeighbor(id: UUID, direction: Int) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard direction != 0 else { return }
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let neighborIndex = index + (direction > 0 ? 1 : -1)
        guard neighborIndex >= 0, neighborIndex < tabs.count else { return }
        tabs.swapAt(index, neighborIndex)
        Log.info("Swapped tab \(id) from index \(index) to \(neighborIndex)")
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
        if isSemanticSearch && FeatureSettings.shared.isSemanticSearchEnabled {
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
        isSearchVisible = false
        renameTabID = tab.id
        renameText = tab.displayTitle
        renameColor = tab.color
        renameOriginalTitle = renameText
        renameOriginalColor = renameColor
        isRenameVisible = true
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
    }

    func isTabSuspended(_ id: UUID) -> Bool {
        suspendedTabIDs.contains(id)
    }

    private func updateSuspensionState() {
        let validIDs = Set(tabs.map { $0.id })

        suspendWorkItems
            .filter { !validIDs.contains($0.key) }
            .forEach { $0.value.cancel() }
        suspendWorkItems = suspendWorkItems.filter { validIDs.contains($0.key) }
        suspendedTabIDs = suspendedTabIDs.intersection(validIDs)

        guard isRenderSuspensionEnabled else {
            suspendWorkItems.values.forEach { $0.cancel() }
            suspendWorkItems.removeAll()
            suspendedTabIDs.removeAll()
            return
        }

        // Selected tab should always be active.
        suspendedTabIDs.remove(selectedTabID)
        cancelSuspension(for: selectedTabID)

        for tab in tabs where tab.id != selectedTabID {
            scheduleSuspension(for: tab.id)
        }
    }

    private func scheduleSuspension(for id: UUID) {
        guard !suspendedTabIDs.contains(id) else { return }
        guard suspendWorkItems[id] == nil else { return }

        let item = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.isRenderSuspensionEnabled else { return }
                guard self.selectedTabID != id else { return }
                self.suspendedTabIDs.insert(id)
                self.suspendWorkItems.removeValue(forKey: id)
            }
        }
        suspendWorkItems[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + renderSuspensionDelay, execute: item)
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
        paste()  // Paste into terminal
    }

    // MARK: - F17: Bookmarks

    func toggleBookmarkList() {
        isBookmarkListVisible.toggle()
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
        if isSnippetManagerVisible {
            isSearchVisible = false
            isRenameVisible = false
            isClipboardHistoryVisible = false
            isBookmarkListVisible = false
        } else {
            // Focus terminal when snippet manager is closed
            focusSelected()
        }
    }

    func dismissOverlays() {
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
            isOverridden: entry.isOverridden
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
        let scrollOffset = 0  // Would get from terminal
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
                    self.updateCurrentCandidate(from: candidates)
                }
                .store(in: &taskCancellables)

            // Observe active tasks
            ipc.$activeTasks
                .receive(on: DispatchQueue.main)
                .sink { [weak self] tasks in
                    guard let self else { return }
                    self.updateCurrentTask(from: tasks)
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
            }
        }
    }
}
