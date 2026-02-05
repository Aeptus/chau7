import Foundation
import UserNotifications
import Chau7Core

final class NotificationManager {
    static let shared = NotificationManager()

    /// Tracks whether UNUserNotificationCenter is available and authorized
    /// Access must be synchronized via the serial queue
    private var _useNativeNotifications = true
    private var loggedAuthorizationStatuses: Set<UNAuthorizationStatus> = []
    private var didLogNativeError = false
    private let queue = DispatchQueue(label: "com.chau7.notificationManager")
    var tabTitleProvider: ((String) -> String?)?

    private var useNativeNotifications: Bool {
        get { queue.sync { _useNativeNotifications } }
        set { queue.sync { _useNativeNotifications = newValue } }
    }

    func updateAuthorizationStatus(_ status: UNAuthorizationStatus) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            useNativeNotifications = true
        case .denied:
            useNativeNotifications = false
        case .notDetermined:
            // Leave as-is; we'll fall back per-request.
            break
        @unknown default:
            break
        }
    }

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

        // Execute configured actions for this trigger
        executeActionsForEvent(event)
    }

    /// Execute the actions configured for the trigger matching this event
    private func executeActionsForEvent(_ event: AIEvent) {
        // Must access FeatureSettings on main thread
        let executeOnMain = { [weak self] in
            guard let trigger = NotificationTriggerCatalog.trigger(for: event) else {
                // No matching trigger, use default notification
                self?.showDefaultNotification(for: event)
                return
            }

            let actions = FeatureSettings.shared.actionsForTrigger(trigger.id)

            // If no custom actions and only default showNotification, use the fallback
            if actions.count == 1,
               let firstAction = actions.first,
               firstAction.actionType == .showNotification,
               firstAction.config.isEmpty {
                // Use optimized native/AppleScript notification path
                self?.showDefaultNotification(for: event)
                return
            }

            // Execute all configured actions
            NotificationActionExecutor.shared.execute(actions: actions, for: event)
        }

        if Thread.isMainThread {
            executeOnMain()
        } else {
            DispatchQueue.main.async(execute: executeOnMain)
        }
    }

    /// Show the default notification using native or AppleScript
    private func showDefaultNotification(for event: AIEvent) {
        if useNativeNotifications {
            tryNativeNotification(for: event)
        } else {
            let title = event.notificationTitle(toolOverride: resolveTabTitle(for: event.tool))
            sendAppleScriptNotification(title: title, body: event.notificationBody)
        }
    }

    private func tryNativeNotification(for event: AIEvent) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self?.scheduleNativeNotification(for: event)
            case .denied:
                self?.logAuthorizationOnce(
                    status: .denied,
                    message: "Native notifications denied, using AppleScript fallback"
                )
                self?.useNativeNotifications = false
                let title = event.notificationTitle(toolOverride: self?.resolveTabTitle(for: event.tool))
                self?.sendAppleScriptNotification(title: title, body: event.notificationBody)
            case .notDetermined:
                self?.logAuthorizationOnce(
                    status: .notDetermined,
                    message: "Notification permission not determined, using AppleScript fallback"
                )
                let title = event.notificationTitle(toolOverride: self?.resolveTabTitle(for: event.tool))
                self?.sendAppleScriptNotification(title: title, body: event.notificationBody)
            @unknown default:
                Log.warn("Unknown notification authorization status, trying AppleScript")
                let title = event.notificationTitle(toolOverride: self?.resolveTabTitle(for: event.tool))
                self?.sendAppleScriptNotification(title: title, body: event.notificationBody)
            }
        }
    }

    private func scheduleNativeNotification(for event: AIEvent) {
        Log.info("Scheduling notification: type=\(event.type) tool=\(event.tool)")

        let content = UNMutableNotificationContent()
        content.title = event.notificationTitle(toolOverride: resolveTabTitle(for: event.tool))
        content.body = event.notificationBody
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        center.add(request) { [weak self] error in
            if let error {
                if self?.didLogNativeError == false {
                    Log.error("Native notification error: \(error.localizedDescription)")
                    self?.didLogNativeError = true
                } else {
                    Log.warn("Native notification error (suppressed): \(error.localizedDescription)")
                }
                // Fall back to AppleScript for future notifications
                self?.useNativeNotifications = false
                // Try AppleScript for this notification
                let title = event.notificationTitle(toolOverride: self?.resolveTabTitle(for: event.tool))
                self?.sendAppleScriptNotification(title: title, body: event.notificationBody)
            } else {
                Log.info("Native notification scheduled successfully.")
            }
        }
    }

    private func logAuthorizationOnce(status: UNAuthorizationStatus, message: String) {
        let shouldLog = queue.sync { () -> Bool in
            if loggedAuthorizationStatuses.contains(status) {
                return false
            }
            loggedAuthorizationStatuses.insert(status)
            return true
        }
        if shouldLog {
            Log.info(message)
        }
    }

    /// Send notification via AppleScript (works without code signing)
    private func sendAppleScriptNotification(title: String, body: String) {
        // Escape special characters for AppleScript string literals
        // Order matters: escape backslashes first, then quotes
        let escapedTitle = title
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "")
        let escapedBody = body
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "")

        let script = """
        display notification "\(escapedBody)" with title "\(escapedTitle)" sound name "default"
        """

        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(&error)
                if let error = error {
                    Log.error("AppleScript notification error: \(error)")
                } else {
                    Log.info("AppleScript notification sent: \(title)")
                }
            } else {
                Log.error("Failed to create AppleScript for notification")
            }
        }
    }

    private func shouldNotify(_ event: AIEvent) -> Bool {
        if let trigger = NotificationTriggerCatalog.trigger(for: event) {
            return FeatureSettings.shared.notificationTriggerState.isEnabled(for: trigger)
        }
        return true
    }

    private func resolveTabTitle(for tool: String) -> String? {
        guard let provider = tabTitleProvider else { return nil }
        if Thread.isMainThread {
            return provider(tool)
        }
        var value: String?
        DispatchQueue.main.sync {
            value = provider(tool)
        }
        return value
    }
}
