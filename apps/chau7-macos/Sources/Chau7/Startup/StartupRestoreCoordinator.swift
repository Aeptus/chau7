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
            deliveredResumePrefills=\(summary.deliveredResumePrefills)
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
}
