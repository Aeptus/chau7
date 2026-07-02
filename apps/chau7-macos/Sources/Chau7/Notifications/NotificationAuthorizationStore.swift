import Foundation
import UserNotifications

/// The single source for notification authorization state.
///
/// Authorization used to be read in three places with two independent caches
/// (AppModel's settings snapshot, NotificationManager's cached status, and
/// PermissionCenterModel's ad-hoc fetch), which could disagree between
/// refreshes. Every consumer now reads through this store; the only
/// `getNotificationSettings` call for status purposes lives here.
@MainActor
@Observable
final class NotificationAuthorizationStore {

    static let shared = NotificationAuthorizationStore()

    /// Latest known authorization status. `.notDetermined` until the first
    /// refresh or explicit `apply` resolves it.
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    /// Whether any authoritative signal (refresh or authorization request
    /// result) has been received this launch.
    private(set) var hasResolvedAuthorization = false
    /// Full settings from the last refresh (alert/sound/badge/style), for UI.
    private(set) var lastSettings: UNNotificationSettings?

    private init() {}

    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .denied, .notDetermined:
            return false
        @unknown default:
            return false
        }
    }

    /// Re-read the system settings. `completion` runs on the main actor with
    /// the fresh settings after the store has updated itself.
    func refresh(completion: (@MainActor (UNNotificationSettings) -> Void)? = nil) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.apply(status: settings.authorizationStatus)
                self.lastSettings = settings
                completion?(settings)
            }
        }
    }

    /// Record an authoritative status (e.g. the result of
    /// `requestAuthorization`, or a settings read performed elsewhere).
    func apply(status: UNAuthorizationStatus) {
        authorizationStatus = status
        hasResolvedAuthorization = true
    }
}
