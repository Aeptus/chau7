import Chau7Core
import Foundation

/// Background rendering suspension + the render-lifecycle snapshot/decision
/// plumbing that feeds it. Two concerns live in one extension because they
/// share every helper: the snapshot describes "which tab is where in the
/// lifecycle," the decision combines snapshot + per-tab descriptor to yield
/// a phase, and suspension timers act on the `.hidden` phase output.
///
/// Stored state stays on the main class (Swift can't put stored properties
/// in an extension):
///   - `isRenderSuspensionEnabled`, `renderSuspensionDelay`
///   - `suspendWorkItems`, `suspendedTabIDs`
///   - `renderLifecycleRefreshToken`, `restoreBootstrapTabIDs`, `prewarmingTabIDs`
///   - `renderLifecycleController`
///   - `overlayWindow`
extension OverlayTabsModel {
    func configureRenderSuspension(enabled: Bool, delay: TimeInterval) {
        isRenderSuspensionEnabled = enabled
        renderSuspensionDelay = max(0, delay)
        suspendWorkItems.values.forEach { $0.cancel() }
        suspendWorkItems.removeAll()
        updateSuspensionState()
        logVisualState(reason: "renderSuspension: enabled=\(enabled) delay=\(renderSuspensionDelay)")
    }

    func isTabSuspended(_ id: UUID) -> Bool {
        renderPhase(forTabID: id) == .hidden
    }

    var isWindowVisibleForRendering: Bool {
        if StartupRestoreCoordinator.shared.isActive {
            return true
        }
        guard let overlayWindow else { return true }
        return overlayWindow.isVisible && !overlayWindow.isMiniaturized
    }

    func renderLifecycleSnapshot() -> TabRenderLifecycleController.Snapshot {
        let isInputPriorityWindow: Bool
        let isStartupRestoreActive = StartupRestoreCoordinator.shared.isActive
        if let overlayWindow {
            isInputPriorityWindow = TabRenderLifecyclePolicy.isInputPriorityWindow(
                hasWindow: true,
                isKeyWindow: overlayWindow.isKeyWindow,
                isMainWindow: overlayWindow.isMainWindow,
                isStartupRestoreActive: isStartupRestoreActive
            )
        } else {
            isInputPriorityWindow = TabRenderLifecyclePolicy.isInputPriorityWindow(
                hasWindow: false,
                isKeyWindow: false,
                isMainWindow: false,
                isStartupRestoreActive: isStartupRestoreActive
            )
        }
        return TabRenderLifecycleController.Snapshot(
            selectedTabID: selectedTabID,
            isInputPriorityWindow: isInputPriorityWindow,
            isWindowVisibleForRendering: isWindowVisibleForRendering,
            previousLiveHierarchyTabID: previousLiveHierarchyTabID,
            prewarmingTabIDs: prewarmingTabIDs,
            restoreBootstrapTabIDs: restoreBootstrapTabIDs,
            isRenderSuspensionEnabled: isRenderSuspensionEnabled,
            isStartupRestoreActive: isStartupRestoreActive
        )
    }

    func renderLifecycleDescriptor(for tab: OverlayTab) -> TabRenderLifecycleController.TabDescriptor {
        let hasAttachedTerminalView = !tab.splitController.terminalSessions.contains { _, session in
            session.existingRustTerminalView == nil
        }
        let hasBackgroundActivity = tab.splitController.terminalSessions.contains { _, session in
            session.shouldKeepLiveRenderingInBackground
        }
        return TabRenderLifecycleController.TabDescriptor(
            id: tab.id,
            isMCPControlled: tab.isMCPControlled,
            hasAttachedTerminalView: hasAttachedTerminalView,
            hasBackgroundActivity: hasBackgroundActivity
        )
    }

    func renderLifecycleDecision(for tab: OverlayTab) -> TabRenderLifecycleDecision {
        renderLifecycleController.decision(
            for: renderLifecycleDescriptor(for: tab),
            snapshot: renderLifecycleSnapshot()
        )
    }

    func renderPhase(for tab: OverlayTab) -> TabRenderPhase {
        let decision = renderLifecycleDecision(for: tab)
        guard decision.phase == .hidden else { return decision.phase }
        return suspendedTabIDs.contains(tab.id) ? .hidden : .warm
    }

    func invalidateRenderLifecycle(reason: String) {
        renderLifecycleRefreshToken = UUID()
        updateSuspensionState()
        // Re-attach the shared Metal coordinator to the selected tab.
        // This is the ONLY reliable path for app-focus-restore because:
        // - selectTab() has an early exit for already-selected tabs
        // - .terminalDidStart only fires once at launch
        // - updateNSView sets a flag but never calls switchToView
        _ = refreshSelectedTabInPlaceIfPossible(reason: "invalidateRenderLifecycle:\(reason)")
        Log.trace("renderLifecycle: invalidated [\(reason)]")
    }

    func renderPhase(forTabID id: UUID) -> TabRenderPhase {
        guard let tab = tabs.first(where: { $0.id == id }) else { return .hidden }
        return renderPhase(for: tab)
    }

    func isInteractive(tab: OverlayTab) -> Bool {
        renderLifecycleDecision(for: tab).isInteractive
    }

    var shouldHoldLowLatencyWhileInactive: Bool {
        guard isWindowVisibleForRendering else {
            return false
        }

        return tabs.contains { tab in
            let decision = renderLifecycleDecision(for: tab)
            guard decision.phase.allowsLivePresentation,
                  let session = selectedPresentationSession(for: tab) else {
                return false
            }
            return session.existingRustTerminalView != nil || session.awaitingVisibleFrameReady
        }
    }

    /// Fresh MCP tabs need a real terminal view at least once so background
    /// exec/input requests have a PTY to land on. Once a terminal view has
    /// attached, the retained Rust view keeps the session alive even if the tab
    /// later drops out of the visible hierarchy.
    ///
    /// Observability: `TabRenderLifecyclePolicy.keepsLiveHierarchy(for:)`
    /// currently returns `true` unconditionally (verified in
    /// `Sources/Chau7Core/TabRenderLifecycle.swift:142`). Any `false` return
    /// here indicates either a policy change or an upstream feature flag we
    /// don't know about, and would resurrect the dead `Color.clear`
    /// placeholder branch in `Chau7OverlayView.terminalStack` — which the
    /// W1.1 investigation flagged as broken for split panes. Emit a Log.warn
    /// so a regression turns up in the log instead of in user-visible UI.
    func shouldKeepTabInLiveHierarchy(tab: OverlayTab, index _: Int) -> Bool {
        let decision = renderLifecycleDecision(for: tab)
        let result = decision.keepsLiveHierarchy
        if !result {
            Log.warn(
                """
                renderLifecycle: keepsLiveHierarchy=false unexpected for \
                tab=\(tab.id) phase=\(decision.phase.rawValue) \
                isInteractive=\(decision.isInteractive) — current policy returns true unconditionally; \
                a false here would re-enable the unreachable Color.clear branch in Chau7OverlayView \
                that the W1.1 investigation identified as broken for split panes. Investigate.
                """
            )
        }
        return result
    }

    func updateSuspensionState() {
        let previousSuspended = suspendedTabIDs
        let validIDs = Set(tabs.map { $0.id })

        suspendWorkItems
            .filter { !validIDs.contains($0.key) }
            .forEach { $0.value.cancel() }
        suspendWorkItems = suspendWorkItems.filter { validIDs.contains($0.key) }
        suspendedTabIDs = suspendedTabIDs.intersection(validIDs)
        restoreBootstrapTabIDs = restoreBootstrapTabIDs.intersection(validIDs)

        guard isRenderSuspensionEnabled else {
            suspendWorkItems.values.forEach { $0.cancel() }
            suspendWorkItems.removeAll()
            suspendedTabIDs.removeAll()
            if previousSuspended != suspendedTabIDs {
                logVisualState(reason: "renderSuspension: cleared")
            }
            return
        }

        // Selected tab should always be active.
        suspendedTabIDs.remove(selectedTabID)
        cancelSuspension(for: selectedTabID)

        let snapshot = renderLifecycleSnapshot()
        for tab in tabs where tab.id != selectedTabID {
            let decision = renderLifecycleController.decision(
                for: renderLifecycleDescriptor(for: tab),
                snapshot: snapshot
            )
            if decision.phase != .hidden {
                cancelSuspension(for: tab.id)
                let wasSuspended = suspendedTabIDs.remove(tab.id) != nil
                if wasSuspended {
                    Log.info(
                        "renderSuspension: reactivated tab \(tab.id) as \(decision.phase.rawValue) (\(tabRenderSuspensionSummary(tab)))"
                    )
                }
                continue
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
        let decision = renderLifecycleController.decision(
            for: renderLifecycleDescriptor(for: tab),
            snapshot: renderLifecycleSnapshot()
        )

        if decision.phase != .hidden {
            Log.trace(
                "renderSuspension: skipped scheduling for tab \(id) because phase=\(decision.phase.rawValue) (\(tabRenderSuspensionSummary(tab)))"
            )
            return
        }

        let item = DispatchWorkItem { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.isRenderSuspensionEnabled else { return }
                guard self.selectedTabID != id else { return }
                guard let tab = self.tabs.first(where: { $0.id == id }) else { return }
                let decision = self.renderLifecycleController.decision(
                    for: self.renderLifecycleDescriptor(for: tab),
                    snapshot: self.renderLifecycleSnapshot()
                )
                guard decision.phase == .hidden else {
                    Log.info(
                        "renderSuspension: cancelled at deadline for tab \(id) because phase=\(decision.phase.rawValue) (\(self.tabRenderSuspensionSummary(tab)))"
                    )
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
}
