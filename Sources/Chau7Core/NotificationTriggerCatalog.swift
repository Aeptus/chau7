import Foundation

public struct NotificationTriggerDisplay: OptionSet {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let settings = NotificationTriggerDisplay(rawValue: 1 << 0)
    public static let activity = NotificationTriggerDisplay(rawValue: 1 << 1)
    public static let debug = NotificationTriggerDisplay(rawValue: 1 << 2)
}

public struct NotificationTriggerSourceInfo: Identifiable, Equatable {
    public let id: AIEventSource
    public let labelKey: String
    public let labelFallback: String
    public let sortOrder: Int

    public init(id: AIEventSource, labelKey: String, labelFallback: String, sortOrder: Int) {
        self.id = id
        self.labelKey = labelKey
        self.labelFallback = labelFallback
        self.sortOrder = sortOrder
    }
}

public struct NotificationTrigger: Identifiable, Equatable {
    public let id: String
    public let source: AIEventSource
    public let type: String
    public let labelKey: String
    public let labelFallback: String
    public let descriptionKey: String
    public let descriptionFallback: String
    public let defaultEnabled: Bool
    public let displayContexts: NotificationTriggerDisplay

    public init(
        source: AIEventSource,
        type: String,
        labelKey: String,
        labelFallback: String,
        descriptionKey: String,
        descriptionFallback: String,
        defaultEnabled: Bool,
        displayContexts: NotificationTriggerDisplay
    ) {
        let normalizedType = NotificationTriggerCatalog.normalizeType(type)
        self.id = NotificationTriggerCatalog.triggerId(source: source, type: normalizedType)
        self.source = source
        self.type = normalizedType
        self.labelKey = labelKey
        self.labelFallback = labelFallback
        self.descriptionKey = descriptionKey
        self.descriptionFallback = descriptionFallback
        self.defaultEnabled = defaultEnabled
        self.displayContexts = displayContexts
    }

    public var isWildcard: Bool {
        type == NotificationTriggerCatalog.wildcardType
    }
}

public struct NotificationTriggerState: Codable, Equatable {
    public var overrides: [String: Bool]

    public init(overrides: [String: Bool] = [:]) {
        self.overrides = overrides
    }

    public func isEnabled(for trigger: NotificationTrigger) -> Bool {
        overrides[trigger.id] ?? trigger.defaultEnabled
    }

    public mutating func setEnabled(_ enabled: Bool, for trigger: NotificationTrigger) {
        overrides[trigger.id] = enabled
    }

    public mutating func normalize(using catalog: [NotificationTrigger] = NotificationTriggerCatalog.all) {
        let known = Set(catalog.map(\.id))
        overrides = overrides.filter { known.contains($0.key) }
    }
}

public enum NotificationTriggerCatalog {
    public static let wildcardType = "*"

    public static let sources: [NotificationTriggerSourceInfo] = [
        // Core sources
        NotificationTriggerSourceInfo(
            id: .eventsLog,
            labelKey: "notifications.source.eventsLog",
            labelFallback: "AI Events Log",
            sortOrder: 0
        ),
        NotificationTriggerSourceInfo(
            id: .terminalSession,
            labelKey: "notifications.source.terminalSession",
            labelFallback: "Terminal Session",
            sortOrder: 1
        ),
        NotificationTriggerSourceInfo(
            id: .historyMonitor,
            labelKey: "notifications.source.historyMonitor",
            labelFallback: "History Monitor",
            sortOrder: 2
        ),
        // Shell source
        NotificationTriggerSourceInfo(
            id: .shell,
            labelKey: "notifications.source.shell",
            labelFallback: "Shell",
            sortOrder: 10
        ),
        // AI Coding Apps (sorted together)
        NotificationTriggerSourceInfo(
            id: .claudeCode,
            labelKey: "notifications.source.claudeCode",
            labelFallback: "Claude Code",
            sortOrder: 20
        ),
        NotificationTriggerSourceInfo(
            id: .codex,
            labelKey: "notifications.source.codex",
            labelFallback: "Codex",
            sortOrder: 21
        ),
        NotificationTriggerSourceInfo(
            id: .cursor,
            labelKey: "notifications.source.cursor",
            labelFallback: "Cursor",
            sortOrder: 22
        ),
        NotificationTriggerSourceInfo(
            id: .windsurf,
            labelKey: "notifications.source.windsurf",
            labelFallback: "Windsurf",
            sortOrder: 23
        ),
        NotificationTriggerSourceInfo(
            id: .copilot,
            labelKey: "notifications.source.copilot",
            labelFallback: "GitHub Copilot",
            sortOrder: 24
        ),
        NotificationTriggerSourceInfo(
            id: .aider,
            labelKey: "notifications.source.aider",
            labelFallback: "Aider",
            sortOrder: 25
        ),
        NotificationTriggerSourceInfo(
            id: .cline,
            labelKey: "notifications.source.cline",
            labelFallback: "Cline",
            sortOrder: 26
        ),
        NotificationTriggerSourceInfo(
            id: .continueAI,
            labelKey: "notifications.source.continueAI",
            labelFallback: "Continue",
            sortOrder: 27
        ),
        // App source (last)
        NotificationTriggerSourceInfo(
            id: .app,
            labelKey: "notifications.source.app",
            labelFallback: "App",
            sortOrder: 100
        )
    ]

    public static let all: [NotificationTrigger] = [
        // MARK: - Events Log Triggers
        NotificationTrigger(
            source: .eventsLog,
            type: "finished",
            labelKey: "notifications.trigger.eventsLog.finished.label",
            labelFallback: "Task finished",
            descriptionKey: "notifications.trigger.eventsLog.finished.description",
            descriptionFallback: "An AI event reports a completed task.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .eventsLog,
            type: "failed",
            labelKey: "notifications.trigger.eventsLog.failed.label",
            labelFallback: "Task failed",
            descriptionKey: "notifications.trigger.eventsLog.failed.description",
            descriptionFallback: "An AI event reports a failure or error.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .eventsLog,
            type: "needs_validation",
            labelKey: "notifications.trigger.eventsLog.needsValidation.label",
            labelFallback: "Needs validation",
            descriptionKey: "notifications.trigger.eventsLog.needsValidation.description",
            descriptionFallback: "An AI event requests review or confirmation.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .eventsLog,
            type: "permission",
            labelKey: "notifications.trigger.eventsLog.permission.label",
            labelFallback: "Permission request",
            descriptionKey: "notifications.trigger.eventsLog.permission.description",
            descriptionFallback: "An AI event requests permission to proceed.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .eventsLog,
            type: "tool_complete",
            labelKey: "notifications.trigger.eventsLog.toolComplete.label",
            labelFallback: "Tool complete",
            descriptionKey: "notifications.trigger.eventsLog.toolComplete.description",
            descriptionFallback: "An AI event reports a tool finished executing.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .eventsLog,
            type: "session_end",
            labelKey: "notifications.trigger.eventsLog.sessionEnd.label",
            labelFallback: "Session ended",
            descriptionKey: "notifications.trigger.eventsLog.sessionEnd.description",
            descriptionFallback: "An AI event reports a session ended.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .eventsLog,
            type: "idle",
            labelKey: "notifications.trigger.eventsLog.idle.label",
            labelFallback: "Command idle",
            descriptionKey: "notifications.trigger.eventsLog.idle.description",
            descriptionFallback: "An AI event reports inactivity or waiting for input.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .eventsLog,
            type: "notification",
            labelKey: "notifications.trigger.eventsLog.notification.label",
            labelFallback: "Custom notification",
            descriptionKey: "notifications.trigger.eventsLog.notification.description",
            descriptionFallback: "An AI event requests a custom notification.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .eventsLog,
            type: wildcardType,
            labelKey: "notifications.trigger.eventsLog.other.label",
            labelFallback: "Other events",
            descriptionKey: "notifications.trigger.eventsLog.other.description",
            descriptionFallback: "Any other AI event types not listed above.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),

        // MARK: - Terminal Session Triggers
        NotificationTrigger(
            source: .terminalSession,
            type: "finished",
            labelKey: "notifications.trigger.terminalSession.finished.label",
            labelFallback: "Command idle",
            descriptionKey: "notifications.trigger.terminalSession.finished.description",
            descriptionFallback: "Terminal command produced no output for the idle timeout.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .terminalSession,
            type: "failed",
            labelKey: "notifications.trigger.terminalSession.failed.label",
            labelFallback: "Shell exited",
            descriptionKey: "notifications.trigger.terminalSession.failed.description",
            descriptionFallback: "Terminal shell process exited.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),

        // MARK: - History Monitor Triggers
        NotificationTrigger(
            source: .historyMonitor,
            type: "idle",
            labelKey: "notifications.trigger.historyMonitor.idle.label",
            labelFallback: "History idle",
            descriptionKey: "notifications.trigger.historyMonitor.idle.description",
            descriptionFallback: "No new history entries for the idle timeout.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),

        // MARK: - Shell Triggers
        NotificationTrigger(
            source: .shell,
            type: "command_finished",
            labelKey: "notifications.trigger.shell.commandFinished.label",
            labelFallback: "Command finished",
            descriptionKey: "notifications.trigger.shell.commandFinished.description",
            descriptionFallback: "A shell command completed execution.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .shell,
            type: "command_failed",
            labelKey: "notifications.trigger.shell.commandFailed.label",
            labelFallback: "Command failed",
            descriptionKey: "notifications.trigger.shell.commandFailed.description",
            descriptionFallback: "A shell command exited with non-zero status.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .shell,
            type: "exit_code_match",
            labelKey: "notifications.trigger.shell.exitCodeMatch.label",
            labelFallback: "Exit code match",
            descriptionKey: "notifications.trigger.shell.exitCodeMatch.description",
            descriptionFallback: "Command exited with a specific exit code.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .shell,
            type: "pattern_match",
            labelKey: "notifications.trigger.shell.patternMatch.label",
            labelFallback: "Output pattern match",
            descriptionKey: "notifications.trigger.shell.patternMatch.description",
            descriptionFallback: "Command output matched a configured pattern.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .shell,
            type: "long_running",
            labelKey: "notifications.trigger.shell.longRunning.label",
            labelFallback: "Long-running command",
            descriptionKey: "notifications.trigger.shell.longRunning.description",
            descriptionFallback: "Command has been running longer than threshold.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .shell,
            type: "process_started",
            labelKey: "notifications.trigger.shell.processStarted.label",
            labelFallback: "Process started",
            descriptionKey: "notifications.trigger.shell.processStarted.description",
            descriptionFallback: "A new process was started in the shell.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .shell,
            type: "process_ended",
            labelKey: "notifications.trigger.shell.processEnded.label",
            labelFallback: "Process ended",
            descriptionKey: "notifications.trigger.shell.processEnded.description",
            descriptionFallback: "A shell process has terminated.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .shell,
            type: "directory_changed",
            labelKey: "notifications.trigger.shell.directoryChanged.label",
            labelFallback: "Directory changed",
            descriptionKey: "notifications.trigger.shell.directoryChanged.description",
            descriptionFallback: "Working directory was changed (cd).",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .shell,
            type: "git_branch_changed",
            labelKey: "notifications.trigger.shell.gitBranchChanged.label",
            labelFallback: "Git branch changed",
            descriptionKey: "notifications.trigger.shell.gitBranchChanged.description",
            descriptionFallback: "Git branch was switched or changed.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .shell,
            type: wildcardType,
            labelKey: "notifications.trigger.shell.other.label",
            labelFallback: "Other shell events",
            descriptionKey: "notifications.trigger.shell.other.description",
            descriptionFallback: "Any other shell event types.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),

        // MARK: - Claude Code Triggers
        NotificationTrigger(
            source: .claudeCode,
            type: "finished",
            labelKey: "notifications.trigger.claudeCode.finished.label",
            labelFallback: "Response complete",
            descriptionKey: "notifications.trigger.claudeCode.finished.description",
            descriptionFallback: "Claude Code finished responding.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .claudeCode,
            type: "permission",
            labelKey: "notifications.trigger.claudeCode.permission.label",
            labelFallback: "Permission request",
            descriptionKey: "notifications.trigger.claudeCode.permission.description",
            descriptionFallback: "Claude Code needs permission to continue.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .claudeCode,
            type: "idle",
            labelKey: "notifications.trigger.claudeCode.idle.label",
            labelFallback: "Session idle",
            descriptionKey: "notifications.trigger.claudeCode.idle.description",
            descriptionFallback: "Claude Code session appears idle.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .claudeCode,
            type: "token_threshold",
            labelKey: "notifications.trigger.claudeCode.tokenThreshold.label",
            labelFallback: "Token threshold",
            descriptionKey: "notifications.trigger.claudeCode.tokenThreshold.description",
            descriptionFallback: "Token usage exceeded threshold.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .claudeCode,
            type: "cost_threshold",
            labelKey: "notifications.trigger.claudeCode.costThreshold.label",
            labelFallback: "Cost threshold",
            descriptionKey: "notifications.trigger.claudeCode.costThreshold.description",
            descriptionFallback: "Session cost exceeded threshold.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .claudeCode,
            type: "tool_called",
            labelKey: "notifications.trigger.claudeCode.toolCalled.label",
            labelFallback: "Tool called",
            descriptionKey: "notifications.trigger.claudeCode.toolCalled.description",
            descriptionFallback: "Claude Code called a tool.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .claudeCode,
            type: "file_edited",
            labelKey: "notifications.trigger.claudeCode.fileEdited.label",
            labelFallback: "File edited",
            descriptionKey: "notifications.trigger.claudeCode.fileEdited.description",
            descriptionFallback: "Claude Code edited a file.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .claudeCode,
            type: "error",
            labelKey: "notifications.trigger.claudeCode.error.label",
            labelFallback: "Error occurred",
            descriptionKey: "notifications.trigger.claudeCode.error.description",
            descriptionFallback: "Claude Code encountered an error.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .claudeCode,
            type: "context_limit",
            labelKey: "notifications.trigger.claudeCode.contextLimit.label",
            labelFallback: "Context limit",
            descriptionKey: "notifications.trigger.claudeCode.contextLimit.description",
            descriptionFallback: "Approaching context window limit.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .claudeCode,
            type: wildcardType,
            labelKey: "notifications.trigger.claudeCode.other.label",
            labelFallback: "Other Claude Code events",
            descriptionKey: "notifications.trigger.claudeCode.other.description",
            descriptionFallback: "Any other Claude Code event types.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),

        // MARK: - Codex Triggers
        NotificationTrigger(
            source: .codex,
            type: "finished",
            labelKey: "notifications.trigger.codex.finished.label",
            labelFallback: "Response complete",
            descriptionKey: "notifications.trigger.codex.finished.description",
            descriptionFallback: "Codex finished responding.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .codex,
            type: "permission",
            labelKey: "notifications.trigger.codex.permission.label",
            labelFallback: "Permission request",
            descriptionKey: "notifications.trigger.codex.permission.description",
            descriptionFallback: "Codex needs permission to continue.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .codex,
            type: "idle",
            labelKey: "notifications.trigger.codex.idle.label",
            labelFallback: "Session idle",
            descriptionKey: "notifications.trigger.codex.idle.description",
            descriptionFallback: "Codex session appears idle.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .codex,
            type: "token_threshold",
            labelKey: "notifications.trigger.codex.tokenThreshold.label",
            labelFallback: "Token threshold",
            descriptionKey: "notifications.trigger.codex.tokenThreshold.description",
            descriptionFallback: "Token usage exceeded threshold.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .codex,
            type: "cost_threshold",
            labelKey: "notifications.trigger.codex.costThreshold.label",
            labelFallback: "Cost threshold",
            descriptionKey: "notifications.trigger.codex.costThreshold.description",
            descriptionFallback: "Session cost exceeded threshold.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .codex,
            type: "tool_called",
            labelKey: "notifications.trigger.codex.toolCalled.label",
            labelFallback: "Tool called",
            descriptionKey: "notifications.trigger.codex.toolCalled.description",
            descriptionFallback: "Codex called a tool.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .codex,
            type: "file_edited",
            labelKey: "notifications.trigger.codex.fileEdited.label",
            labelFallback: "File edited",
            descriptionKey: "notifications.trigger.codex.fileEdited.description",
            descriptionFallback: "Codex edited a file.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .codex,
            type: "error",
            labelKey: "notifications.trigger.codex.error.label",
            labelFallback: "Error occurred",
            descriptionKey: "notifications.trigger.codex.error.description",
            descriptionFallback: "Codex encountered an error.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .codex,
            type: wildcardType,
            labelKey: "notifications.trigger.codex.other.label",
            labelFallback: "Other Codex events",
            descriptionKey: "notifications.trigger.codex.other.description",
            descriptionFallback: "Any other Codex event types.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),

        // MARK: - Cursor Triggers
        NotificationTrigger(
            source: .cursor,
            type: "finished",
            labelKey: "notifications.trigger.cursor.finished.label",
            labelFallback: "Response complete",
            descriptionKey: "notifications.trigger.cursor.finished.description",
            descriptionFallback: "Cursor finished responding.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cursor,
            type: "permission",
            labelKey: "notifications.trigger.cursor.permission.label",
            labelFallback: "Permission request",
            descriptionKey: "notifications.trigger.cursor.permission.description",
            descriptionFallback: "Cursor needs permission to continue.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cursor,
            type: "idle",
            labelKey: "notifications.trigger.cursor.idle.label",
            labelFallback: "Session idle",
            descriptionKey: "notifications.trigger.cursor.idle.description",
            descriptionFallback: "Cursor session appears idle.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cursor,
            type: "token_threshold",
            labelKey: "notifications.trigger.cursor.tokenThreshold.label",
            labelFallback: "Token threshold",
            descriptionKey: "notifications.trigger.cursor.tokenThreshold.description",
            descriptionFallback: "Token usage exceeded threshold.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cursor,
            type: "cost_threshold",
            labelKey: "notifications.trigger.cursor.costThreshold.label",
            labelFallback: "Cost threshold",
            descriptionKey: "notifications.trigger.cursor.costThreshold.description",
            descriptionFallback: "Session cost exceeded threshold.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cursor,
            type: "tool_called",
            labelKey: "notifications.trigger.cursor.toolCalled.label",
            labelFallback: "Tool called",
            descriptionKey: "notifications.trigger.cursor.toolCalled.description",
            descriptionFallback: "Cursor called a tool.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cursor,
            type: "file_edited",
            labelKey: "notifications.trigger.cursor.fileEdited.label",
            labelFallback: "File edited",
            descriptionKey: "notifications.trigger.cursor.fileEdited.description",
            descriptionFallback: "Cursor edited a file.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cursor,
            type: "error",
            labelKey: "notifications.trigger.cursor.error.label",
            labelFallback: "Error occurred",
            descriptionKey: "notifications.trigger.cursor.error.description",
            descriptionFallback: "Cursor encountered an error.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cursor,
            type: wildcardType,
            labelKey: "notifications.trigger.cursor.other.label",
            labelFallback: "Other Cursor events",
            descriptionKey: "notifications.trigger.cursor.other.description",
            descriptionFallback: "Any other Cursor event types.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),

        // MARK: - Windsurf Triggers
        NotificationTrigger(
            source: .windsurf,
            type: "finished",
            labelKey: "notifications.trigger.windsurf.finished.label",
            labelFallback: "Response complete",
            descriptionKey: "notifications.trigger.windsurf.finished.description",
            descriptionFallback: "Windsurf finished responding.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .windsurf,
            type: "permission",
            labelKey: "notifications.trigger.windsurf.permission.label",
            labelFallback: "Permission request",
            descriptionKey: "notifications.trigger.windsurf.permission.description",
            descriptionFallback: "Windsurf needs permission to continue.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .windsurf,
            type: "idle",
            labelKey: "notifications.trigger.windsurf.idle.label",
            labelFallback: "Session idle",
            descriptionKey: "notifications.trigger.windsurf.idle.description",
            descriptionFallback: "Windsurf session appears idle.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .windsurf,
            type: "token_threshold",
            labelKey: "notifications.trigger.windsurf.tokenThreshold.label",
            labelFallback: "Token threshold",
            descriptionKey: "notifications.trigger.windsurf.tokenThreshold.description",
            descriptionFallback: "Token usage exceeded threshold.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .windsurf,
            type: "cost_threshold",
            labelKey: "notifications.trigger.windsurf.costThreshold.label",
            labelFallback: "Cost threshold",
            descriptionKey: "notifications.trigger.windsurf.costThreshold.description",
            descriptionFallback: "Session cost exceeded threshold.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .windsurf,
            type: "tool_called",
            labelKey: "notifications.trigger.windsurf.toolCalled.label",
            labelFallback: "Tool called",
            descriptionKey: "notifications.trigger.windsurf.toolCalled.description",
            descriptionFallback: "Windsurf called a tool.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .windsurf,
            type: "file_edited",
            labelKey: "notifications.trigger.windsurf.fileEdited.label",
            labelFallback: "File edited",
            descriptionKey: "notifications.trigger.windsurf.fileEdited.description",
            descriptionFallback: "Windsurf edited a file.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .windsurf,
            type: "error",
            labelKey: "notifications.trigger.windsurf.error.label",
            labelFallback: "Error occurred",
            descriptionKey: "notifications.trigger.windsurf.error.description",
            descriptionFallback: "Windsurf encountered an error.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .windsurf,
            type: wildcardType,
            labelKey: "notifications.trigger.windsurf.other.label",
            labelFallback: "Other Windsurf events",
            descriptionKey: "notifications.trigger.windsurf.other.description",
            descriptionFallback: "Any other Windsurf event types.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),

        // MARK: - GitHub Copilot Triggers
        NotificationTrigger(
            source: .copilot,
            type: "finished",
            labelKey: "notifications.trigger.copilot.finished.label",
            labelFallback: "Response complete",
            descriptionKey: "notifications.trigger.copilot.finished.description",
            descriptionFallback: "Copilot finished responding.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .copilot,
            type: "permission",
            labelKey: "notifications.trigger.copilot.permission.label",
            labelFallback: "Permission request",
            descriptionKey: "notifications.trigger.copilot.permission.description",
            descriptionFallback: "Copilot needs permission to continue.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .copilot,
            type: "idle",
            labelKey: "notifications.trigger.copilot.idle.label",
            labelFallback: "Session idle",
            descriptionKey: "notifications.trigger.copilot.idle.description",
            descriptionFallback: "Copilot session appears idle.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .copilot,
            type: "suggestion_accepted",
            labelKey: "notifications.trigger.copilot.suggestionAccepted.label",
            labelFallback: "Suggestion accepted",
            descriptionKey: "notifications.trigger.copilot.suggestionAccepted.description",
            descriptionFallback: "A Copilot suggestion was accepted.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .copilot,
            type: "error",
            labelKey: "notifications.trigger.copilot.error.label",
            labelFallback: "Error occurred",
            descriptionKey: "notifications.trigger.copilot.error.description",
            descriptionFallback: "Copilot encountered an error.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .copilot,
            type: wildcardType,
            labelKey: "notifications.trigger.copilot.other.label",
            labelFallback: "Other Copilot events",
            descriptionKey: "notifications.trigger.copilot.other.description",
            descriptionFallback: "Any other Copilot event types.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),

        // MARK: - Aider Triggers
        NotificationTrigger(
            source: .aider,
            type: "finished",
            labelKey: "notifications.trigger.aider.finished.label",
            labelFallback: "Response complete",
            descriptionKey: "notifications.trigger.aider.finished.description",
            descriptionFallback: "Aider finished responding.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .aider,
            type: "permission",
            labelKey: "notifications.trigger.aider.permission.label",
            labelFallback: "Permission request",
            descriptionKey: "notifications.trigger.aider.permission.description",
            descriptionFallback: "Aider needs permission to continue.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .aider,
            type: "idle",
            labelKey: "notifications.trigger.aider.idle.label",
            labelFallback: "Session idle",
            descriptionKey: "notifications.trigger.aider.idle.description",
            descriptionFallback: "Aider session appears idle.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .aider,
            type: "token_threshold",
            labelKey: "notifications.trigger.aider.tokenThreshold.label",
            labelFallback: "Token threshold",
            descriptionKey: "notifications.trigger.aider.tokenThreshold.description",
            descriptionFallback: "Token usage exceeded threshold.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .aider,
            type: "cost_threshold",
            labelKey: "notifications.trigger.aider.costThreshold.label",
            labelFallback: "Cost threshold",
            descriptionKey: "notifications.trigger.aider.costThreshold.description",
            descriptionFallback: "Session cost exceeded threshold.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .aider,
            type: "file_edited",
            labelKey: "notifications.trigger.aider.fileEdited.label",
            labelFallback: "File edited",
            descriptionKey: "notifications.trigger.aider.fileEdited.description",
            descriptionFallback: "Aider edited a file.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .aider,
            type: "error",
            labelKey: "notifications.trigger.aider.error.label",
            labelFallback: "Error occurred",
            descriptionKey: "notifications.trigger.aider.error.description",
            descriptionFallback: "Aider encountered an error.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .aider,
            type: wildcardType,
            labelKey: "notifications.trigger.aider.other.label",
            labelFallback: "Other Aider events",
            descriptionKey: "notifications.trigger.aider.other.description",
            descriptionFallback: "Any other Aider event types.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),

        // MARK: - Cline Triggers
        NotificationTrigger(
            source: .cline,
            type: "finished",
            labelKey: "notifications.trigger.cline.finished.label",
            labelFallback: "Response complete",
            descriptionKey: "notifications.trigger.cline.finished.description",
            descriptionFallback: "Cline finished responding.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cline,
            type: "permission",
            labelKey: "notifications.trigger.cline.permission.label",
            labelFallback: "Permission request",
            descriptionKey: "notifications.trigger.cline.permission.description",
            descriptionFallback: "Cline needs permission to continue.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cline,
            type: "idle",
            labelKey: "notifications.trigger.cline.idle.label",
            labelFallback: "Session idle",
            descriptionKey: "notifications.trigger.cline.idle.description",
            descriptionFallback: "Cline session appears idle.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cline,
            type: "token_threshold",
            labelKey: "notifications.trigger.cline.tokenThreshold.label",
            labelFallback: "Token threshold",
            descriptionKey: "notifications.trigger.cline.tokenThreshold.description",
            descriptionFallback: "Token usage exceeded threshold.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cline,
            type: "cost_threshold",
            labelKey: "notifications.trigger.cline.costThreshold.label",
            labelFallback: "Cost threshold",
            descriptionKey: "notifications.trigger.cline.costThreshold.description",
            descriptionFallback: "Session cost exceeded threshold.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cline,
            type: "tool_called",
            labelKey: "notifications.trigger.cline.toolCalled.label",
            labelFallback: "Tool called",
            descriptionKey: "notifications.trigger.cline.toolCalled.description",
            descriptionFallback: "Cline called a tool.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cline,
            type: "file_edited",
            labelKey: "notifications.trigger.cline.fileEdited.label",
            labelFallback: "File edited",
            descriptionKey: "notifications.trigger.cline.fileEdited.description",
            descriptionFallback: "Cline edited a file.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cline,
            type: "error",
            labelKey: "notifications.trigger.cline.error.label",
            labelFallback: "Error occurred",
            descriptionKey: "notifications.trigger.cline.error.description",
            descriptionFallback: "Cline encountered an error.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .cline,
            type: wildcardType,
            labelKey: "notifications.trigger.cline.other.label",
            labelFallback: "Other Cline events",
            descriptionKey: "notifications.trigger.cline.other.description",
            descriptionFallback: "Any other Cline event types.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),

        // MARK: - Continue AI Triggers
        NotificationTrigger(
            source: .continueAI,
            type: "finished",
            labelKey: "notifications.trigger.continueAI.finished.label",
            labelFallback: "Response complete",
            descriptionKey: "notifications.trigger.continueAI.finished.description",
            descriptionFallback: "Continue finished responding.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .continueAI,
            type: "permission",
            labelKey: "notifications.trigger.continueAI.permission.label",
            labelFallback: "Permission request",
            descriptionKey: "notifications.trigger.continueAI.permission.description",
            descriptionFallback: "Continue needs permission to continue.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .continueAI,
            type: "idle",
            labelKey: "notifications.trigger.continueAI.idle.label",
            labelFallback: "Session idle",
            descriptionKey: "notifications.trigger.continueAI.idle.description",
            descriptionFallback: "Continue session appears idle.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .continueAI,
            type: "error",
            labelKey: "notifications.trigger.continueAI.error.label",
            labelFallback: "Error occurred",
            descriptionKey: "notifications.trigger.continueAI.error.description",
            descriptionFallback: "Continue encountered an error.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .continueAI,
            type: wildcardType,
            labelKey: "notifications.trigger.continueAI.other.label",
            labelFallback: "Other Continue events",
            descriptionKey: "notifications.trigger.continueAI.other.description",
            descriptionFallback: "Any other Continue event types.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),

        // MARK: - App Triggers
        NotificationTrigger(
            source: .app,
            type: "info",
            labelKey: "notifications.trigger.app.info.label",
            labelFallback: "Test notification",
            descriptionKey: "notifications.trigger.app.info.description",
            descriptionFallback: "Manual test notification from settings.",
            defaultEnabled: true,
            displayContexts: [.activity]
        ),
        NotificationTrigger(
            source: .app,
            type: "scheduled",
            labelKey: "notifications.trigger.app.scheduled.label",
            labelFallback: "Scheduled event",
            descriptionKey: "notifications.trigger.app.scheduled.description",
            descriptionFallback: "A scheduled timer fired.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .app,
            type: "inactivity_timeout",
            labelKey: "notifications.trigger.app.inactivityTimeout.label",
            labelFallback: "Inactivity timeout",
            descriptionKey: "notifications.trigger.app.inactivityTimeout.description",
            descriptionFallback: "User was inactive for the configured duration.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .app,
            type: "memory_threshold",
            labelKey: "notifications.trigger.app.memoryThreshold.label",
            labelFallback: "Memory threshold",
            descriptionKey: "notifications.trigger.app.memoryThreshold.description",
            descriptionFallback: "Memory usage exceeded threshold.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .app,
            type: "tab_opened",
            labelKey: "notifications.trigger.app.tabOpened.label",
            labelFallback: "Tab opened",
            descriptionKey: "notifications.trigger.app.tabOpened.description",
            descriptionFallback: "A new tab was opened.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .app,
            type: "tab_closed",
            labelKey: "notifications.trigger.app.tabClosed.label",
            labelFallback: "Tab closed",
            descriptionKey: "notifications.trigger.app.tabClosed.description",
            descriptionFallback: "A tab was closed.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .app,
            type: "window_focused",
            labelKey: "notifications.trigger.app.windowFocused.label",
            labelFallback: "Window focused",
            descriptionKey: "notifications.trigger.app.windowFocused.description",
            descriptionFallback: "App window gained focus.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .app,
            type: "window_unfocused",
            labelKey: "notifications.trigger.app.windowUnfocused.label",
            labelFallback: "Window unfocused",
            descriptionKey: "notifications.trigger.app.windowUnfocused.description",
            descriptionFallback: "App window lost focus.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .app,
            type: "file_modified",
            labelKey: "notifications.trigger.app.fileModified.label",
            labelFallback: "File modified",
            descriptionKey: "notifications.trigger.app.fileModified.description",
            descriptionFallback: "A watched file was modified.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .app,
            type: "docker_event",
            labelKey: "notifications.trigger.app.dockerEvent.label",
            labelFallback: "Docker event",
            descriptionKey: "notifications.trigger.app.dockerEvent.description",
            descriptionFallback: "A Docker container event occurred.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .app,
            type: wildcardType,
            labelKey: "notifications.trigger.app.other.label",
            labelFallback: "Other app events",
            descriptionKey: "notifications.trigger.app.other.description",
            descriptionFallback: "Any other app event types.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        )
    ]

    public static func triggerId(source: AIEventSource, type: String) -> String {
        "\(source.rawValue).\(normalizeType(type))"
    }

    public static func trigger(for event: AIEvent) -> NotificationTrigger? {
        trigger(source: event.source, type: event.type)
    }

    public static func trigger(source: AIEventSource, type: String) -> NotificationTrigger? {
        let normalizedType = normalizeType(type)
        if let match = all.first(where: { $0.source == source && $0.type == normalizedType }) {
            return match
        }
        return all.first(where: { $0.source == source && $0.isWildcard })
    }

    public static func triggers(for source: AIEventSource) -> [NotificationTrigger] {
        all.filter { $0.source == source }
    }

    public static func displayableTriggers(in context: NotificationTriggerDisplay) -> [NotificationTrigger] {
        all.filter { $0.displayContexts.contains(context) }
    }

    fileprivate static func normalizeType(_ type: String) -> String {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
