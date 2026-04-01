import Foundation
import Chau7Core

/// View model for the bug report dialog.
///
/// Captures a `StateSnapshot` on init and lets the user toggle which sections
/// to include. The `markdownReport` computed property rebuilds in real time
/// as toggles change, powering the live preview in `BugReportDialogView`.
///
/// Privacy-first: all sensitive sections are OFF by default.
final class BugReportDraft: ObservableObject {

    // MARK: - Snapshot (immutable, captured once)

    let snapshot: StateSnapshot
    let currentTabID: UUID?
    let availableTabs: [(id: UUID, label: String)]

    // MARK: - User Input

    @Published var userDescription = ""
    @Published var contactName: String
    @Published var contactHandle: String
    @Published var saveContactInfo: Bool

    // MARK: - Global Toggles

    @Published var includeFeatureFlags = true
    @Published var includeLogs = false
    @Published var includeEvents = false

    // MARK: - Per-Toggle Tab Pickers

    @Published var includeTabMetadata = false
    @Published var metadataTabID: UUID?

    @Published var includeTerminalHistory = false
    @Published var historyTabID: UUID?

    @Published var includeAISession = false

    // MARK: - Cached Tab History

    /// Cached terminal output, populated on toggle-on to avoid I/O in computed property.
    @Published var cachedTerminalHistory: String?

    // MARK: - Submission State

    @Published var isSubmitting = false
    @Published var submitError: String?
    @Published var submitSuccess: Int? // issue number

    // MARK: - Init

    init(snapshot: StateSnapshot, currentTabID: UUID?, overlayModel: OverlayTabsModel?) {
        self.snapshot = snapshot
        self.currentTabID = currentTabID

        // Build tab list for pickers
        var tabs: [(id: UUID, label: String)] = []
        if let overlay = overlayModel {
            for tab in overlay.tabs {
                let label = tab.customTitle ?? tab.session?.title ?? "Tab"
                tabs.append((id: tab.id, label: label))
            }
        }
        self.availableTabs = tabs

        // Default tab pickers to current tab
        self.metadataTabID = currentTabID
        self.historyTabID = currentTabID

        // Pre-fill contact info from settings
        let settings = FeatureSettings.shared
        self.contactName = settings.bugReportContactName
        self.contactHandle = settings.bugReportContactHandle
        self.saveContactInfo = !settings.bugReportContactName.isEmpty || !settings.bugReportContactHandle.isEmpty
    }

    // MARK: - Tab Lookup

    /// The tab ID to use for AI session info: metadata tab if metadata is on, otherwise current tab.
    var aiSessionTabID: UUID? {
        includeTabMetadata ? metadataTabID : currentTabID
    }

    /// Find a snapshot TabState by UUID string.
    private func tabState(for id: UUID?) -> StateSnapshot.TabState? {
        guard let id else { return nil }
        return snapshot.tabStates.first { $0.id == id.uuidString }
    }

    // MARK: - Path Redaction

    /// Replace home directory with ~ and strip username from paths.
    static func redactPath(_ path: String) -> String {
        guard !path.isEmpty else { return path }
        let home = NSHomeDirectory()
        var result = path
        if result.hasPrefix(home) {
            result = "~" + result.dropFirst(home.count)
        }
        return result
    }

    // MARK: - Terminal History Capture

    /// Reads the last N lines of scrollback from a tab via TerminalControlService.
    func captureTabHistory(tabID: UUID, lines: Int = 50) -> String? {
        let result = TerminalControlService.shared.tabOutput(tabID: tabID.uuidString, lines: lines)
        guard let data = result.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? String,
              !output.isEmpty else {
            return nil
        }
        return output
    }

    // MARK: - Markdown Composition

    var markdownReport: String {
        var sections: [String] = []

        // Header — always included
        sections.append("# Chau7 Bug Report\nGenerated: \(ISO8601DateFormatter().string(from: snapshot.timestamp))")

        // Contact info — only if provided
        if !contactName.isEmpty || !contactHandle.isEmpty {
            var contactSection = "## Contact"
            if !contactName.isEmpty { contactSection += "\n- Name: \(contactName)" }
            if !contactHandle.isEmpty { contactSection += "\n- GitHub/Email: \(contactHandle)" }
            sections.append(contactSection)
        }

        // Description — always included
        let desc = userDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        sections.append("## Description\n\(desc.isEmpty ? "(No description provided)" : desc)")

        // Environment — always included, no sensitive data
        sections.append("## Environment\n- App Version: \(snapshot.appVersion)\n- macOS: \(snapshot.osVersion)\n- Tabs: \(snapshot.tabCount)")

        // Feature flags
        if includeFeatureFlags {
            var flagSection = "## Feature Flags"
            for (flag, enabled) in snapshot.featureFlags.sorted(by: { $0.key < $1.key }) {
                flagSection += "\n- \(flag): \(enabled ? "on" : "off")"
            }
            sections.append(flagSection)
        }

        // Tab metadata
        if includeTabMetadata, let tab = tabState(for: metadataTabID) {
            var tabSection = "## Tab: \(tab.customTitle ?? tab.title)"
            tabSection += "\n- Status: \(tab.status)"
            tabSection += "\n- Active App: \(tab.activeAppName ?? "none")"
            tabSection += "\n- Directory: \(Self.redactPath(tab.currentDirectory))"
            if tab.isGitRepo {
                tabSection += "\n- Git Branch: \(tab.gitBranch ?? "unknown")"
            }
            sections.append(tabSection)
        }

        // Terminal history (uses cached value, not live I/O)
        if includeTerminalHistory {
            if let output = cachedTerminalHistory, !output.isEmpty {
                sections.append("## Terminal History\n```\n\(output)\n```")
            } else {
                sections.append("## Terminal History\n(No output captured)")
            }
        }

        // AI session
        if includeAISession, let sessionTabID = aiSessionTabID {
            let tabDir = tabState(for: sessionTabID)?.currentDirectory ?? ""
            let matching = snapshot.claudeSessions.filter { session in
                guard !tabDir.isEmpty else { return false }
                // Compare raw paths: exact match or one is a prefix of the other
                return session.projectName == tabDir
                    || tabDir.hasPrefix(session.projectName)
                    || session.projectName.hasPrefix(tabDir)
            }
            if !matching.isEmpty {
                var aiSection = "## AI Sessions"
                for session in matching {
                    aiSection += "\n- State: \(session.state)"
                    aiSection += " | Project: \(Self.redactPath(session.projectName))"
                    aiSection += " | Last tool: \(session.lastToolName ?? "none")"
                    aiSection += " | Last activity: \(ISO8601DateFormatter().string(from: session.lastActivity))"
                }
                sections.append(aiSection)
            } else if !snapshot.claudeSessions.isEmpty {
                // Fallback: include all sessions if we can't match by tab
                var aiSection = "## AI Sessions"
                for session in snapshot.claudeSessions {
                    aiSection += "\n- Project: \(Self.redactPath(session.projectName))"
                    aiSection += " | State: \(session.state)"
                    aiSection += " | Last tool: \(session.lastToolName ?? "none")"
                }
                sections.append(aiSection)
            }
        }

        // Recent events
        if includeEvents, !snapshot.recentEvents.isEmpty {
            var eventsSection = "## Recent Events (last \(snapshot.recentEvents.count))"
            for event in snapshot.recentEvents {
                let tool = event.toolName.isEmpty ? event.hook : event.toolName
                eventsSection += "\n- [\(event.type)] \(tool): \(event.message)"
            }
            sections.append(eventsSection)
        }

        // Logs
        if includeLogs, !snapshot.recentLogs.isEmpty {
            let filtered = snapshot.recentLogs.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !filtered.isEmpty {
                sections.append("## Recent Logs (last \(filtered.count) lines)\n```\n\(filtered.joined(separator: "\n"))\n```")
            }
        }

        return sections.joined(separator: "\n\n")
    }

    // MARK: - Submission

    /// POST the report to the Cloudflare Worker issue endpoint.
    /// Call `prepareSubmission()` on the main thread first, then pass the result here.
    func submit(preparedReport: String) async throws -> Int {
        let endpoint = FeatureSettings.shared.bugReportIssueEndpoint
        guard let url = URL(string: endpoint), !endpoint.isEmpty else {
            throw BugReportError.invalidEndpoint
        }

        let title = "Bug report from Chau7 \(snapshot.appVersion)"
        let body: [String: Any] = [
            "title": title,
            "body": preparedReport
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = jsonData
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw BugReportError.networkError("Invalid response")
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 201 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            if httpResponse.statusCode == 429 {
                throw BugReportError.rateLimited
            }
            throw BugReportError.serverError(httpResponse.statusCode, body)
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let issueNumber = json["issue_number"] as? Int {
            return issueNumber
        }

        return 0 // success but no issue number returned
    }

    /// Save report locally as a fallback.
    func saveLocally() -> String? {
        let report = markdownReport
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let filename = "chau7-bug-report-\(formatter.string(from: Date())).md"

        let dir = RuntimeIsolation.chau7Directory()
            .appendingPathComponent("reports", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let path = dir.appendingPathComponent(filename)
            try report.write(to: path, atomically: true, encoding: .utf8)
            Log.info("Bug report saved to \(path.path)")
            return path.path
        } catch {
            Log.error("Failed to save bug report: \(error)")
            return nil
        }
    }

    /// Persist contact info to FeatureSettings if the user opted in.
    func persistContactInfoIfNeeded() {
        let settings = FeatureSettings.shared
        if saveContactInfo {
            settings.bugReportContactName = contactName
            settings.bugReportContactHandle = contactHandle
        } else {
            settings.bugReportContactName = ""
            settings.bugReportContactHandle = ""
        }
    }
}

// MARK: - Errors

enum BugReportError: LocalizedError {
    case invalidEndpoint
    case rateLimited
    case networkError(String)
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidEndpoint:
            return "Issue reporting endpoint is not configured."
        case .rateLimited:
            return "Too many reports submitted recently. Please try again later."
        case .networkError(let msg):
            return "Network error: \(msg)"
        case .serverError(let code, let body):
            return "Server error (\(code)): \(body)"
        }
    }
}
