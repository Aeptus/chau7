import UIKit

/// Wraps a single UIKit background task used to keep the relay connection alive
/// long enough to deliver a queued approval after the app is backgrounded.
///
/// Extracted from `RemoteClient` so the `beginBackgroundTask`/`endBackgroundTask`
/// bookkeeping (and the expiration race) is owned by one type. The client
/// supplies `onExpire` to run its own teardown (suppress local notifications,
/// disconnect, update status) when the system reclaims the task.
@MainActor
final class BackgroundKeepalive {
    private var taskID: UIBackgroundTaskIdentifier = .invalid
    private let name: String

    /// Invoked on the main actor when the background task expires. The keepalive
    /// has already released its task identifier by the time this runs.
    var onExpire: (() -> Void)?

    init(name: String) {
        self.name = name
    }

    var isActive: Bool {
        taskID != .invalid
    }

    func begin() {
        guard taskID == .invalid else { return }
        var requestedID: UIBackgroundTaskIdentifier = .invalid
        requestedID = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            UIApplication.shared.endBackgroundTask(requestedID)
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.taskID == requestedID {
                    self.taskID = .invalid
                }
                self.onExpire?()
            }
        }
        taskID = requestedID
    }

    func end() {
        guard taskID != .invalid else { return }
        UIApplication.shared.endBackgroundTask(taskID)
        taskID = .invalid
    }
}
