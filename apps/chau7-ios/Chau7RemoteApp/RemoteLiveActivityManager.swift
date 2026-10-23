/// Manages ActivityKit Live Activities for the Dynamic Island and Lock Screen.
///
/// Creates, updates, and dismisses activities based on `RemoteActivityState`
/// frames from the Mac. Completed activities dismiss after 8 seconds,
/// failed activities after 20 seconds.
import ActivityKit
import Foundation
import os
import Chau7Core

@MainActor
final class RemoteLiveActivityManager {
    static let shared = RemoteLiveActivityManager()

    /// How long a live activity may go without an update before the system
    /// marks it stale.
    ///
    /// The activity is requested locally (no `pushType`), so it can only be
    /// updated while the app's socket is alive. With `staleDate: nil` a
    /// suspended app left the last-known state pinned for up to the 8-hour
    /// system cap — including an "approval required" card whose Approve/Deny
    /// links could no longer do anything.
    private static let staleAfter: TimeInterval = 120

    private let log = Logger(subsystem: "ch7", category: "RemoteLiveActivity")
    private var activity: Activity<Chau7RemoteActivityAttributes>?

    private init() {
        // Adopt whatever activity survived a process restart. Without this the
        // first update after any relaunch saw a nil handle and requested a
        // *second* activity for the same task, orphaning the first until the
        // 8-hour cap.
        adoptExistingActivity()
    }

    func update(with state: RemoteActivityState?) {
        // Teardown must not be gated on the user still having Live Activities
        // enabled: if they were switched off mid-flight the running activity
        // still has to be ended, or it lingers until the system cap.
        guard let state else {
            endCurrentActivity(after: nil)
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = Chau7RemoteActivityAttributes(activityID: state.activityID)
        let contentState = Chau7RemoteActivityAttributes.ContentState(
            state: state,
            redactDetails: AppSettings.hideSensitiveNotifications
        )
        let staleDate = Date().addingTimeInterval(Self.staleAfter)

        // Snapshot before any request, so the activity requested below is
        // never in the set that gets ended.
        let existing = Activity<Chau7RemoteActivityAttributes>.activities

        if let activity, activity.attributes.activityID == state.activityID,
           RemoteLiveActivityPolicy.acceptsUpdates(activity.activityState) {
            Task {
                await activity.update(ActivityContent(state: contentState, staleDate: staleDate))
                await scheduleEndIfNeeded(for: activity, status: state.status)
            }
        } else {
            // Untracked, or ended/dismissed by the user. Request a fresh one.
            activity = nil
            do {
                let requested = try Activity.request(
                    attributes: attributes,
                    content: ActivityContent(state: contentState, staleDate: staleDate)
                )
                activity = requested
                Task {
                    await scheduleEndIfNeeded(for: requested, status: state.status)
                }
            } catch {
                log.error("Failed to request live activity: \(error.localizedDescription)")
                DiagnosticsLog.shared.error(.lifecycle, "Live Activity request failed", [
                    "error": error.localizedDescription
                ])
            }
        }

        // Only one activity is shown. End everything else, including an older
        // duplicate for the same task, so two never coexist.
        let keptID = activity?.id
        let leftovers = existing.filter { $0.id != keptID }
        guard !leftovers.isEmpty else { return }
        Task {
            for candidate in leftovers {
                await candidate.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    /// Recovers the tracked activity after a process restart, preferring one
    /// that is still active.
    private func adoptExistingActivity() {
        let existing = Activity<Chau7RemoteActivityAttributes>.activities
        guard !existing.isEmpty else { return }
        activity = existing.first { RemoteLiveActivityPolicy.acceptsUpdates($0.activityState) } ?? existing.first
    }

    private func scheduleEndIfNeeded(
        for activity: Activity<Chau7RemoteActivityAttributes>,
        status: RemoteActivityStatus
    ) async {
        switch status {
        case .completed:
            await end(activity: activity, after: 8)
        case .failed:
            await end(activity: activity, after: 20)
        case .idle, .running, .approvalRequired, .waitingInput:
            return
        }
    }

    private func endCurrentActivity(after delay: TimeInterval?) {
        let tracked = activity
        activity = nil
        // End every activity we can see, not just the tracked handle: after a
        // relaunch the handle may be nil while an orphan is still on screen.
        let candidates = Activity<Chau7RemoteActivityAttributes>.activities
        guard tracked != nil || !candidates.isEmpty else { return }
        Task {
            for candidate in candidates {
                await end(activity: candidate, after: delay)
            }
            if let tracked, !candidates.contains(where: { $0.id == tracked.id }) {
                await end(activity: tracked, after: delay)
            }
        }
    }

    private func end(
        activity: Activity<Chau7RemoteActivityAttributes>,
        after delay: TimeInterval?
    ) async {
        let dismissalPolicy: ActivityUIDismissalPolicy
        if let delay {
            dismissalPolicy = .after(Date().addingTimeInterval(delay))
        } else {
            dismissalPolicy = .immediate
        }
        await activity.end(nil, dismissalPolicy: dismissalPolicy)
    }
}
