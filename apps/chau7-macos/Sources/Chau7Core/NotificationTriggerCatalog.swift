import Foundation

public struct NotificationTriggerDisplay: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let settings = NotificationTriggerDisplay(rawValue: 1 << 0)
    public static let activity = NotificationTriggerDisplay(rawValue: 1 << 1)
    public static let debug = NotificationTriggerDisplay(rawValue: 1 << 2)
}

public struct NotificationTriggerSourceInfo: Identifiable, Equatable, Sendable {
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

public struct NotificationTrigger: Identifiable, Equatable, Sendable {
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

/// Conditions that must be met for a trigger to fire.
/// Each trigger gets a default condition; users can override per-trigger in settings.
public struct TriggerCondition: Codable, Equatable, Sendable {
    /// Only fire if Chau7 is not the frontmost application
    public var onlyWhenUnfocused: Bool
    /// Only fire if the triggering tab is not the currently selected tab
    public var onlyWhenTabInactive: Bool
    /// Suppress this trigger when macOS Focus/DND is active
    public var respectDND: Bool

    public init(
        onlyWhenUnfocused: Bool = false,
        onlyWhenTabInactive: Bool = true,
        respectDND: Bool = true
    ) {
        self.onlyWhenUnfocused = onlyWhenUnfocused
        self.onlyWhenTabInactive = onlyWhenTabInactive
        self.respectDND = respectDND
    }

    public static let `default` = TriggerCondition()
}

public struct NotificationTriggerGroup: Identifiable, Equatable, Sendable {
    public let id: String
    public let labelKey: String
    public let labelFallback: String
    public let sources: [AIEventSource]
    public let triggerTypes: [String]

    public init(id: String, labelKey: String, labelFallback: String, sources: [AIEventSource], triggerTypes: [String]) {
        self.id = id
        self.labelKey = labelKey
        self.labelFallback = labelFallback
        self.sources = sources
        self.triggerTypes = triggerTypes
    }

    public func groupTriggerId(for type: String) -> String {
        "\(id).\(type)"
    }

    public func contains(source: AIEventSource) -> Bool {
        sources.contains(source)
    }
}

public struct GroupTriggerInfo: Identifiable, Equatable, Sendable {
    public let id: String
    public let type: String
    public let labelFallback: String
    public let descriptionFallback: String
    public let defaultEnabled: Bool
}

public struct NotificationTriggerState: Codable, Equatable, Sendable {
    public var overrides: [String: Bool]
    public var groupOverrides: [String: Bool]

    public init(overrides: [String: Bool] = [:], groupOverrides: [String: Bool] = [:]) {
        self.overrides = overrides
        self.groupOverrides = groupOverrides
    }

    /// 3-tier resolution: per-trigger override → group override → catalog default
    public func isEnabled(for trigger: NotificationTrigger) -> Bool {
        // Tier 1: per-trigger override
        if let perTrigger = overrides[trigger.id] {
            return perTrigger
        }
        // Tier 2: group override
        if let group = NotificationTriggerCatalog.group(for: trigger.source) {
            let groupId = group.groupTriggerId(for: trigger.type)
            if let groupValue = groupOverrides[groupId] {
                return groupValue
            }
        }
        // Tier 3: catalog default
        return trigger.defaultEnabled
    }

    public func hasPerTriggerOverride(for trigger: NotificationTrigger) -> Bool {
        overrides[trigger.id] != nil
    }

    public func isGroupEnabled(groupId: String, type: String, defaultEnabled: Bool) -> Bool {
        let key = "\(groupId).\(type)"
        return groupOverrides[key] ?? defaultEnabled
    }

    public mutating func setEnabled(_ enabled: Bool, for trigger: NotificationTrigger) {
        overrides[trigger.id] = enabled
    }

    public mutating func setGroupEnabled(_ enabled: Bool, groupId: String, type: String) {
        let key = "\(groupId).\(type)"
        groupOverrides[key] = enabled
    }

    public mutating func removeGroupOverride(groupId: String, type: String) {
        let key = "\(groupId).\(type)"
        groupOverrides.removeValue(forKey: key)
    }

    public mutating func removeOverride(for trigger: NotificationTrigger) {
        overrides.removeValue(forKey: trigger.id)
    }

    public mutating func normalize(using catalog: [NotificationTrigger] = NotificationTriggerCatalog.all) {
        let known = Set(catalog.map(\.id))
        overrides = overrides.filter { known.contains($0.key) }
        let knownGroupIds = NotificationTriggerCatalog.allGroupTriggerIds
        groupOverrides = groupOverrides.filter { knownGroupIds.contains($0.key) }
    }

    // MARK: - Codable (backward compat)

    private enum CodingKeys: String, CodingKey {
        case overrides
        case groupOverrides
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.overrides = try container.decode([String: Bool].self, forKey: .overrides)
        self.groupOverrides = try container.decodeIfPresent([String: Bool].self, forKey: .groupOverrides) ?? [:]
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
            id: .gemini,
            labelKey: "notifications.source.gemini",
            labelFallback: "Gemini",
            sortOrder: 22
        ),
        NotificationTriggerSourceInfo(
            id: .chatgpt,
            labelKey: "notifications.source.chatgpt",
            labelFallback: "ChatGPT",
            sortOrder: 23
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
        NotificationTriggerSourceInfo(
            id: .runtime,
            labelKey: "notifications.source.runtime",
            labelFallback: "Runtime Agent",
            sortOrder: 28
        ),
        // App source
        NotificationTriggerSourceInfo(
            id: .app,
            labelKey: "notifications.source.app",
            labelFallback: "App",
            sortOrder: 100
        ),
        // Catch-all sources (last)
        NotificationTriggerSourceInfo(
            id: .apiProxy,
            labelKey: "notifications.source.apiProxy",
            labelFallback: "API Proxy",
            sortOrder: 200
        ),
        NotificationTriggerSourceInfo(
            id: .unknown,
            labelKey: "notifications.source.unknown",
            labelFallback: "Unknown",
            sortOrder: 201
        )
    ]

    // MARK: - AI Trigger Matrix

    /// Trigger types shared across all AI coding tools.
    /// (type, camelKey for localization, label suffix, description suffix, defaultEnabled)
    private static let aiTriggerTypes: [(type: String, camelKey: String, labelSuffix: String, descSuffix: String, defaultEnabled: Bool)] = [
        ("finished", "finished", "Response complete", "finished responding.", true),
        ("failed", "failed", "Task failed", "failed or exited with an error.", true),
        ("permission", "permission", "Permission request", "needs permission to continue.", true),
        ("waiting_input", "waitingInput", "Waiting for input", "is waiting for your input.", true),
        ("attention_required", "attentionRequired", "Needs attention", "needs your attention.", true),
        ("authentication_succeeded", "authenticationSucceeded", "Authentication complete", "completed authentication.", false),
        ("idle", "idle", "Session idle", "session appears idle.", false),
        ("token_threshold", "tokenThreshold", "Token threshold", "Token usage exceeded threshold.", false),
        ("cost_threshold", "costThreshold", "Cost threshold", "Session cost exceeded threshold.", false),
        ("tool_called", "toolCalled", "Tool called", "called a tool.", false),
        ("file_edited", "fileEdited", "File edited", "edited a file.", false),
        ("error", "error", "Error occurred", "encountered an error.", false),
        ("context_limit", "contextLimit", "Context limit", "approaching context window limit.", false),
        (wildcardType, "other", "Other events", "event types.", false)
    ]

    /// AI sources that share the same trigger structure.
    /// (source, display name, camelCase key for localization)
    private static let aiSources: [(source: AIEventSource, name: String, camelCase: String)] = [
        (.claudeCode, "Claude Code", "claudeCode"),
        (.codex, "Codex", "codex"),
        (.gemini, "Gemini", "gemini"),
        (.chatgpt, "ChatGPT", "chatgpt"),
        (.cursor, "Cursor", "cursor"),
        (.windsurf, "Windsurf", "windsurf"),
        (.copilot, "GitHub Copilot", "copilot"),
        (.aider, "Aider", "aider"),
        (.cline, "Cline", "cline"),
        (.continueAI, "Continue", "continueAI"),
        (.runtime, "Runtime Agent", "runtime")
    ]

    /// All AI triggers generated from the source × type matrix.
    private static let aiTriggers: [NotificationTrigger] = aiSources.flatMap { src in
        aiTriggerTypes.map { tt in
            NotificationTrigger(
                source: src.source,
                type: tt.type,
                labelKey: "notifications.trigger.\(src.camelCase).\(tt.camelKey).label",
                labelFallback: tt.type == wildcardType
                    ? "Other \(src.name) events"
                    : tt.labelSuffix,
                descriptionKey: "notifications.trigger.\(src.camelCase).\(tt.camelKey).description",
                descriptionFallback: tt.type == wildcardType
                    ? "Any other \(src.name) event types."
                    : "\(src.name) \(tt.descSuffix)",
                defaultEnabled: tt.defaultEnabled,
                displayContexts: [.settings, .activity]
            )
        }
    }

    // MARK: - Non-AI Triggers (unique types and descriptions)

    private static let eventsLogTriggers: [NotificationTrigger] = [
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
            defaultEnabled: false,
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
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .eventsLog,
            type: "notification",
            labelKey: "notifications.trigger.eventsLog.notification.label",
            labelFallback: "Custom notification",
            descriptionKey: "notifications.trigger.eventsLog.notification.description",
            descriptionFallback: "An AI event requests a custom notification.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .eventsLog,
            type: wildcardType,
            labelKey: "notifications.trigger.eventsLog.other.label",
            labelFallback: "Other events",
            descriptionKey: "notifications.trigger.eventsLog.other.description",
            descriptionFallback: "Any other AI event types not listed above.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        )
    ]

    private static let terminalSessionTriggers: [NotificationTrigger] = [
        NotificationTrigger(
            source: .terminalSession,
            type: "finished",
            labelKey: "notifications.trigger.terminalSession.finished.label",
            labelFallback: "AI tool finished",
            descriptionKey: "notifications.trigger.terminalSession.finished.description",
            descriptionFallback: "An AI tool finished in the terminal.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .terminalSession,
            type: "permission",
            labelKey: "notifications.trigger.terminalSession.permission.label",
            labelFallback: "AI tool needs permission",
            descriptionKey: "notifications.trigger.terminalSession.permission.description",
            descriptionFallback: "An AI tool in the terminal needs permission to continue.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .terminalSession,
            type: "idle",
            labelKey: "notifications.trigger.terminalSession.idle.label",
            labelFallback: "Command idle",
            descriptionKey: "notifications.trigger.terminalSession.idle.description",
            descriptionFallback: "Terminal command produced no output for the idle timeout.",
            defaultEnabled: false,
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
        NotificationTrigger(
            source: .terminalSession,
            type: "info",
            labelKey: "notifications.trigger.terminalSession.info.label",
            labelFallback: "AI tool started",
            descriptionKey: "notifications.trigger.terminalSession.info.description",
            descriptionFallback: "An AI tool started in the terminal.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        )
    ]

    private static let historyMonitorTriggers: [NotificationTrigger] = [
        NotificationTrigger(
            source: .historyMonitor,
            type: "finished",
            labelKey: "notifications.trigger.historyMonitor.finished.label",
            labelFallback: "Session completed (history)",
            descriptionKey: "notifications.trigger.historyMonitor.finished.description",
            descriptionFallback: "AI session completed as detected by history file monitoring.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .historyMonitor,
            type: "idle",
            labelKey: "notifications.trigger.historyMonitor.idle.label",
            labelFallback: "History idle",
            descriptionKey: "notifications.trigger.historyMonitor.idle.description",
            descriptionFallback: "No new history entries for the idle timeout.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        )
    ]

    private static let shellTriggers: [NotificationTrigger] = [
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
        )
    ]

    private static let appTriggers: [NotificationTrigger] = [
        NotificationTrigger(
            source: .app,
            type: "launch",
            labelKey: "notifications.trigger.app.launch.label",
            labelFallback: "App launched",
            descriptionKey: "notifications.trigger.app.launch.description",
            descriptionFallback: "The app was launched.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .app,
            type: "update_available",
            labelKey: "notifications.trigger.app.updateAvailable.label",
            labelFallback: "Update available",
            descriptionKey: "notifications.trigger.app.updateAvailable.description",
            descriptionFallback: "A new version is available.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .app,
            type: "file_conflict",
            labelKey: "notifications.trigger.app.fileConflict.label",
            labelFallback: "File conflict detected",
            descriptionKey: "notifications.trigger.app.fileConflict.description",
            descriptionFallback: "Multiple tabs modified the same file, risking merge conflicts.",
            defaultEnabled: true,
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
        // The following triggers have no event emitters yet — hidden from settings, visible in activity only.
        NotificationTrigger(
            source: .app,
            type: "window_focused",
            labelKey: "notifications.trigger.app.windowFocused.label",
            labelFallback: "Window focused",
            descriptionKey: "notifications.trigger.app.windowFocused.description",
            descriptionFallback: "App window gained focus.",
            defaultEnabled: false,
            displayContexts: [.activity]
        ),
        NotificationTrigger(
            source: .app,
            type: "window_unfocused",
            labelKey: "notifications.trigger.app.windowUnfocused.label",
            labelFallback: "Window unfocused",
            descriptionKey: "notifications.trigger.app.windowUnfocused.description",
            descriptionFallback: "App window lost focus.",
            defaultEnabled: false,
            displayContexts: [.activity]
        ),
        NotificationTrigger(
            source: .app,
            type: "file_modified",
            labelKey: "notifications.trigger.app.fileModified.label",
            labelFallback: "File modified",
            descriptionKey: "notifications.trigger.app.fileModified.description",
            descriptionFallback: "A watched file was modified.",
            defaultEnabled: false,
            displayContexts: [.activity]
        ),
        NotificationTrigger(
            source: .app,
            type: "docker_event",
            labelKey: "notifications.trigger.app.dockerEvent.label",
            labelFallback: "Docker event",
            descriptionKey: "notifications.trigger.app.dockerEvent.description",
            descriptionFallback: "A Docker container event occurred.",
            defaultEnabled: false,
            displayContexts: [.activity]
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

    // MARK: - Catch-All Triggers (sources without dedicated trigger sets)

    private static let apiProxyTriggers: [NotificationTrigger] = [
        NotificationTrigger(
            source: .apiProxy,
            type: wildcardType,
            labelKey: "notifications.trigger.apiProxy.other.label",
            labelFallback: "API Proxy events",
            descriptionKey: "notifications.trigger.apiProxy.other.description",
            descriptionFallback: "Any event from the API proxy.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        )
    ]

    private static let unknownSourceTriggers: [NotificationTrigger] = [
        NotificationTrigger(
            source: .unknown,
            type: wildcardType,
            labelKey: "notifications.trigger.unknown.other.label",
            labelFallback: "Unknown source events",
            descriptionKey: "notifications.trigger.unknown.other.description",
            descriptionFallback: "Events from unrecognized sources.",
            defaultEnabled: false,
            displayContexts: [.settings, .activity]
        )
    ]

    // MARK: - Combined Catalog

    public static let all: [NotificationTrigger] =
        eventsLogTriggers + terminalSessionTriggers + historyMonitorTriggers
            + shellTriggers + aiTriggers + appTriggers
            + apiProxyTriggers + unknownSourceTriggers

    // MARK: - O(1) Lookup Indexes (built once at startup)

    /// Maps trigger id → trigger for O(1) exact-match lookup.
    private static let index: [String: NotificationTrigger] = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    /// Maps source → wildcard trigger for O(1) fallback lookup.
    private static let wildcardIndex: [AIEventSource: NotificationTrigger] = Dictionary(
        all.filter(\.isWildcard).map { ($0.source, $0) },
        uniquingKeysWith: { first, _ in first }
    )

    public static func triggerId(source: AIEventSource, type: String) -> String {
        "\(source.rawValue).\(normalizeType(type))"
    }

    public static func trigger(for event: AIEvent) -> NotificationTrigger? {
        trigger(source: event.source, type: event.type)
    }

    /// O(1) trigger lookup: checks exact match first, then falls back to wildcard.
    public static func trigger(source: AIEventSource, type: String) -> NotificationTrigger? {
        let id = triggerId(source: source, type: normalizeType(type))
        return index[id] ?? wildcardIndex[source]
    }

    public static func triggers(for source: AIEventSource) -> [NotificationTrigger] {
        all.filter { $0.source == source }
    }

    public static func displayableTriggers(in context: NotificationTriggerDisplay) -> [NotificationTrigger] {
        all.filter { $0.displayContexts.contains(context) }
    }

    // MARK: - Source Group Support

    public static let aiCodingGroup = NotificationTriggerGroup(
        id: "ai_coding",
        labelKey: "notifications.group.aiCoding",
        labelFallback: "All AI Sources",
        sources: aiSources.map(\.source),
        triggerTypes: aiTriggerTypes.map(\.type)
    )

    public static let groups: [NotificationTriggerGroup] = [aiCodingGroup]

    /// O(1) lookup: source → group
    private static let sourceToGroup: [AIEventSource: NotificationTriggerGroup] = {
        var map = [AIEventSource: NotificationTriggerGroup]()
        for group in groups {
            for source in group.sources {
                map[source] = group
            }
        }
        return map
    }()

    public static func group(for source: AIEventSource) -> NotificationTriggerGroup? {
        sourceToGroup[source]
    }

    /// All valid group trigger IDs (for normalize())
    public static let allGroupTriggerIds: Set<String> = {
        var ids = Set<String>()
        for group in groups {
            for type in group.triggerTypes {
                ids.insert(group.groupTriggerId(for: type))
            }
        }
        return ids
    }()

    /// Group trigger info for settings UI
    public static func groupTriggerInfos(for group: NotificationTriggerGroup) -> [GroupTriggerInfo] {
        group.triggerTypes.compactMap { type in
            // Find a representative trigger to get label/description/default
            guard let representative = aiTriggerTypes.first(where: { $0.type == type }) else { return nil }
            return GroupTriggerInfo(
                id: group.groupTriggerId(for: type),
                type: type,
                labelFallback: representative.labelSuffix,
                descriptionFallback: "All AI sources: \(representative.descSuffix)",
                defaultEnabled: representative.defaultEnabled
            )
        }
    }

    fileprivate static func normalizeType(_ type: String) -> String {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
