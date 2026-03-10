import Foundation
import AppKit
import UserNotifications
import Chau7Core

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()

    /// Tracks whether UNUserNotificationCenter is available and authorized
    private var useNativeNotifications = true
    private var cachedAuthorizationStatus: UNAuthorizationStatus = .notDetermined
    private var hasCachedAuthorization = false
    private var loggedAuthorizationStatuses: Set<UNAuthorizationStatus> = []
    private var didLogNativeError = false
    private var nativeNotificationFailureCount = 0
    private var nativeNotificationErrorCooldownUntil: Date?
    private let nativeNotificationBaseCooldown: TimeInterval = 15
    private let nativeNotificationMaxCooldown: TimeInterval = 300

    var tabTitleProvider: ((TabTarget) -> String?)?

    /// Rate limiter — prevents notification spam from burst events
    let rateLimiter = NotificationRateLimiter()
    /// Audit trail of fired (and rate-limited) notifications
    let history = NotificationHistory()

    /// Injectable check: returns true if the given target's tab is currently selected.
    var activeTabChecker: ((TabTarget) -> Bool)?

    // MARK: - Focus/DND State (push-based)

    private var isFocusModeActive = false
    private var focusRefreshTimer: Timer?

    // MARK: - Notification coalescing

    private let coalescingWindow: TimeInterval = MonitoringSchedule.defaultCoalescingWindow
    private var pendingNotifications: [String: AIEvent] = [:]
    private var pendingNotificationOrder: [String] = []
    private var pendingNotificationFlushWorkItem: DispatchWorkItem?

    private init() {
        startFocusRefreshTimer()
    }

    func updateAuthorizationStatus(_ status: UNAuthorizationStatus) {
        cachedAuthorizationStatus = status
        hasCachedAuthorization = true
        switch status {
        case .authorized, .provisional, .ephemeral:
            resetNativeNotificationState()
            useNativeNotifications = true
        case .denied:
            resetNativeNotificationState()
            useNativeNotifications = false
        case .notDetermined:
            resetNativeNotificationState()
        @unknown default:
            break
        }
    }

    // MARK: - Entry Point

    /// Notify for an event. Safe to call from any thread.
    nonisolated func notify(for event: AIEvent) {
        guard Bundle.main.bundleIdentifier != nil else {
            Log.info("Skipping notification (not running as bundle): type=\(event.type) tool=\(event.tool)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.enqueueEvent(event)
        }
    }

    private func enqueueEvent(_ event: AIEvent) {
        let key = MonitoringSchedule.notificationCoalescingKey(for: event)
        let isNewKey = pendingNotifications[key] == nil
        pendingNotifications[key] = event

        if isNewKey {
            pendingNotificationOrder.append(key)
        }

        if pendingNotificationFlushWorkItem != nil {
            return
        }

        let workItem = DispatchWorkItem { [weak self] in
            self?.flushPendingNotifications()
        }
        pendingNotificationFlushWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + coalescingWindow, execute: workItem)
    }

    private func flushPendingNotifications() {
        let events = pendingNotificationOrder.compactMap { key in
            pendingNotifications.removeValue(forKey: key)
        }
        pendingNotificationOrder.removeAll(keepingCapacity: true)
        pendingNotificationFlushWorkItem = nil

        for event in events {
            processEvent(event)
        }
    }

    /// All processing on main actor — delegates decision to pure pipeline, then executes.
    private func processEvent(_ event: AIEvent) {
        let ns = FeatureSettings.shared.notificationSettings
        let input = NotificationPipeline.Input(
            event: event,
            triggerState: ns.triggerState,
            triggerConditions: ns.triggerConditions,
            actionBindings: ns.triggerActionBindings,
            groupConditions: ns.groupConditions,
            groupActionBindings: ns.groupActionBindings,
            isFocusModeActive: isFocusModeActive,
            isAppActive: NSApp.isActive,
            isToolTabActive: activeTabChecker?(event.tabTarget) ?? false
        )

        let decision = NotificationPipeline.evaluate(input)

        switch decision {
        case .drop(let reason):
            Log.trace("Notification dropped: \(reason) (type=\(event.type) tool=\(event.tool))")

        case .fireDefault(let triggerId):
            let rateLimitKey = triggerId ?? "unmatched.\(event.source.rawValue)"
            guard rateLimiter.checkAndConsume(triggerId: rateLimitKey) else {
                Log.info("Rate limited: \(rateLimitKey) for tool=\(event.tool)")
                history.record(event: event, triggerId: rateLimitKey, actionsExecuted: [], wasRateLimited: true)
                return
            }
            showDefaultNotification(for: event)
            history.record(event: event, triggerId: rateLimitKey, actionsExecuted: ["showNotification"], wasRateLimited: false)

        case .fireActions(let triggerId, let actions):
            guard rateLimiter.checkAndConsume(triggerId: triggerId) else {
                Log.info("Rate limited: \(triggerId) for tool=\(event.tool)")
                history.record(event: event, triggerId: triggerId, actionsExecuted: [], wasRateLimited: true)
                return
            }
            NotificationActionExecutor.shared.execute(actions: actions, for: event)
            history.record(
                event: event,
                triggerId: triggerId,
                actionsExecuted: actions.filter(\.enabled).map(\.actionType.rawValue),
                wasRateLimited: false
            )
        }
    }

    // MARK: - Notification Dispatch

    private func showDefaultNotification(for event: AIEvent) {
        if shouldUseNativeNotifications() {
            tryNativeNotification(for: event)
        } else {
            let title = event.notificationTitle(toolOverride: tabTitleProvider?(event.tabTarget))
            sendAppleScriptNotification(title: title, body: event.notificationBody)
        }
    }

    private func tryNativeNotification(for event: AIEvent) {
        guard shouldUseNativeNotifications() else {
            let title = event.notificationTitle(toolOverride: tabTitleProvider?(event.tabTarget))
            sendAppleScriptNotification(title: title, body: event.notificationBody)
            return
        }

        guard hasCachedAuthorization else {
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { [weak self] settings in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.cachedAuthorizationStatus = settings.authorizationStatus
                    self.hasCachedAuthorization = true
                    self.handleAuthorizationResult(settings.authorizationStatus, for: event)
                }
            }
            return
        }

        handleAuthorizationResult(cachedAuthorizationStatus, for: event)
    }

    private func handleAuthorizationResult(_ status: UNAuthorizationStatus, for event: AIEvent) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            resetNativeNotificationState()
            scheduleNativeNotification(for: event)
        case .denied:
            logAuthorizationOnce(status: .denied, message: "Native notifications denied, using AppleScript fallback")
            useNativeNotifications = false
            let title = event.notificationTitle(toolOverride: tabTitleProvider?(event.tabTarget))
            sendAppleScriptNotification(title: title, body: event.notificationBody)
        case .notDetermined:
            logAuthorizationOnce(status: .notDetermined, message: "Notification permission not determined, using AppleScript fallback")
            let title = event.notificationTitle(toolOverride: tabTitleProvider?(event.tabTarget))
            sendAppleScriptNotification(title: title, body: event.notificationBody)
        @unknown default:
            Log.warn("Unknown notification authorization status, trying AppleScript")
            let title = event.notificationTitle(toolOverride: tabTitleProvider?(event.tabTarget))
            sendAppleScriptNotification(title: title, body: event.notificationBody)
        }
    }

    private func scheduleNativeNotification(for event: AIEvent) {
        Log.info("Scheduling notification: type=\(event.type) tool=\(event.tool)")

        let content = UNMutableNotificationContent()
        content.title = event.notificationTitle(toolOverride: tabTitleProvider?(event.tabTarget))
        content.body = event.notificationBody
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        let center = UNUserNotificationCenter.current()
        center.add(request) { [weak self] error in
            guard let error else {
                Log.info("Native notification scheduled successfully.")
                return
            }
            DispatchQueue.main.async {
                self?.handleNativeNotificationError(error, for: event)
            }
        }
    }

    private func handleNativeNotificationError(_ error: Error, for event: AIEvent) {
        nativeNotificationFailureCount += 1
        nativeNotificationErrorCooldownUntil = Date().addingTimeInterval(nextNativeCooldown())
        let cooldown = Int(nativeNotificationErrorCooldownUntil!.timeIntervalSinceNow.rounded(.up))
        if !didLogNativeError {
            Log.error("Native notification error: \(error.localizedDescription)")
            didLogNativeError = true
        } else {
            Log.warn("Native notification error: \(error.localizedDescription) (failure #\(nativeNotificationFailureCount), cooldown=\(cooldown)s)")
        }
        let source = tabTitleProvider?(event.tabTarget) ?? event.tool
        Log.warn("Temporarily disabling native notifications for \(source) events for \(cooldown)s to allow retry.")
        let title = event.notificationTitle(toolOverride: tabTitleProvider?(event.tabTarget))
        sendAppleScriptNotification(title: title, body: event.notificationBody)
    }

    private func shouldUseNativeNotifications() -> Bool {
        if !useNativeNotifications {
            return false
        }

        guard let until = nativeNotificationErrorCooldownUntil else { return true }

        if until <= Date() {
            nativeNotificationErrorCooldownUntil = nil
            didLogNativeError = false
            return true
        }
        return false
    }

    private func nextNativeCooldown() -> TimeInterval {
        let failureExponent = min(max(0, nativeNotificationFailureCount), 5)
        let backoff = nativeNotificationBaseCooldown * pow(2.0, Double(failureExponent))
        return min(backoff, nativeNotificationMaxCooldown)
    }

    private func resetNativeNotificationState() {
        nativeNotificationFailureCount = 0
        nativeNotificationErrorCooldownUntil = nil
        didLogNativeError = false
    }

    private func logAuthorizationOnce(status: UNAuthorizationStatus, message: String) {
        guard !loggedAuthorizationStatuses.contains(status) else { return }
        loggedAuthorizationStatuses.insert(status)
        Log.info(message)
    }

    /// Send notification via AppleScript (works without code signing)
    private func sendAppleScriptNotification(title: String, body: String) {
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

    // MARK: - Focus/DND Detection (timer-based, push model)

    private func startFocusRefreshTimer() {
        // Refresh every 30 seconds — non-blocking, push-based
        focusRefreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            // Timer fires on main run loop, but compiler doesn't model this — dispatch explicitly
            DispatchQueue.main.async {
                self?.refreshFocusState()
            }
        }
        // Also refresh immediately
        refreshFocusState()
    }

    private func refreshFocusState() {
        let screenLocked = isScreenLocked()

        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFocusModeActive = (settings.notificationCenterSetting == .disabled) || screenLocked

                // Periodically re-check native notification authorization to recover from transient errors
                self.updateAuthorizationStatus(settings.authorizationStatus)
            }
        }
    }

    /// Check if the screen is locked via CGSessionCopyCurrentDictionary
    private func isScreenLocked() -> Bool {
        guard let sessionInfo = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return sessionInfo["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
