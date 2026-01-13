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
        NotificationTriggerSourceInfo(
            id: .claudeCode,
            labelKey: "notifications.source.claudeCode",
            labelFallback: "Claude Code",
            sortOrder: 3
        ),
        NotificationTriggerSourceInfo(
            id: .app,
            labelKey: "notifications.source.app",
            labelFallback: "App",
            sortOrder: 4
        )
    ]

    public static let all: [NotificationTrigger] = [
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
        NotificationTrigger(
            source: .historyMonitor,
            type: "idle",
            labelKey: "notifications.trigger.historyMonitor.idle.label",
            labelFallback: "History idle",
            descriptionKey: "notifications.trigger.historyMonitor.idle.description",
            descriptionFallback: "No new history entries for the idle timeout.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .claudeCode,
            type: "finished",
            labelKey: "notifications.trigger.claudeCode.finished.label",
            labelFallback: "Response complete",
            descriptionKey: "notifications.trigger.claudeCode.finished.description",
            descriptionFallback: "Claude Code finished responding in a session.",
            defaultEnabled: true,
            displayContexts: [.settings, .activity]
        ),
        NotificationTrigger(
            source: .claudeCode,
            type: "permission",
            labelKey: "notifications.trigger.claudeCode.permission.label",
            labelFallback: "Permission request",
            descriptionKey: "notifications.trigger.claudeCode.permission.description",
            descriptionFallback: "Claude Code is waiting for permission to continue.",
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
            source: .app,
            type: "info",
            labelKey: "notifications.trigger.app.info.label",
            labelFallback: "Test notification",
            descriptionKey: "notifications.trigger.app.info.description",
            descriptionFallback: "Manual test notification from settings.",
            defaultEnabled: true,
            displayContexts: [.activity]
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
