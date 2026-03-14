import ActivityKit
import Foundation
import os
import Chau7Core

@available(iOS 16.1, *)
@MainActor
final class RemoteLiveActivityManager {
    static let shared = RemoteLiveActivityManager()

    private let log = Logger(subsystem: "ch7", category: "RemoteLiveActivity")
    private var activity: Activity<Chau7RemoteActivityAttributes>?

    private init() {}

    func update(with state: RemoteActivityState?) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        guard let state else {
            endCurrentActivity(after: nil)
            return
        }

        let attributes = Chau7RemoteActivityAttributes(activityID: state.activityID)
        let contentState = Chau7RemoteActivityAttributes.ContentState(state: state)

        if let activity, activity.attributes.activityID != state.activityID {
            endCurrentActivity(after: nil)
        }

        if let activity {
            Task {
                await activity.update(ActivityContent(state: contentState, staleDate: nil))
                await scheduleEndIfNeeded(for: activity, status: state.status)
            }
            return
        }

        do {
            let requested = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: contentState, staleDate: nil)
            )
            activity = requested
            Task {
                await scheduleEndIfNeeded(for: requested, status: state.status)
            }
        } catch {
            log.error("Failed to request live activity: \(error.localizedDescription)")
        }
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
        case .idle, .running, .waitingInput:
            return
        }
    }

    private func endCurrentActivity(after delay: TimeInterval?) {
        guard let activity else { return }
        self.activity = nil
        Task {
            await end(activity: activity, after: delay)
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
