import Foundation
import AppKit
import UserNotifications
import Chau7Core

@MainActor
final class NotificationManager {
    static let shared = NotificationManager()
    private let isIsolatedTestMode = RuntimeIsolation.isIsolatedTestMode()

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
    var repoNameProvider: ((TabTarget) -> String?)?

    /// Rate limiter — prevents notification spam from burst events
    let rateLimiter = NotificationRateLimiter()
    /// Audit trail of fired (and rate-limited) notifications
    let history = NotificationHistory()

    /// Injectable check: returns true if the given target's tab is currently selected.
    var activeTabChecker: ((TabTarget) -> Bool)?

    /// Injectable resolver: maps a TabTarget to the owning tab's UUID.
    /// Used to fill in missing tabIDs on events from external sources (e.g. Claude Code hooks).
    /// Wired to `TabResolver.resolve` — gets full 5-tier matching for free.
    var tabResolver: ((TabTarget) -> UUID?)?

    // MARK: - Focus/DND State (push-based)

    private var isFocusModeActive = false
    private var focusRefreshTimer: Timer?

    // MARK: - Notification coalescing

    private let coalescingWindow: TimeInterval = MonitoringSchedule.defaultCoalescingWindow
    private var pendingNotifications: [String: AIEvent] = [:]
    private var pendingNotificationOrder: [String] = []
    private var pendingNotificationFlushWorkItem: DispatchWorkItem?
    private var routingRetryCounts: [UUID: Int] = [:]
    private var recentAuthoritativeEvents: [String: Date] = [:]
    private let authoritativeRetryDelays: [TimeInterval] = [0.05, 0.15, 0.5]

    private init() {
        guard !isIsolatedTestMode else {
            self.useNativeNotifications = false
            return
        }
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
            Log.warn("Unknown UNAuthorizationStatus (\(status.rawValue)) in updateAuthorizationStatus, treating as notDetermined")
            resetNativeNotificationState()
        }
    }

    // MARK: - Entry Point

    /// Notify for an event. Safe to call from any thread.
    nonisolated func notify(for event: AIEvent) {
        guard !RuntimeIsolation.isIsolatedTestMode() else {
            Log.info("Skipping notification in isolated test mode: type=\(event.type) tool=\(event.tool)")
            return
        }
        guard Bundle.main.bundleIdentifier != nil else {
            Log.info("Skipping notification (not running as bundle): type=\(event.type) tool=\(event.tool)")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.history.begin(event: event)
            self?.enqueueEvent(event)
        }
    }

    private func enqueueEvent(_ event: AIEvent) {
        let key = MonitoringSchedule.notificationCoalescingKey(for: event)
        let isNewKey = pendingNotifications[key] == nil
        pendingNotifications[key] = event

        if isNewKey {
            pendingNotificationOrder.append(key)
        } else {
            history.markCoalesced(eventID: event.id, key: key)
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
        pruneAuthoritativeEvents()

        let normalizedEvent: AIEvent
        switch NotificationProviderAdapterRegistry.adapt(event) {
        case .drop(let reason):
            Log.trace("Notification dropped: \(reason) (type=\(event.type) tool=\(event.tool))")
            history.markDropped(eventID: event.id, reason: reason)
            return
        case .passThrough(let adapted):
            normalizedEvent = adapted
        case .emit(let adapted, let canonical):
            normalizedEvent = adapted
            history.markCanonicalized(
                eventID: event.id,
                semanticKind: canonical.kind.rawValue,
                rawType: canonical.rawType,
                notificationType: canonical.notificationType
            )
        }

        let ns = FeatureSettings.shared.notificationSettings
        let preparedEvent: AIEvent
        let resolutionMethod: String
        switch NotificationEventPreparation.prepare(
            normalizedEvent,
            triggerState: ns.triggerState,
            tabResolver: tabResolver
        ) {
        case .drop(let reason):
            Log.trace("Notification dropped: \(reason) (type=\(normalizedEvent.type) tool=\(normalizedEvent.tool))")
            history.markDropped(eventID: event.id, reason: reason)
            return
        case .proceed(let prepared):
            preparedEvent = prepared.event
            resolutionMethod = prepared.resolutionMethod
        }

        history.markPrepared(event: preparedEvent, resolutionMethod: resolutionMethod)

        if NotificationDeliverySemantics.requiresAuthoritativeRouting(preparedEvent),
           preparedEvent.tabID == nil,
           scheduleRoutingRetryIfNeeded(for: preparedEvent) {
            return
        }

        if NotificationDeliverySemantics.shouldSuppressAsFallback(
            preparedEvent,
            authoritativeEvents: recentAuthoritativeEvents
        ) {
            let reason = "Suppressed fallback event shadowed by authoritative delivery"
            Log.trace("Notification dropped: \(reason) (type=\(preparedEvent.type) tool=\(preparedEvent.tool))")
            history.markDropped(eventID: preparedEvent.id, reason: reason)
            return
        }

        registerAuthoritativeEventIfNeeded(preparedEvent)

        let input = NotificationPipeline.Input(
            event: preparedEvent,
            triggerState: ns.triggerState,
            triggerConditions: ns.triggerConditions,
            actionBindings: ns.triggerActionBindings,
            groupConditions: ns.groupConditions,
            groupActionBindings: ns.groupActionBindings,
            isFocusModeActive: isFocusModeActive,
            isAppActive: NSApp.isActive,
            isToolTabActive: activeTabChecker?(preparedEvent.tabTarget) ?? false
        )

        let decision = NotificationPipeline.evaluate(input)

        switch decision {
        case .drop(let reason):
            Log.trace("Notification dropped: \(reason) (type=\(preparedEvent.type) tool=\(preparedEvent.tool))")
            history.markDropped(eventID: preparedEvent.id, reason: reason)
            routingRetryCounts.removeValue(forKey: preparedEvent.id)

        case .fireDefault(let triggerId):
            let baseRateLimitKey = triggerId ?? "unmatched.\(preparedEvent.source.rawValue).\(preparedEvent.tool.lowercased())"
            let rateLimitKey = MonitoringSchedule.notificationRateLimitKey(triggerID: baseRateLimitKey, event: preparedEvent)
            guard rateLimiter.checkAndConsume(triggerId: rateLimitKey) else {
                Log.info("Rate limited: \(rateLimitKey) for tool=\(preparedEvent.tool)")
                history.markRateLimited(eventID: preparedEvent.id, triggerId: baseRateLimitKey)
                routingRetryCounts.removeValue(forKey: preparedEvent.id)
                return
            }
            let didDispatchBanner = showDefaultNotification(for: preparedEvent)
            // Safe to call without re-checking isToolTabActive: processEvent runs
            // entirely on @MainActor, so no tab switch can interleave between the
            // pipeline's active-tab check and this call. The pipeline already
            // dropped events for active tabs before reaching .fireDefault.
            let didStyleTab = applyDefaultTabStyle(for: preparedEvent)
            var actions = ["showNotification"]
            if didStyleTab { actions.append("styleTab") }
            history.markActionsExecuted(
                eventID: preparedEvent.id,
                triggerId: baseRateLimitKey,
                actionsExecuted: actions,
                didDispatchBanner: didDispatchBanner,
                didStyleTab: didStyleTab
            )
            history.markCompleted(eventID: preparedEvent.id)
            routingRetryCounts.removeValue(forKey: preparedEvent.id)

        case .fireStyleOnly(let triggerId, let actions):
            let baseRateLimitKey = triggerId ?? "unmatched.\(preparedEvent.source.rawValue).\(preparedEvent.tool.lowercased())"
            let rateLimitKey = MonitoringSchedule.notificationRateLimitKey(triggerID: baseRateLimitKey, event: preparedEvent)
            guard rateLimiter.checkAndConsume(triggerId: rateLimitKey) else {
                Log.info("Rate limited: \(rateLimitKey) for tool=\(preparedEvent.tool)")
                history.markRateLimited(eventID: preparedEvent.id, triggerId: baseRateLimitKey)
                routingRetryCounts.removeValue(forKey: preparedEvent.id)
                return
            }
            NotificationActionExecutor.shared.execute(actions: actions, for: preparedEvent)
            let actionNames = actions.filter(\.enabled).map(\.actionType.rawValue)
            history.markActionsExecuted(
                eventID: preparedEvent.id,
                triggerId: baseRateLimitKey,
                actionsExecuted: actionNames,
                didDispatchBanner: actionNames.contains(NotificationActionType.showNotification.rawValue),
                didStyleTab: actionNames.contains(NotificationActionType.styleTab.rawValue)
            )
            history.markCompleted(eventID: preparedEvent.id)
            routingRetryCounts.removeValue(forKey: preparedEvent.id)

        case .fireActions(let triggerId, let actions):
            let rateLimitKey = MonitoringSchedule.notificationRateLimitKey(triggerID: triggerId, event: preparedEvent)
            guard rateLimiter.checkAndConsume(triggerId: rateLimitKey) else {
                Log.info("Rate limited: \(triggerId) for tool=\(preparedEvent.tool)")
                history.markRateLimited(eventID: preparedEvent.id, triggerId: triggerId)
                routingRetryCounts.removeValue(forKey: preparedEvent.id)
                return
            }
            NotificationActionExecutor.shared.execute(actions: actions, for: preparedEvent)
            var executedActions = actions.filter(\.enabled).map(\.actionType.rawValue)
            var didStyleTab = executedActions.contains(NotificationActionType.styleTab.rawValue)
            if let supplementalStyleAction = NotificationStylePlanner.supplementalStyleAction(
                for: preparedEvent,
                from: actions
            ) {
                NotificationActionExecutor.shared.execute(actions: [supplementalStyleAction], for: preparedEvent)
                executedActions.append(NotificationActionType.styleTab.rawValue)
                didStyleTab = true
            }
            history.markActionsExecuted(
                eventID: preparedEvent.id,
                triggerId: triggerId,
                actionsExecuted: executedActions,
                didDispatchBanner: executedActions.contains(NotificationActionType.showNotification.rawValue),
                didStyleTab: didStyleTab
            )
            history.markCompleted(eventID: preparedEvent.id)
            routingRetryCounts.removeValue(forKey: preparedEvent.id)
        }
    }

    private func scheduleRoutingRetryIfNeeded(for event: AIEvent) -> Bool {
        let attempts = routingRetryCounts[event.id] ?? 0
        guard attempts < authoritativeRetryDelays.count,
              event.sessionID != nil || event.directory != nil else {
            return false
        }

        let nextAttempt = attempts + 1
        routingRetryCounts[event.id] = nextAttempt
        history.markRetryScheduled(
            eventID: event.id,
            attempt: nextAttempt,
            reason: "authoritative event missing exact tab route"
        )

        let delay = authoritativeRetryDelays[attempts]
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.enqueueEvent(event)
        }
        return true
    }

    private func registerAuthoritativeEventIfNeeded(_ event: AIEvent) {
        guard event.reliability == .authoritative else {
            return
        }
        let now = Date()
        for key in NotificationDeliverySemantics.authorityKeys(for: event) {
            recentAuthoritativeEvents[key] = now
        }
        routingRetryCounts.removeValue(forKey: event.id)
    }

    private func pruneAuthoritativeEvents(now: Date = Date()) {
        recentAuthoritativeEvents = recentAuthoritativeEvents.filter {
            now.timeIntervalSince($0.value) <= NotificationDeliverySemantics.authorityRetentionSeconds
        }
        // Cap routing retry entries: any event that exhausted its retries
        // but was never cleaned up (e.g., dropped before reaching processEvent)
        // will linger. Remove entries that exceeded the max retry count.
        if routingRetryCounts.count > 100 {
            routingRetryCounts = routingRetryCounts.filter { $0.value < authoritativeRetryDelays.count }
        }
    }

    /// Applies a default tab style for attention-worthy events when no explicit
    /// `.styleTab` action is configured. This ensures tab visual feedback works
    /// out-of-the-box without requiring user configuration.
    ///
    /// Routes through `NotificationActionExecutor` (not the delegate directly)
    /// so the executor's auto-clear timer management kicks in — the style
    /// automatically clears after 30 seconds.
    ///
    /// Returns `true` if a style action was dispatched (for audit trail).
    @discardableResult
    private func applyDefaultTabStyle(for event: AIEvent) -> Bool {
        guard let action = NotificationStylePlanner.defaultStyleAction(for: event) else { return false }
        NotificationActionExecutor.shared.execute(actions: [action], for: event)
        return true
    }

    // MARK: - Notification Dispatch

    /// Used by the executor's .showNotification action — routes through the full
    /// authorization check + AppleScript fallback chain so custom-action notifications
    /// get the same reliability as default notifications.
    @discardableResult
    func dispatchActionNotification(title: String, body: String, for event: AIEvent) -> Bool {
        dispatchNotification(title: title, body: body, for: event)
    }

    @discardableResult
    private func showDefaultNotification(for event: AIEvent) -> Bool {
        let tabTitle = tabTitleProvider?(event.tabTarget)
        let repoName = repoNameProvider?(event.tabTarget)
        let title = event.notificationTitle(toolOverride: tabTitle, repoName: repoName)
        return dispatchNotification(title: title, body: event.notificationBody, for: event)
    }

    @discardableResult
    private func dispatchNotification(title: String, body: String, for event: AIEvent) -> Bool {
        guard !isIsolatedTestMode else {
            Log.info("Skipping notification dispatch in isolated test mode: \(title)")
            return false
        }
        if shouldUseNativeNotifications() {
            tryNativeNotification(title: title, body: body, for: event)
            return true
        } else {
            sendAppleScriptNotification(title: title, body: body)
            return true
        }
    }

    private func tryNativeNotification(title: String, body: String, for event: AIEvent) {
        guard shouldUseNativeNotifications() else {
            sendAppleScriptNotification(title: title, body: body)
            return
        }

        guard hasCachedAuthorization else {
            let center = UNUserNotificationCenter.current()
            center.getNotificationSettings { [weak self] settings in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.cachedAuthorizationStatus = settings.authorizationStatus
                    self.hasCachedAuthorization = true
                    self.handleAuthorizationResult(settings.authorizationStatus, title: title, body: body, for: event)
                }
            }
            return
        }

        handleAuthorizationResult(cachedAuthorizationStatus, title: title, body: body, for: event)
    }

    private func handleAuthorizationResult(_ status: UNAuthorizationStatus, title: String, body: String, for event: AIEvent) {
        switch status {
        case .authorized, .provisional, .ephemeral:
            resetNativeNotificationState()
            scheduleNativeNotification(title: title, body: body, for: event)
        case .denied:
            logAuthorizationOnce(status: .denied, message: "Native notifications denied, using AppleScript fallback")
            useNativeNotifications = false
            sendAppleScriptNotification(title: title, body: body)
        case .notDetermined:
            logAuthorizationOnce(status: .notDetermined, message: "Notification permission not determined, using AppleScript fallback")
            sendAppleScriptNotification(title: title, body: body)
        @unknown default:
            Log.warn("Unknown notification authorization status, trying AppleScript")
            sendAppleScriptNotification(title: title, body: body)
        }
    }

    private func scheduleNativeNotification(title: String, body: String, for event: AIEvent) {
        Log.info("Scheduling notification: type=\(event.type) tool=\(event.tool)")

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
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
                self?.handleNativeNotificationError(error, title: title, body: body)
            }
        }
    }

    private func handleNativeNotificationError(_ error: Error, title: String, body: String) {
        nativeNotificationFailureCount += 1
        nativeNotificationErrorCooldownUntil = Date().addingTimeInterval(nextNativeCooldown())
        let cooldown = Int(nativeNotificationErrorCooldownUntil!.timeIntervalSinceNow.rounded(.up))
        if !didLogNativeError {
            Log.error("Native notification error: \(error.localizedDescription)")
            didLogNativeError = true
        } else {
            Log.warn("Native notification error: \(error.localizedDescription) (failure #\(nativeNotificationFailureCount), cooldown=\(cooldown)s)")
        }
        Log.warn("Temporarily disabling native notifications for \(cooldown)s, falling back to AppleScript.")
        sendAppleScriptNotification(title: title, body: body)
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
        guard !isIsolatedTestMode else {
            isFocusModeActive = false
            return
        }
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

    /// Check if the screen is locked via CGSessionCopyCurrentDictionary.
    /// Returns false (conservative) when the API is unavailable.
    private func isScreenLocked() -> Bool {
        guard let sessionInfo = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            Log.trace("CGSessionCopyCurrentDictionary returned nil (sandboxed or API unavailable)")
            return false
        }
        return sessionInfo["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
