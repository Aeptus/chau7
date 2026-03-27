import Foundation
import AppKit
import UserNotifications
import Chau7Core

struct SessionStatus: Identifiable, Equatable {
    let id: String
    let sessionId: String
    let tool: String
    var state: HistorySessionState
    var lastSeen: Date
}

/// Main application model managing state, monitoring, and notifications.
/// - Note: Thread Safety - @Published properties must be modified on main thread.
///   Use DispatchQueue.main.async when updating state from background callbacks.
final class AppModel: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    enum NotificationPermissionState: String, Codable {
        case unavailableNotBundled
        case unknown
        case notDetermined
        case denied
        case authorized
        case provisional
        case ephemeral

        static func from(_ status: UNAuthorizationStatus) -> NotificationPermissionState {
            switch status {
            case .authorized:
                return .authorized
            case .denied:
                return .denied
            case .notDetermined:
                return .notDetermined
            case .provisional:
                return .provisional
            case .ephemeral:
                return .ephemeral
            @unknown default:
                return .unknown
            }
        }

        var localizedLabel: String {
            switch self {
            case .unavailableNotBundled:
                return L("settings.notifications.permission.state.unavailable", "Unavailable (Not Bundled)")
            case .unknown:
                return L("settings.notifications.permission.state.unknown", "Unknown")
            case .notDetermined:
                return L("settings.notifications.permission.state.notDetermined", "Not Determined")
            case .denied:
                return L("settings.notifications.permission.state.denied", "Denied")
            case .authorized:
                return L("settings.notifications.permission.state.authorized", "Authorized")
            case .provisional:
                return L("settings.notifications.permission.state.provisional", "Provisional")
            case .ephemeral:
                return L("settings.notifications.permission.state.ephemeral", "Ephemeral")
            }
        }

        var isAuthorized: Bool {
            switch self {
            case .authorized, .provisional, .ephemeral:
                return true
            case .unavailableNotBundled, .unknown, .notDetermined, .denied:
                return false
            }
        }

        var showRequestPermissionAction: Bool {
            switch self {
            case .notDetermined:
                return true
            case .unknown, .authorized, .provisional, .ephemeral, .unavailableNotBundled:
                return false
            case .denied:
                return false
            }
        }

        var requiresSystemSettingsAction: Bool {
            switch self {
            case .denied:
                return true
            case .unknown, .notDetermined, .authorized, .provisional, .ephemeral, .unavailableNotBundled:
                return false
            }
        }
    }

    @Published var isMonitoring: Bool {
        didSet {
            UserDefaults.standard.set(isMonitoring, forKey: Keys.isMonitoring)
        }
    }

    @Published var logPath: String {
        didSet {
            UserDefaults.standard.set(logPath, forKey: Keys.logPath)
        }
    }

    @Published var isIdleMonitoring: Bool {
        didSet {
            UserDefaults.standard.set(isIdleMonitoring, forKey: Keys.isIdleMonitoring)
        }
    }

    @Published var idleSecondsText: String {
        didSet {
            let normalized = Self.normalizeSecondsText(
                idleSecondsText,
                defaultValue: 5.0,
                min: 1.0
            )
            if idleSecondsText != normalized {
                idleSecondsText = normalized
                return
            }
            UserDefaults.standard.set(idleSecondsText, forKey: Keys.idleSeconds)
            let staleNormalized = Self.normalizeSecondsText(
                staleSecondsText,
                defaultValue: 180.0,
                min: Self.parseSecondsText(idleSecondsText, defaultValue: 5.0) + 1.0
            )
            if staleSecondsText != staleNormalized {
                staleSecondsText = staleNormalized
            }
        }
    }

    @Published var staleSecondsText: String {
        didSet {
            let idle = Self.parseSecondsText(idleSecondsText, defaultValue: 5.0)
            let normalized = Self.normalizeSecondsText(
                staleSecondsText,
                defaultValue: 180.0,
                min: idle + 1.0
            )
            if staleSecondsText != normalized {
                staleSecondsText = normalized
                return
            }
            UserDefaults.standard.set(staleSecondsText, forKey: Keys.staleSeconds)
        }
    }

    @Published var isTerminalMonitoring: Bool {
        didSet {
            UserDefaults.standard.set(isTerminalMonitoring, forKey: Keys.isTerminalMonitoring)
        }
    }

    @Published var codexTerminalPath: String {
        didSet {
            UserDefaults.standard.set(codexTerminalPath, forKey: Keys.codexTerminalPath)
        }
    }

    @Published var claudeTerminalPath: String {
        didSet {
            UserDefaults.standard.set(claudeTerminalPath, forKey: Keys.claudeTerminalPath)
        }
    }

    @Published var isTerminalNormalize: Bool {
        didSet {
            UserDefaults.standard.set(isTerminalNormalize, forKey: Keys.isTerminalNormalize)
        }
    }

    @Published var isTerminalAnsi: Bool {
        didSet {
            UserDefaults.standard.set(isTerminalAnsi, forKey: Keys.isTerminalAnsi)
        }
    }

    @Published var isSuspendBackgroundRendering: Bool {
        didSet {
            UserDefaults.standard.set(isSuspendBackgroundRendering, forKey: Keys.isSuspendBackgroundRendering)
        }
    }

    @Published var suspendRenderDelayText: String {
        didSet {
            let normalized = Self.normalizeSecondsText(
                suspendRenderDelayText,
                defaultValue: 5.0,
                min: 0.0
            )
            if suspendRenderDelayText != normalized {
                suspendRenderDelayText = normalized
                return
            }
            UserDefaults.standard.set(suspendRenderDelayText, forKey: Keys.suspendRenderDelaySeconds)
        }
    }

    @Published var codexHistoryPath: String {
        didSet {
            UserDefaults.standard.set(codexHistoryPath, forKey: Keys.codexHistoryPath)
        }
    }

    @Published var claudeHistoryPath: String {
        didSet {
            UserDefaults.standard.set(claudeHistoryPath, forKey: Keys.claudeHistoryPath)
        }
    }

    @Published var notificationStatus = "Unknown"
    @Published var notificationPermissionState: NotificationPermissionState = .unknown
    @Published var notificationWarning: String?
    @Published var logFilePath = ""
    @Published var logLines: [String] = []
    @Published var toolHistoryEntries: [String: [HistoryEntry]] = [:]
    @Published var toolTerminalLines: [String: [String]] = [:]
    @Published var sessionStatuses: [SessionStatus] = []
    /// Tracks when each session last emitted a "finished" notification
    /// via the active→idle bridge. 30-second cooldown prevents rapid re-firing.
    private var sessionFinishedTimestamps: [String: Date] = [:]

    /// Backward-compat computed accessors for MainPanelView / LogsSettingsView
    var codexHistoryEntries: [HistoryEntry] {
        toolHistoryEntries["codex"] ?? []
    }

    var claudeHistoryEntries: [HistoryEntry] {
        toolHistoryEntries["claude"] ?? []
    }

    var codexTerminalLines: [String] {
        toolTerminalLines["codex"] ?? []
    }

    var claudeTerminalLines: [String] {
        toolTerminalLines["claude"] ?? []
    }

    func latestSessionStatus(toolName: String, sessionId: String) -> SessionStatus? {
        let trimmedTool = toolName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSessionId = sessionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTool.isEmpty, !trimmedSessionId.isEmpty else { return nil }

        return sessionStatuses
            .filter {
                $0.sessionId == trimmedSessionId &&
                    $0.tool.caseInsensitiveCompare(trimmedTool) == .orderedSame
            }
            .max(by: { $0.lastSeen < $1.lastSeen })
    }

    /// Returns the configured terminal log path for a given tool name, or nil if none.
    func terminalLogPath(forToolName toolName: String) -> String? {
        let key = AIToolRegistry.resumeProviderKey(for: toolName) ?? toolName.lowercased()
        switch key {
        case "codex":
            let path = codexTerminalPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        case "claude":
            let path = claudeTerminalPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? nil : path
        default:
            return nil
        }
    }

    /// Tool-agnostic event stream from ALL monitors (file tailer, terminal, API proxy, hooks, etc.).
    /// This is the canonical event feed for cross-tool UI — command center timeline, notifications, etc.
    @Published var recentEvents: [AIEvent] = []
    /// Claude Code hook-specific events. Only use for Claude Code-specific UI (e.g. hook debugging).
    /// For cross-tool UI, use `recentEvents` instead — see AIEvent.swift header for rationale.
    @Published var claudeCodeEvents: [ClaudeCodeEvent] = []
    @Published var claudeCodeSessions: [ClaudeCodeMonitor.ClaudeSessionInfo] = []
    @Published var apiCallEvents: [APICallEvent] = []
    @Published var apiCallStats: APICallStats?

    private var tailer: FileTailer<AIEvent>?
    private var apiCallObserver: Any?
    private var idleMonitors: [HistoryIdleMonitor] = []
    private var codexTerminalTailer: FileTailer<String>?
    private var claudeTerminalTailer: FileTailer<String>?
    private var cleanupTimer: DispatchSourceTimer?
    private var appEventEmitter: AppEventEmitter?
    private let maxLogLines = 300
    private let maxHistoryEntries = 200
    private let maxTerminalLines = 250
    private let terminalPrefillLines = 200
    private let maxEntryAgeSeconds: TimeInterval = 7 * 24 * 60 * 60 // 7 days
    private var notificationSettingsSnapshot: NotificationSettingsSnapshot?

    private struct NotificationSettingsSnapshot {
        let authorizationStatus: UNAuthorizationStatus
        let alertSetting: UNNotificationSetting
        let soundSetting: UNNotificationSetting
        let badgeSetting: UNNotificationSetting
        let alertStyle: UNAlertStyle
    }

    private static func normalizeSecondsText(_ text: String, defaultValue: Double, min: Double) -> String {
        let value = parseSecondsText(text, defaultValue: defaultValue)
        let clamped = max(min, value)
        return formatSecondsText(clamped)
    }

    private static func parseSecondsText(_ text: String, defaultValue: Double) -> Double {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = Double(trimmed) {
            return value
        }
        return defaultValue
    }

    private static func formatSecondsText(_ value: Double) -> String {
        if value.rounded(.towardZero) == value {
            return String(Int(value))
        }
        return String(value)
    }

    private enum Keys {
        static let isMonitoring = "isMonitoring"
        static let logPath = "logPath"
        static let isIdleMonitoring = "isIdleMonitoring"
        static let idleSeconds = "idleSeconds"
        static let staleSeconds = "staleSeconds"
        static let isTerminalMonitoring = "isTerminalMonitoring"
        static let codexTerminalPath = "codexTerminalPath"
        static let claudeTerminalPath = "claudeTerminalPath"
        static let isTerminalNormalize = "isTerminalNormalize"
        static let isTerminalAnsi = "isTerminalAnsi"
        static let isSuspendBackgroundRendering = "isSuspendBackgroundRendering"
        static let suspendRenderDelaySeconds = "suspendRenderDelaySeconds"
        static let codexHistoryPath = "codexHistoryPath"
        static let claudeHistoryPath = "claudeHistoryPath"
    }

    override init() {
        Log.configure()
        let defaults = UserDefaults.standard
        let home = RuntimeIsolation.homeDirectory()

        // Default paths
        let defaultLogPath = home.appendingPathComponent(".ai-events.log").path
        let defaultCodexHistoryPath = home.appendingPathComponent(".codex/history.jsonl").path
        let defaultClaudeHistoryPath = home.appendingPathComponent(".claude/history.jsonl").path
        let defaultTerminalLogDir = RuntimeIsolation.logsDirectory()
            .appendingPathComponent("Chau7", isDirectory: true).path
        let defaultCodexTerminalPath = "\(defaultTerminalLogDir)/codex-pty.log"
        let defaultClaudeTerminalPath = "\(defaultTerminalLogDir)/claude-pty.log"

        // Environment variables (with legacy fallbacks)
        let envLogPath = EnvVars.get(EnvVars.eventsLog, legacy: EnvVars.legacyEventsLog)
        let envCodexHistoryPath = EnvVars.get(EnvVars.codexHistoryLog, legacy: EnvVars.legacyCodexHistoryLog)
        let envClaudeHistoryPath = EnvVars.get(EnvVars.claudeHistoryLog, legacy: EnvVars.legacyClaudeHistoryLog)
        let envStaleSeconds = EnvVars.get(EnvVars.idleStaleSeconds, legacy: EnvVars.legacyStaleSeconds)
        let envCodexTerminalPath = EnvVars.get(EnvVars.codexTerminalLog, legacy: EnvVars.legacyCodexTerminalLog)
        let envClaudeTerminalPath = EnvVars.get(EnvVars.claudeTerminalLog, legacy: EnvVars.legacyClaudeTerminalLog)
        let envTerminalNormalize = EnvVars.get(EnvVars.terminalNormalize, legacy: EnvVars.legacyTerminalNormalize)
        let envTerminalAnsi = EnvVars.get(EnvVars.terminalAnsi, legacy: EnvVars.legacyTerminalAnsi)

        let storedLogPath = defaults.string(forKey: Keys.logPath)

        self.isMonitoring = defaults.object(forKey: Keys.isMonitoring) as? Bool ?? true
        self.logPath = envLogPath ?? storedLogPath ?? defaultLogPath

        self.isIdleMonitoring = defaults.object(forKey: Keys.isIdleMonitoring) as? Bool ?? true
        self.idleSecondsText = defaults.string(forKey: Keys.idleSeconds) ?? "5"
        self.staleSecondsText = envStaleSeconds
            ?? defaults.string(forKey: Keys.staleSeconds)
            ?? "180"
        self.isTerminalMonitoring = defaults.object(forKey: Keys.isTerminalMonitoring) as? Bool ?? true
        self.codexTerminalPath = envCodexTerminalPath
            ?? defaults.string(forKey: Keys.codexTerminalPath)
            ?? defaultCodexTerminalPath
        self.claudeTerminalPath = envClaudeTerminalPath
            ?? defaults.string(forKey: Keys.claudeTerminalPath)
            ?? defaultClaudeTerminalPath
        if let envTerminalNormalize {
            self.isTerminalNormalize = envTerminalNormalize != "0"
        } else {
            self.isTerminalNormalize = defaults.object(forKey: Keys.isTerminalNormalize) as? Bool ?? true
        }
        if let envTerminalAnsi {
            self.isTerminalAnsi = envTerminalAnsi != "0"
        } else {
            self.isTerminalAnsi = defaults.object(forKey: Keys.isTerminalAnsi) as? Bool ?? true
        }
        self.isSuspendBackgroundRendering = defaults.object(forKey: Keys.isSuspendBackgroundRendering) as? Bool ?? false
        self.suspendRenderDelayText = defaults.string(forKey: Keys.suspendRenderDelaySeconds) ?? "5"
        self.codexHistoryPath = envCodexHistoryPath
            ?? defaults.string(forKey: Keys.codexHistoryPath)
            ?? defaultCodexHistoryPath
        self.claudeHistoryPath = envClaudeHistoryPath
            ?? defaults.string(forKey: Keys.claudeHistoryPath)
            ?? defaultClaudeHistoryPath

        super.init()

        self.logFilePath = Log.filePath
        Log.sink = { [weak self] line in
            DispatchQueue.main.async {
                guard let self else { return }
                self.logLines.append(line)
                self.logLines.trimToLast(self.maxLogLines)
            }
        }

        Log.info("Initialized. monitoring=\(isMonitoring) logPath=\(logPath)")
        Log.info("Idle monitoring=\(isIdleMonitoring) idleSeconds=\(idleSecondsText) staleSeconds=\(staleSecondsText)")
        Log.info("Terminal monitoring=\(isTerminalMonitoring) normalize=\(isTerminalNormalize)")
        Log.info("Terminal ANSI=\(isTerminalAnsi)")
        Log.info("Codex terminal=\(codexTerminalPath)")
        Log.info("Claude terminal=\(claudeTerminalPath)")
        Log.info("Codex history=\(codexHistoryPath)")
        Log.info("Claude history=\(claudeHistoryPath)")
        Log.info("Bundle id=\(Bundle.main.bundleIdentifier ?? "nil")")
        Log.info("Bundle url=\(Bundle.main.bundleURL.path)")
        Log.info("Process=\(ProcessInfo.processInfo.processName)")
        Log.info("Log file=\(logFilePath)")
    }

    deinit {
        Log.warn("AppModel deinit — possible SwiftUI scene recreation (pid=\(ProcessInfo.processInfo.processIdentifier))")
    }

    func bootstrap() {
        Log.info("Bootstrapping app model.")
        if RuntimeIsolation.isIsolatedTestMode() {
            setNotificationState(
                .unavailableNotBundled,
                warning: "Notifications are disabled in isolated test mode."
            )
            Log.info("Isolated test mode - notifications disabled.")
        }
        // Only use UNUserNotificationCenter if running as a proper app bundle
        // This allows running from command line for testing
        if Bundle.main.bundleIdentifier != nil, !RuntimeIsolation.isIsolatedTestMode() {
            UNUserNotificationCenter.current().delegate = self
            requestNotificationPermission()
            refreshNotificationStatus()
        } else if Bundle.main.bundleIdentifier == nil {
            setNotificationState(
                .unavailableNotBundled,
                warning: L("settings.notifications.permission.warning.notBundled", "Notifications require the app bundle. Build and launch Chau7.app.")
            )
            Log.warn("Not running as bundle - notifications disabled.")
        }
        applyMonitoringState()
        applyIdleMonitoringState()
        applyTerminalMonitoringState()
        startClaudeCodeMonitor()
        startAPICallObserver()
        startCleanupTimer()
        RuntimeSessionManager.shared.startCleanupTimer()
        startAppEventEmitter()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            ConflictDetector.shared.configure(appModel: self)
        }
    }

    // MARK: - App Event Emitter

    private func startAppEventEmitter() {
        appEventEmitter = AppEventEmitter(appModel: self)
        Log.info("App event emitter started")
    }

    /// Call when user activity is detected (used by AppEventEmitter for inactivity tracking)
    func recordUserActivity() {
        appEventEmitter?.recordActivity()
    }

    // MARK: - API Call Tracking (from Proxy)

    private func startAPICallObserver() {
        apiCallObserver = NotificationCenter.default.addObserver(
            forName: .apiCallRecorded,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self,
                  let event = notification.userInfo?["event"] as? APICallEvent else { return }
            handleAPICallEvent(event)
        }
        Log.info("API call observer started")
    }

    private func handleAPICallEvent(_ event: APICallEvent) {
        apiCallEvents.append(event)
        apiCallEvents.trimToLast(100)

        // Also create an AIEvent for the unified event stream
        let message = "\(event.provider.displayName) \(event.model): in:\(event.inputTokens) out:\(event.outputTokens) \(event.formattedCost)"
        let aiEvent = AIEvent(
            id: event.id,
            source: .apiProxy,
            type: event.hasError ? "error" : "api_call",
            tool: event.provider.displayName,
            message: message,
            ts: DateFormatters.iso8601.string(from: event.timestamp)
        )
        recentEvents.append(aiEvent)
        recentEvents.trimToLast(25)

        Log.info("API call recorded: \(event.provider.rawValue) \(event.model) $\(String(format: "%.4f", event.costUSD))")
    }

    func refreshAPIStats() async {
        apiCallStats = await ProxyManager.shared.getStats()
    }

    // MARK: - Periodic Cleanup (Memory optimization)

    private func startCleanupTimer() {
        cleanupTimer?.cancel()

        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        // Run cleanup every hour
        timer.schedule(deadline: .now() + 3600, repeating: 3600)
        timer.setEventHandler { [weak self] in
            self?.performCleanup()
        }
        timer.resume()
        cleanupTimer = timer
        Log.info("Started cleanup timer (hourly, 7-day retention).")
    }

    private func performCleanup() {
        let cutoff = Date().addingTimeInterval(-maxEntryAgeSeconds)
        let cutoffInterval = cutoff.timeIntervalSince1970

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }

            // Clean old history entries (timestamp is TimeInterval since 1970)
            var totalHistoryRemoved = 0
            for key in toolHistoryEntries.keys {
                let before = toolHistoryEntries[key]?.count ?? 0
                toolHistoryEntries[key]?.removeAll { $0.timestamp < cutoffInterval }
                totalHistoryRemoved += before - (toolHistoryEntries[key]?.count ?? 0)
            }

            // Clean old session statuses (stale sessions older than 7 days)
            let sessionsBefore = sessionStatuses.count
            sessionStatuses.removeAll { status in
                status.lastSeen < cutoff
            }
            let sessionsRemoved = sessionsBefore - sessionStatuses.count

            // Prune finished-notification timestamps to match surviving sessions
            let activeStatusIds = Set(sessionStatuses.map(\.id))
            sessionFinishedTimestamps = sessionFinishedTimestamps.filter { activeStatusIds.contains($0.key) }

            // Clean old events (ts is ISO8601 string)
            let eventsBefore = recentEvents.count
            recentEvents.removeAll { event in
                guard let date = DateFormatters.iso8601.date(from: event.ts) else { return false }
                return date < cutoff
            }
            let eventsRemoved = eventsBefore - recentEvents.count

            let totalRemoved = totalHistoryRemoved + sessionsRemoved + eventsRemoved
            if totalRemoved > 0 {
                Log.info("Cleanup removed \(totalRemoved) old entries (history=\(totalHistoryRemoved) sessions=\(sessionsRemoved) events=\(eventsRemoved)).")
            }
        }
    }

    func applyMonitoringState() {
        if isMonitoring {
            Log.info("Monitoring enabled. Starting event tailer.")
            startTailer()
        } else {
            Log.info("Monitoring disabled. Stopping event tailer.")
            stopTailer()
        }
    }

    func restartTailer() {
        Log.info("Restarting event tailer.")
        stopTailer()
        if isMonitoring {
            startTailer()
        }
    }

    func applyIdleMonitoringState() {
        if isIdleMonitoring {
            Log.info("Idle monitoring enabled.")
            startIdleMonitors()
        } else {
            Log.info("Idle monitoring disabled.")
            stopIdleMonitors()
        }
    }

    func restartIdleMonitors() {
        Log.info("Restarting idle monitors.")
        stopIdleMonitors()
        if isIdleMonitoring {
            startIdleMonitors()
        }
    }

    func applyTerminalMonitoringState() {
        if isTerminalMonitoring {
            Log.info("Terminal monitoring enabled.")
            startTerminalMonitors()
        } else {
            Log.info("Terminal monitoring disabled.")
            stopTerminalMonitors()
        }
    }

    func restartTerminalMonitors() {
        Log.info("Restarting terminal monitors.")
        stopTerminalMonitors()
        if isTerminalMonitoring {
            startTerminalMonitors()
        }
    }

    func reloadTerminalPrefill() {
        Log.info("Reloading terminal logs (prefill).")
        clearTerminalLogs()
        stopTerminalMonitors()
        if isTerminalMonitoring {
            startTerminalMonitors()
        }
    }

    func refreshNotificationStatus() {
        guard Bundle.main.bundleIdentifier != nil else {
            setNotificationState(
                .unavailableNotBundled,
                warning: L("settings.notifications.permission.warning.notBundled", "Notifications require the app bundle. Build and launch Chau7.app.")
            )
            Log.warn("Not running as bundle - cannot refresh notification status.")
            return
        }
        guard !RuntimeIsolation.isIsolatedTestMode() else {
            setNotificationState(
                .unavailableNotBundled,
                warning: "Notifications are disabled in isolated test mode."
            )
            Log.info("Isolated test mode - skipping notification status refresh.")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            let permissionState = NotificationPermissionState.from(settings.authorizationStatus)
            let snapshot = NotificationSettingsSnapshot(
                authorizationStatus: settings.authorizationStatus,
                alertSetting: settings.alertSetting,
                soundSetting: settings.soundSetting,
                badgeSetting: settings.badgeSetting,
                alertStyle: settings.alertStyle
            )
            DispatchQueue.main.async {
                guard let self else { return }
                NotificationManager.shared.updateAuthorizationStatus(settings.authorizationStatus)
                self.notificationPermissionState = permissionState
                self.notificationStatus = permissionState.localizedLabel
                self.notificationSettingsSnapshot = snapshot
                self.notificationWarning = self.notificationWarning(for: permissionState, snapshot: snapshot)
            }
            Log.info("Notification status: \(permissionState.localizedLabel)")
            Log
                .trace(
                    "Notification settings: alert=\(settings.alertSetting.rawValue) sound=\(settings.soundSetting.rawValue) badge=\(settings.badgeSetting.rawValue) lock=\(settings.lockScreenSetting.rawValue) center=\(settings.notificationCenterSetting.rawValue) style=\(settings.alertStyle.rawValue)"
                )
        }
    }

    /// Request notification permission. Called automatically on first launch (once).
    /// - Parameter force: If true, requests permission even if already requested before.
    func requestNotificationPermission(force: Bool = false) {
        guard Bundle.main.bundleIdentifier != nil else {
            setNotificationState(
                .unavailableNotBundled,
                warning: L("settings.notifications.permission.warning.notBundled", "Notifications require the app bundle. Build and launch Chau7.app.")
            )
            Log.warn("Not running as bundle - skipping permission request.")
            return
        }
        guard !RuntimeIsolation.isIsolatedTestMode() else {
            setNotificationState(
                .unavailableNotBundled,
                warning: "Notifications are disabled in isolated test mode."
            )
            Log.info("Isolated test mode - skipping permission request.")
            return
        }

        // Skip if already requested (unless forced by user)
        if !force, FeatureSettings.shared.hasRequestedNotificationPermission {
            Log.trace("Notification permission already requested, skipping automatic prompt.")
            return
        }

        let center = UNUserNotificationCenter.current()
        Log.info("Requesting notification permissions (force=\(force)).")

        // Mark as requested BEFORE the async callback to prevent duplicate requests
        if Thread.isMainThread {
            FeatureSettings.shared.hasRequestedNotificationPermission = true
        } else {
            DispatchQueue.main.async {
                FeatureSettings.shared.hasRequestedNotificationPermission = true
            }
        }

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error as NSError? {
                // UNErrorCode.notificationsNotAllowed is 1; avoid using UNErrorCode for older SDKs.
                let isNotAllowed = error.domain == UNErrorDomain && error.code == 1
                if isNotAllowed {
                    Log.warn("Notification permission not allowed: \(error.localizedDescription)")
                } else {
                    Log.error("Notification permission error: \(error.localizedDescription)")
                }
            } else {
                Log.info("Notification permission granted=\(granted)")
            }
            self.refreshNotificationStatus()
        }
    }

    /// Reset the notification permission prompt so it shows again on next launch.
    /// Call this if user wants to see the permission dialog again.
    func resetNotificationPermissionPrompt() {
        FeatureSettings.shared.hasRequestedNotificationPermission = false
        Log.info("Notification permission prompt reset - will show on next app launch.")
    }

    private func notificationWarningMessage(for snapshot: NotificationSettingsSnapshot) -> String? {
        switch snapshot.authorizationStatus {
        case .notDetermined:
            return L("settings.notifications.permission.warning.notDetermined", "Permission has not been requested.")
        case .denied:
            return L("settings.notifications.permission.warning.denied", "Notifications are denied. Open System Settings and allow alerts for Chau7.")
        case .authorized, .provisional, .ephemeral:
            if snapshot.alertSetting == .disabled || snapshot.alertStyle == .none {
                return L("settings.notifications.permission.warning.alertsDisabled", "Alerts are disabled for Chau7. Enable banners or alerts in System Settings.")
            }
            return nil
        @unknown default:
            return L("settings.notifications.permission.warning.unknown", "Notification status unknown. Check System Settings > Notifications > Chau7.")
        }
    }

    private func notificationWarning(for state: NotificationPermissionState, snapshot: NotificationSettingsSnapshot?) -> String? {
        if state == .unavailableNotBundled {
            return L("settings.notifications.permission.warning.notBundled", "Notifications require the app bundle. Build and launch Chau7.app.")
        }

        guard let snapshot else {
            return state == .notDetermined
                ? L("settings.notifications.permission.warning.notDetermined", "Permission has not been requested.")
                : (state == .unknown
                    ? L("settings.notifications.permission.warning.unknown", "Notification status unknown. Check System Settings > Notifications > Chau7.")
                    : nil)
        }

        return notificationWarningMessage(for: snapshot)
    }

    private func setNotificationState(_ state: NotificationPermissionState, warning: String? = nil) {
        DispatchQueue.main.async {
            self.notificationPermissionState = state
            self.notificationStatus = state.localizedLabel
            self.notificationWarning = warning
        }
    }

    private func notificationPresentationOptions() -> UNNotificationPresentationOptions {
        guard let snapshot = notificationSettingsSnapshot else { return [] }
        var options: UNNotificationPresentationOptions = []
        if snapshot.alertSetting == .enabled, snapshot.alertStyle != .none {
            options.insert(.banner)
        }
        if snapshot.soundSetting == .enabled {
            options.insert(.sound)
        }
        if snapshot.badgeSetting == .enabled {
            options.insert(.badge)
        }
        return options
    }

    func sendTestNotification() {
        guard Bundle.main.bundleIdentifier != nil else {
            setNotificationState(
                .unavailableNotBundled,
                warning: L("settings.notifications.permission.warning.notBundled", "Notifications require the app bundle. Build and launch Chau7.app.")
            )
            Log.warn("Not running as bundle - skipping test notification.")
            return
        }
        guard notificationPermissionState.isAuthorized else {
            notificationWarning = L("settings.notifications.permission.warning.testRequiresPermission", "Enable notifications first to send test notifications.")
            return
        }
        let event = AIEvent(
            source: .app,
            type: "update_available",
            tool: "Chau7",
            message: "This is a test notification from Chau7.",
            ts: DateFormatters.nowISO8601()
        )
        Task { @MainActor in NotificationManager.shared.notify(for: event) }
    }

    func recordEvent(
        source: AIEventSource,
        type: String,
        tool: String,
        message: String,
        notify: Bool,
        directory: String? = nil,
        tabID: UUID? = nil,
        sessionID: String? = nil
    ) {
        // Sanitize message to remove escape sequences before logging/storing
        let sanitizedMessage = EscapeSequenceSanitizer.sanitizeForLogging(message)
        let event = AIEvent(
            source: source,
            type: type,
            tool: tool,
            message: sanitizedMessage,
            ts: DateFormatters.nowISO8601(),
            directory: directory,
            tabID: tabID,
            sessionID: sessionID
        )
        // Use trace level for high-frequency events, info for important ones
        let isHighFrequency = ["process_started", "process_ended"].contains(type)
        if isHighFrequency {
            Log.trace("Recorded event: type=\(type) tool=\(tool) message=\"\(sanitizedMessage)\"")
        } else {
            Log.info("Recorded event: type=\(type) tool=\(tool) message=\"\(sanitizedMessage)\"")
        }
        DispatchQueue.main.async { [weak self] in
            if notify {
                NotificationManager.shared.notify(for: event)
            }
            guard let self else { return }
            recentEvents.append(event)
            recentEvents.trimToLast(25)
        }
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func revealLogFile() {
        let url = URL(fileURLWithPath: logFilePath).standardizedFileURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func clearLogs() {
        logLines.removeAll()
        Log.trace("Cleared log stream.")
    }

    func clearHistory() {
        toolHistoryEntries.removeAll()
        sessionStatuses.removeAll()
        Log.trace("Cleared history streams.")
    }

    func clearTerminalLogs() {
        toolTerminalLines.removeAll()
        Log.trace("Cleared terminal streams.")
    }

    func revealLogInFinder() {
        let url = URL(fileURLWithPath: logPath).standardizedFileURL
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func startTailer() {
        guard tailer == nil else { return }

        let url = URL(fileURLWithPath: logPath)
        let parent = url.deletingLastPathComponent()
        FileOperations.createDirectory(at: parent)

        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: nil)
            Log.info("Created event log file at \(url.path)")
        }

        tailer = FileTailer<AIEvent>.eventTailer(fileURL: url) { [weak self] event in
            Log.trace("Event received: type=\(event.type) tool=\(event.tool) message=\"\(event.message)\"")
            DispatchQueue.main.async {
                NotificationManager.shared.notify(for: event)
                guard let self else { return }
                self.recentEvents.append(event)
                self.recentEvents.trimToLast(25)
            }
        }
        tailer?.start()
    }

    private func stopTailer() {
        tailer?.stop()
        tailer = nil
    }

    private func startIdleMonitors() {
        stopIdleMonitors()

        var monitors: [HistoryIdleMonitor] = []

        let codexPath = codexHistoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !codexPath.isEmpty {
            Log.info("Starting Codex history monitor at \(codexPath)")
            let monitor = HistoryIdleMonitor(
                fileURL: URL(fileURLWithPath: codexPath),
                idleSecondsProvider: { [weak self] in self?.idleSeconds ?? 5.0 },
                staleSecondsProvider: { [weak self] in self?.staleSeconds ?? 180.0 },
                onEntry: { [weak self] entry in
                    self?.handleHistoryEntry(entry, toolName: "Codex")
                },
                onStateChange: { [weak self] sessionId, state, lastSeen, idleFor in
                    self?.updateSessionStatus(
                        sessionId: sessionId,
                        toolName: "Codex",
                        state: state,
                        lastSeen: lastSeen,
                        idleFor: idleFor
                    )
                },
                onIdle: { [weak self] entry, idleFor in
                    self?.notifyIdle(entry: entry, idleFor: idleFor, toolName: "Codex")
                }
            )
            monitors.append(monitor)
        }

        let claudePath = claudeHistoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !claudePath.isEmpty {
            Log.info("Starting Claude history monitor at \(claudePath)")
            let monitor = HistoryIdleMonitor(
                fileURL: URL(fileURLWithPath: claudePath),
                idleSecondsProvider: { [weak self] in self?.idleSeconds ?? 5.0 },
                staleSecondsProvider: { [weak self] in self?.staleSeconds ?? 180.0 },
                onEntry: { [weak self] entry in
                    self?.handleHistoryEntry(entry, toolName: "Claude")
                },
                onStateChange: { [weak self] sessionId, state, lastSeen, idleFor in
                    self?.updateSessionStatus(
                        sessionId: sessionId,
                        toolName: "Claude",
                        state: state,
                        lastSeen: lastSeen,
                        idleFor: idleFor
                    )
                },
                onIdle: { [weak self] entry, idleFor in
                    self?.notifyIdle(entry: entry, idleFor: idleFor, toolName: "Claude")
                }
            )
            monitors.append(monitor)
        }

        idleMonitors = monitors
        idleMonitors.forEach { $0.start() }
    }

    private func stopIdleMonitors() {
        idleMonitors.forEach { $0.stop() }
        idleMonitors.removeAll()
    }

    private func startTerminalMonitors() {
        stopTerminalMonitors()

        let codexPath = codexTerminalPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !codexPath.isEmpty {
            Log.info("Starting Codex terminal tailer at \(codexPath)")
            let tailer = FileTailer<String>.textTailer(fileURL: URL(fileURLWithPath: codexPath)) { [weak self] line in
                self?.appendTerminalLine(line, toolName: "Codex")
            }
            codexTerminalTailer = tailer
            tailer.start(prefillLines: terminalPrefillLines)
        }

        let claudePath = claudeTerminalPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !claudePath.isEmpty {
            Log.info("Starting Claude terminal tailer at \(claudePath)")
            let tailer = FileTailer<String>.textTailer(fileURL: URL(fileURLWithPath: claudePath)) { [weak self] line in
                self?.appendTerminalLine(line, toolName: "Claude")
            }
            claudeTerminalTailer = tailer
            tailer.start(prefillLines: terminalPrefillLines)
        }
    }

    private func stopTerminalMonitors() {
        codexTerminalTailer?.stop()
        codexTerminalTailer = nil
        claudeTerminalTailer?.stop()
        claudeTerminalTailer = nil
    }

    // MARK: - Claude Code Integration

    private func startClaudeCodeMonitor() {
        let monitor = ClaudeCodeMonitor.shared

        // Set up callbacks (all called on main thread)
        monitor.onEvent = { [weak self] event in
            guard let self else { return }
            claudeCodeEvents.append(event)
            claudeCodeEvents.trimToLast(50)

            // Also feed into the tool-agnostic recentEvents stream so Claude Code
            // events appear in the command center timeline alongside events from
            // other tools (Cursor, Codex, etc.). Without this, only the notification
            // system sees Claude Code events — the timeline would be empty.
            //
            // Use "Claude" as the tool name — NOT event.toolName (which is an
            // internal Claude tool like "Write", "Bash", "Read"). TabResolver
            // matches the tool field against tab branding to resolve which tab
            // the event belongs to. Internal tool names are unmatchable, causing
            // the onlyWhenTabInactive guard to misfire and tab styling to fail.
            let aiEvent = AIEvent(
                source: .claudeCode,
                type: event.type.rawValue,
                tool: "Claude",
                message: event.message,
                ts: DateFormatters.iso8601.string(from: event.timestamp),
                directory: event.cwd.isEmpty ? nil : event.cwd,
                sessionID: event.sessionId.isEmpty ? nil : event.sessionId
            )
            recentEvents.append(aiEvent)
            recentEvents.trimToLast(25)

            // Feed into the notification pipeline so tab styling, system
            // notifications, and all configured actions fire for Claude Code events.
            Task { @MainActor in
                NotificationManager.shared.notify(for: aiEvent)
            }

            // Bridge session IDs from Claude Code hooks to the telemetry system.
            // Hook events carry sessionId + cwd; match to in-progress telemetry runs
            // so content extraction can find the right transcript files on run end.
            if !event.sessionId.isEmpty, !event.cwd.isEmpty {
                TelemetryRecorder.shared.updateSessionID(
                    provider: "claude", cwd: event.cwd, sessionID: event.sessionId
                )
            }

            // Feed events into the agent runtime session manager so runtime sessions
            // can track Claude Code state transitions and journal events for orchestrators.
            RuntimeSessionManager.shared.handleClaudeEvent(event)

            // Keep menu bar / command center session snapshots in sync for every
            // session state transition, especially `sessionEnd` which does not
            // trigger the idle/response-complete callbacks below.
            syncClaudeCodeSessions()
        }

        monitor.onSessionIdle = { [weak self] session in
            Log.info("Claude Code session idle: \(session.projectName) (\(session.id.prefix(8)))")
            self?.syncClaudeCodeSessions()
            // Route idle notification through the unified pipeline (was previously
            // handled by ClaudeCodeMonitor.notifySessionIdle directly)
            self?.recordEvent(
                source: .claudeCode, type: "idle", tool: "Claude",
                message: "Waiting for input in \(session.projectName)",
                notify: true,
                directory: session.cwd.isEmpty ? nil : session.cwd,
                sessionID: session.id
            )
        }

        monitor.onResponseComplete = { [weak self] event in
            Log.info("Claude Code response complete: \(event.projectName)")
            self?.syncClaudeCodeSessions()
        }

        // Start monitoring
        monitor.start()
        CodexSessionResolver.registerWithTabResolver()

        // Register session finders so OverlayTabsModel resolves sessions via the registry
        OverlayTabsModel.registerSessionFinder(forProviderKey: "claude") { directory, referenceDate, claimedSessionIds in
            OverlayTabsModel.findClaudeSessionId(
                forDirectory: directory, referenceDate: referenceDate, claimedSessionIds: claimedSessionIds
            )
        }
        OverlayTabsModel.registerSessionFinder(forProviderKey: "codex") { directory, referenceDate, claimedSessionIds in
            OverlayTabsModel.findCodexSessionId(
                forDirectory: directory, referenceDate: referenceDate, claimedSessionIds: claimedSessionIds
            )
        }

        // Initial sync
        syncClaudeCodeSessions()
    }

    private var pendingSyncWork: DispatchWorkItem?

    /// Coalesced session sync — multiple rapid events within 100ms share a single sync.
    private func syncClaudeCodeSessions() {
        pendingSyncWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let monitor = ClaudeCodeMonitor.shared
            claudeCodeSessions = Array(monitor.activeSessions.values).sorted { $0.lastActivity > $1.lastActivity }
            pendingSyncWork = nil
        }
        pendingSyncWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    /// Get transcript messages for a Claude Code session
    func getClaudeTranscript(sessionId: String, count: Int = 20) -> [ClaudeTranscriptMessage] {
        return ClaudeCodeMonitor.shared.getTranscriptMessages(for: sessionId, count: count)
    }

    private var idleSeconds: TimeInterval {
        let trimmed = idleSecondsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Double(trimmed) ?? 5.0
        return max(1.0, value)
    }

    private var staleSeconds: TimeInterval {
        let trimmed = staleSecondsText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Double(trimmed) ?? 180.0
        return max(idleSeconds + 1.0, value)
    }

    var suspendRenderDelaySeconds: TimeInterval {
        let trimmed = suspendRenderDelayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Double(trimmed) ?? 5.0
        return max(0.0, value)
    }

    private func handleHistoryEntry(_ entry: HistoryEntry, toolName: String) {
        // Sanitize summary to remove escape sequences from logged messages
        let sanitizedSummary = EscapeSequenceSanitizer.sanitizeForLogging(entry.summary)
        Log.info("History entry: tool=\(toolName) session=\(entry.sessionId) summary=\"\(sanitizedSummary)\"")

        let providerKey = AIToolRegistry.resumeProviderKey(for: toolName) ?? toolName.lowercased()

        // Codex-specific telemetry bridge (intentional — CodexSessionResolver manages its own session cache)
        if providerKey == "codex" {
            let referenceDate = Date(timeIntervalSince1970: entry.timestamp)
            if let metadata = CodexSessionResolver.metadata(
                forSessionID: entry.sessionId,
                referenceDate: referenceDate
            ) {
                TelemetryRecorder.shared.updateSessionID(
                    provider: "codex",
                    cwd: metadata.cwd,
                    sessionID: entry.sessionId
                )
            } else {
                Log.trace("Codex history bridge: no session metadata found for session=\(entry.sessionId.prefix(8))")
            }
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var entries = toolHistoryEntries[providerKey] ?? []
            entries.append(entry)
            entries.trimToLast(maxHistoryEntries)
            toolHistoryEntries[providerKey] = entries
        }
    }

    /// Map tool name to AIEventSource for proper trigger matching.
    /// Uses `eventSourceRawValue` from AIToolRegistry to ensure exact rawValue match
    /// with the static constants on `AIEventSource`.
    private func aiEventSource(for toolName: String) -> AIEventSource {
        let lowered = toolName.lowercased()
        if let rawValue = AIToolRegistry.eventSourceRawValue(for: lowered) {
            return AIEventSource(rawValue: rawValue)
        }
        return .historyMonitor
    }

    private func updateSessionStatus(
        sessionId: String,
        toolName: String,
        state: HistorySessionState,
        lastSeen: Date,
        idleFor: TimeInterval?
    ) {
        Log.info("Session state: tool=\(toolName) session=\(sessionId) state=\(state.rawValue)")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let statusId = "\(toolName)-\(sessionId)"
            let previousState: HistorySessionState?
            if let index = sessionStatuses.firstIndex(where: { $0.id == statusId }) {
                previousState = sessionStatuses[index].state
                sessionStatuses[index].state = state
                sessionStatuses[index].lastSeen = lastSeen
            } else {
                previousState = nil
                sessionStatuses.append(SessionStatus(
                    id: statusId,
                    sessionId: sessionId,
                    tool: toolName,
                    state: state,
                    lastSeen: lastSeen
                ))
            }

            // When a session transitions from active → idle/closed, emit a "finished"
            // notification. Guard with a minimum interval (30s) per session to prevent
            // the history monitor's rapid read-cycle (closed→active→idle) from
            // producing repeated notifications for the same session.
            //
            // When a session transitions from active → idle/closed, emit a "finished"
            // notification. The 30s cooldown per session prevents duplicate notifications
            // from the history monitor's rapid read-cycle (closed→active→idle).
            let sessionEnded = state == .idle || state == .closed
            if previousState == .active, sessionEnded {
                let now = Date()
                let lastFired = sessionFinishedTimestamps[statusId]
                let cooldown: TimeInterval = 30
                if lastFired == nil || now.timeIntervalSince(lastFired!) > cooldown {
                    sessionFinishedTimestamps[statusId] = now
                    recordEvent(
                        source: aiEventSource(for: toolName),
                        type: "finished",
                        tool: toolName,
                        message: "\(toolName) session completed",
                        notify: true,
                        sessionID: sessionId
                    )
                }
            }
        }
    }

    private func notifyIdle(entry: HistoryEntry, idleFor: TimeInterval, toolName: String) {
        let shortSession = String(entry.sessionId.prefix(8))
        let idleSeconds = Int(idleFor.rounded())
        let summary = entry.summary.isEmpty ? "Session idle." : entry.summary
        let message = "No new history for \(idleSeconds)s (session \(shortSession)). \(summary)"

        Log.info("Idle detected for \(toolName) session=\(shortSession) idleFor=\(idleSeconds)s")

        // Use tool-specific source for proper trigger matching
        let source = aiEventSource(for: toolName)
        let event = AIEvent(
            source: source,
            type: "idle",
            tool: toolName,
            message: message,
            ts: DateFormatters.nowISO8601(),
            sessionID: entry.sessionId
        )

        DispatchQueue.main.async { [weak self] in
            NotificationManager.shared.notify(for: event)
            guard let self else { return }
            recentEvents.append(event)
            recentEvents.trimToLast(25)
        }
    }

    private func appendTerminalLine(_ line: String, toolName: String) {
        let trimmedNewlines = line.trimmingCharacters(in: .newlines)
        if trimmedNewlines.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        let providerKey = AIToolRegistry.resumeProviderKey(for: toolName) ?? toolName.lowercased()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            var lines = toolTerminalLines[providerKey] ?? []
            lines.append(trimmedNewlines)
            lines.trimToLast(maxTerminalLines)
            toolTerminalLines[providerKey] = lines
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler(notificationPresentationOptions())
    }
}
