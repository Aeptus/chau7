import AppKit
import Chau7Core
import Foundation

/// Coordinates the "preview snapshot → live Metal frame → swap" handoff
/// for the selected terminal tab on `OverlayTabsModel`. Three concerns:
///
///   1. **Pre-reveal scheduling** —
///      `scheduleSelectedTerminalPresentationCommit` arms a debounced
///      `DispatchWorkItem` that commits the live presentation if the
///      generation token still matches when the timer fires.
///      `scheduleSelectedTerminalRevealTimeout` arms a 0.75s backstop
///      that force-reveals if the surface still isn't live-presentable.
///      `resetSelectedTerminalRevealScheduling` cancels both.
///
///   2. **Commit + force-reveal** — `completeSelectedTabRevealIfNeeded`
///      is the central commit gate; `forceSelectedTabRevealLive` is the
///      no-questions-asked path used when scheduling fails.
///      `discardSettledRestorePreviews` clears stale preview snapshots
///      on tabs whose restore bootstrap has already finished.
///
///   3. **First-frame reporting to `StartupRestoreCoordinator`** —
///      `noteStartupSelectedTabLiveFrameIfNeeded` and the after-bootstrap
///      variant are the signal source for the coordinator's
///      `isReadyForVisibleStartupCompletion` check, which gates the
///      app-wide startup-restore completion.
///
/// Pure presentation/render coordination — no disk I/O, no notification
/// fanout, no AI metadata. Lives separately from the larger restore
/// pipeline (`OverlayTabsModel+RestorePipeline.swift`) because the
/// reveal-handoff state machine is conceptually distinct from the
/// scrollback / resume-prefill machinery.
extension OverlayTabsModel {

    func scheduleSelectedTerminalPresentationCommit(reason: String, delay: TimeInterval) {
        terminalReadyCommitWorkItem?.cancel()
        let expectedTabID = selectedTabID
        let expectedGeneration = selectedPresentationSession(for: selectedTab)?.presentationSurfaceState.generation
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard selectedTabID == expectedTabID else { return }
            guard selectedPresentationSession(for: self.selectedTab)?.presentationSurfaceState.generation == expectedGeneration,
                  let selectedTab = selectedTab else {
                return
            }
            completeSelectedTabRevealIfNeeded(for: selectedTab, reason: reason, force: false)
        }
        terminalReadyCommitWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    func resetSelectedTerminalRevealScheduling() {
        terminalReadyCommitWorkItem?.cancel()
        terminalReadyCommitWorkItem = nil
        selectedTerminalRevealTimeoutWorkItem?.cancel()
        selectedTerminalRevealTimeoutWorkItem = nil
    }

    func discardSettledRestorePreviews(reason: String) {
        for index in tabs.indices where tabs[index].restorePreviewSnapshot != nil {
            let phase = tabs[index].displaySession?.restoreBootstrapPhase ?? .inactive
            if phase != .replaying {
                StartupRestoreCoordinator.shared.noteRestorePreviewDiscarded(
                    tabID: tabs[index].id,
                    windowNumber: overlayWindow?.windowNumber,
                    reason: "\(reason)_phase_\(phase.rawValue)"
                )
                tabs[index].restorePreviewSnapshot = nil
            }
        }
    }

    func scheduleSelectedTerminalRevealTimeout(
        tabID: UUID,
        generation: UInt64,
        reason: String
    ) {
        selectedTerminalRevealTimeoutWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard selectedTabID == tabID,
                  let selectedTab = selectedTab,
                  let session = selectedPresentationSession(for: selectedTab),
                  session.presentationSurfaceState.generation == generation,
                  !self.selectedSurfacePresentation.isLivePresentable else {
                return
            }
            Log.warn(
                "selected-tab live reveal timeout[\(reason)]: forcing live presentation for tab \(tabID) generation=\(generation)"
            )
            completeSelectedTabRevealIfNeeded(for: selectedTab, reason: "\(reason)_timeout", force: true)
        }
        selectedTerminalRevealTimeoutWorkItem = item
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.selectedTerminalRevealTimeout,
            execute: item
        )
    }

    private func logSelectedTabRevealCompletion(
        _ completion: TerminalPresentationRevealCompletion,
        tabID: UUID,
        reason: String
    ) {
        if let totalMs = completion.totalMs, let postPresentMs = completion.postPresentMs {
            Log.trace(
                "tab handoff complete[\(reason)]: tab=\(tabID) total=\(totalMs)ms post_present=\(postPresentMs)ms"
            )
        } else if let totalMs = completion.totalMs {
            Log.trace("tab handoff complete[\(reason)]: tab=\(tabID) total=\(totalMs)ms")
        } else {
            Log.trace("tab handoff complete[\(reason)]: tab=\(tabID)")
        }
    }

    private func completeSelectedTabRevealIfNeeded(
        for tab: OverlayTab,
        reason: String,
        force: Bool
    ) {
        guard let session = selectedPresentationSession(for: tab) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        let completion = force
            ? session.forcePresentationLive(now: now, preserveVisibleFrameHandoff: true)
            : session.commitPresentationReveal(now: now)
        guard let completion else { return }

        resetSelectedTerminalRevealScheduling()
        if !force {
            session.cancelVisibleFrameReadyHandoff()
        }
        if let selectedIndex = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs[selectedIndex].restorePreviewSnapshot = nil
        }
        logSelectedTabRevealCompletion(completion, tabID: tab.id, reason: reason)
    }

    func forceSelectedTabRevealLive(tabID: UUID? = nil) {
        resetSelectedTerminalRevealScheduling()
        guard let targetID = tabID ?? selectedTab?.id,
              let tab = tabs.first(where: { $0.id == targetID }),
              let session = selectedPresentationSession(for: tab) else { return }
        let now = CFAbsoluteTimeGetCurrent()
        _ = session.forcePresentationLive(now: now)
        session.cancelVisibleFrameReadyHandoff()
    }

    func noteStartupSelectedTabLiveFrameIfNeeded(reason: String) {
        guard let tab = selectedTab,
              let windowNumber = overlayWindow?.windowNumber else {
            return
        }
        if tab.restorePreviewSnapshot != nil,
           tab.displaySession?.isRestoreBootstrapPending == true {
            guard let selectedSession = selectedPresentationSession(for: tab),
                  selectedSession.presentationSurfaceState.isLivePresentable else {
                return
            }
            if let selectedIndex = tabs.firstIndex(where: { $0.id == tab.id }) {
                StartupRestoreCoordinator.shared.noteRestorePreviewDiscarded(
                    tabID: tab.id,
                    windowNumber: windowNumber,
                    reason: "\(reason)_live_surface_ready"
                )
                tabs[selectedIndex].restorePreviewSnapshot = nil
            }
        }
        StartupRestoreCoordinator.shared.noteSelectedTabLiveFrame(
            windowNumber: windowNumber,
            selectedTabID: tab.id,
            reason: reason
        )
        onStartupSelectedTabLiveFrameRecorded?()
    }

    @discardableResult
    func noteStartupSelectedTabLiveFrameAfterRestoreBootstrapSettledIfNeeded(
        tabID: UUID,
        reason: String
    ) -> Bool {
        guard StartupRestoreCoordinator.shared.isActive,
              tabID == selectedTabID,
              let selectedTab,
              let selectedSession = selectedPresentationSession(for: selectedTab),
              selectedSession.existingRustTerminalView != nil,
              selectedSession.presentationSurfaceState.isLivePresentable else {
            return false
        }

        let alreadyRecorded = overlayWindow.map {
            StartupRestoreCoordinator.shared.hasSelectedTabLiveFrame(windowNumber: $0.windowNumber)
        } ?? false
        guard !alreadyRecorded else { return false }

        noteStartupSelectedTabLiveFrameIfNeeded(reason: reason)
        return true
    }

    /// Catch the case where the selected session's visible frame already
    /// presented before the per-window `terminalSessionVisibleFrameReady`
    /// observer was registered. Multi-window startup deterministically
    /// trips this: the SwiftUI terminal view's first paint fires the
    /// notification synchronously, but `OverlayTabsModel.init` for the
    /// second window runs after that paint (the notification has nowhere
    /// to land), and the 5 s coordinator fallback then synthesizes one.
    ///
    /// Called from `showOverlayWindow` immediately after `noteWindowVisible`
    /// arms the fallback timer, so the catch-up runs *before* the timer
    /// would otherwise fire. Idempotent — `noteStartupSelectedTabLiveFrame`
    /// dedups on the coordinator side.
    @discardableResult
    func replaySelectedTabLiveFrameIfAlreadyPresented(reason: String) -> Bool {
        guard StartupRestoreCoordinator.shared.isActive,
              let selectedTab,
              let selectedSession = selectedPresentationSession(for: selectedTab),
              selectedSession.presentationSurfaceState.lastVisibleFramePresentedAt != nil
        else {
            return false
        }
        let alreadyRecorded = overlayWindow.map {
            StartupRestoreCoordinator.shared.hasSelectedTabLiveFrame(windowNumber: $0.windowNumber)
        } ?? false
        guard !alreadyRecorded else { return false }

        noteStartupSelectedTabLiveFrameIfNeeded(reason: reason)
        return true
    }
}
