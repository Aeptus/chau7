import Foundation
import Chau7Core

/// Selection-aware queue management for deferred tab-state restore on
/// `OverlayTabsModel`. The model's `init` populates
/// `deferredRestoreStatesByTabID` + `deferredRestoreTabOrder` for every
/// non-selected tab restored from saved state, and these helpers drain
/// the queue:
///
///   - `beginDeferredRestoreIfNeeded` — flips `hasStartedDeferredRestore`
///     once the scheduler is ready to start consuming.
///   - `restoreOneDeferredTabIfNeeded` — chooses the next background tab
///     using a selection-aware policy and performs identity-only hydration.
///     The full saved state remains parked for selection, close, export, or
///     cross-window transfer.
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

    enum DeferredRestoreStepResult: Equatable {
        case idle
        case deferred(TimeInterval)
        case restored
    }

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
        restoreOneDeferredTabIfAllowed(reason: reason) == .restored
    }

    @discardableResult
    func restoreOneDeferredTabIfAllowed(
        reason: String,
        now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()
    ) -> DeferredRestoreStepResult {
        if !hasStartedDeferredRestore {
            beginDeferredRestoreIfNeeded(reason: reason)
        }
        guard !deferredRestoreTabOrder.isEmpty else { return .idle }
        let decision = DeferredRestoreSchedulingPolicy.decide(
            pendingTabIDs: deferredRestoreTabOrder,
            tabOrder: tabs.map(\.id),
            selectedTabID: selectedTabID,
            lastSelectionChangedAt: lastSelectionChangedAt,
            now: now
        )
        let targetTabID: UUID
        let priority: DeferredRestoreCandidatePriority
        switch decision {
        case .idle:
            return .idle
        case .wait(let delay):
            Log.trace(
                "Deferred restore: pausing background identity work for \(Int((delay * 1000).rounded()))ms after tab selection [\(reason)]"
            )
            return .deferred(delay)
        case .restore(let tabID, let candidatePriority):
            targetTabID = tabID
            priority = candidatePriority
        }

        if targetTabID == selectedTabID,
           deferredRestoreStatesByTabID[selectedTabID] != nil {
            restoreSelectedDeferredTabIfNeeded(
                reason: "\(reason):scheduler_selected",
                executeSynchronouslyWhenPossible: true
            )
            return .restored
        }

        let previousHadPendingWork = hasPendingStartupRestoreWork
        deferredRestoreTabOrder.removeAll { $0 == targetTabID }
        hasStartedDeferredRestore = !deferredRestoreTabOrder.isEmpty
        guard let state = deferredRestoreStatesByTabID[targetTabID] else {
            notifyStartupRestoreWorkIfDrained(previousHadPendingWork: previousHadPendingWork)
            return .restored
        }
        guard let tab = tabs.first(where: { $0.id == targetTabID }) else {
            deferredRestoreStatesByTabID.removeValue(forKey: targetTabID)
            notifyStartupRestoreWorkIfDrained(previousHadPendingWork: previousHadPendingWork)
            return .restored
        }
        Log.info(
            """
            Deferred restore: hydrating identity for tab=\(targetTabID) \
            priority=\(priority.rawValue) remaining=\(deferredRestoreTabOrder.count) [\(reason)]
            """
        )
        restoreTabState(
            for: tab,
            state: state,
            scheduledDelayOverride: 0,
            executionProfile: .backgroundIdentityOnly
        )
        notifyStartupRestoreWorkIfDrained(previousHadPendingWork: previousHadPendingWork)
        return .restored
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
