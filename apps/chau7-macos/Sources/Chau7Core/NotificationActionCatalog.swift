import Foundation

// MARK: - Action Types

/// All available notification actions
public enum NotificationActionType: String, Codable, CaseIterable, Identifiable, Sendable {
    // Basic actions
    case showNotification = "show_notification"
    case playSound = "play_sound"
    case focusWindow = "focus_window"
    case dockBounce = "dock_bounce"
    case badgeTab = "badge_tab"
    case styleTab = "style_tab"

    // Script & automation
    case runScript = "run_script"
    case runShortcut = "run_shortcut"
    case executeSnippet = "execute_snippet"

    // Network & integration
    case webhook
    case sendSlack = "send_slack"
    case sendDiscord = "send_discord"

    // Docker & DevOps
    case dockerBump = "docker_bump"
    case dockerCompose = "docker_compose"
    case kubernetesRollout = "kubernetes_rollout"

    // Productivity
    case copyToClipboard = "copy_to_clipboard"
    case writeToFile = "write_to_file"
    case openURL = "open_url"
    case gitCommit = "git_commit"

    // Accessibility & UX
    case voiceAnnounce = "voice_announce"
    case flashScreen = "flash_screen"
    case menuBarAlert = "menu_bar_alert"

    // Time tracking
    case startTimer = "start_timer"
    case stopTimer = "stop_timer"
    case logTime = "log_time"

    public var id: String {
        rawValue
    }

    /// Whether this action appears as a primary toggle in the AI-coding
    /// notification-settings panel (the quick-switches next to each
    /// notification-kind row). All other actions are "extras" — the user
    /// opts into them through the Advanced editor.
    ///
    /// Declared here (on the enum) rather than as a hardcoded `Set` in
    /// `AINotificationSettingsBridge` so Swift forces every future case
    /// to be categorized via exhaustive switch. Pre-W3.8 the set was
    /// four literals and a new action added to the catalog had to be
    /// manually echoed in the bridge.
    public var isAICodingPrimary: Bool {
        switch self {
        case .showNotification, .styleTab, .playSound, .dockBounce:
            return true
        case .focusWindow, .badgeTab, .runScript, .runShortcut, .executeSnippet,
             .webhook, .sendSlack, .sendDiscord, .dockerBump, .dockerCompose,
             .kubernetesRollout, .copyToClipboard, .writeToFile, .openURL,
             .gitCommit, .voiceAnnounce, .flashScreen, .menuBarAlert,
             .startTimer, .stopTimer, .logTime:
            return false
        }
    }
}

// MARK: - Action Metadata

public struct NotificationActionInfo: Identifiable, Equatable, Sendable {
    public let type: NotificationActionType
    public let labelKey: String
    public let labelFallback: String
    public let descriptionKey: String
    public let descriptionFallback: String
    public let icon: String
    public let category: ActionCategory
    public let requiresConfig: Bool
    public let configFields: [ActionConfigField]

    public var id: String {
        type.rawValue
    }

    public init(
        type: NotificationActionType,
        labelKey: String,
        labelFallback: String,
        descriptionKey: String,
        descriptionFallback: String,
        icon: String,
        category: ActionCategory,
        requiresConfig: Bool = false,
        configFields: [ActionConfigField] = []
    ) {
        self.type = type
        self.labelKey = labelKey
        self.labelFallback = labelFallback
        self.descriptionKey = descriptionKey
        self.descriptionFallback = descriptionFallback
        self.icon = icon
        self.category = category
        self.requiresConfig = requiresConfig
        self.configFields = configFields
    }
}

public enum ActionCategory: String, Codable, CaseIterable, Sendable {
    case basic
    case automation
    case integration
    case devops
    case productivity
    case accessibility
    case timeTracking = "time_tracking"

    public var displayName: String {
        switch self {
        case .basic: return "Basic"
        case .automation: return "Automation"
        case .integration: return "Integrations"
        case .devops: return "DevOps"
        case .productivity: return "Productivity"
        case .accessibility: return "Accessibility"
        case .timeTracking: return "Time Tracking"
        }
    }

    public var icon: String {
        switch self {
        case .basic: return "bell"
        case .automation: return "gearshape.2"
        case .integration: return "network"
        case .devops: return "server.rack"
        case .productivity: return "tray.full"
        case .accessibility: return "accessibility"
        case .timeTracking: return "clock"
        }
    }
}

// MARK: - Action Configuration

public struct ActionConfigField: Identifiable, Equatable, Sendable {
    public let id: String
    public let labelKey: String
    public let labelFallback: String
    public let type: ConfigFieldType
    public let required: Bool
    public let defaultValue: String?
    public let placeholder: String?
    public let options: [ConfigOption]?

    public init(
        id: String,
        labelKey: String,
        labelFallback: String,
        type: ConfigFieldType,
        required: Bool = false,
        defaultValue: String? = nil,
        placeholder: String? = nil,
        options: [ConfigOption]? = nil
    ) {
        self.id = id
        self.labelKey = labelKey
        self.labelFallback = labelFallback
        self.type = type
        self.required = required
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.options = options
    }
}

public enum ConfigFieldType: String, Codable, Sendable {
    case text
    case textArea
    case number
    case toggle
    case picker
    case filePath
    case soundPicker
    case secretText
}

public struct ConfigOption: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

// MARK: - Action Instance Configuration

public struct NotificationActionConfig: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let actionType: NotificationActionType
    public var enabled: Bool
    public var config: [String: String]

    public init(
        id: UUID = UUID(),
        actionType: NotificationActionType,
        enabled: Bool = true,
        config: [String: String] = [:]
    ) {
        self.id = id
        self.actionType = actionType
        self.enabled = enabled
        self.config = config
    }

    public func configValue(_ key: String) -> String? {
        config[key]
    }

    public func configBool(_ key: String, default defaultValue: Bool = false) -> Bool {
        guard let value = config[key] else { return defaultValue }
        return value.lowercased() == "true" || value == "1"
    }

    public func configInt(_ key: String, default defaultValue: Int = 0) -> Int {
        guard let value = config[key] else { return defaultValue }
        return Int(value) ?? defaultValue
    }
}

// MARK: - Trigger Action Binding

public struct TriggerActionBinding: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let triggerId: String
    public var actions: [NotificationActionConfig]

    public init(
        id: UUID = UUID(),
        triggerId: String,
        actions: [NotificationActionConfig] = []
    ) {
        self.id = id
        self.triggerId = triggerId
        self.actions = actions
    }
}

// MARK: - Action Catalog

public enum NotificationActionCatalog {

    /// O(1) lookup index (built once at first access)
    private static let index: [NotificationActionType: NotificationActionInfo] = Dictionary(uniqueKeysWithValues: all.map { ($0.type, $0) })

    public static func action(for type: NotificationActionType) -> NotificationActionInfo? {
        index[type]
    }

    public static func actions(in category: ActionCategory) -> [NotificationActionInfo] {
        all.filter { $0.category == category }
    }

    public static var byCategory: [(category: ActionCategory, actions: [NotificationActionInfo])] {
        ActionCategory.allCases.compactMap { category in
            let actions = actions(in: category)
            return actions.isEmpty ? nil : (category, actions)
        }
    }
}
