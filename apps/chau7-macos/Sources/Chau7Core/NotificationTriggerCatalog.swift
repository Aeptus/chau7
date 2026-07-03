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

    /// Every source's label key follows `notifications.source.<camelKey>`.
    private static func sourceInfo(
        _ id: AIEventSource,
        camel: String,
        label: String,
        sortOrder: Int
    ) -> NotificationTriggerSourceInfo {
        NotificationTriggerSourceInfo(
            id: id,
            labelKey: "notifications.source.\(camel)",
            labelFallback: label,
            sortOrder: sortOrder
        )
    }

    public static let sources: [NotificationTriggerSourceInfo] =
        // Core sources
        [
            sourceInfo(.eventsLog, camel: "eventsLog", label: "AI Events Log", sortOrder: 0),
            sourceInfo(.terminalSession, camel: "terminalSession", label: "Terminal Session", sortOrder: 1),
            sourceInfo(.historyMonitor, camel: "historyMonitor", label: "History Monitor", sortOrder: 2),
            // Shell source
            sourceInfo(.shell, camel: "shell", label: "Shell", sortOrder: 10)
        ]
        // AI Coding Apps (derived from AIToolRegistry, sorted together)
        + aiSources.enumerated().map { index, src in
            sourceInfo(src.source, camel: src.camelCase, label: src.name, sortOrder: 20 + index)
        }

        + [
            // App source
            sourceInfo(.app, camel: "app", label: "App", sortOrder: 100),
            // Catch-all sources (last)
            sourceInfo(.apiProxy, camel: "apiProxy", label: "API Proxy", sortOrder: 200),
            sourceInfo(.unknown, camel: "unknown", label: "Unknown", sortOrder: 201)
        ]

    // MARK: - AI Trigger Matrix

    /// Localization-key segment for a trigger type ("needs_validation" →
    /// "needsValidation"); the wildcard maps to "other".
    private static func typeCamelKey(_ type: String) -> String {
        type == wildcardType ? "other" : type.snakeToCamelKey
    }

    /// Trigger types shared across all AI coding tools.
    /// (type, label suffix, description suffix, defaultEnabled)
    private static let aiTriggerTypes: [(type: String, labelSuffix: String, descSuffix: String, defaultEnabled: Bool)] = [
        // Default-on set is intentionally limited to two situations: the agent
        // has finished working (finished / failed / response_failed) and the
        // agent is waiting on the user (permission / waiting_input /
        // attention_required / elicitation). Mid-run noise (tool_failed) and the
        // idle heuristic stay off by default — explicit waiting_input/permission
        // hooks cover "needs me", so idle would only double up with noise.
        ("finished", "Response complete", "finished responding.", true),
        ("failed", "Task failed", "failed or exited with an error.", true),
        ("permission", "Permission request", "needs permission to continue.", true),
        ("waiting_input", "Waiting for input", "is waiting for your input.", true),
        ("attention_required", "Needs attention", "needs your attention.", true),
        ("tool_failed", "Tool failed", "tool execution failed.", false),
        ("response_failed", "Response failed", "response ended with an error.", true),
        ("elicitation", "MCP input request", "MCP server requesting user input.", true),
        ("authentication_succeeded", "Authentication complete", "completed authentication.", false),
        ("idle", "Session idle", "session appears idle.", false),
        ("token_threshold", "Token threshold", "Token usage exceeded threshold.", false),
        ("cost_threshold", "Cost threshold", "Session cost exceeded threshold.", false),
        ("tool_called", "Tool called", "called a tool.", false),
        ("file_edited", "File edited", "edited a file.", false),
        ("error", "Error occurred", "encountered an error.", false),
        ("context_limit", "Context limit", "approaching context window limit.", false),
        (wildcardType, "Other events", "event types.", false)
    ]

    /// AI sources that share the same trigger structure, derived from
    /// `AIToolRegistry.allTools` (every tool with an event source, in registry
    /// order) plus the runtime agent — adding a tool to the registry adds its
    /// notification source, triggers, and localization keys automatically.
    /// (source, notification display name, camelCase key for localization)
    private static let aiSources: [(source: AIEventSource, name: String, camelCase: String)] =
        AIToolRegistry.allTools.compactMap { tool in
            guard let source = tool.eventSource, let camel = tool.eventSourceCamelKey else { return nil }
            return (source, tool.notificationDisplayName, camel)
        } + [(.runtime, "Runtime Agent", "runtime")]

    /// All AI triggers generated from the source × type matrix.
    private static let aiTriggers: [NotificationTrigger] = aiSources.flatMap { src in
        aiTriggerTypes.map { tt in
            NotificationTrigger(
                source: src.source,
                type: tt.type,
                labelKey: "notifications.trigger.\(src.camelCase).\(typeCamelKey(tt.type)).label",
                labelFallback: tt.type == wildcardType
                    ? "Other \(src.name) events"
                    : tt.labelSuffix,
                descriptionKey: "notifications.trigger.\(src.camelCase).\(typeCamelKey(tt.type)).description",
                descriptionFallback: tt.type == wildcardType
                    ? "Any other \(src.name) event types."
                    : "\(src.name) \(tt.descSuffix)",
                defaultEnabled: tt.defaultEnabled,
                displayContexts: [.settings, .activity]
            )
        }
    }

    // MARK: - Non-AI Triggers (unique types and descriptions)

    /// One row of a per-source trigger table: `(type, label, description)`
    /// plus defaults. Localization keys are derived mechanically as
    /// `notifications.trigger.<sourceCamel>.<typeCamel>.label` /
    /// `.description` — the exact convention every previously hand-written
    /// entry already followed. `NotificationTriggerCatalogGoldenTests` pins
    /// the full derived key set byte-for-byte.
    private struct TriggerSpec {
        let type: String
        let label: String
        let description: String
        let defaultEnabled: Bool
        let displayContexts: NotificationTriggerDisplay

        init(
            _ type: String,
            _ label: String,
            _ description: String,
            defaultEnabled: Bool = false,
            displayContexts: NotificationTriggerDisplay = [.settings, .activity]
        ) {
            self.type = type
            self.label = label
            self.description = description
            self.defaultEnabled = defaultEnabled
            self.displayContexts = displayContexts
        }
    }

    /// Expands a source's spec table into catalog triggers with derived keys.
    private static func buildTriggers(
        source: AIEventSource,
        sourceCamel: String,
        _ specs: [TriggerSpec]
    ) -> [NotificationTrigger] {
        specs.map { spec in
            NotificationTrigger(
                source: source,
                type: spec.type,
                labelKey: "notifications.trigger.\(sourceCamel).\(typeCamelKey(spec.type)).label",
                labelFallback: spec.label,
                descriptionKey: "notifications.trigger.\(sourceCamel).\(typeCamelKey(spec.type)).description",
                descriptionFallback: spec.description,
                defaultEnabled: spec.defaultEnabled,
                displayContexts: spec.displayContexts
            )
        }
    }

    private static let eventsLogTriggers: [NotificationTrigger] = buildTriggers(source: .eventsLog, sourceCamel: "eventsLog", [
        .init("finished", "Task finished", "An AI event reports a completed task.", defaultEnabled: true),
        .init("failed", "Task failed", "An AI event reports a failure or error.", defaultEnabled: true),
        .init("needs_validation", "Needs validation", "An AI event requests review or confirmation."),
        .init("permission", "Permission request", "An AI event requests permission to proceed.", defaultEnabled: true),
        .init("tool_complete", "Tool complete", "An AI event reports a tool finished executing."),
        .init("session_end", "Session ended", "An AI event reports a session ended."),
        .init("idle", "Command idle", "An AI event reports inactivity or waiting for input."),
        .init("notification", "Custom notification", "An AI event requests a custom notification."),
        .init(wildcardType, "Other events", "Any other AI event types not listed above.")
    ])

    private static let terminalSessionTriggers: [NotificationTrigger] = buildTriggers(source: .terminalSession, sourceCamel: "terminalSession", [
        .init("finished", "AI tool finished", "An AI tool finished in the terminal.", defaultEnabled: true),
        .init("permission", "AI tool needs permission", "An AI tool in the terminal needs permission to continue.", defaultEnabled: true),
        .init("idle", "Command idle", "Terminal command produced no output for the idle timeout."),
        .init("failed", "Shell exited", "Terminal shell process exited.", defaultEnabled: true),
        .init("info", "AI tool started", "An AI tool started in the terminal.")
    ])

    private static let historyMonitorTriggers: [NotificationTrigger] = buildTriggers(source: .historyMonitor, sourceCamel: "historyMonitor", [
        .init("finished", "Session completed (history)", "AI session completed as detected by history file monitoring.", defaultEnabled: true),
        .init("idle", "History idle", "No new history entries for the idle timeout.")
    ])

    private static let shellTriggers: [NotificationTrigger] = buildTriggers(source: .shell, sourceCamel: "shell", [
        // command_finished / command_failed are off by default: plain shell
        // command completion or a non-zero exit is not an agent event and
        // would notify on every command. Opt in from settings.
        .init("command_finished", "Command finished", "A shell command completed execution."),
        .init("command_failed", "Command failed", "A shell command exited with non-zero status."),
        .init("exit_code_match", "Exit code match", "Command exited with a specific exit code."),
        .init("pattern_match", "Output pattern match", "Command output matched a configured pattern."),
        .init("long_running", "Long-running command", "Command has been running longer than threshold."),
        .init("process_started", "Process started", "A new process was started in the shell."),
        .init("process_ended", "Process ended", "A shell process has terminated."),
        .init("directory_changed", "Directory changed", "Working directory was changed (cd)."),
        .init("git_branch_changed", "Git branch changed", "Git branch was switched or changed."),
        .init(wildcardType, "Other shell events", "Any other shell event types.")
    ])

    private static let appTriggers: [NotificationTrigger] = buildTriggers(source: .app, sourceCamel: "app", [
        .init("launch", "App launched", "The app was launched."),
        .init("update_available", "Update available", "A new version is available.", defaultEnabled: true),
        .init("file_conflict", "File conflict detected", "Multiple tabs modified the same file, risking merge conflicts.", defaultEnabled: true),
        .init("memory_threshold", "Memory threshold", "Memory usage exceeded threshold."),
        .init("tab_opened", "Tab opened", "A new tab was opened."),
        .init("tab_closed", "Tab closed", "A tab was closed."),
        // The following triggers have no event emitters yet — hidden from settings, visible in activity only.
        .init("window_focused", "Window focused", "App window gained focus.", displayContexts: [.activity]),
        .init("window_unfocused", "Window unfocused", "App window lost focus.", displayContexts: [.activity]),
        .init("file_modified", "File modified", "A watched file was modified.", displayContexts: [.activity]),
        .init("docker_event", "Docker event", "A Docker container event occurred.", displayContexts: [.activity]),
        .init(wildcardType, "Other app events", "Any other app event types.")
    ])

    // MARK: - Catch-All Triggers (sources without dedicated trigger sets)

    private static let apiProxyTriggers: [NotificationTrigger] = buildTriggers(source: .apiProxy, sourceCamel: "apiProxy", [
        .init(wildcardType, "API Proxy events", "Any event from the API proxy.")
    ])

    private static let unknownSourceTriggers: [NotificationTrigger] = buildTriggers(source: .unknown, sourceCamel: "unknown", [
        .init(wildcardType, "Unknown source events", "Events from unrecognized sources.")
    ])

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
        // Shares the semantic mapping's normalizer (snake-cases hyphens and
        // spaces): a "tool-failed" spelling used to match the semantic kind
        // mapping but MISS the catalog lookup because this helper only
        // trimmed and lowercased — the two vocabularies must agree.
        NotificationSemanticMapping.normalize(type)
    }
}
