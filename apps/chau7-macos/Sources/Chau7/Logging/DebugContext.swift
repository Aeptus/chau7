import Foundation
import AppKit
import Chau7Core

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

    struct TabState: Codable {
        let id: String
        let title: String
        let customTitle: String?
        let activeAppName: String?
        let status: String
        let effectiveStatus: String
        let currentDirectory: String
        let isGitRepo: Bool
        let gitBranch: String?
        let notificationStyle: String
        let stateAttentionKind: String
        let desiredAttentionKind: String
        let attentionReport: String
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
                let attentionReport = overlay.attentionReport(for: tab)
                tabStates.append(TabState(
                    id: tab.id.uuidString,
                    title: tab.session?.title ?? "(no terminal)",
                    customTitle: tab.customTitle,
                    activeAppName: tab.session?.activeAppName ?? "",
                    status: tab.session?.status.rawValue ?? "unknown",
                    effectiveStatus: tab.displaySession?.effectiveStatus.rawValue
                        ?? tab.session?.effectiveStatus.rawValue
                        ?? "unknown",
                    currentDirectory: tab.session?.currentDirectory ?? "",
                    isGitRepo: tab.session?.isGitRepo ?? false,
                    gitBranch: tab.session?.gitBranch,
                    notificationStyle: attentionReport.styleSummary,
                    stateAttentionKind: attentionReport.ownedKind.rawValue,
                    desiredAttentionKind: attentionReport.desiredKind.rawValue,
                    attentionReport: attentionReport.compactLine
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
            recentLogs: recentLogs
        )
    }

    /// Saves snapshot to file and returns the path
    func save() -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "chau7-snapshot-\(formatter.string(from: timestamp)).json"

        let dir = RuntimeIsolation.chau7Directory()
            .appendingPathComponent("snapshots", isDirectory: true)

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

        let dir = RuntimeIsolation.chau7Directory()
            .appendingPathComponent("reports", isDirectory: true)

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
        Generated: \(DateFormatters.iso8601NoFractional.string(from: Date()))

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
              Last activity: \(DateFormatters.iso8601NoFractional.string(from: session.lastActivity))
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
        let dir = RuntimeIsolation.chau7Directory()
            .appendingPathComponent("reports", isDirectory: true)
        NSWorkspace.shared.open(dir)
    }
}
