import Foundation

/// Rename dialog, search panel, and clipboard/zoom pass-through commands.
/// Three concerns bundled because they share the session-forwarding idiom
/// (`selectedTab?.session?.xxx()`) and the "only one overlay visible at a
/// time" exclusive-toggle pattern (search hides rename hides snippets,
/// etc.).
///
/// Stored state stays on the main class: `renameTabID`, `renameText`,
/// `renameColor`, `renameOriginal*`, `searchQuery`, `searchResults`,
/// `isSearchVisible`, `isRenameVisible`, `isCaseSensitive`,
/// `isRegexSearch`, `isSemanticSearch`, `searchError`, `searchMatchCount`.
extension OverlayTabsModel {

    // MARK: - Color / Clipboard / Zoom (session pass-throughs)


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

    // MARK: - Search

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

    // MARK: - Rename dialog

    func beginRenameSelected() {
        guard let tab = selectedTab else { return }
        dismissHoverCard()
        isSearchVisible = false
        renameTabID = tab.id
        // Pre-fill with the user's customTitle if one exists, otherwise
        // fall back to displayTitle. Using displayTitle directly meant
        // users editing an AI-prefixed tab saw the composed form
        // ("Codex - my tab") in the field and had to manually strip the
        // prefix to edit just their part. With this change, users with
        // a custom title see exactly what they typed; users without one
        // see the current displayed title (AI name or fallback) as a
        // suggested starting point.
        if let custom = tab.customTitle, !custom.isEmpty {
            renameText = custom
        } else {
            renameText = tab.displayTitle
        }
        renameColor = tab.color
        renameOriginalTitle = renameText
        renameOriginalCustomTitle = tab.customTitle
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

        // Conflict detection: if something external (MCP renameTab, extension,
        // etc.) mutated the tab's customTitle while the rename dialog was
        // open, the user's commit would silently overwrite that change. Log
        // the conflict so it's visible in the log — the user's action still
        // wins (they hit Save deliberately), but operators can reconcile
        // after the fact if needed.
        let currentCustomTitle = tabs[index].customTitle
        if currentCustomTitle != renameOriginalCustomTitle {
            Log.warn(
                "Tab rename conflict: external mutator changed customTitle from \(renameOriginalCustomTitle ?? "nil") to \(currentCustomTitle ?? "nil") while rename dialog was open (tabID=\(renameTabID)). User's commit will overwrite."
            )
        }

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
        renameOriginalCustomTitle = nil
        renameOriginalColor = renameColor
        logVisualState(reason: "renameCleared")
        if shouldFocus {
            focusSelected()
        }
    }
}
