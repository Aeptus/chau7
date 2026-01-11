import Foundation
import UserNotifications

final class NotificationManager {
    static let shared = NotificationManager()

    func notify(for event: AIEvent) {
        // Skip notifications when not running as a proper app bundle
        guard Bundle.main.bundleIdentifier != nil else {
            Log.info("Skipping notification (not running as bundle): type=\(event.type) tool=\(event.tool)")
            return
        }
        if !shouldNotify(event) {
            Log.trace("Notification filtered: type=\(event.type) tool=\(event.tool)")
            return
        }

        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                break
            case .denied, .notDetermined:
                Log.warn("Skipping notification (not authorized): status=\(settings.authorizationStatus.rawValue)")
                return
            @unknown default:
                Log.warn("Skipping notification (unknown authorization status).")
                return
            }

            Log.info("Scheduling notification: type=\(event.type) tool=\(event.tool)")

            let content = UNMutableNotificationContent()
            content.title = event.notificationTitle
            content.body = event.notificationBody
            content.sound = .default

            let request = UNNotificationRequest(
                identifier: UUID().uuidString,
                content: content,
                trigger: nil
            )

            center.add(request) { error in
                if let error {
                    Log.error("Notification error: \(error.localizedDescription)")
                } else {
                    Log.info("Notification scheduled successfully.")
                }
            }
        }
    }

    private func shouldNotify(_ event: AIEvent) -> Bool {
        let filters = FeatureSettings.shared.notificationFilters
        switch event.type.lowercased() {
        case "finished":
            return filters.taskFinished
        case "failed":
            return filters.taskFailed
        case "needs_validation":
            return filters.needsValidation
        case "permission":
            return filters.permissionRequest
        case "tool_complete":
            return filters.toolComplete
        case "session_end":
            return filters.sessionEnd
        case "idle":
            return filters.commandIdle
        default:
            return true
        }
    }
}
