import Foundation
import Chau7Core

final class StartupRestoreCoordinator {
    static let shared = StartupRestoreCoordinator()

    private let lock = NSLock()
    private var tracker = StartupRestoreTracker()

    private init() {}

    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return tracker.isActive
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
            firstSelectedTabLiveFrameMs=\(summary.firstSelectedTabLiveFrameMs.map(String.init) ?? "nil") \
            slowestSelectedTabLiveFrameMs=\(summary.slowestSelectedTabLiveFrameMs.map(String.init) ?? "nil")
            """
        )
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
        defer { lock.unlock() }
        guard tracker.isActive else { return }
        tracker.noteWindowVisible(windowNumber: windowNumber, at: Date())
        let tabLabel = selectedTabID?.uuidString ?? "nil"
        Log.info("Startup window visible: window=\(windowNumber) selectedTab=\(tabLabel)")
    }

    func noteSelectedTabLiveFrame(windowNumber: Int, selectedTabID: UUID?, reason: String) {
        lock.lock()
        defer { lock.unlock() }
        guard tracker.isActive else { return }
        guard let elapsedMs = tracker.noteSelectedTabLiveFrame(windowNumber: windowNumber, at: Date()) else {
            return
        }
        let tabLabel = selectedTabID?.uuidString ?? "nil"
        Log.info(
            "Startup selected-tab first live frame: window=\(windowNumber) selectedTab=\(tabLabel) elapsed=\(elapsedMs)ms reason=\(reason)"
        )
    }
}
