import Foundation
import Observation
import UserNotifications
import Chau7Core

@MainActor
@Observable
final class PermissionCenterModel {
    var protectedSnapshots: [ProtectedPathAccessSnapshot] = []
    var notificationPermissionState: AppModel.NotificationPermissionState = .unknown
    /// Full Disk Access — the grant child processes (codex, claude, shells)
    /// inherit. Distinct from `protectedSnapshots`, which are Chau7's own
    /// security-scoped bookmarks.
    var fullDiskAccessStatus: FullDiskAccessProbe.Status = .indeterminate
    var lastRefreshedAt: Date?

    func refresh() {
        protectedSnapshots = ProtectedPathPolicy.snapshots()
        fullDiskAccessStatus = FullDiskAccessProbe.probe()
        lastRefreshedAt = Date()

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationPermissionState = AppModel.NotificationPermissionState.from(settings.authorizationStatus)
            }
        }
    }
}
