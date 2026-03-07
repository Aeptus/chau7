import Foundation
import AppKit

// MARK: - Debug Context

/// Provides structured debugging context for tracing operations across the app.
/// Each operation gets a unique correlation ID that flows through all related log entries.
///
/// Usage:
/// ```
/// let ctx = DebugContext(operation: "command-detection", metadata: ["input": commandLine])
/// ctx.log("Starting detection")
/// ctx.log("Found token", metadata: ["token": token])
/// ctx.complete(success: true, metadata: ["result": appName])
/// ```
final class DebugContext: @unchecked Sendable {
    let id: String
    let operation: String
    let startTime: Date
    private(set) var metadata: [String: Any]
    private var events: [(timestamp: Date, message: String, metadata: [String: Any])]
    private let lock = NSLock()

    /// All active contexts for inspection
    private static var activeContexts: [String: DebugContext] = [:]
    private static let contextLock = NSLock()

    /// History of completed contexts (limited to last 100)
    private static var completedContexts: [DebugContext] = []
    private static let maxHistory = 100

    init(operation: String, metadata: [String: Any] = [:]) {
        self.id = Self.generateId()
        self.operation = operation
        self.startTime = Date()
        self.metadata = metadata
        self.events = []

        Self.contextLock.lock()
        Self.activeContexts[id] = self
        Self.contextLock.unlock()

        Log.trace("[\(id)] START \(operation) \(Self.formatMetadata(metadata))")
    }

    /// Logs an event within this context
    func log(_ message: String, metadata: [String: Any] = [:], level: LogLevel = .trace) {
        lock.lock()
        events.append((Date(), message, metadata))
        lock.unlock()

        let metaStr = metadata.isEmpty ? "" : " \(Self.formatMetadata(metadata))"
        let logMessage = "[\(id)] \(message)\(metaStr)"

        switch level {
        case .trace:
            Log.trace(logMessage)
        case .info:
            Log.info(logMessage)
        case .warn:
            Log.warn(logMessage)
        case .error:
            Log.error(logMessage)
        }
    }

    /// Marks this context as complete
    func complete(success: Bool, metadata: [String: Any] = [:]) {
        let duration = Date().timeIntervalSince(startTime)
        let status = success ? "SUCCESS" : "FAILURE"

        lock.lock()
        self.metadata.merge(metadata) { _, new in new }
        self.metadata["_duration_ms"] = Int(duration * 1000)
        self.metadata["_success"] = success
        lock.unlock()

        Log.trace("[\(id)] END \(operation) \(status) (\(Int(duration * 1000))ms) \(Self.formatMetadata(metadata))")

        Self.contextLock.lock()
        Self.activeContexts.removeValue(forKey: id)
        Self.completedContexts.append(self)
        if Self.completedContexts.count > Self.maxHistory {
            Self.completedContexts.removeFirst()
        }
        Self.contextLock.unlock()
    }

    /// Creates a child context for nested operations
    func child(operation: String, metadata: [String: Any] = [:]) -> DebugContext {
        var childMeta = metadata
        childMeta["_parent"] = id
        return DebugContext(operation: "\(self.operation)/\(operation)", metadata: childMeta)
    }

    // MARK: - Static Accessors

    static var active: [DebugContext] {
        contextLock.lock()
        defer { contextLock.unlock() }
        return Array(activeContexts.values)
    }

    static var history: [DebugContext] {
        contextLock.lock()
        defer { contextLock.unlock() }
        return completedContexts
    }

    static func find(id: String) -> DebugContext? {
        contextLock.lock()
        defer { contextLock.unlock() }
        return activeContexts[id] ?? completedContexts.first { $0.id == id }
    }

    // MARK: - Helpers

    private static func generateId() -> String {
        let chars = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789"
        return String((0 ..< 6).map { _ in chars.randomElement()! })
    }

    private static func formatMetadata(_ meta: [String: Any]) -> String {
        guard !meta.isEmpty else { return "" }
        let pairs = meta.map { "\($0.key)=\(String(describing: $0.value))" }
        return "{\(pairs.joined(separator: ", "))}"
    }

    enum LogLevel {
        case trace, info, warn, error
    }
}

// MARK: - State Snapshot

/// Captures a snapshot of the entire app state for debugging.
/// Used for crash reports, bug reports, and state inspection.
struct StateSnapshot: Codable {
    let timestamp: Date
    let appVersion: String
    let osVersion: String

    // Session state
    let tabCount: Int
    let activeTabIndex: Int
    let tabStates: [TabState]

    // Claude Code state
    let claudeSessions: [ClaudeSessionState]
    let recentEvents: [EventState]

    /// Feature flags
    let featureFlags: [String: Bool]

    /// Recent log entries
    let recentLogs: [String]

    /// Active debug contexts
    let activeContexts: [ContextState]

    struct TabState: Codable {
        let id: String
        let title: String
        let customTitle: String?
        let activeAppName: String?
        let status: String
        let currentDirectory: String
        let isGitRepo: Bool
        let gitBranch: String?
    }

    struct ClaudeSessionState: Codable {
        let id: String
        let projectName: String
        let state: String
        let lastActivity: Date
        let lastToolName: String?
    }

    struct EventState: Codable {
        let timestamp: Date
        let type: String
        let hook: String
        let toolName: String
        let message: String
    }

    struct ContextState: Codable {
        let id: String
        let operation: String
        let startTime: Date
        let durationMs: Int
    }

    /// Creates a snapshot of the current app state
    static func capture(from appModel: AppModel?, overlayModel: OverlayTabsModel?) -> StateSnapshot {
        let processInfo = ProcessInfo.processInfo

        // Capture tab states
        var tabStates: [TabState] = []
        var activeTabIndex = 0
        var tabCount = 0

        if let overlay = overlayModel {
            tabCount = overlay.tabs.count
            activeTabIndex = overlay.tabs.firstIndex { $0.id == overlay.selectedTabID } ?? 0

            for tab in overlay.tabs {
                tabStates.append(TabState(
                    id: tab.id.uuidString,
                    title: tab.session?.title ?? "(no terminal)",
                    customTitle: tab.customTitle,
                    activeAppName: tab.session?.activeAppName ?? "",
                    status: tab.session?.status.rawValue ?? "unknown",
                    currentDirectory: tab.session?.currentDirectory ?? "",
                    isGitRepo: tab.session?.isGitRepo ?? false,
                    gitBranch: tab.session?.gitBranch
                ))
            }
        }

        // Capture Claude sessions
        var claudeSessions: [ClaudeSessionState] = []
        if let model = appModel {
            for session in model.claudeCodeSessions {
                claudeSessions.append(ClaudeSessionState(
                    id: session.id,
                    projectName: session.projectName,
                    state: session.state.rawValue,
                    lastActivity: session.lastActivity,
                    lastToolName: session.lastToolName
                ))
            }
        }

        // Capture recent events
        var recentEvents: [EventState] = []
        if let model = appModel {
            for event in model.claudeCodeEvents.suffix(20) {
                recentEvents.append(EventState(
                    timestamp: event.timestamp,
                    type: event.type.rawValue,
                    hook: event.hook,
                    toolName: event.toolName,
                    message: event.message
                ))
            }
        }

        // Capture feature flags
        let features = FeatureSettings.shared
        let featureFlags: [String: Bool] = [
            "snippets": features.isSnippetsEnabled,
            "repoSnippets": features.isRepoSnippetsEnabled,
            "broadcastMode": features.isBroadcastEnabled,
            "clipboardHistory": features.isClipboardHistoryEnabled,
            "bookmarks": features.isBookmarksEnabled
        ]

        // Capture active contexts
        var contextStates: [ContextState] = []
        for ctx in DebugContext.active {
            contextStates.append(ContextState(
                id: ctx.id,
                operation: ctx.operation,
                startTime: ctx.startTime,
                durationMs: Int(Date().timeIntervalSince(ctx.startTime) * 1000)
            ))
        }

        // Read recent log lines
        var recentLogs: [String] = []
        if let logData = FileOperations.readString(from: Log.filePath) {
            let lines = logData.components(separatedBy: .newlines)
            recentLogs = Array(lines.suffix(50))
        }

        return StateSnapshot(
            timestamp: Date(),
            appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev",
            osVersion: processInfo.operatingSystemVersionString,
            tabCount: tabCount,
            activeTabIndex: activeTabIndex,
            tabStates: tabStates,
            claudeSessions: claudeSessions,
            recentEvents: recentEvents,
            featureFlags: featureFlags,
            recentLogs: recentLogs,
            activeContexts: contextStates
        )
    }

    /// Saves snapshot to file and returns the path
    func save() -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "chau7-snapshot-\(formatter.string(from: timestamp)).json"

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".chau7/snapshots")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent(filename)

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601

            let data = try encoder.encode(self)
            try data.write(to: path)

            Log.info("State snapshot saved to \(path.path)")
            return path.path
        } catch {
            Log.error("Failed to save snapshot: \(error)")
            return nil
        }
    }
}

// MARK: - Bug Reporter

/// Generates bug reports with full context for easy debugging.
final class BugReporter {
    static let shared = BugReporter()
    private init() {}

    private weak var appModel: AppModel?
    private weak var overlayModel: OverlayTabsModel?
    private static let githubIssueOwner = "anthropics"
    private static let githubIssueRepo = "chau7"

    func configure(appModel: AppModel, overlayModel: OverlayTabsModel) {
        self.appModel = appModel
        self.overlayModel = overlayModel
    }

    func prefilledIssueURL(userDescription: String = "") -> URL? {
        let payload = makeReportPayload(userDescription: userDescription)
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(Self.githubIssueOwner)/\(Self.githubIssueRepo)/issues/new"
        components.queryItems = [
            URLQueryItem(name: "title", value: "Bug report from Chau7 \(payload.snapshot.appVersion)"),
            URLQueryItem(name: "body", value: payload.report)
        ]
        return components.url
    }

    /// Generates a bug report and returns the file path
    func generateReport(userDescription: String = "") -> String? {
        let payload = makeReportPayload(userDescription: userDescription)
        let report = payload.report
        let snapshot = payload.snapshot

        // Save report
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "chau7-bug-report-\(formatter.string(from: Date())).md"

        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".chau7/reports")

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent(filename)
            try report.write(to: path, atomically: true, encoding: .utf8)

            // Also save JSON snapshot
            _ = snapshot.save()

            Log.info("Bug report saved to \(path.path)")
            return path.path
        } catch {
            Log.error("Failed to save bug report: \(error)")
            return nil
        }
    }

    private func makeReportPayload(userDescription: String) -> (snapshot: StateSnapshot, report: String) {
        let snapshot = StateSnapshot.capture(from: appModel, overlayModel: overlayModel)
        let bodyDescription = userDescription.isEmpty ? "(No description provided)" : userDescription

        var report = """
        # Chau7 Bug Report
        Generated: \(ISO8601DateFormatter().string(from: Date()))

        ## User Description
        \(bodyDescription)

        ## Environment
        - App Version: \(snapshot.appVersion)
        - OS Version: \(snapshot.osVersion)
        - Tabs: \(snapshot.tabCount) (active: \(snapshot.activeTabIndex))

        ## Tab States
        """

        for (i, tab) in snapshot.tabStates.enumerated() {
            report += """

            ### Tab \(i + 1): \(tab.customTitle ?? tab.title)
            - Active App: \(tab.activeAppName ?? "none")
            - Status: \(tab.status)
            - Directory: \(tab.currentDirectory)
            - Git: \(tab.isGitRepo ? (tab.gitBranch ?? "yes") : "no")
            """
        }

        report += """


        ## Claude Code Sessions
        """

        for session in snapshot.claudeSessions {
            report += """

            - \(session.projectName): \(session.state)
              Last activity: \(ISO8601DateFormatter().string(from: session.lastActivity))
              Last tool: \(session.lastToolName ?? "none")
            """
        }

        report += """


        ## Recent Events (last 20)
        """

        for event in snapshot.recentEvents {
            report += "\n- [\(event.type)] \(event.toolName.isEmpty ? event.hook : event.toolName): \(event.message)"
        }

        report += """


        ## Active Debug Contexts
        """

        for ctx in snapshot.activeContexts {
            report += "\n- [\(ctx.id)] \(ctx.operation) (running \(ctx.durationMs)ms)"
        }

        report += """


        ## Feature Flags
        """

        for (flag, enabled) in snapshot.featureFlags.sorted(by: { $0.key < $1.key }) {
            report += "\n- \(flag): \(enabled ? "enabled" : "disabled")"
        }

        report += """


        ## Recent Logs (last 50 lines)
        ```
        \(snapshot.recentLogs.joined(separator: "\n"))
        ```
        """

        return (snapshot, report)
    }

    /// Opens Finder at the reports directory
    func openReportsFolder() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".chau7/reports")
        NSWorkspace.shared.open(dir)
    }
}

// MARK: - Debug Assertions

/// Debug-only assertions that help catch issues during development
enum DebugAssert {
    /// Asserts a condition in debug builds, logs in release
    static func check(_ condition: @autoclosure () -> Bool, _ message: String, file: String = #file, line: Int = #line) {
        #if DEBUG
        if !condition() {
            let location = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
            Log.error("ASSERTION FAILED at \(location): \(message)")
            assertionFailure(message)
        }
        #else
        if !condition() {
            let location = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
            Log.error("Check failed at \(location): \(message)")
        }
        #endif
    }

    /// Marks code that should never be reached
    static func unreachable(_ message: String = "This code should be unreachable", file: String = #file, line: Int = #line) -> Never {
        let location = "\(URL(fileURLWithPath: file).lastPathComponent):\(line)"
        Log.error("UNREACHABLE at \(location): \(message)")
        fatalError(message)
    }
}
