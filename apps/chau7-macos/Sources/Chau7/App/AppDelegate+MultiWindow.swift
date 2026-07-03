import AppKit
import Chau7Core

/// Multi-window management, split out of AppDelegate.swift verbatim: the atomic
/// 30-second autosave + termination snapshot reuse, moving tabs/groups between
/// windows (including drag-drop landing), and restoring additional windows on
/// launch. All state (`overlayHosts`, autosave caches, `hiddenWindowNumbers`)
/// stays stored on AppDelegate; window creation primitives (`createOverlayWindow`,
/// `showOverlayWindow`, `allocateOverlayWindowNumber`, lifecycle logging) remain
/// in AppDelegate.swift and are reached here as internal members.
extension AppDelegate {

    // MARK: - Multi-Window Autosave

    /// Start a centralized 30-second autosave timer that atomically saves ALL windows.
    /// Replaces the per-window autosave that caused race conditions on the same UserDefaults key.
    func startMultiWindowAutoSaveTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in
            Log.wakeup("autosave")
            self?.saveAllWindowStates(reason: .autosave)
        }
        timer.resume()
        multiWindowAutoSaveTimer = timer
    }

    static let terminationStateReuseFreshness: TimeInterval = 35

    /// The cached snapshot is reusable at quit only when it is recent AND the
    /// live window structure still matches the fingerprint captured when the
    /// snapshot was saved. The autosave interval (30s) exceeds nothing here:
    /// any structural change since the last save forces a fresh collection,
    /// so reuse can only ever skip re-capturing scrollback content.
    func shouldReuseCachedWindowStatesForTermination(now: Date = Date()) -> Bool {
        guard let lastSavedWindowStatesAt,
              !lastSavedWindowStates.isEmpty else {
            return false
        }
        guard now.timeIntervalSince(lastSavedWindowStatesAt) <= Self.terminationStateReuseFreshness else {
            return false
        }
        return currentWindowStateSignature() == lastSavedWindowStatesSignature
    }

    private func currentWindowStateSignature() -> [[String]] {
        overlayHosts
            .filter { !$0.model.tabs.isEmpty }
            .map { $0.model.liveStateSignature() }
    }

    #if DEBUG
    func setCachedWindowStatesForTesting(_ states: [[SavedTabState]], at date: Date?) {
        lastSavedWindowStates = states
        lastSavedWindowStatesAt = date
        lastSavedWindowStatesSignature = currentWindowStateSignature()
    }
    #endif

    private func collectRestorableWindowStates() -> [[SavedTabState]] {
        var allWindows: [[SavedTabState]] = []
        for host in overlayHosts {
            let states = host.model.exportTabStates()
            if !states.isEmpty { allWindows.append(states) }
        }
        return allWindows
    }

    private func persistWindowStates(_ allWindows: [[SavedTabState]], reason: TabStateSaveReason) {
        lastSavedWindowStates = allWindows
        lastSavedWindowStatesAt = Date()
        lastSavedWindowStatesSignature = currentWindowStateSignature()

        var legacyPayloadBytes = 0
        var multiWindowPayloadBytes = 0

        // The file-based restore bundle (below) is the full primary source: it keeps
        // multi-MB scrollback in integrity-checked sidecar files instead of the prefs
        // plist. UserDefaults holds a *scrollback-stripped* index — written on EVERY
        // autosave (not just at termination) — so the restore fallback stays fresh even
        // on an unclean quit. Regression fix: a termination-only UserDefaults write could
        // leave a stale index that dropped recently-created tabs (and whole additional
        // windows) when the bundle didn't cover them. The stripped index is small (KB,
        // not MB), so this restores pre-bundle freshness without the plist-bloat that
        // motivated moving the heavy payloads out.
        let indexWindows = allWindows.map { window in window.map(\.strippedForRestoreIndex) }

        // One token per save cycle, stamped on the index AND the bundle
        // manifest. At restore, token equality tells whether the bundle still
        // reflects the latest save (see RestoreSourceArbiter) — a bundle that
        // silently failed to write for hours must not beat a fresh index.
        let saveToken = UUID().uuidString
        var indexWriteSucceeded = false

        if let firstWindow = indexWindows.first,
           let data = Persist.encodeLogged(firstWindow, context: "window0.tabState") {
            legacyPayloadBytes = data.count
            UserDefaults.standard.set(data, forKey: SavedTabState.userDefaultsKey)
            indexWriteSucceeded = true
        }
        if indexWindows.count > 1 {
            let multiState = SavedMultiWindowState(windows: indexWindows)
            if let data = Persist.encodeLogged(multiState, context: "multiWindow.tabState") {
                multiWindowPayloadBytes = data.count
                UserDefaults.standard.set(data, forKey: SavedMultiWindowState.userDefaultsKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        }
        if indexWriteSucceeded {
            UserDefaults.standard.set(saveToken, forKey: SavedTabState.restoreIndexSaveTokenKey)
        }
        do {
            // sourceData nil → the bundle fingerprints from the full state (incl.
            // scrollback) so sidecars re-flush when only scrollback changes.
            _ = try TabRestoreBundleStore.persistCurrentBundle(
                windowStates: allWindows,
                reason: reason,
                sourceData: nil,
                saveToken: indexWriteSucceeded ? saveToken : nil
            )
        } catch {
            Log.warn("Failed to persist split tab restore bundle [\(reason.rawValue)]: \(error)")
        }
        recordRestorePayloadBreadcrumb(
            allWindows,
            reason: reason,
            legacyPayloadBytes: legacyPayloadBytes,
            multiWindowPayloadBytes: multiWindowPayloadBytes
        )
        // Flush to disk immediately — UserDefaults coalesces writes and the
        // process may exit before the next automatic sync.
        if reason == .termination {
            UserDefaults.standard.synchronize()
        }
        OverlayTabsModel.persistWindowStateBackups(windowStates: allWindows, reason: reason)
        Log.trace("Saved \(allWindows.count) window(s) tab state [\(reason.rawValue)]")
    }

    /// Save all non-empty overlay windows' tab states atomically to UserDefaults and disk backups.
    /// Window 0 → legacy key, windows 1..N → additional entries in the
    /// multi-window key.
    func saveAllWindowStates(reason: TabStateSaveReason) {
        let reusedTerminationSnapshot = reason == .termination && shouldReuseCachedWindowStatesForTermination()
        let allWindows = reusedTerminationSnapshot ? lastSavedWindowStates : collectRestorableWindowStates()
        if reusedTerminationSnapshot {
            Log.info("Reusing cached window state snapshot for termination to avoid blocking quit")
        }
        guard !allWindows.isEmpty else {
            if reason == .termination {
                OverlayTabsModel.clearPersistedWindowState()
                UserDefaults.standard.synchronize()
                Log.trace("Cleared persisted window state [\(reason.rawValue)] because no visible windows remained")
            }
            return
        }
        persistWindowStates(allWindows, reason: reason)
    }

    private func recordRestorePayloadBreadcrumb(
        _ allWindows: [[SavedTabState]],
        reason: TabStateSaveReason,
        legacyPayloadBytes: Int,
        multiWindowPayloadBytes: Int
    ) {
        var tabCount = 0
        var paneCount = 0
        var largestTabPayloadBytes = 0
        var largestTabID: String?
        var largestTabTitle: String?
        var largestPanePayloadBytes = 0
        var largestPaneID: String?
        var largestPaneDirectory: String?

        for window in allWindows {
            tabCount += window.count
            for state in window {
                for pane in state.paneStates ?? [] {
                    paneCount += 1
                    let panePayloadBytes = OverlayTabsModel.estimatedRestorePayloadBytes(for: pane)
                    if panePayloadBytes > largestPanePayloadBytes {
                        largestPanePayloadBytes = panePayloadBytes
                        largestPaneID = pane.paneID
                        largestPaneDirectory = pane.directory
                    }
                }
                let payloadBytes = OverlayTabsModel.estimatedRestorePayloadBytes(for: state)
                if payloadBytes > largestTabPayloadBytes {
                    largestTabPayloadBytes = payloadBytes
                    largestTabID = state.tabID
                    largestTabTitle = state.customTitle ?? state.directory
                }
            }
        }

        IncidentBreadcrumbStore.shared.recordRestorePayloadSnapshot(
            RestorePayloadBreadcrumbSnapshot(
                reason: reason.rawValue,
                windowCount: allWindows.count,
                tabCount: tabCount,
                paneCount: paneCount,
                legacyPayloadBytes: legacyPayloadBytes,
                multiWindowPayloadBytes: multiWindowPayloadBytes,
                largestTabPayloadBytes: largestTabPayloadBytes,
                largestTabID: largestTabID,
                largestTabTitle: largestTabTitle,
                largestPanePayloadBytes: largestPanePayloadBytes,
                largestPaneID: largestPaneID,
                largestPaneDirectory: largestPaneDirectory
            )
        )
    }

    // MARK: - Tab Move Between Windows

    /// Wire tab-move callbacks on all overlay models and update their window lists.
    /// Called after window creation, tab moves, and window activation.
    func wireTabMoveCallbacks() {
        Log.info("wireTabMoveCallbacks: \(overlayHosts.count) hosts")
        for (i, host) in overlayHosts.enumerated() {
            // Use weak self + resolve index at call time to handle array mutations
            let model = host.model
            model.onMoveTabToWindow = { [weak self, weak model] tabID, targetWindowIndex in
                guard let self, let model,
                      let currentIndex = overlayHosts.firstIndex(where: { $0.model === model }) else { return }
                moveTab(tabID, fromWindowIndex: currentIndex, toWindowIndex: targetWindowIndex)
            }
            model.onMoveGroupToWindow = { [weak self, weak model] groupID, targetWindowIndex in
                guard let self, let model,
                      let currentIndex = overlayHosts.firstIndex(where: { $0.model === model }) else { return }
                moveGroup(groupID, fromWindowIndex: currentIndex, toWindowIndex: targetWindowIndex)
            }
            // Wire the lazy refresh callback for context menu
            model.onRefreshWindowTitles = { [weak self] in
                self?.wireTabMoveCallbacks()
            }
            // Build window titles: "Window N (M tabs)" for each OTHER window
            let beforeCount = model.otherWindowTitles.count
            model.otherWindowTitles = overlayHosts.enumerated().compactMap { j, other in
                guard j != i else { return nil }
                let tabCount = other.model.tabs.count
                let title = other.window.title.isEmpty
                    ? "Window \(j + 1) (\(tabCount) tab\(tabCount == 1 ? "" : "s"))"
                    : "\(other.window.title) (\(tabCount) tab\(tabCount == 1 ? "" : "s"))"
                return OverlayTabsModel.WindowMenuItem(id: j, title: title)
            }
            Log
                .info(
                    "wireTabMoveCallbacks: window \(i) has \(model.otherWindowTitles.count) other windows (was \(beforeCount)), onMoveTab=\(model.onMoveTabToWindow != nil), onMoveGroup=\(model.onMoveGroupToWindow != nil)"
                )
        }
    }

    private func hideEmptiedWindowIfNeeded(at index: Int, reason: String) {
        guard overlayHosts.indices.contains(index) else { return }
        let host = overlayHosts[index]
        guard host.model.tabs.isEmpty else { return }
        hiddenWindowNumbers.insert(host.window.windowNumber)
        host.model.noteTabBarVisibilityChanged(isVisible: false)
        logOverlayWindowLifecycle(reason: reason, window: host.window)
        host.window.orderOut(nil)
    }

    /// Move a tab from one window to another. Pass toWindowIndex = -1 to create a new window.
    private func moveTab(_ tabID: UUID, fromWindowIndex: Int, toWindowIndex: Int) {
        // Diagnostic tag: correlate all rss samples from one drag operation.
        let dragID = String(UUID().uuidString.prefix(8))
        Self.logRSSSample("moveTab[\(dragID)] entry from=\(fromWindowIndex) to=\(toWindowIndex)")
        guard fromWindowIndex < overlayHosts.count else {
            Log.warn("moveTab: fromWindowIndex \(fromWindowIndex) out of bounds (count=\(overlayHosts.count))")
            return
        }
        let source = overlayHosts[fromWindowIndex].model
        guard let tab = source.extractTabForWindowTransfer(id: tabID) else { return }
        // Carry any pending deferred restore state along with the tab. If
        // the tab was still in the source model's deferred queue (not yet
        // restored), the state would otherwise be orphaned there and the
        // tab would arrive on the target without its persisted scrollback,
        // resume command, or agent metadata.
        let carriedDeferredState = source.drainDeferredRestoreState(tabID: tabID)
        Self.logRSSSample("moveTab[\(dragID)] after extractTabForWindowTransfer")

        if toWindowIndex == -1 {
            // Create a new window and move the tab into it
            guard let model else { return }
            let tabsModel = OverlayTabsModel(appModel: model, restoreState: false)
            // Replace the default fresh tab with the moved tab
            var movedTab = tab
            tabsModel.tabs = [movedTab]
            tabsModel.selectedTabID = movedTab.id
            movedTab.stampOwnerTabID()
            tabsModel.tabs[0] = movedTab
            if let carriedDeferredState {
                tabsModel.queueDeferredRestoreState(tabID: movedTab.id, state: carriedDeferredState)
            }
            TerminalControlService.shared.register(tabsModel)
            let windowNumber = allocateOverlayWindowNumber()
            let window = createOverlayWindow(tabsModel: tabsModel, windowNumber: windowNumber)
            let host = OverlayHost(window: window, model: tabsModel)
            overlayHosts.append(host)
            Self.logRSSSample("moveTab[\(dragID)] after createOverlayWindow")
            wireTabMoveCallbacks()
            Self.logRSSSample("moveTab[\(dragID)] after wireTabMoveCallbacks")
            hideEmptiedWindowIfNeeded(at: fromWindowIndex, reason: "moveTab-hideEmptiedSource")
            Self.logRSSSample("moveTab[\(dragID)] after hideEmptiedWindowIfNeeded")
            showOverlayWindow(host, reason: "moveToNewWindow")
            Self.logRSSSample("moveTab[\(dragID)] after showOverlayWindow (newWindow)")
            Log.info("Moved tab \(tabID) to new window \(windowNumber)")
        } else {
            guard toWindowIndex < overlayHosts.count else {
                Log.warn("moveTab: target window \(toWindowIndex) closed during drag (count=\(overlayHosts.count)), re-inserting tab into source")
                source.tabs.append(tab)
                if let carriedDeferredState {
                    source.queueDeferredRestoreState(tabID: tab.id, state: carriedDeferredState)
                }
                source.selectTab(id: tab.id)
                return
            }
            let target = overlayHosts[toWindowIndex].model
            target.tabs.append(tab)
            if let carriedDeferredState {
                target.queueDeferredRestoreState(tabID: tab.id, state: carriedDeferredState)
            }
            target.selectTab(id: tab.id)
            Self.logRSSSample("moveTab[\(dragID)] after target.tabs.append+selectTab")
            wireTabMoveCallbacks()
            Self.logRSSSample("moveTab[\(dragID)] after wireTabMoveCallbacks")
            hideEmptiedWindowIfNeeded(at: fromWindowIndex, reason: "moveTab-hideEmptiedSource")
            Self.logRSSSample("moveTab[\(dragID)] after hideEmptiedWindowIfNeeded")
            showOverlayWindow(overlayHosts[toWindowIndex], reason: "moveToExistingWindow")
            Self.logRSSSample("moveTab[\(dragID)] after showOverlayWindow (existingWindow)")
            Log.info("Moved tab \(tabID) from window \(fromWindowIndex) to \(toWindowIndex)")
        }

        // Schedule delayed samples across the window during which the 50GB spike
        // was observed (~52s after drag end in historical logs) — only when memory
        // diagnostics are enabled, so normal drags don't keep work scheduled 50s out.
        if EnvVars.isEnabled(EnvVars.memoryDiagnostics) {
            for delay in [0.1, 1.0, 5.0, 15.0, 30.0, 50.0] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    Self.logRSSSample("moveTab[\(dragID)] +\(delay)s")
                }
            }
        }
    }

    /// Move all tabs in a repo group from one window to another.
    private func moveGroup(_ repoGroupID: String, fromWindowIndex: Int, toWindowIndex: Int) {
        let repoName = URL(fileURLWithPath: repoGroupID).lastPathComponent
        Log.info("moveGroup: \(repoName) from=\(fromWindowIndex) to=\(toWindowIndex) hosts=\(overlayHosts.count)")
        guard fromWindowIndex < overlayHosts.count else {
            Log.warn("moveGroup: fromWindowIndex \(fromWindowIndex) out of bounds (count=\(overlayHosts.count))")
            return
        }
        let source = overlayHosts[fromWindowIndex].model
        let groupTabs = source.extractGroupForWindowTransfer(repoGroupID: repoGroupID)
        guard !groupTabs.isEmpty else {
            Log.warn("moveGroup: no tabs found for group \(repoName)")
            return
        }
        // Carry each tab's pending deferred restore state so none of them
        // arrive on the target model stripped of their persisted AI /
        // scrollback metadata.
        let carriedDeferredStates: [(UUID, SavedTabState)] = groupTabs.compactMap { tab in
            guard let state = source.drainDeferredRestoreState(tabID: tab.id) else { return nil }
            return (tab.id, state)
        }
        Log.info("moveGroup: extracted \(groupTabs.count) tabs from \(repoName)")

        if toWindowIndex == -1 {
            guard let model else { return }
            let tabsModel = OverlayTabsModel(appModel: model, restoreState: false)
            tabsModel.tabs = groupTabs.map { var t = $0
                t.stampOwnerTabID()
                return t
            }
            tabsModel.selectedTabID = groupTabs[0].id
            for (tabID, state) in carriedDeferredStates {
                tabsModel.queueDeferredRestoreState(tabID: tabID, state: state)
            }
            TerminalControlService.shared.register(tabsModel)
            let windowNumber = allocateOverlayWindowNumber()
            let window = createOverlayWindow(tabsModel: tabsModel, windowNumber: windowNumber)
            let host = OverlayHost(window: window, model: tabsModel)
            overlayHosts.append(host)
            wireTabMoveCallbacks()
            hideEmptiedWindowIfNeeded(at: fromWindowIndex, reason: "moveGroup-hideEmptiedSource")
            showOverlayWindow(host, reason: "moveGroupToNewWindow")
            Log.info("Moved group \(repoGroupID) (\(groupTabs.count) tabs) to new window \(windowNumber)")
        } else {
            guard toWindowIndex < overlayHosts.count else {
                Log.warn("moveGroup: target window \(toWindowIndex) closed during drag (count=\(overlayHosts.count)), re-inserting group into source")
                source.tabs.append(contentsOf: groupTabs)
                for (tabID, state) in carriedDeferredStates {
                    source.queueDeferredRestoreState(tabID: tabID, state: state)
                }
                source.selectTab(id: groupTabs[0].id)
                return
            }
            let target = overlayHosts[toWindowIndex].model
            target.tabs.append(contentsOf: groupTabs)
            for (tabID, state) in carriedDeferredStates {
                target.queueDeferredRestoreState(tabID: tabID, state: state)
            }
            target.selectTab(id: groupTabs[0].id)
            wireTabMoveCallbacks()
            hideEmptiedWindowIfNeeded(at: fromWindowIndex, reason: "moveGroup-hideEmptiedSource")
            showOverlayWindow(overlayHosts[toWindowIndex], reason: "moveGroupToExistingWindow")
            Log.info("Moved group \(repoGroupID) (\(groupTabs.count) tabs) from window \(fromWindowIndex) to \(toWindowIndex)")
        }
    }

    func handleTabDrop(tabID: UUID, from sourceModel: OverlayTabsModel, atScreenPoint point: CGPoint) -> Bool {
        guard let sourceIndex = overlayHosts.firstIndex(where: { $0.model === sourceModel }) else {
            Log.warn("handleTabDrop: source model not found in overlayHosts")
            return false
        }

        let candidates = overlayHosts.enumerated().compactMap { index, host -> OverlayWindowDropCandidate? in
            guard host.window.isVisible, !host.window.isMiniaturized else { return nil }
            return OverlayWindowDropCandidate(
                index: index,
                primaryFrame: host.model.tabBarDropFrame,
                fallbackFrame: host.window.frame
            )
        }

        Log.info("handleTabDrop: point=\(Int(point.x)),\(Int(point.y)) candidates=\(candidates.count) source=\(sourceIndex)")
        for c in candidates {
            Log
                .info(
                    "  window \(c.index): tabBar=\(Int(c.primaryFrame.minX)),\(Int(c.primaryFrame.minY)),\(Int(c.primaryFrame.width))x\(Int(c.primaryFrame.height)) window=\(Int(c.fallbackFrame.minX)),\(Int(c.fallbackFrame.minY)),\(Int(c.fallbackFrame.width))x\(Int(c.fallbackFrame.height))"
                )
        }

        guard let targetIndex = OverlayWindowDropResolver.targetIndex(
            at: point,
            candidates: candidates,
            excluding: sourceIndex
        ) else {
            Log.info("handleTabDrop: no target window at drop point")
            return false
        }

        Log.info("handleTabDrop: moving tab to window \(targetIndex)")
        moveTab(tabID, fromWindowIndex: sourceIndex, toWindowIndex: targetIndex)
        return true
    }

    func handleGroupDrop(repoGroupID: String, from sourceModel: OverlayTabsModel, atScreenPoint point: CGPoint) -> Bool {
        let repoName = URL(fileURLWithPath: repoGroupID).lastPathComponent
        Log.info("handleGroupDrop: \(repoName) point=(\(Int(point.x)),\(Int(point.y)))")
        guard let sourceIndex = overlayHosts.firstIndex(where: { $0.model === sourceModel }) else {
            Log.warn("handleGroupDrop: source model not found in overlayHosts")
            return false
        }

        let candidates = overlayHosts.enumerated().compactMap { index, host -> OverlayWindowDropCandidate? in
            guard host.window.isVisible, !host.window.isMiniaturized else { return nil }
            return OverlayWindowDropCandidate(
                index: index,
                primaryFrame: host.model.tabBarDropFrame,
                fallbackFrame: host.window.frame
            )
        }

        Log.info("handleGroupDrop: group=\(repoGroupID) point=\(Int(point.x)),\(Int(point.y)) candidates=\(candidates.count) source=\(sourceIndex)")

        guard let targetIndex = OverlayWindowDropResolver.targetIndex(
            at: point,
            candidates: candidates,
            excluding: sourceIndex
        ) else {
            Log.info("handleGroupDrop: no target window at drop point")
            return false
        }

        Log.info("handleGroupDrop: moving group to window \(targetIndex)")
        moveGroup(repoGroupID, fromWindowIndex: sourceIndex, toWindowIndex: targetIndex)
        return true
    }

    // MARK: - Multi-Window Restoration

    /// Restore additional windows saved in the multi-window state.
    /// The primary OverlayTabsModel already hydrates the first saved window.
    /// This method recreates windows 1..N from the remaining saved entries.
    func restoreAdditionalWindows() {
        guard let model else { return }
        let restoreStartedAt = CFAbsoluteTimeGetCurrent()
        defer {
            FeatureProfiler.shared.recordMainThreadStallIfNeeded(
                operation: "AppDelegate.restoreAdditionalWindows",
                startedAt: restoreStartedAt,
                thresholdMs: 150
            )
        }
        let restoredWindows: [[SavedTabState]]
        let restoreSource: String

        let multiState = Persist.decodeLogged(
            SavedMultiWindowState.self,
            from: UserDefaults.standard.data(forKey: SavedMultiWindowState.userDefaultsKey),
            context: "multiWindow.restore"
        )
        if OverlayTabsModel.bundleIsCurrentRestoreSource(),
           let bundleWindows = TabRestoreBundleStore.loadCurrentWindowStates(), bundleWindows.count > 1 {
            // Primary: the file-based restore bundle (windows beyond the first).
            // Same freshest-wins arbitration as the primary-window restore so
            // window 0 and windows 1..N come from one consistent source.
            restoredWindows = Array(bundleWindows.dropFirst())
            restoreSource = "restore bundle"
        } else if let multiState, multiState.windows.count > 1 {
            restoredWindows = Array(multiState.windows.dropFirst())
            restoreSource = "user defaults"
            // Keep this until the next real save replaces it. Clearing during
            // launch removes the strongest recovery copy for additional windows.
        } else if let backupWindows = OverlayTabsModel.restoreAdditionalWindowStatesFromBackups() {
            let window0TabIDs = Set(overlayHosts.first?.model.tabs.map(\.id) ?? [])
            let candidates = backupWindows.map { windowStates in
                WindowStateRestorePlanner.CandidateWindow(
                    tabIDs: windowStates.compactMap { UUID(uuidString: $0.tabID ?? "") }
                )
            }
            let planned = WindowStateRestorePlanner.additionalWindowsFromBackup(
                currentPrimaryTabIDs: window0TabIDs,
                backupWindows: candidates
            )
            let plannedIDSets = Set(planned.map { Set($0.tabIDs) })
            restoredWindows = backupWindows.filter { windowStates in
                let ids = Set(windowStates.compactMap { UUID(uuidString: $0.tabID ?? "") })
                return plannedIDSets.contains(ids)
            }
            restoreSource = "disk backup"
        } else {
            return
        }

        // Hard per-tab dedup across all windows: a saved tab restores exactly
        // once, no matter how many window snapshots claim its ID (first
        // occurrence wins). This replaces the old >50%-overlap window skip,
        // which let partially-duplicated windows restore both copies and
        // re-persist the duplication forever.
        let window0TabIDs = Set(overlayHosts.first?.model.tabs.map(\.id) ?? [])
        let claims = WindowStateRestorePlanner.claimTabs(
            alreadyClaimed: window0TabIDs,
            windows: restoredWindows.map { windowStates in
                windowStates.map { UUID(uuidString: $0.tabID ?? "") }
            }
        )

        for (windowIndex, windowStates) in restoredWindows.enumerated() {
            guard !windowStates.isEmpty else { continue }
            let windowClaims = claims[windowIndex]
            let uniqueStates = zip(windowStates, windowClaims)
                .filter { $0.1 == .restore }
                .map(\.0)
            let droppedCount = windowStates.count - uniqueStates.count
            if droppedCount > 0 {
                Log.warn("restoreAdditionalWindows: window \(windowIndex + 1) dropped \(droppedCount)/\(windowStates.count) tab(s) whose IDs were already restored by an earlier window")
            }
            guard !uniqueStates.isEmpty else {
                Log.warn("Skipping duplicate window \(windowIndex + 1): every tab ID was already restored by an earlier window")
                continue
            }

            // Pass pre-decoded states directly — no UserDefaults round-trip
            let windowRestoreStartedAt = CFAbsoluteTimeGetCurrent()
            let tabsModel = OverlayTabsModel(appModel: model, restoringStates: uniqueStates)
            TerminalControlService.shared.register(tabsModel)
            let windowNumber = allocateOverlayWindowNumber()
            let window = createOverlayWindow(tabsModel: tabsModel, windowNumber: windowNumber)
            overlayHosts.append(OverlayHost(window: window, model: tabsModel))
            FeatureProfiler.shared.recordMainThreadStallIfNeeded(
                operation: "AppDelegate.restoreAdditionalWindow",
                startedAt: windowRestoreStartedAt,
                thresholdMs: 150,
                metadata: "index=\(windowIndex + 1) tabs=\(uniqueStates.count)"
            )

            Log.info("Restored additional window \(windowIndex + 1) with \(uniqueStates.count) tab(s) from \(restoreSource)")
        }

        // Wire callbacks for ALL windows now that additional hosts are registered.
        // Without this, restored windows have nil onMoveTabToWindow/onMoveGroupToWindow
        // and zero otherWindowTitles — making "Move to Window" menus empty.
        if overlayHosts.count > 1 {
            wireTabMoveCallbacks()
        }
    }
}
