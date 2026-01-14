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
                defaultValue: 600.0,
                min: (Self.parseSecondsText(idleSecondsText, defaultValue: 5.0) + 1.0)
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
                defaultValue: 600.0,
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

    @Published var notificationStatus: String = "Unknown"
    @Published var notificationWarning: String? = nil
    @Published var logFilePath: String = ""
    @Published var logLines: [String] = []
    @Published var codexHistoryEntries: [HistoryEntry] = []
    @Published var claudeHistoryEntries: [HistoryEntry] = []
    @Published var codexTerminalLines: [String] = []
    @Published var claudeTerminalLines: [String] = []
    @Published var sessionStatuses: [SessionStatus] = []
    @Published var recentEvents: [AIEvent] = []
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
    private let maxLogLines = 300
    private let maxHistoryEntries = 200
    private let maxTerminalLines = 250
    private let terminalPrefillLines = 200
    private let maxEntryAgeSeconds: TimeInterval = 7 * 24 * 60 * 60  // 7 days
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
        let home = FileManager.default.homeDirectoryForCurrentUser

        // Default paths
        let defaultLogPath = home.appendingPathComponent(".ai-events.log").path
        let defaultCodexHistoryPath = home.appendingPathComponent(".codex/history.jsonl").path
        let defaultClaudeHistoryPath = home.appendingPathComponent(".claude/history.jsonl").path
        let defaultTerminalLogDir = home.appendingPathComponent("Library/Logs/Chau7").path
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
            ?? "600"
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

        logFilePath = Log.filePath
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

    func bootstrap() {
        Log.info("Bootstrapping app model.")
        // Only use UNUserNotificationCenter if running as a proper app bundle
        // This allows running from command line for testing
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            requestNotificationPermission()
            refreshNotificationStatus()
        } else {
            notificationStatus = "Unavailable (Not Bundled)"
            notificationWarning = "Notifications require the app bundle. Build and launch Chau7.app."
            Log.warn("Not running as bundle - notifications disabled.")
        }
        applyMonitoringState()
        applyIdleMonitoringState()
        applyTerminalMonitoringState()
        startClaudeCodeMonitor()
        startAPICallObserver()
        startCleanupTimer()
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
            self.handleAPICallEvent(event)
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
            let codexBefore = self.codexHistoryEntries.count
            self.codexHistoryEntries.removeAll { entry in
                entry.timestamp < cutoffInterval
            }
            let codexRemoved = codexBefore - self.codexHistoryEntries.count

            let claudeBefore = self.claudeHistoryEntries.count
            self.claudeHistoryEntries.removeAll { entry in
                entry.timestamp < cutoffInterval
            }
            let claudeRemoved = claudeBefore - self.claudeHistoryEntries.count

            // Clean old session statuses (stale sessions older than 7 days)
            let sessionsBefore = self.sessionStatuses.count
            self.sessionStatuses.removeAll { status in
                status.lastSeen < cutoff
            }
            let sessionsRemoved = sessionsBefore - self.sessionStatuses.count

            // Clean old events (ts is ISO8601 string)
            let eventsBefore = self.recentEvents.count
            self.recentEvents.removeAll { event in
                guard let date = DateFormatters.iso8601.date(from: event.ts) else { return false }
                return date < cutoff
            }
            let eventsRemoved = eventsBefore - self.recentEvents.count

            let totalRemoved = codexRemoved + claudeRemoved + sessionsRemoved + eventsRemoved
            if totalRemoved > 0 {
                Log.info("Cleanup removed \(totalRemoved) old entries (codex=\(codexRemoved) claude=\(claudeRemoved) sessions=\(sessionsRemoved) events=\(eventsRemoved)).")
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
            notificationStatus = "Unavailable (Not Bundled)"
            notificationWarning = "Notifications require the app bundle. Build and launch Chau7.app."
            Log.warn("Not running as bundle - cannot refresh notification status.")
            return
        }
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] settings in
            let snapshot = NotificationSettingsSnapshot(
                authorizationStatus: settings.authorizationStatus,
                alertSetting: settings.alertSetting,
                soundSetting: settings.soundSetting,
                badgeSetting: settings.badgeSetting,
                alertStyle: settings.alertStyle
            )
            let status: String
            switch settings.authorizationStatus {
            case .authorized:
                status = "Authorized"
            case .denied:
                status = "Denied"
            case .notDetermined:
                status = "Not Determined"
            case .provisional:
                status = "Provisional"
            case .ephemeral:
                status = "Ephemeral"
            @unknown default:
                status = "Unknown"
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.notificationStatus = status
                self.notificationSettingsSnapshot = snapshot
                self.notificationWarning = self.notificationWarningMessage(for: snapshot)
            }
            Log.info("Notification status: \(status)")
            Log.trace("Notification settings: alert=\(settings.alertSetting.rawValue) sound=\(settings.soundSetting.rawValue) badge=\(settings.badgeSetting.rawValue) lock=\(settings.lockScreenSetting.rawValue) center=\(settings.notificationCenterSetting.rawValue) style=\(settings.alertStyle.rawValue)")
        }
    }

    func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else {
            notificationStatus = "Unavailable (Not Bundled)"
            notificationWarning = "Notifications require the app bundle. Build and launch Chau7.app."
            Log.warn("Not running as bundle - skipping permission request.")
            return
        }
        let center = UNUserNotificationCenter.current()
        Log.info("Requesting notification permissions.")
        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error {
                Log.error("Notification permission error: \(error.localizedDescription)")
            } else {
                Log.info("Notification permission granted=\(granted)")
            }
            self.refreshNotificationStatus()
        }
    }

    private func notificationWarningMessage(for snapshot: NotificationSettingsSnapshot) -> String? {
        switch snapshot.authorizationStatus {
        case .notDetermined:
            return "Permission not requested. Click “Request Permission”."
        case .denied:
            return "Notifications are denied. Open System Settings > Notifications > Chau7 and allow alerts."
        case .authorized, .provisional, .ephemeral:
            if snapshot.alertSetting == .disabled || snapshot.alertStyle == .none {
                return "Alerts are off. In System Settings > Notifications > Chau7, choose Banners or Alerts."
            }
            return nil
        @unknown default:
            return "Notification status unknown. Check System Settings > Notifications > Chau7."
        }
    }

    private func notificationPresentationOptions() -> UNNotificationPresentationOptions {
        guard let snapshot = notificationSettingsSnapshot else { return [] }
        var options: UNNotificationPresentationOptions = []
        if snapshot.alertSetting == .enabled && snapshot.alertStyle != .none {
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
            notificationStatus = "Unavailable (Not Bundled)"
            notificationWarning = "Notifications require the app bundle. Build and launch Chau7.app."
            Log.warn("Not running as bundle - skipping test notification.")
            return
        }
        let event = AIEvent(
            source: .app,
            type: "info",
            tool: "Chau7",
            message: "Test notification",
            ts: DateFormatters.nowISO8601()
        )
        NotificationManager.shared.notify(for: event)
    }

    func recordEvent(source: AIEventSource, type: String, tool: String, message: String, notify: Bool) {
        let event = AIEvent(
            source: source,
            type: type,
            tool: tool,
            message: message,
            ts: DateFormatters.nowISO8601()
        )
        Log.info("Recorded event: type=\(type) tool=\(tool) message=\"\(message)\"")
        if notify {
            NotificationManager.shared.notify(for: event)
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recentEvents.append(event)
            self.recentEvents.trimToLast(25)
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
        codexHistoryEntries.removeAll()
        claudeHistoryEntries.removeAll()
        sessionStatuses.removeAll()
        Log.trace("Cleared history streams.")
    }

    func clearTerminalLogs() {
        codexTerminalLines.removeAll()
        claudeTerminalLines.removeAll()
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
            Log.info("Event received: type=\(event.type) tool=\(event.tool) message=\"\(event.message)\"")
            NotificationManager.shared.notify(for: event)
            DispatchQueue.main.async {
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
                staleSecondsProvider: { [weak self] in self?.staleSeconds ?? 600.0 },
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
                staleSecondsProvider: { [weak self] in self?.staleSeconds ?? 600.0 },
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

    // MARK: - Claude Code Integration (Hooks-based)

    private func startClaudeCodeMonitor() {
        let monitor = ClaudeCodeMonitor.shared

        // Set up callbacks (all called on main thread)
        monitor.onEvent = { [weak self] event in
            guard let self else { return }
            self.claudeCodeEvents.append(event)
            self.claudeCodeEvents.trimToLast(50)
        }

        monitor.onSessionIdle = { [weak self] session in
            Log.info("Claude Code session idle: \(session.projectName) (\(session.id.prefix(8)))")
            self?.syncClaudeCodeSessions()
        }

        monitor.onResponseComplete = { [weak self] event in
            Log.info("Claude Code response complete: \(event.projectName)")
            self?.syncClaudeCodeSessions()
        }

        // Start monitoring
        monitor.start()

        // Initial sync
        syncClaudeCodeSessions()

        if ClaudeCodeMonitor.isHookInstalled {
            Log.info("Claude Code monitor started. Hook installed at ~/.chau7/hooks/claude-notify.sh")
        } else {
            Log.warn("Claude Code hook not installed. Run: chmod +x ~/.chau7/hooks/claude-notify.sh")
            Log.info("Then add to ~/.claude/settings.json under 'hooks'")
        }
    }

    private func syncClaudeCodeSessions() {
        let monitor = ClaudeCodeMonitor.shared
        claudeCodeSessions = Array(monitor.activeSessions.values).sorted { $0.lastActivity > $1.lastActivity }
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
        let value = Double(trimmed) ?? 600.0
        return max(idleSeconds + 1.0, value)
    }

    var suspendRenderDelaySeconds: TimeInterval {
        let trimmed = suspendRenderDelayText.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = Double(trimmed) ?? 5.0
        return max(0.0, value)
    }

    private func handleHistoryEntry(_ entry: HistoryEntry, toolName: String) {
        Log.info("History entry: tool=\(toolName) session=\(entry.sessionId) summary=\"\(entry.summary)\"")
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if toolName == "Codex" {
                self.codexHistoryEntries.append(entry)
                self.codexHistoryEntries.trimToLast(self.maxHistoryEntries)
            } else {
                self.claudeHistoryEntries.append(entry)
                self.claudeHistoryEntries.trimToLast(self.maxHistoryEntries)
            }
        }
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
            if let index = self.sessionStatuses.firstIndex(where: { $0.id == statusId }) {
                self.sessionStatuses[index].state = state
                self.sessionStatuses[index].lastSeen = lastSeen
            } else {
                self.sessionStatuses.append(SessionStatus(
                    id: statusId,
                    sessionId: sessionId,
                    tool: toolName,
                    state: state,
                    lastSeen: lastSeen
                ))
            }
        }
    }

    private func notifyIdle(entry: HistoryEntry, idleFor: TimeInterval, toolName: String) {
        let shortSession = String(entry.sessionId.prefix(8))
        let idleSeconds = Int(idleFor.rounded())
        let summary = entry.summary.isEmpty ? "Session idle." : entry.summary
        let message = "No new history for \(idleSeconds)s (session \(shortSession)). \(summary)"

        Log.info("Idle detected for \(toolName) session=\(shortSession) idleFor=\(idleSeconds)s")

        let event = AIEvent(
            source: .historyMonitor,
            type: "idle",
            tool: toolName,
            message: message,
            ts: DateFormatters.nowISO8601()
        )

        NotificationManager.shared.notify(for: event)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.recentEvents.append(event)
            self.recentEvents.trimToLast(25)
        }
    }

    private func appendTerminalLine(_ line: String, toolName: String) {
        let trimmedNewlines = line.trimmingCharacters(in: .newlines)
        if trimmedNewlines.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if toolName == "Codex" {
                self.codexTerminalLines.append(trimmedNewlines)
                self.codexTerminalLines.trimToLast(self.maxTerminalLines)
            } else {
                self.claudeTerminalLines.append(trimmedNewlines)
                self.claudeTerminalLines.trimToLast(self.maxTerminalLines)
            }
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
