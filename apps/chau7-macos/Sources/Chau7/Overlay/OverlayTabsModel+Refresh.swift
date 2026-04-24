import AppKit
import Chau7Core
import Foundation

/// Forced re-render / recovery surface for `OverlayTabsModel`. Two
/// concerns bundled because `forceRefreshSelectedTab` drives into the
/// lower-level in-place refresh helpers which feed into the tab-bar
/// toolbar recreation path:
///
///   - **Tab Bar Recovery** — `refreshTabBar()`: full toolbar re-create
///     when NSHostingView state becomes stale after window hide/show
///     cycles. The only reliable escape hatch because direct manipulation
///     of the hosting view has caused EXC_BREAKPOINT crashes.
///   - **Force Refresh Terminal** — `forceRefreshSelectedTab()` and
///     friends (`refreshSelectedTabInPlaceIfPossible`,
///     `performSelectedTabInPlaceRefresh`, `resetSelectedTerminalReveal
///     Scheduling`, `forceSelectedTabRevealLive`, etc.). Recovers from
///     stuck isHidden, disabled Metal views, or stale display state on
///     the currently selected tab.
extension OverlayTabsModel {

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

        forceSelectedTabRevealLive(tabID: selectedTabID)
        cancelSuspension(for: selectedTabID)
        suspendedTabIDs.remove(selectedTabID)
        if let selectedTab,
           let session = selectedPresentationSession(for: selectedTab) {
            performSelectedTabInPlaceRefresh(
                session: session,
                selectedDecision: renderLifecycleDecision(for: selectedTab)
            )
        }
        focusSelected()

        logVisualState(reason: "forceRefreshSelectedTab")
    }

    @discardableResult
    func refreshSelectedTabInPlaceIfPossible(reason: String) -> Bool {
        guard let selectedTab,
              let session = selectedPresentationSession(for: selectedTab) else {
            return false
        }
        let selectedDecision = renderLifecycleDecision(for: selectedTab)
        guard selectedDecision.phase.keepsVisibleSurface,
              session.existingRustTerminalView != nil,
              session.presentationSurfaceState.isLivePresentable else {
            return false
        }

        session.resetPresentationSurfaceToLive()
        resetSelectedTerminalRevealScheduling()
        performSelectedTabInPlaceRefresh(
            session: session,
            selectedDecision: selectedDecision
        )
        Log.info(
            "refreshSelectedTabInPlaceIfPossible[\(reason)]: refreshed selected tab \(selectedTabID) as \(selectedDecision.phase.rawValue)"
        )
        return true
    }

    private func performSelectedTabInPlaceRefresh(
        session: TerminalSessionModel,
        selectedDecision: TabRenderLifecycleDecision
    ) {
        guard let rustView = session.existingRustTerminalView else { return }

        rustView.applyRenderPhase(
            selectedDecision.phase,
            isInteractive: selectedDecision.isInteractive,
            reason: "selectedTabInPlaceRefresh"
        )
        rustView.needsDisplay = true

        if let container = rustView.superview as? RustTerminalContainerView {
            container.isHidden = !selectedDecision.phase.keepsVisibleSurface

            // Shared Metal renderer: switch the window's single coordinator
            // to render this tab's content. Creates the coordinator lazily
            // on first use.
            if FeatureSettings.shared.useMetalRenderer {
                if let coordinator = sharedMetalCoordinator {
                    coordinator.switchToView(rustView, container: container)
                    coordinator.metalView.isHidden = !selectedDecision.phase.keepsVisibleSurface
                    session.windowMetalCoordinator = coordinator
                } else if let coordinator = RustMetalDisplayCoordinator(
                    terminalView: rustView,
                    gridProvider: rustView.makeGridProvider() ?? { nil }
                ) {
                    sharedMetalCoordinator = coordinator
                    coordinator.switchToView(rustView, container: container)
                    coordinator.metalView.isHidden = !selectedDecision.phase.keepsVisibleSurface
                    session.windowMetalCoordinator = coordinator
                    Log.info("OverlayTabsModel: shared Metal coordinator created")
                }
            }
        }

        if selectedDecision.phase.allowsLivePresentation {
            rustView.needsGridSync = true
            rustView.pollAndSync()
        }
    }

    func requestSelectedTabAuthoritativeReveal(reason: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        discardSettledRestorePreviews(reason: reason)

        guard let selectedTab,
              let session = selectedPresentationSession(for: selectedTab) else {
            Log.warn("requestSelectedTabAuthoritativeReveal[\(reason)]: no session for selectedTabID=\(selectedTabID)")
            return
        }

        let selectedDecision = renderLifecycleDecision(for: selectedTab)
        let hasAttachedRenderer = session.existingRustTerminalView != nil
        let revealTrigger = selectedTabRevealTrigger(for: reason)
        let revealRequest = SelectedTabRevealRequest(
            trigger: revealTrigger,
            keepsVisibleSurface: selectedDecision.phase.keepsVisibleSurface,
            hasAttachedRenderer: hasAttachedRenderer,
            isCurrentlyLivePresentable: session.presentationSurfaceState.isLivePresentable
        )
        let refreshAction = SelectedTabRefreshPolicy.action(for: revealRequest)

        if case .authoritativeReveal(let shouldAwaitVisibleFrame) = refreshAction {
            _ = session.beginPresentationReveal(
                shouldAwaitVisibleFrame: shouldAwaitVisibleFrame,
                now: CFAbsoluteTimeGetCurrent()
            )
            if shouldAwaitVisibleFrame {
                let revealGeneration = session.presentationSurfaceState.generation
                scheduleSelectedTerminalRevealTimeout(
                    tabID: selectedTab.id,
                    generation: revealGeneration,
                    reason: reason
                )
            } else {
                resetSelectedTerminalRevealScheduling()
            }
        } else {
            session.resetPresentationSurfaceToLive()
            resetSelectedTerminalRevealScheduling()
        }

        guard let rustView = session.existingRustTerminalView else {
            Log.info("requestSelectedTabAuthoritativeReveal[\(reason)]: armed visible-frame handoff before Rust view was attached for tab \(selectedTabID)")
            return
        }

        var blockingMode = "in_place"

        switch refreshAction {
        case .liveRepaintInPlace:
            performSelectedTabInPlaceRefresh(
                session: session,
                selectedDecision: selectedDecision
            )
        case .authoritativeReveal(let shouldAwaitVisibleFrame):
            rustView.applyRenderPhase(
                selectedDecision.phase,
                isInteractive: selectedDecision.isInteractive,
                reason: "authoritativeReveal"
            )
            rustView.needsDisplay = true
            if let container = rustView.superview as? RustTerminalContainerView {
                container.isHidden = !selectedDecision.phase.keepsVisibleSurface
            }
            rustView.requestAuthoritativeReveal(reason: reason)
            if let coordinator = sharedMetalCoordinator {
                coordinator.metalView.isHidden = !selectedDecision.phase.keepsVisibleSurface
                coordinator.forceAuthoritativeRefresh(reason: reason)
            }
            if selectedDecision.phase.allowsLivePresentation {
                rustView.needsGridSync = true
                rustView.performAuthoritativeRevealPass(reason: reason)
            }
            blockingMode = shouldAwaitVisibleFrame ? "blocking" : "in_place"
        }
        Log.info("requestSelectedTabAuthoritativeReveal[\(reason)]: refreshed selected tab \(selectedTabID) as \(selectedDecision.phase.rawValue) mode=\(blockingMode)")
    }

    private func selectedTabRevealTrigger(for reason: String) -> SelectedTabRevealTrigger {
        switch reason {
        case "select_tab":
            return .selectionChange
        case "forceRefreshSelectedTab":
            return .explicitRefresh
        case "startup_prepare", "init_restore":
            return .startup
        case "restore_bootstrap_phase":
            return .restoreBootstrap
        default:
            if reason.hasPrefix("windowDid") {
                return .reactivation
            }
            return .other
        }
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

    /// Drains and returns any deferred restore state for this tab ID. The
    /// caller (typically AppDelegate during cross-window tab transfer) is
    /// responsible for re-queueing the state on the destination model via
    /// `queueDeferredRestoreState` — otherwise the tab arrives on the target
    /// without its persisted scrollback / resume command / agent metadata.
    func drainDeferredRestoreState(tabID: UUID) -> SavedTabState? {
        guard let state = deferredRestoreStatesByTabID.removeValue(forKey: tabID) else {
            return nil
        }
        deferredRestoreTabOrder.removeAll { $0 == tabID }
        hasStartedDeferredRestore = !deferredRestoreTabOrder.isEmpty
        return state
    }

    /// Inject a deferred restore state for a tab that was transferred from
    /// another model. The state is appended to the round-robin drain order
    /// so the deferred-restore scheduler will process it on its next tick.
    func queueDeferredRestoreState(tabID: UUID, state: SavedTabState) {
        deferredRestoreStatesByTabID[tabID] = state
        if !deferredRestoreTabOrder.contains(tabID) {
            deferredRestoreTabOrder.append(tabID)
        }
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

}
