import Foundation

/// FIFO queue management for deferred tab-state restore on
/// `OverlayTabsModel`. The model's `init` populates
/// `deferredRestoreStatesByTabID` + `deferredRestoreTabOrder` for every
/// non-selected tab restored from saved state, and these helpers drain
/// the queue:
///
///   - `beginDeferredRestoreIfNeeded` — flips `hasStartedDeferredRestore`
///     once the scheduler is ready to start consuming.
///   - `restoreOneDeferredTabIfNeeded` — pops the next queued tab and
///     invokes `restoreTabState` (in `+RestorePipeline.swift`).
///   - `restoreSelectedDeferredTabIfNeeded` — priority path used by
///     `selectTab` so a clicked background tab restores immediately
///     rather than waiting for its turn in the FIFO.
///   - `notifyStartupRestoreWorkIfDrained` — fires
///     `onStartupRestoreWorkDrained` when the queue + bootstrap set
///     transition from non-empty to empty.
///
/// `hasPendingDeferredRestore` / `hasPendingStartupRestoreWork` are the
/// observable status flags `AppDelegate` checks from its watchdog and
/// from `completeStartupRestoreIfReady`.
extension OverlayTabsModel {

    func beginDeferredRestoreIfNeeded(reason: String) {
        guard !hasStartedDeferredRestore else { return }
        guard !deferredRestoreTabOrder.isEmpty else { return }
        hasStartedDeferredRestore = true
        Log.info(
            "Starting deferred restore for \(deferredRestoreTabOrder.count) background tab(s) [\(reason)]"
        )
    }

    var hasPendingDeferredRestore: Bool {
        !deferredRestoreTabOrder.isEmpty
    }

    var hasPendingStartupRestoreWork: Bool {
        !restoreBootstrapTabIDs.isEmpty
    }

    func notifyStartupRestoreWorkIfDrained(previousHadPendingWork: Bool) {
        if previousHadPendingWork, !hasPendingStartupRestoreWork {
            onStartupRestoreWorkDrained?()
        }
    }

    @discardableResult
    func restoreOneDeferredTabIfNeeded(reason: String) -> Bool {
        if !hasStartedDeferredRestore {
            beginDeferredRestoreIfNeeded(reason: reason)
        }
        guard !deferredRestoreTabOrder.isEmpty else { return false }
        let previousHadPendingWork = hasPendingStartupRestoreWork
        let tabID = deferredRestoreTabOrder.removeFirst()
        guard let state = deferredRestoreStatesByTabID.removeValue(forKey: tabID) else {
            notifyStartupRestoreWorkIfDrained(previousHadPendingWork: previousHadPendingWork)
            return true
        }
        guard let tab = tabs.first(where: { $0.id == tabID }) else {
            notifyStartupRestoreWorkIfDrained(previousHadPendingWork: previousHadPendingWork)
            return true
        }
        Log.info("Deferred restore: restoring tab=\(tabID) remaining=\(deferredRestoreTabOrder.count) [\(reason)]")
        restoreTabState(for: tab, state: state, scheduledDelayOverride: 0)
        notifyStartupRestoreWorkIfDrained(previousHadPendingWork: previousHadPendingWork)
        return true
    }

    func restoreSelectedDeferredTabIfNeeded(
        reason: String,
        executeSynchronouslyWhenPossible: Bool = false
    ) {
        guard let deferredState = deferredRestoreStatesByTabID.removeValue(forKey: selectedTabID) else { return }
        let previousHadPendingWork = hasPendingStartupRestoreWork
        deferredRestoreTabOrder.removeAll { $0 == selectedTabID }
        hasStartedDeferredRestore = !deferredRestoreTabOrder.isEmpty
        guard let tab = tabs.first(where: { $0.id == selectedTabID }) else { return }
        Log.info("Deferred restore: prioritizing selected tab=\(selectedTabID) [\(reason)]")
        restoreTabState(
            for: tab,
            state: deferredState,
            scheduledDelayOverride: 0,
            useResumeRetryScheduler: false,
            executeSynchronouslyWhenPossible: executeSynchronouslyWhenPossible
        )
        notifyStartupRestoreWorkIfDrained(previousHadPendingWork: previousHadPendingWork)
    }
}
