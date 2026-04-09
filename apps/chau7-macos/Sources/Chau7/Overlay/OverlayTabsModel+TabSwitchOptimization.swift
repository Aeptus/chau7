import Foundation
import AppKit
import Chau7Core

// MARK: - Tab Switch Optimization

extension OverlayTabsModel {

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

    /// Create a new tab.
    /// - Parameters:
    ///   - inherit: When `true` (default, Cmd+T), inherits the current tab's working directory
    ///     and repo group. When `false` ("+" button), opens at the default path with no group.
    ///   - selectNewTab: Whether to select the new tab after creation.
    func newTab(inherit: Bool = true, selectNewTab: Bool = true) {
        dispatchPrecondition(condition: .onQueue(.main))
        Log.trace("newTab: creating new tab, inherit=\(inherit), current tabs.count=\(tabs.count)")
        needsFreshTabOnShow = false
        var tab = OverlayTab(appModel: appModel)
        let colors = TabColor.allCases
        if !colors.isEmpty {
            tab.color = colors[tabs.count % colors.count]
        }
        tab.stampOwnerTabID()
        let startDirectory = inherit ? inheritedStartDirectory() : nil
        if let startDirectory {
            tab.session?.updateCurrentDirectory(startDirectory)
        }
        let inheritedRepoGroupID = RepoGroupInheritance.inheritedGroupID(
            selectedRepoGroupID: inherit ? selectedTab?.repoGroupID : nil,
            startDirectory: startDirectory
        )
        tab.repoGroupID = inheritedRepoGroupID
        tab.hasInheritedRepoGroup = inheritedRepoGroupID != nil

        let insertIndex = inherit
            ? insertionIndexForNewTab(inheritingRepoGroupID: inheritedRepoGroupID)
            : tabs.count
        tabs.insert(tab, at: insertIndex)
        Log.trace("newTab: inserted at index \(insertIndex), tabs.count=\(tabs.count), inheritedRepoGroupID=\(inheritedRepoGroupID ?? "nil")")

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
        let inheritedRepoGroupID = RepoGroupInheritance.inheritedGroupID(
            selectedRepoGroupID: selectedTab?.repoGroupID,
            startDirectory: directory
        )
        tab.repoGroupID = inheritedRepoGroupID
        tab.hasInheritedRepoGroup = inheritedRepoGroupID != nil

        let insertIndex = insertionIndexForNewTab(inheritingRepoGroupID: inheritedRepoGroupID)
        tabs.insert(tab, at: insertIndex)

        // Keep inherited repo groups provisional so manual-mode detachment
        // still works when this tab later resolves to a different git root.
        setupRepoGroupingForTab(tab)

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
    func countRunningProcesses(in tab: OverlayTab) -> Int {
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

    /// Show confirmation dialog before closing tab. Returns true if user confirms.
    /// - Parameters:
    ///   - runningProcessCount: Number of running processes in the tab
    ///   - isLastTab: Whether this is the last tab (will be replaced, not closed)
    ///   - willCloseWindow: Whether closing will close the window entirely
    ///   - isAlwaysWarnMode: Whether we're warning due to "always warn" setting (shows suppression option)
    /// Ask the user whether to also close the window when closing the last tab.
    /// Returns true if the user wants to close the window.
    func confirmCloseLastTab() -> Bool {
        let alert = NSAlert()
        alert.messageText = L("alert.closeLastTab.title", "This is the last tab")
        alert.informativeText = L("alert.closeLastTab.message", "Do you want to close the window, or keep it open with a new tab?")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("alert.closeLastTab.closeWindow", "Close Window"))
        alert.addButton(withTitle: L("alert.closeLastTab.newTab", "New Tab"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    func confirmTabClose(
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
            let aiSessionID = tabs[idx].session?.effectiveAISessionId
            MainActor.assumeIsolated {
                NotificationActionExecutor.shared.cancelPendingStyleWork(tabID: id, sessionID: aiSessionID)
            }

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
        let aiSessionID = tabs[index].session?.effectiveAISessionId
        MainActor.assumeIsolated {
            NotificationActionExecutor.shared.cancelPendingStyleWork(tabID: id, sessionID: aiSessionID)
        }

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
            paneStates: state.paneStates,
            directory: state.directory,
            knownRepoRoot: state.knownRepoRoot ?? state.repoGroupID,
            knownGitBranch: state.knownGitBranch
        )

        let restoredTabID = Self.validatedUUID(from: state.tabID) ?? UUID()
        let restoredCreatedAt: Date
        if let iso = state.createdAt,
           let parsed = DateFormatters.iso8601.date(from: iso) {
            restoredCreatedAt = parsed
        } else {
            restoredCreatedAt = entry.closedAt
        }

        var tab = OverlayTab(
            appModel: appModel,
            splitController: controller,
            id: restoredTabID,
            createdAt: restoredCreatedAt
        )
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

    func ensureFreshTabIfNeeded() {
        guard needsFreshTabOnShow else { return }
        needsFreshTabOnShow = false

        let newTab = makeFreshTab(inheritedDirectory: nil)
        if let index = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs[index] = newTab
        } else {
            tabs = [newTab]
        }
        selectedTabID = newTab.id
        updateSnippetContextForSelection()
    }

    func makeFreshTab(inheritedDirectory: String?) -> OverlayTab {
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

}
