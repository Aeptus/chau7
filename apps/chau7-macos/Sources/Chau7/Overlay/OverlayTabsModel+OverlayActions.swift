import Foundation

/// Generic overlay-management helpers and small action surfaces on
/// `OverlayTabsModel`: the global overlay dismissal (cancels rename,
/// hides search/clipboard/bookmark/snippets panels, dismisses hover
/// card), the `logVisualState` debug trace, snippet-insert wrappers,
/// and bookmarks add/jump. Bundled because they either dispatch to
/// multiple overlays or are small glue methods that don't belong in
/// any single feature file.
extension OverlayTabsModel {

    // MARK: - Overlay Dismissal

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

    // MARK: - Debug tracing

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

    // MARK: - Snippets insertion

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

    // MARK: - F17: Bookmarks (add/jump)

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

    // MARK: - F02: Split Panes (pass-throughs)

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
}
