import Foundation
import AppKit

struct OverlayTab: Identifiable, Equatable {
    let id: UUID
    let session: TerminalSessionModel
    let createdAt: Date
    var customTitle: String? = nil
    var color: TabColor = .blue
    var autoColor: TabColor? = nil  // F05: Auto-assigned color based on AI model
    var isManualColorOverride: Bool = false
    var lastCommand: LastCommandInfo? = nil  // F20: Last command tracking
    var bookmarks: [BookmarkManager.Bookmark] = []  // F17: Bookmarks

    init(appModel: AppModel) {
        self.id = UUID()
        self.session = TerminalSessionModel(appModel: appModel)
        self.createdAt = Date()
    }

    var displayTitle: String {
        if let customTitle, !customTitle.isEmpty {
            return customTitle
        }
        if let activeName = session.activeAppName, !activeName.isEmpty {
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
}

final class OverlayTabsModel: ObservableObject {
    @Published var tabs: [OverlayTab]
    @Published var selectedTabID: UUID
    @Published var isSearchVisible: Bool = false
    @Published var searchQuery: String = ""
    @Published var searchResults: [String] = []
    @Published var searchMatchCount: Int = 0
    @Published var isCaseSensitive: Bool = false  // Issue #23 fix
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

    private var renameTabID: UUID? = nil
    private var renameOriginalTitle: String = ""
    private var renameOriginalColor: TabColor = .blue
    private var suspendWorkItems: [UUID: DispatchWorkItem] = [:]
    private var isRenderSuspensionEnabled = false
    private var renderSuspensionDelay: TimeInterval = 5.0

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

    func selectTab(id: UUID) {
        guard selectedTabID != id else { return }
        if isRenameVisible {
            clearRenameState(shouldFocus: false)
        }
        selectedTabID = id
        focusSelected()
        updateSuspensionState()
        if isSearchVisible {
            refreshSearch()
        }
    }

    func newTab() {
        var tab = OverlayTab(appModel: appModel)
        let colors = TabColor.allCases
        if !colors.isEmpty {
            tab.color = colors[tabs.count % colors.count]
        }
        tabs.append(tab)
        selectedTabID = tab.id
        focusSelected()
        updateSuspensionState()
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

        // Close the session
        tabs[index].session.closeSession()

        if tabs.count == 1 {
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
        if isSearchVisible {
            refreshSearch()
        }
        Log.info("closeTab completed. tabs.count=\(tabs.count)")
    }

    func selectNextTab() {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let nextIndex = (index + 1) % tabs.count
        selectedTabID = tabs[nextIndex].id
        focusSelected()
        updateSuspensionState()
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
        if isSearchVisible {
            refreshSearch()
        }
    }

    func focusSelected() {
        guard let window = overlayWindow else { return }
        selectedTab?.session.focusTerminal(in: window)
    }

    func selectTab(number: Int) {
        let index = max(0, number - 1)
        guard index < tabs.count else { return }
        selectedTabID = tabs[index].id
        focusSelected()
        updateSuspensionState()
        if isSearchVisible {
            refreshSearch()
        }
    }

    func copyOrInterrupt() {
        selectedTab?.session.copyOrInterrupt()
    }

    func paste() {
        selectedTab?.session.paste()
    }

    func zoomIn() {
        selectedTab?.session.zoomIn()
    }

    func zoomOut() {
        selectedTab?.session.zoomOut()
    }

    func zoomReset() {
        selectedTab?.session.zoomReset()
    }

    func toggleSearch() {
        isSearchVisible.toggle()
        if isSearchVisible {
            isRenameVisible = false
            refreshSearch()
        } else {
            searchQuery = ""
            searchResults = []
            searchMatchCount = 0
            // Only clear search for current tab, not all tabs (Issue #7 fix)
            selectedTab?.session.clearSearch()
            focusSelected()
        }
    }

    func refreshSearch() {
        guard !searchQuery.isEmpty else {
            searchResults = []
            searchMatchCount = 0
            selectedTab?.session.clearSearch()
            return
        }
        guard let session = selectedTab?.session else { return }
        // Pass case sensitivity setting (Issue #23 fix)
        let result = session.updateSearch(
            query: searchQuery,
            maxMatches: 400,
            maxPreviewLines: 12,
            caseSensitive: isCaseSensitive
        )
        searchResults = result.previewLines
        searchMatchCount = result.count
    }

    func nextMatch() {
        guard let session = selectedTab?.session else { return }
        session.nextMatch()
        // Note: Don't call refreshSearch() here - it recomputes all matches
        // which is wasteful when just moving to the next match (Issue #12 fix)
    }

    func previousMatch() {
        guard let session = selectedTab?.session else { return }
        session.previousMatch()
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

        // Check against AI model mappings
        for (pattern, color) in FeatureSettings.aiModelColors {
            if firstWord.contains(pattern) {
                tabs[index].autoColor = color
                Log.trace("F05: Auto-colored tab for \(pattern) -> \(color)")
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
            tab.session.sendInput(text)
        }
    }

    // MARK: - F16: Clipboard History

    func toggleClipboardHistory() {
        isClipboardHistoryVisible.toggle()
        if isClipboardHistoryVisible {
            isSearchVisible = false
            isRenameVisible = false
            isBookmarkListVisible = false
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
        }
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
