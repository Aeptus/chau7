import Foundation
import Observation
import UserNotifications
import Chau7Core

@MainActor
@Observable
final class PermissionCenterModel {
    var protectedSnapshots: [ProtectedPathAccessSnapshot] = []
    var notificationPermissionState: AppModel.NotificationPermissionState = .unknown
    var lastRefreshedAt: Date?

    func refresh() {
        protectedSnapshots = ProtectedPathPolicy.snapshots()
        lastRefreshedAt = Date()

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationPermissionState = AppModel.NotificationPermissionState.from(settings.authorizationStatus)
            }
        }
    }
}
