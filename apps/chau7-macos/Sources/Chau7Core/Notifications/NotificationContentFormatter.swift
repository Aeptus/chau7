import Foundation

/// The single source of user-facing notification text.
///
/// Every surface renders from here so the same semantic event produces the
/// same words everywhere:
/// - macOS local notifications (`AIEvent.notificationTitle/Subtitle/Body`
///   delegate here),
/// - iOS local notifications (`RemoteNotificationScheduler`),
/// - iOS push text (composed on the Mac and carried over the wire; the Go
///   agent's legacy formatters mirror these rules until it becomes a pure
///   relay),
/// - Live Activity headlines (`RemoteActivityProjection`).
public enum NotificationContentFormatter {

    // MARK: - AIEvent-driven local notification content

    /// Title: "<repo — >Tool: State".
    public static func title(
        for event: AIEvent,
        toolOverride: String? = nil,
        repoName: String? = nil
    ) -> String {
        let toolName = (toolOverride ?? event.tool).trimmingCharacters(in: .whitespacesAndNewlines)
        let name = toolName.isEmpty ? event.tool : toolName
        // Prefix with repo name when available (e.g. "Mockup — Claude: Task finished")
        let prefix: String
        if let repo = repoName, !repo.isEmpty, repo != name {
            prefix = "\(repo) — \(name)"
        } else {
            prefix = name
        }
        return "\(prefix): \(titleSuffix(forType: event.type))"
    }

    static func titleSuffix(forType type: String) -> String {
        switch type.lowercased() {
        case "needs_validation":
            return LCore("aiEvent.title.needsValidation", "Needs review")
        case "idle", "waiting_input":
            return LCore("aiEvent.title.waitingInput", "Waiting for input")
        case "attention_required":
            return LCore("aiEvent.title.attention", "Needs attention")
        case "finished":
            return LCore("aiEvent.title.finished", "Finished")
        case "failed":
            return LCore("aiEvent.title.failed", "Failed")
        case "permission":
            return LCore("aiEvent.title.permission", "Permission needed")
        case "error":
            return LCore("aiEvent.title.error", "Error")
        case "context_limit":
            return LCore("aiEvent.title.contextLimit", "Context limit reached")
        case "file_conflict":
            return LCore("aiEvent.title.fileConflict", "File conflict")
        case "tool_called":
            return LCore("aiEvent.title.toolCalled", "Tool called")
        case "file_edited":
            return LCore("aiEvent.title.fileEdited", "File edited")
        case "token_threshold":
            return LCore("aiEvent.title.tokenThreshold", "Token threshold")
        case "cost_threshold":
            return LCore("aiEvent.title.costThreshold", "Cost threshold")
        default:
            return LCore("aiEvent.title.update", "Update")
        }
    }

    /// Subtitle: short routing context ("Repo: X · Tab: Y"). The title already
    /// carries tool and state; this keeps identity separate and drops parts
    /// that would just repeat the tool or repo.
    public static func subtitle(
        for event: AIEvent,
        tabTitle: String? = nil,
        repoName: String? = nil
    ) -> String {
        let repo = firstNonEmpty(
            repoName,
            event.repoPath.map { URL(fileURLWithPath: $0).lastPathComponent }
        )
        let directoryName = repo == nil
            ? cleanPart(event.directory.map { URL(fileURLWithPath: $0).lastPathComponent })
            : nil
        let tab = cleanPart(tabTitle)
        let toolName = cleanPart(event.tool)

        var parts: [String] = []
        if let repo {
            parts.append("\(LCore("aiEvent.subtitle.repo", "Repo")): \(repo)")
        } else if let directoryName {
            parts.append("\(LCore("aiEvent.subtitle.directory", "Dir")): \(directoryName)")
        }
        if let tab, !matches(tab, repo), !matches(tab, toolName) {
            parts.append("\(LCore("aiEvent.subtitle.tab", "Tab")): \(tab)")
        }
        return parts.joined(separator: " · ")
    }

    /// Body: producer-supplied message wins for known types; localized
    /// default otherwise. Unknown types fall back to "<type>: <message>".
    public static func body(for event: AIEvent) -> String {
        let message = event.message
        switch event.type.lowercased() {
        case "needs_validation":
            return message.isEmpty ? LCore("aiEvent.body.needsValidation", "Your input is required.") : message
        case "idle":
            return message.isEmpty ? LCore("aiEvent.body.idle", "No new history entries for a while.") : message
        case "waiting_input":
            return message.isEmpty ? LCore("aiEvent.body.waitingInput", "Ready for your input.") : message
        case "attention_required":
            return message.isEmpty ? LCore("aiEvent.body.attention", "Needs your attention.") : message
        case "finished":
            return message.isEmpty ? LCore("aiEvent.body.finished", "Done.") : message
        case "failed":
            return message.isEmpty ? LCore("aiEvent.body.failed", "Check the logs.") : message
        case "permission":
            return message.isEmpty ? LCore("aiEvent.body.permission", "Needs your permission to continue.") : message
        case "error":
            return message.isEmpty ? LCore("aiEvent.body.error", "An error occurred.") : message
        case "context_limit":
            return message.isEmpty ? LCore("aiEvent.body.contextLimit", "Approaching context window limit.") : message
        case "token_threshold", "cost_threshold":
            return message.isEmpty ? LCore("aiEvent.body.usageThreshold", "Usage threshold exceeded.") : message
        default:
            return message.isEmpty ? event.type : "\(event.type): \(message)"
        }
    }

    // MARK: - Remote approval / interactive prompt titles

    /// Push/local title for an approval request. Leads with the tool name so
    /// the lock-screen banner reads "Codex needs approval"; protected actions
    /// get a distinct title.
    public static func approvalTitle(toolName: String?, isProtectedAction: Bool) -> String {
        if isProtectedAction {
            return "Protected action needs approval"
        }
        if let tool = cleanPart(toolName) {
            return "\(tool) needs approval"
        }
        return "Command approval"
    }

    /// Push/local title for an interactive prompt.
    public static func interactivePromptTitle(toolName: String?) -> String {
        if let tool = cleanPart(toolName) {
            return "\(tool) is waiting"
        }
        return "Interactive prompt"
    }

    /// One-line "where" context shown as a push/local subtitle:
    /// `tab · project (branch) · dir`. The tool name leads the title, so it is
    /// deliberately omitted here. Pass `homeDirectory` to abbreviate paths
    /// under it to `~` (iOS local notifications do; wire text does not).
    public static func locationSummary(
        tabTitle: String?,
        projectName: String?,
        branchName: String?,
        currentDirectory: String?,
        homeDirectory: String? = nil
    ) -> String? {
        var parts: [String] = []
        if let tab = cleanPart(tabTitle) { parts.append(tab) }
        switch (cleanPart(projectName), cleanPart(branchName)) {
        case let (project?, branch?): parts.append("\(project) (\(branch))")
        case let (project?, nil): parts.append(project)
        case let (nil, branch?): parts.append(branch)
        case (nil, nil): break
        }
        if let directory = cleanPart(currentDirectory) {
            parts.append(abbreviate(path: directory, homeDirectory: homeDirectory))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    // MARK: - Live Activity headline

    /// Headline for the remote activity surface. Same vocabulary as the
    /// notification titles, keyed by activity status.
    public static func activityHeadline(status: RemoteActivityStatus, toolName: String) -> String {
        switch status {
        case .approvalRequired:
            return "Approval required"
        case .waitingInput:
            return "\(toolName) needs input"
        case .failed:
            return "\(toolName) failed"
        case .running:
            return "\(toolName) is active"
        case .completed:
            return "\(toolName) finished"
        case .idle:
            return toolName
        }
    }

    // MARK: - Helpers

    private static func abbreviate(path: String, homeDirectory: String?) -> String {
        guard let home = homeDirectory, !home.isEmpty else { return path }
        if path == home { return "~" }
        if path.hasPrefix(home + "/") {
            return "~" + String(path.dropFirst(home.count))
        }
        return path
    }

    private static func firstNonEmpty(_ candidates: String?...) -> String? {
        for candidate in candidates {
            if let cleaned = cleanPart(candidate) {
                return cleaned
            }
        }
        return nil
    }

    private static func cleanPart(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func matches(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs = cleanPart(lhs), let rhs = cleanPart(rhs) else {
            return false
        }
        return lhs.caseInsensitiveCompare(rhs) == .orderedSame
    }
}

public extension String {
    /// Escapes a string for interpolation inside a double-quoted AppleScript
    /// literal. Newlines become spaces (AppleScript `display notification`
    /// renders single-line strings).
    var appleScriptQuoted: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: "")
    }
}
