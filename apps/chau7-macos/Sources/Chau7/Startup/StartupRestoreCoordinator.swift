import Foundation
import Chau7Core

final class StartupRestoreCoordinator {
    static let shared = StartupRestoreCoordinator()

    /// How long after `noteWindowVisible` we'll wait for the natural
    /// `noteSelectedTabLiveFrame` before synthesizing one. Tuned shorter
    /// than the t=8s `coordinator_ended` backstop in `AppDelegate.finishLaunching`
    /// so a stuck window unblocks startup completion before the global
    /// kick fires.
    static let liveFrameSynthesisDelay: TimeInterval = 5.0

    private let lock = NSLock()
    private var tracker = StartupRestoreTracker()

    /// Per-window pending fallback timers. When `noteWindowVisible` fires
    /// for a window, an item is scheduled here; if `noteSelectedTabLiveFrame`
    /// arrives naturally it cancels the item; otherwise the item synthesizes
    /// the live-frame signal so completion can proceed.
    private var liveFrameFallbackByWindow: [Int: DispatchWorkItem] = [:]

    private init() {}

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tracker.isActive
    }

    var selectedTabLiveFrameCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return tracker.selectedTabLiveFrameMsByWindow.count
    }

    func hasSelectedTabLiveFrame(windowNumber: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tracker.hasSelectedTabLiveFrame(windowNumber: windowNumber)
    }

    func noteWindowPrepared(windowNumber: Int, selectedTabID: UUID?) {
        lock.lock()
        defer { lock.unlock() }
        guard tracker.isActive else { return }
        tracker.noteWindowPrepared(windowNumber: windowNumber, at: Date())
        let tabLabel = selectedTabID?.uuidString ?? "nil"
        Log.info("Startup window prepared: window=\(windowNumber) selectedTab=\(tabLabel)")
    }

    func begin() {
        lock.lock()
        tracker.begin(at: Date())
        lock.unlock()
    }

    func end() {
        lock.lock()
        let summary = tracker.end(at: Date())
        lock.unlock()
        guard let summary else { return }
        let protectedRoots = summary.protectedRoots.isEmpty ? "(none)" : summary.protectedRoots.joined(separator: ", ")
        Log.info(
            """
            Startup restore summary: duration=\(summary.durationMs)ms \
            protectedRoots=\(protectedRoots) protectedPathDeferrals=\(summary.protectedPathDeferrals) \
            debouncedSnippetResolves=\(summary.debouncedSnippetResolves) \
            completedSnippetResolves=\(summary.completedSnippetResolves) \
            delayedResumePrefills=\(summary.delayedResumePrefills) \
            queuedResumePrefills=\(summary.queuedResumePrefills) \
            deliveredResumePrefills=\(summary.deliveredResumePrefills) \
            restoreBootstrapStarted=\(summary.restoreBootstrapStarted) \
            restoreBootstrapSettled=\(summary.restoreBootstrapSettled) \
            restorePreviewShown=\(summary.restorePreviewShown) \
            restorePreviewDiscarded=\(summary.restorePreviewDiscarded) \
            selectedTabLiveFrameCount=\(summary.selectedTabLiveFrameCount) \
            firstWindowVisibleMs=\(summary.firstWindowVisibleMs.map(String.init) ?? "nil") \
            firstSelectedTabLiveFrameSinceStartMs=\(summary.firstSelectedTabLiveFrameSinceStartMs.map(String.init) ?? "nil") \
            firstSelectedTabLiveFrameMs=\(summary.firstSelectedTabLiveFrameMs.map(String.init) ?? "nil") \
            slowestSelectedTabLiveFrameMs=\(summary.slowestSelectedTabLiveFrameMs.map(String.init) ?? "nil")
            """
        )
    }

    func isReadyToComplete(expectedWindowCount: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tracker.isReadyForVisibleStartupCompletion(expectedWindowCount: expectedWindowCount)
    }

    func shouldLogProtectedPathDeferral(forPath path: String) -> Bool {
        lock.lock()
        let isActive = tracker.isActive
        lock.unlock()
        guard isActive,
              let root = ProtectedPathPolicy.protectedRootForDiagnostics(path: path) else {
            return true
        }
        lock.lock()
        let shouldLog = tracker.noteProtectedPathDeferral(root: root)
        lock.unlock()
        return shouldLog
    }

    func shouldDebounceSnippetResolve(forPath path: String) -> Bool {
        lock.lock()
        let isActive = tracker.isActive
        lock.unlock()
        let shouldDebounce = StartupSnippetResolvePolicy.shouldDebounce(
            isStartupRestoreActive: isActive,
            path: path,
            homePath: RuntimeIsolation.homePath()
        )
        if shouldDebounce {
            lock.lock()
            tracker.noteSnippetResolveDebounced()
            lock.unlock()
        }
        return shouldDebounce
    }

    func noteSnippetResolveCompleted() {
        lock.lock()
        defer { lock.unlock() }
        guard tracker.isActive else { return }
        tracker.noteSnippetResolveCompleted()
    }

    func noViewResumeDecision(remainingAttempts: Int) -> StartupResumePrefillPolicy.NoViewDecision {
        lock.lock()
        let isActive = tracker.isActive
        lock.unlock()
        let decision = StartupResumePrefillPolicy.noViewDecision(
            isStartupRestoreActive: isActive,
            remainingAttempts: remainingAttempts
        )
        if decision == .retryWaitingForView {
            lock.lock()
            tracker.noteResumePrefillDelayed()
            lock.unlock()
        }
        return decision
    }

    func shouldWarnAboutResumeNotReady() -> Bool {
        lock.lock()
        let isActive = tracker.isActive
        lock.unlock()
        return StartupResumePrefillPolicy.shouldWarnAboutNotReady(isStartupRestoreActive: isActive)
    }

    func noteQueuedResumePrefill() {
        lock.lock()
        defer { lock.unlock() }
        guard tracker.isActive else { return }
        tracker.noteResumePrefillQueued()
    }

    func noteDeliveredResumePrefill() {
        lock.lock()
        defer { lock.unlock() }
        guard tracker.isActive else { return }
        tracker.noteResumePrefillDelivered()
    }

    func noteRestoreBootstrapStarted(tabID: UUID, paneID: UUID, expectsResumePrefill: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard tracker.isActive else { return }
        tracker.noteRestoreBootstrapStarted()
        Log.info(
            "Restore bootstrap began: tab=\(tabID) pane=\(paneID) expectsResumePrefill=\(expectsResumePrefill)"
        )
    }

    func noteRestoreBootstrapSettled(tabID: UUID, paneID: UUID, source: String) {
        lock.lock()
        defer { lock.unlock() }
        guard tracker.isActive else { return }
        tracker.noteRestoreBootstrapSettled()
        Log.info("Restore bootstrap settled: tab=\(tabID) pane=\(paneID) source=\(source)")
    }

    func noteRestorePreviewShown(tabID: UUID, windowNumber: Int?, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard tracker.isActive else { return }
        tracker.noteRestorePreviewShown()
        let windowLabel = windowNumber.map(String.init) ?? "nil"
        Log.info("Restore preview shown: tab=\(tabID) window=\(windowLabel) reason=\(reason)")
    }

    func noteRestorePreviewDiscarded(tabID: UUID, windowNumber: Int?, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard tracker.isActive else { return }
        tracker.noteRestorePreviewDiscarded()
        let windowLabel = windowNumber.map(String.init) ?? "nil"
        Log.info("Restore preview discarded: tab=\(tabID) window=\(windowLabel) reason=\(reason)")
    }

    func noteWindowVisible(windowNumber: Int, selectedTabID: UUID?) {
        lock.lock()
        tracker.noteWindowPrepared(windowNumber: windowNumber, at: Date())
        tracker.noteWindowVisible(windowNumber: windowNumber, at: Date())
        let isActive = tracker.isActive
        lock.unlock()

        guard isActive else { return }
        let tabLabel = selectedTabID?.uuidString ?? "nil"
        Log.info("Startup window visible: window=\(windowNumber) selectedTab=\(tabLabel)")

        scheduleLiveFrameFallback(windowNumber: windowNumber)
    }

    func noteSelectedTabLiveFrame(windowNumber: Int, selectedTabID: UUID?, reason: String) {
        lock.lock()
        let isActive = tracker.isActive
        let elapsedMs: Int? = isActive
            ? tracker.noteSelectedTabLiveFrame(windowNumber: windowNumber, at: Date())
            : nil
        let pending = liveFrameFallbackByWindow.removeValue(forKey: windowNumber)
        lock.unlock()

        pending?.cancel()

        guard isActive, let elapsedMs else { return }
        let tabLabel = selectedTabID?.uuidString ?? "nil"
        Log.info(
            "Startup selected-tab first live frame: window=\(windowNumber) selectedTab=\(tabLabel) elapsed=\(elapsedMs)ms reason=\(reason)"
        )
    }

    // MARK: - Live-frame synthesis fallback (P2)

    /// Pure decision: should we synthesize a live-frame for the given
    /// window? Yes only if startup-restore is still active AND no live
    /// frame has been recorded for the window. Extracted as a static
    /// helper so the rule is unit-testable without standing up a
    /// coordinator instance + DispatchQueue timing.
    static func shouldSynthesizeLiveFrameFallback(
        isCoordinatorActive: Bool,
        hasReportedLiveFrame: Bool
    ) -> Bool {
        guard isCoordinatorActive else { return false }
        return !hasReportedLiveFrame
    }

    private func scheduleLiveFrameFallback(windowNumber: Int) {
        let item = DispatchWorkItem { [weak self] in
            self?.synthesizeLiveFrameIfStillMissing(windowNumber: windowNumber)
        }
        lock.lock()
        liveFrameFallbackByWindow[windowNumber]?.cancel()
        liveFrameFallbackByWindow[windowNumber] = item
        lock.unlock()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.liveFrameSynthesisDelay,
            execute: item
        )
    }

    private func synthesizeLiveFrameIfStillMissing(windowNumber: Int) {
        lock.lock()
        liveFrameFallbackByWindow.removeValue(forKey: windowNumber)
        let isActive = tracker.isActive
        let alreadyReported = tracker.hasSelectedTabLiveFrame(windowNumber: windowNumber)
        let shouldSynthesize = Self.shouldSynthesizeLiveFrameFallback(
            isCoordinatorActive: isActive,
            hasReportedLiveFrame: alreadyReported
        )
        let elapsedMs: Int? = shouldSynthesize
            ? tracker.noteSelectedTabLiveFrame(windowNumber: windowNumber, at: Date())
            : nil
        lock.unlock()

        guard shouldSynthesize, let elapsedMs else { return }
        Log.warn(
            """
            Startup selected-tab live-frame synthesized: window=\(windowNumber) \
            elapsed=\(elapsedMs)ms reason=fallback_\(Int(Self.liveFrameSynthesisDelay))s_no_live_frame. \
            The natural noteSelectedTabLiveFrame callback never reached the coordinator — likely a \
            missed didBecomeMain/didBecomeKey handoff during multi-window startup. \
            Synthesizing so completeStartupRestoreIfReady can proceed.
            """
        )
    }
}
