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
    case webhook = "webhook"
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

    public var id: String { rawValue }
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

    public var id: String { type.rawValue }

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
    case basic = "basic"
    case automation = "automation"
    case integration = "integration"
    case devops = "devops"
    case productivity = "productivity"
    case accessibility = "accessibility"
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

    public static let all: [NotificationActionInfo] = [
        // MARK: Basic Actions
        NotificationActionInfo(
            type: .showNotification,
            labelKey: "action.showNotification.label",
            labelFallback: "Show Notification",
            descriptionKey: "action.showNotification.description",
            descriptionFallback: "Display a macOS notification with title and message",
            icon: "bell.badge",
            category: .basic,
            requiresConfig: false,
            configFields: [
                ActionConfigField(id: "customTitle", labelKey: "action.field.customTitle", labelFallback: "Custom Title", type: .text, placeholder: "Leave empty for default"),
                ActionConfigField(id: "customBody", labelKey: "action.field.customBody", labelFallback: "Custom Message", type: .textArea, placeholder: "Use ${message}, ${type}, ${tool} variables")
            ]
        ),
        NotificationActionInfo(
            type: .playSound,
            labelKey: "action.playSound.label",
            labelFallback: "Play Sound",
            descriptionKey: "action.playSound.description",
            descriptionFallback: "Play a custom sound effect",
            icon: "speaker.wave.3",
            category: .basic,
            requiresConfig: true,
            configFields: [
                ActionConfigField(id: "sound", labelKey: "action.field.sound", labelFallback: "Sound", type: .soundPicker, required: true, defaultValue: "default"),
                ActionConfigField(id: "volume", labelKey: "action.field.volume", labelFallback: "Volume", type: .number, defaultValue: "100", placeholder: "0-100")
            ]
        ),
        NotificationActionInfo(
            type: .focusWindow,
            labelKey: "action.focusWindow.label",
            labelFallback: "Focus Window",
            descriptionKey: "action.focusWindow.description",
            descriptionFallback: "Bring the app window to the front and focus the relevant tab",
            icon: "macwindow",
            category: .basic,
            configFields: [
                ActionConfigField(id: "focusTab", labelKey: "action.field.focusTab", labelFallback: "Focus Source Tab", type: .toggle, defaultValue: "true")
            ]
        ),
        NotificationActionInfo(
            type: .dockBounce,
            labelKey: "action.dockBounce.label",
            labelFallback: "Dock Bounce",
            descriptionKey: "action.dockBounce.description",
            descriptionFallback: "Bounce the dock icon to attract attention",
            icon: "arrow.up.arrow.down",
            category: .basic,
            configFields: [
                ActionConfigField(id: "critical", labelKey: "action.field.critical", labelFallback: "Critical (continuous bounce)", type: .toggle, defaultValue: "false")
            ]
        ),
        NotificationActionInfo(
            type: .badgeTab,
            labelKey: "action.badgeTab.label",
            labelFallback: "Badge Tab",
            descriptionKey: "action.badgeTab.description",
            descriptionFallback: "Show a badge indicator on the source tab",
            icon: "tag.circle",
            category: .basic,
            configFields: [
                ActionConfigField(id: "badgeText", labelKey: "action.field.badgeText", labelFallback: "Badge Text", type: .text, placeholder: "! or custom text"),
                ActionConfigField(id: "badgeColor", labelKey: "action.field.badgeColor", labelFallback: "Badge Color", type: .picker, defaultValue: "red", options: [
                    ConfigOption(id: "red", label: "Red"),
                    ConfigOption(id: "orange", label: "Orange"),
                    ConfigOption(id: "yellow", label: "Yellow"),
                    ConfigOption(id: "green", label: "Green"),
                    ConfigOption(id: "blue", label: "Blue")
                ])
            ]
        ),
        NotificationActionInfo(
            type: .styleTab,
            labelKey: "action.styleTab.label",
            labelFallback: "Style Tab",
            descriptionKey: "action.styleTab.description",
            descriptionFallback: "Apply visual styling to the tab (color, italic, pulse animation)",
            icon: "paintbrush",
            category: .basic,
            configFields: [
                ActionConfigField(id: "style", labelKey: "action.field.style", labelFallback: "Style Preset", type: .picker, defaultValue: "waiting", options: [
                    ConfigOption(id: "waiting", label: "Waiting (orange italic + pulse)"),
                    ConfigOption(id: "error", label: "Error (red bold)"),
                    ConfigOption(id: "success", label: "Success (green)"),
                    ConfigOption(id: "attention", label: "Attention (yellow bold + pulse)"),
                    ConfigOption(id: "clear", label: "Clear Style")
                ]),
                ActionConfigField(id: "customColor", labelKey: "action.field.customColor", labelFallback: "Custom Color (optional)", type: .picker, options: [
                    ConfigOption(id: "", label: "Use preset"),
                    ConfigOption(id: "red", label: "Red"),
                    ConfigOption(id: "orange", label: "Orange"),
                    ConfigOption(id: "yellow", label: "Yellow"),
                    ConfigOption(id: "green", label: "Green"),
                    ConfigOption(id: "blue", label: "Blue"),
                    ConfigOption(id: "purple", label: "Purple"),
                    ConfigOption(id: "pink", label: "Pink")
                ]),
                ActionConfigField(id: "italic", labelKey: "action.field.italic", labelFallback: "Italic", type: .toggle, defaultValue: "false"),
                ActionConfigField(id: "bold", labelKey: "action.field.bold", labelFallback: "Bold", type: .toggle, defaultValue: "false"),
                ActionConfigField(id: "pulse", labelKey: "action.field.pulse", labelFallback: "Pulse Animation", type: .toggle, defaultValue: "false"),
                ActionConfigField(id: "autoClearSeconds", labelKey: "action.field.autoClearSeconds", labelFallback: "Auto-clear after (seconds)", type: .number, placeholder: "0 = never")
            ]
        ),

        // MARK: Automation Actions
        NotificationActionInfo(
            type: .runScript,
            labelKey: "action.runScript.label",
            labelFallback: "Run Script",
            descriptionKey: "action.runScript.description",
            descriptionFallback: "Execute a shell script or command with event data as environment variables",
            icon: "terminal",
            category: .automation,
            requiresConfig: true,
            configFields: [
                ActionConfigField(id: "script", labelKey: "action.field.script", labelFallback: "Script/Command", type: .textArea, required: true, placeholder: "echo \"Task $CHAU7_TYPE completed\""),
                ActionConfigField(id: "shell", labelKey: "action.field.shell", labelFallback: "Shell", type: .picker, defaultValue: "/bin/zsh", options: [
                    ConfigOption(id: "/bin/zsh", label: "zsh"),
                    ConfigOption(id: "/bin/bash", label: "bash"),
                    ConfigOption(id: "/bin/sh", label: "sh")
                ]),
                ActionConfigField(id: "timeout", labelKey: "action.field.timeout", labelFallback: "Timeout (seconds)", type: .number, defaultValue: "30"),
                ActionConfigField(id: "workingDir", labelKey: "action.field.workingDir", labelFallback: "Working Directory", type: .filePath, placeholder: "Default: event source directory")
            ]
        ),
        NotificationActionInfo(
            type: .runShortcut,
            labelKey: "action.runShortcut.label",
            labelFallback: "Run Shortcut",
            descriptionKey: "action.runShortcut.description",
            descriptionFallback: "Execute a macOS Shortcut with event data as input",
            icon: "square.on.square.badge.person.crop",
            category: .automation,
            requiresConfig: true,
            configFields: [
                ActionConfigField(id: "shortcutName", labelKey: "action.field.shortcutName", labelFallback: "Shortcut Name", type: .text, required: true, placeholder: "My Shortcut"),
                ActionConfigField(id: "passEventData", labelKey: "action.field.passEventData", labelFallback: "Pass Event Data", type: .toggle, defaultValue: "true")
            ]
        ),
        NotificationActionInfo(
            type: .executeSnippet,
            labelKey: "action.executeSnippet.label",
            labelFallback: "Execute Snippet",
            descriptionKey: "action.executeSnippet.description",
            descriptionFallback: "Run a saved snippet in the source terminal tab",
            icon: "doc.text",
            category: .automation,
            requiresConfig: true,
            configFields: [
                ActionConfigField(id: "snippetId", labelKey: "action.field.snippetId", labelFallback: "Snippet ID", type: .text, required: true, placeholder: "my-snippet-id"),
                ActionConfigField(id: "autoExecute", labelKey: "action.field.autoExecute", labelFallback: "Auto Execute (press Enter)", type: .toggle, defaultValue: "false")
            ]
        ),

        // MARK: Integration Actions
        NotificationActionInfo(
            type: .webhook,
            labelKey: "action.webhook.label",
            labelFallback: "Webhook",
            descriptionKey: "action.webhook.description",
            descriptionFallback: "Send an HTTP request to a URL with event data as JSON payload",
            icon: "arrow.up.forward.app",
            category: .integration,
            requiresConfig: true,
            configFields: [
                ActionConfigField(id: "url", labelKey: "action.field.url", labelFallback: "Webhook URL", type: .text, required: true, placeholder: "https://example.com/webhook"),
                ActionConfigField(id: "method", labelKey: "action.field.method", labelFallback: "HTTP Method", type: .picker, defaultValue: "POST", options: [
                    ConfigOption(id: "POST", label: "POST"),
                    ConfigOption(id: "PUT", label: "PUT"),
                    ConfigOption(id: "GET", label: "GET")
                ]),
                ActionConfigField(id: "headers", labelKey: "action.field.headers", labelFallback: "Headers (JSON)", type: .textArea, placeholder: "{\"Authorization\": \"Bearer token\"}"),
                ActionConfigField(id: "customPayload", labelKey: "action.field.customPayload", labelFallback: "Custom Payload (JSON)", type: .textArea, placeholder: "Leave empty for default event JSON")
            ]
        ),
        NotificationActionInfo(
            type: .sendSlack,
            labelKey: "action.sendSlack.label",
            labelFallback: "Send to Slack",
            descriptionKey: "action.sendSlack.description",
            descriptionFallback: "Post a message to a Slack channel via webhook",
            icon: "bubble.left.and.bubble.right",
            category: .integration,
            requiresConfig: true,
            configFields: [
                ActionConfigField(id: "webhookUrl", labelKey: "action.field.webhookUrl", labelFallback: "Slack Webhook URL", type: .secretText, required: true, placeholder: "https://hooks.slack.com/services/..."),
                ActionConfigField(id: "channel", labelKey: "action.field.channel", labelFallback: "Channel Override", type: .text, placeholder: "#general"),
                ActionConfigField(id: "username", labelKey: "action.field.username", labelFallback: "Bot Username", type: .text, defaultValue: "Chau7"),
                ActionConfigField(id: "emoji", labelKey: "action.field.emoji", labelFallback: "Bot Emoji", type: .text, defaultValue: ":computer:")
            ]
        ),
        NotificationActionInfo(
            type: .sendDiscord,
            labelKey: "action.sendDiscord.label",
            labelFallback: "Send to Discord",
            descriptionKey: "action.sendDiscord.description",
            descriptionFallback: "Post a message to a Discord channel via webhook",
            icon: "bubble.left.and.bubble.right.fill",
            category: .integration,
            requiresConfig: true,
            configFields: [
                ActionConfigField(id: "webhookUrl", labelKey: "action.field.webhookUrl", labelFallback: "Discord Webhook URL", type: .secretText, required: true, placeholder: "https://discord.com/api/webhooks/..."),
                ActionConfigField(id: "username", labelKey: "action.field.username", labelFallback: "Bot Username", type: .text, defaultValue: "Chau7"),
                ActionConfigField(id: "avatarUrl", labelKey: "action.field.avatarUrl", labelFallback: "Avatar URL", type: .text, placeholder: "https://example.com/avatar.png")
            ]
        ),

        // MARK: DevOps Actions
        NotificationActionInfo(
            type: .dockerBump,
            labelKey: "action.dockerBump.label",
            labelFallback: "Docker Bump",
            descriptionKey: "action.dockerBump.description",
            descriptionFallback: "Restart a Docker container or rebuild and restart",
            icon: "shippingbox",
            category: .devops,
            requiresConfig: true,
            configFields: [
                ActionConfigField(id: "container", labelKey: "action.field.container", labelFallback: "Container Name/ID", type: .text, required: true, placeholder: "my-container"),
                ActionConfigField(id: "operation", labelKey: "action.field.operation", labelFallback: "Operation", type: .picker, defaultValue: "restart", options: [
                    ConfigOption(id: "restart", label: "Restart"),
                    ConfigOption(id: "stop", label: "Stop"),
                    ConfigOption(id: "start", label: "Start"),
                    ConfigOption(id: "rebuild", label: "Rebuild & Restart")
                ]),
                ActionConfigField(id: "dockerPath", labelKey: "action.field.dockerPath", labelFallback: "Docker Path", type: .filePath, defaultValue: "/usr/local/bin/docker")
            ]
        ),
        NotificationActionInfo(
            type: .dockerCompose,
            labelKey: "action.dockerCompose.label",
            labelFallback: "Docker Compose",
            descriptionKey: "action.dockerCompose.description",
            descriptionFallback: "Run docker-compose commands (up, down, restart, etc.)",
            icon: "square.stack.3d.up",
            category: .devops,
            requiresConfig: true,
            configFields: [
                ActionConfigField(id: "composePath", labelKey: "action.field.composePath", labelFallback: "docker-compose.yml Path", type: .filePath, required: true, placeholder: "/path/to/docker-compose.yml"),
                ActionConfigField(id: "operation", labelKey: "action.field.operation", labelFallback: "Operation", type: .picker, defaultValue: "restart", options: [
                    ConfigOption(id: "up", label: "Up (detached)"),
                    ConfigOption(id: "down", label: "Down"),
                    ConfigOption(id: "restart", label: "Restart"),
                    ConfigOption(id: "build", label: "Build"),
                    ConfigOption(id: "pull", label: "Pull")
                ]),
                ActionConfigField(id: "services", labelKey: "action.field.services", labelFallback: "Services (comma-separated)", type: .text, placeholder: "Leave empty for all services")
            ]
        ),
        NotificationActionInfo(
            type: .kubernetesRollout,
            labelKey: "action.kubernetesRollout.label",
            labelFallback: "Kubernetes Rollout",
            descriptionKey: "action.kubernetesRollout.description",
            descriptionFallback: "Trigger a Kubernetes deployment rollout restart",
            icon: "helm",
            category: .devops,
            requiresConfig: true,
            configFields: [
                ActionConfigField(id: "deployment", labelKey: "action.field.deployment", labelFallback: "Deployment Name", type: .text, required: true, placeholder: "my-deployment"),
                ActionConfigField(id: "namespace", labelKey: "action.field.namespace", labelFallback: "Namespace", type: .text, defaultValue: "default"),
                ActionConfigField(id: "context", labelKey: "action.field.context", labelFallback: "kubectl Context", type: .text, placeholder: "Leave empty for current context"),
                ActionConfigField(id: "operation", labelKey: "action.field.operation", labelFallback: "Operation", type: .picker, defaultValue: "restart", options: [
                    ConfigOption(id: "restart", label: "Rollout Restart"),
                    ConfigOption(id: "scale", label: "Scale (requires replicas)"),
                    ConfigOption(id: "status", label: "Check Status")
                ]),
                ActionConfigField(id: "replicas", labelKey: "action.field.replicas", labelFallback: "Replicas (for scale)", type: .number, placeholder: "3")
            ]
        ),

        // MARK: Productivity Actions
        NotificationActionInfo(
            type: .copyToClipboard,
            labelKey: "action.copyToClipboard.label",
            labelFallback: "Copy to Clipboard",
            descriptionKey: "action.copyToClipboard.description",
            descriptionFallback: "Copy event message or custom text to the clipboard",
            icon: "doc.on.clipboard",
            category: .productivity,
            configFields: [
                ActionConfigField(id: "content", labelKey: "action.field.content", labelFallback: "Content to Copy", type: .textArea, placeholder: "Use ${message}, ${type}, ${tool} or leave empty for message")
            ]
        ),
        NotificationActionInfo(
            type: .writeToFile,
            labelKey: "action.writeToFile.label",
            labelFallback: "Write to File",
            descriptionKey: "action.writeToFile.description",
            descriptionFallback: "Append event data to a log file",
            icon: "doc.badge.plus",
            category: .productivity,
            requiresConfig: true,
            configFields: [
                ActionConfigField(id: "filePath", labelKey: "action.field.filePath", labelFallback: "File Path", type: .filePath, required: true, placeholder: "~/chau7-events.log"),
                ActionConfigField(id: "format", labelKey: "action.field.format", labelFallback: "Format", type: .picker, defaultValue: "text", options: [
                    ConfigOption(id: "text", label: "Text (one line per event)"),
                    ConfigOption(id: "json", label: "JSON (one object per line)"),
                    ConfigOption(id: "csv", label: "CSV")
                ]),
                ActionConfigField(id: "template", labelKey: "action.field.template", labelFallback: "Custom Template", type: .textArea, placeholder: "[${timestamp}] ${type}: ${message}")
            ]
        ),
        NotificationActionInfo(
            type: .openURL,
            labelKey: "action.openURL.label",
            labelFallback: "Open URL",
            descriptionKey: "action.openURL.description",
            descriptionFallback: "Open a URL in the default browser",
            icon: "safari",
            category: .productivity,
            requiresConfig: true,
            configFields: [
                ActionConfigField(id: "url", labelKey: "action.field.url", labelFallback: "URL", type: .text, required: true, placeholder: "https://example.com/dashboard?event=${type}"),
                ActionConfigField(id: "browser", labelKey: "action.field.browser", labelFallback: "Browser", type: .picker, defaultValue: "default", options: [
                    ConfigOption(id: "default", label: "System Default"),
                    ConfigOption(id: "safari", label: "Safari"),
                    ConfigOption(id: "chrome", label: "Chrome"),
                    ConfigOption(id: "firefox", label: "Firefox"),
                    ConfigOption(id: "arc", label: "Arc")
                ])
            ]
        ),
        NotificationActionInfo(
            type: .gitCommit,
            labelKey: "action.gitCommit.label",
            labelFallback: "Git Commit",
            descriptionKey: "action.gitCommit.description",
            descriptionFallback: "Auto-commit changes in the working directory",
            icon: "arrow.triangle.branch",
            category: .productivity,
            requiresConfig: true,
            configFields: [
                ActionConfigField(id: "message", labelKey: "action.field.message", labelFallback: "Commit Message", type: .text, defaultValue: "Auto-commit: ${type} - ${message}"),
                ActionConfigField(id: "addAll", labelKey: "action.field.addAll", labelFallback: "Stage All Changes", type: .toggle, defaultValue: "true"),
                ActionConfigField(id: "push", labelKey: "action.field.push", labelFallback: "Push After Commit", type: .toggle, defaultValue: "false"),
                ActionConfigField(id: "repoPath", labelKey: "action.field.repoPath", labelFallback: "Repository Path", type: .filePath, placeholder: "Default: event source directory")
            ]
        ),

        // MARK: Accessibility Actions
        NotificationActionInfo(
            type: .voiceAnnounce,
            labelKey: "action.voiceAnnounce.label",
            labelFallback: "Voice Announcement",
            descriptionKey: "action.voiceAnnounce.description",
            descriptionFallback: "Read the notification aloud using macOS text-to-speech",
            icon: "speaker.wave.2.bubble.left",
            category: .accessibility,
            configFields: [
                ActionConfigField(id: "text", labelKey: "action.field.text", labelFallback: "Text to Speak", type: .textArea, placeholder: "Use ${message}, ${type} or leave empty for default"),
                ActionConfigField(id: "voice", labelKey: "action.field.voice", labelFallback: "Voice", type: .picker, defaultValue: "default", options: [
                    ConfigOption(id: "default", label: "System Default"),
                    ConfigOption(id: "Alex", label: "Alex"),
                    ConfigOption(id: "Samantha", label: "Samantha"),
                    ConfigOption(id: "Victoria", label: "Victoria"),
                    ConfigOption(id: "Daniel", label: "Daniel (UK)"),
                    ConfigOption(id: "Karen", label: "Karen (AU)")
                ]),
                ActionConfigField(id: "rate", labelKey: "action.field.rate", labelFallback: "Speech Rate", type: .number, defaultValue: "175", placeholder: "150-250 words per minute")
            ]
        ),
        NotificationActionInfo(
            type: .flashScreen,
            labelKey: "action.flashScreen.label",
            labelFallback: "Flash Screen",
            descriptionKey: "action.flashScreen.description",
            descriptionFallback: "Briefly flash the screen for visual attention (accessibility feature)",
            icon: "lightbulb.max",
            category: .accessibility,
            configFields: [
                ActionConfigField(id: "color", labelKey: "action.field.color", labelFallback: "Flash Color", type: .picker, defaultValue: "white", options: [
                    ConfigOption(id: "white", label: "White"),
                    ConfigOption(id: "yellow", label: "Yellow"),
                    ConfigOption(id: "red", label: "Red"),
                    ConfigOption(id: "green", label: "Green"),
                    ConfigOption(id: "blue", label: "Blue")
                ]),
                ActionConfigField(id: "duration", labelKey: "action.field.duration", labelFallback: "Duration (ms)", type: .number, defaultValue: "200"),
                ActionConfigField(id: "count", labelKey: "action.field.count", labelFallback: "Flash Count", type: .number, defaultValue: "2")
            ]
        ),
        NotificationActionInfo(
            type: .menuBarAlert,
            labelKey: "action.menuBarAlert.label",
            labelFallback: "Menu Bar Alert",
            descriptionKey: "action.menuBarAlert.description",
            descriptionFallback: "Show a temporary alert badge in the menu bar icon",
            icon: "menubar.arrow.up.rectangle",
            category: .accessibility,
            configFields: [
                ActionConfigField(id: "duration", labelKey: "action.field.duration", labelFallback: "Duration (seconds)", type: .number, defaultValue: "5"),
                ActionConfigField(id: "animate", labelKey: "action.field.animate", labelFallback: "Animate Icon", type: .toggle, defaultValue: "true")
            ]
        ),

        // MARK: Time Tracking Actions
        NotificationActionInfo(
            type: .startTimer,
            labelKey: "action.startTimer.label",
            labelFallback: "Start Timer",
            descriptionKey: "action.startTimer.description",
            descriptionFallback: "Start a time tracking timer for the current task",
            icon: "play.circle",
            category: .timeTracking,
            configFields: [
                ActionConfigField(id: "timerName", labelKey: "action.field.timerName", labelFallback: "Timer Name", type: .text, placeholder: "Use ${tool} or ${type} for dynamic names"),
                ActionConfigField(id: "project", labelKey: "action.field.project", labelFallback: "Project", type: .text, placeholder: "Project name for grouping")
            ]
        ),
        NotificationActionInfo(
            type: .stopTimer,
            labelKey: "action.stopTimer.label",
            labelFallback: "Stop Timer",
            descriptionKey: "action.stopTimer.description",
            descriptionFallback: "Stop the currently running timer",
            icon: "stop.circle",
            category: .timeTracking,
            configFields: [
                ActionConfigField(id: "timerName", labelKey: "action.field.timerName", labelFallback: "Timer Name", type: .text, placeholder: "Leave empty to stop the most recent timer")
            ]
        ),
        NotificationActionInfo(
            type: .logTime,
            labelKey: "action.logTime.label",
            labelFallback: "Log Time Entry",
            descriptionKey: "action.logTime.description",
            descriptionFallback: "Log a time entry to a file or time tracking service",
            icon: "clock.badge.checkmark",
            category: .timeTracking,
            requiresConfig: true,
            configFields: [
                ActionConfigField(id: "service", labelKey: "action.field.service", labelFallback: "Service", type: .picker, defaultValue: "file", options: [
                    ConfigOption(id: "file", label: "Local File"),
                    ConfigOption(id: "toggl", label: "Toggl Track"),
                    ConfigOption(id: "clockify", label: "Clockify")
                ]),
                ActionConfigField(id: "apiKey", labelKey: "action.field.apiKey", labelFallback: "API Key", type: .secretText, placeholder: "Required for Toggl/Clockify"),
                ActionConfigField(id: "filePath", labelKey: "action.field.filePath", labelFallback: "Log File Path", type: .filePath, placeholder: "~/time-log.csv"),
                ActionConfigField(id: "description", labelKey: "action.field.description", labelFallback: "Entry Description", type: .text, defaultValue: "${type}: ${message}")
            ]
        )
    ]

    public static func action(for type: NotificationActionType) -> NotificationActionInfo? {
        all.first { $0.type == type }
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
