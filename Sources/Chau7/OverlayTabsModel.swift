import Foundation
import AppKit

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

final class OverlayTabsModel: ObservableObject {
    @Published var tabs: [OverlayTab]
    @Published var selectedTabID: UUID
    @Published var isSearchVisible: Bool = false
    @Published var searchQuery: String = ""
    @Published var searchResults: [String] = []
    @Published var searchMatchCount: Int = 0
    @Published var isCaseSensitive: Bool = false  // Issue #23 fix
    @Published var isRegexSearch: Bool = false
    @Published var searchError: String? = nil
    @Published var isRenameVisible: Bool = false
    @Published var renameText: String = ""
    @Published var renameColor: TabColor = .blue
    @Published var suspendedTabIDs: Set<UUID> = []

    // F13: Broadcast Input
    @Published var isBroadcastMode: Bool = false
    @Published var broadcastExcludedTabIDs: Set<UUID> = []

    // F16: Clipboard History
    @Published var isClipboardHistoryVisible: Bool = false

    // F17: Bookmarks
    @Published var isBookmarkListVisible: Bool = false

    // F21: Snippets
    @Published var isSnippetManagerVisible: Bool = false

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
    }

    var selectedTab: OverlayTab? {
        tabs.first { $0.id == selectedTabID }
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

    func selectTab(id: UUID) {
        guard selectedTabID != id else { return }
        if isRenameVisible {
            clearRenameState(shouldFocus: false)
        }
        selectedTabID = id
        focusSelected()
        updateSuspensionState()
        updateSnippetContextForSelection()
        if isSearchVisible {
            refreshSearch()
        }
    }

    func newTab() {
        needsFreshTabOnShow = false
        var tab = OverlayTab(appModel: appModel)
        let colors = TabColor.allCases
        if !colors.isEmpty {
            tab.color = colors[tabs.count % colors.count]
        }

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
    }

    func newTab(at directory: String) {
        needsFreshTabOnShow = false
        var tab = OverlayTab(appModel: appModel)
        let colors = TabColor.allCases
        if !colors.isEmpty {
            tab.color = colors[tabs.count % colors.count]
        }

        // Set the starting directory for the new tab
        tab.session?.currentDirectory = directory

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
    }

    func closeCurrentTab() {
        Log.info("closeCurrentTab called. selectedTabID=\(selectedTabID), tabs.count=\(tabs.count)")
        closeTab(id: selectedTabID)
    }

    func closeTab(id: UUID) {
        Log.info("closeTab called with id=\(id). tabs.count=\(tabs.count)")
        guard let index = tabs.firstIndex(where: { $0.id == id }) else {
            Log.warn("closeTab: tab with id=\(id) not found!")
            return
        }
        Log.info("closeTab: found tab at index=\(index)")
        if isRenameVisible {
            clearRenameState(shouldFocus: false)
        }

        // Close all sessions in the split pane tree
        tabs[index].session?.closeSession()

        if tabs.count == 1 {
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
        Log.info("closeTab completed. tabs.count=\(tabs.count)")
    }

    func closeOtherTabs() {
        guard tabs.count > 1 else { return }
        let currentID = selectedTabID

        // Close all tabs except current one
        for tab in tabs where tab.id != currentID {
            tab.session?.closeSession()
        }

        tabs = tabs.filter { $0.id == currentID }
        Log.info("Closed all other tabs, keeping \(currentID)")
    }

    func selectNextTab() {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let nextIndex = (index + 1) % tabs.count
        selectedTabID = tabs[nextIndex].id
        focusSelected()
        updateSuspensionState()
        updateSnippetContextForSelection()
        if isSearchVisible {
            refreshSearch()
        }
    }

    func selectPreviousTab() {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let prevIndex = (index - 1 + tabs.count) % tabs.count
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
        selectedTab?.session?.focusTerminal(in: window)
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

    // MARK: - Tab Reordering

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
            searchError = nil
            refreshSearch()
        } else {
            searchQuery = ""
            searchResults = []
            searchMatchCount = 0
            searchError = nil
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
        // Pass case sensitivity setting (Issue #23 fix)
        let result = session.updateSearch(
            query: searchQuery,
            maxMatches: 400,
            maxPreviewLines: 12,
            caseSensitive: isCaseSensitive,
            regexEnabled: isRegexSearch
        )
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
        if trimmed.isEmpty {
            tabs[index].customTitle = nil
        } else if titleChanged {
            tabs[index].customTitle = trimmed
        }
        tabs[index].color = renameColor
        if renameColor != renameOriginalColor {
            tabs[index].autoColor = nil
            tabs[index].isManualColorOverride = true
        }
        clearRenameState(shouldFocus: true)
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
}
