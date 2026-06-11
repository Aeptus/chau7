import Foundation

/// Owns the debounced "save after the user stops typing" + "clear the
/// auto-saved status message after a couple seconds" work-item bookkeeping
/// that used to live as two pairs of `private var ...WorkItem: DispatchWorkItem?`
/// + `private func schedule...` on `TextEditorModel`. The model now drives
/// the autosaver via closures instead of owning the work-item state directly.
///
/// The autosaver knows nothing about editor save semantics — it just
/// schedules a closure on the main queue after a delay, and cancels the
/// previous schedule when a new one supersedes it. Tests can verify the
/// scheduling behaviour in isolation.
final class EditorAutoSaver {
    private var saveWorkItem: DispatchWorkItem?
    private var clearStatusWorkItem: DispatchWorkItem?

    deinit {
        saveWorkItem?.cancel()
        clearStatusWorkItem?.cancel()
    }

    /// Schedule a save after `seconds`, replacing any previously scheduled
    /// save. The closure runs on the main queue.
    func scheduleSave(after seconds: TimeInterval = 2.5, perform work: @escaping () -> Void) {
        saveWorkItem?.cancel()
        let item = DispatchWorkItem(block: work)
        saveWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Cancel any pending save without running it. Called by `discardPendingChanges`.
    func cancelPendingSave() {
        saveWorkItem?.cancel()
        saveWorkItem = nil
    }

    /// Schedule the "auto-saved" status message to clear after `seconds`,
    /// replacing any previously scheduled clear.
    func scheduleStatusClear(after seconds: TimeInterval = 2.0, perform work: @escaping () -> Void) {
        clearStatusWorkItem?.cancel()
        let item = DispatchWorkItem(block: work)
        clearStatusWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Cancel any pending status-clear.
    func cancelStatusClear() {
        clearStatusWorkItem?.cancel()
        clearStatusWorkItem = nil
    }
}
