import Foundation
import AppKit
import SwiftUI
import Chau7Core

// Import Localization for AppLanguage
// Note: AppLanguage is defined in Localization.swift
// Note: TerminalColorScheme is defined in TerminalColorScheme.swift

// Notification.Name constants live in App/AppSignals.swift (central registry).

// MARK: - Keyboard Shortcut

struct KeyboardShortcut: Codable, Identifiable, Equatable {
    var id: String {
        action
    }

    let action: String
    var key: String
    var modifiers: [String] // ["cmd", "shift", "ctrl", "opt"]

    var displayString: String {
        var parts: [String] = []
        if modifiers.contains("ctrl") { parts.append("⌃") }
        if modifiers.contains("opt") { parts.append("⌥") }
        if modifiers.contains("shift") { parts.append("⇧") }
        if modifiers.contains("cmd") { parts.append("⌘") }
        parts.append(key.uppercased())
        return parts.joined()
    }

    static let defaultShortcuts: [KeyboardShortcut] = [
        // Standard macOS shortcuts (keep as ⌘)
        KeyboardShortcut(action: "newTab", key: "t", modifiers: ["cmd"]),
        KeyboardShortcut(action: "closeTab", key: "w", modifiers: ["cmd"]),
        KeyboardShortcut(action: "find", key: "f", modifiers: ["cmd"]),
        KeyboardShortcut(action: "findNext", key: "g", modifiers: ["cmd"]),
        KeyboardShortcut(action: "copy", key: "c", modifiers: ["cmd"]),
        KeyboardShortcut(action: "paste", key: "v", modifiers: ["cmd"]),
        KeyboardShortcut(action: "newWindow", key: "n", modifiers: ["cmd"]),
        KeyboardShortcut(action: "zoomIn", key: "=", modifiers: ["cmd"]),
        KeyboardShortcut(action: "zoomOut", key: "-", modifiers: ["cmd"]),
        KeyboardShortcut(action: "zoomReset", key: "0", modifiers: ["cmd"]),
        // Extended shortcuts
        KeyboardShortcut(action: "nextTab", key: "]", modifiers: ["cmd", "shift"]),
        KeyboardShortcut(action: "previousTab", key: "[", modifiers: ["cmd", "shift"]),
        KeyboardShortcut(action: "findPrevious", key: "g", modifiers: ["cmd", "shift"]),
        KeyboardShortcut(action: "clear", key: "k", modifiers: ["cmd", "opt"]),
        KeyboardShortcut(action: "snippets", key: "s", modifiers: ["cmd", "opt"]),
        KeyboardShortcut(action: "renameTab", key: "r", modifiers: ["cmd", "opt"]),
        KeyboardShortcut(action: "debugConsole", key: "l", modifiers: ["cmd", "opt"]),
        KeyboardShortcut(action: "splitHorizontal", key: "d", modifiers: ["cmd"]),
        KeyboardShortcut(action: "splitVertical", key: "d", modifiers: ["cmd", "opt"]),
        KeyboardShortcut(action: "openTextEditor", key: "e", modifiers: ["cmd", "opt"]),
        // Navigation
        KeyboardShortcut(action: "previousInputLine", key: "up", modifiers: ["cmd"]),
        KeyboardShortcut(action: "nextInputLine", key: "down", modifiers: ["cmd"]),
        // Recovery shortcut
        KeyboardShortcut(action: "refreshTabBar", key: "r", modifiers: ["cmd", "opt", "shift"])
    ]

    static func shortcuts(for preset: String) -> [KeyboardShortcut] {
        switch preset {
        case "vim":
            return applyOverrides(
                to: defaultShortcuts,
                overrides: [
                    "nextTab": KeyboardShortcut(action: "nextTab", key: "l", modifiers: ["ctrl"]),
                    "previousTab": KeyboardShortcut(action: "previousTab", key: "h", modifiers: ["ctrl"])
                ]
            )
        case "emacs":
            return applyOverrides(
                to: defaultShortcuts,
                overrides: [
                    "nextTab": KeyboardShortcut(action: "nextTab", key: "n", modifiers: ["ctrl"]),
                    "previousTab": KeyboardShortcut(action: "previousTab", key: "p", modifiers: ["ctrl"])
                ]
            )
        default:
            return defaultShortcuts
        }
    }

    private static func applyOverrides(
        to base: [KeyboardShortcut],
        overrides: [String: KeyboardShortcut]
    ) -> [KeyboardShortcut] {
        base.map { overrides[$0.action] ?? $0 }
    }

    static func actionDisplayName(_ action: String) -> String {
        switch action {
        case "newTab": return L("shortcut.action.newTab", "New Tab")
        case "closeTab": return L("shortcut.action.closeTab", "Close Tab")
        case "nextTab": return L("shortcut.action.nextTab", "Next Tab")
        case "previousTab": return L("shortcut.action.previousTab", "Previous Tab")
        case "find": return L("shortcut.action.find", "Find")
        case "findNext": return L("shortcut.action.findNext", "Find Next")
        case "findPrevious": return L("shortcut.action.findPrevious", "Find Previous")
        case "copy": return L("shortcut.action.copy", "Copy")
        case "paste": return L("shortcut.action.paste", "Paste")
        case "clear": return L("shortcut.action.clearScrollback", "Clear Scrollback")
        case "zoomIn": return L("shortcut.action.zoomIn", "Zoom In")
        case "zoomOut": return L("shortcut.action.zoomOut", "Zoom Out")
        case "zoomReset": return L("shortcut.action.zoomReset", "Reset Zoom")
        case "snippets": return L("shortcut.action.openSnippets", "Open Snippets")
        case "renameTab": return L("shortcut.action.renameTab", "Rename Tab")
        case "debugConsole": return L("shortcut.action.debugConsole", "Debug Console")
        case "newWindow": return L("shortcut.action.newWindow", "New Window")
        case "splitHorizontal": return L("shortcut.action.splitHorizontal", "Split Horizontal")
        case "splitVertical": return L("shortcut.action.splitVertical", "Split Vertical")
        case "openTextEditor": return L("shortcut.action.openTextEditor", "Open Text Editor")
        default: return action
        }
    }
}

// MARK: - Shell Type

enum ShellType: String, CaseIterable, Identifiable {
    case system
    case zsh = "/bin/zsh"
    case bash = "/bin/bash"
    case fish = "/opt/homebrew/bin/fish"
    case fishIntel = "/usr/local/bin/fish"
    case custom

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .system: return L("shell.system", "System Default")
        case .zsh: return L("shell.zsh", "Zsh")
        case .bash: return L("shell.bash", "Bash")
        case .fish: return L("shell.fish.appleSilicon", "Fish (Apple Silicon)")
        case .fishIntel: return L("shell.fish.intel", "Fish (Intel)")
        case .custom: return L("shell.custom", "Custom...")
        }
    }

    var shellName: String {
        switch self {
        case .system: return "system"
        case .zsh: return "zsh"
        case .bash: return "bash"
        case .fish, .fishIntel: return "fish"
        case .custom: return "custom"
        }
    }
}

// MARK: - Notification Settings (Value Type)

/// Groups all notification-related settings into a single value type.
/// Individual fields are persisted as separate UserDefaults keys for backward compatibility.
struct NotificationSettings: Equatable {
    var triggerState: NotificationTriggerState
    var filters: NotificationFilters
    var triggerActionBindings: [String: [NotificationActionConfig]]
    var rateLimitConfig: NotificationRateLimiter.Config
    var triggerConditions: [String: TriggerCondition]
    var groupActionBindings: [String: [NotificationActionConfig]]
    var groupConditions: [String: TriggerCondition]
    /// Per-repo muting/snoozing: repo root path → mute record. One check in
    /// the notification manager silences every surface (local, tab style,
    /// MCP, push) for events under a muted root.
    var mutedRepos: [String: RepoMute] = [:]
    /// Route accepted task-finished/failed notifications to iOS as pushes
    /// (frame 0x52). On by default — the whole point of pairing a phone is
    /// hearing about outcomes while away; approvals/prompts push regardless.
    var pushTaskCompletionsToiOS = true

    static let defaultGroupActionBindings: [String: [NotificationActionConfig]] = [
        "ai_coding.finished": [
            NotificationActionConfig(actionType: .showNotification, enabled: true),
            NotificationActionConfig(actionType: .dockBounce, enabled: true, config: ["critical": "false"]),
            NotificationActionConfig(actionType: .styleTab, enabled: true, config: [
                "style": "custom",
                "customColor": "green",
                "borderWidth": "2",
                "borderStyle": "solid"
            ])
        ],
        "ai_coding.failed": [
            NotificationActionConfig(actionType: .showNotification, enabled: true),
            NotificationActionConfig(actionType: .playSound, enabled: true, config: ["sound": "Basso", "volume": "80"]),
            NotificationActionConfig(actionType: .dockBounce, enabled: true, config: ["critical": "false"]),
            NotificationActionConfig(actionType: .styleTab, enabled: true, config: [
                "style": "error",
                "autoClearSeconds": "60"
            ])
        ],
        "ai_coding.permission": [
            NotificationActionConfig(actionType: .showNotification, enabled: true),
            NotificationActionConfig(actionType: .dockBounce, enabled: true, config: ["critical": "true"]),
            NotificationActionConfig(actionType: .styleTab, enabled: true, config: [
                "style": "custom",
                "customColor": "red",
                "borderWidth": "2",
                "borderStyle": "solid",
                "persistent": "true"
            ])
        ],
        "ai_coding.waiting_input": [
            NotificationActionConfig(actionType: .showNotification, enabled: true),
            NotificationActionConfig(actionType: .dockBounce, enabled: true, config: ["critical": "true"]),
            NotificationActionConfig(actionType: .styleTab, enabled: true, config: [
                "style": "custom",
                "customColor": "red",
                "borderWidth": "2",
                "borderStyle": "solid",
                "persistent": "true"
            ])
        ],
        "ai_coding.attention_required": [
            NotificationActionConfig(actionType: .showNotification, enabled: true),
            NotificationActionConfig(actionType: .dockBounce, enabled: true, config: ["critical": "true"]),
            NotificationActionConfig(actionType: .styleTab, enabled: true, config: [
                "style": "custom",
                "customColor": "red",
                "borderWidth": "2",
                "borderStyle": "solid",
                "persistent": "true"
            ])
        ],
        "ai_coding.elicitation": [
            NotificationActionConfig(actionType: .showNotification, enabled: true),
            NotificationActionConfig(actionType: .dockBounce, enabled: true, config: ["critical": "true"]),
            NotificationActionConfig(actionType: .styleTab, enabled: true, config: [
                "style": "custom",
                "customColor": "red",
                "borderWidth": "2",
                "borderStyle": "solid",
                "persistent": "true"
            ])
        ],
        "ai_coding.response_failed": [
            NotificationActionConfig(actionType: .showNotification, enabled: true),
            NotificationActionConfig(actionType: .dockBounce, enabled: true, config: ["critical": "false"]),
            NotificationActionConfig(actionType: .styleTab, enabled: true, config: [
                "style": "error",
                "autoClearSeconds": "60"
            ])
        ],
        "ai_coding.idle": []
    ]

    static let `default` = NotificationSettings(
        triggerState: NotificationTriggerState(),
        filters: .defaults,
        triggerActionBindings: [:],
        rateLimitConfig: .default,
        triggerConditions: [:],
        groupActionBindings: defaultGroupActionBindings,
        groupConditions: [:]
    )
}

// MARK: - Notification Event Types

struct NotificationFilters: Codable, Equatable {
    var taskFinished = true
    var taskFailed = true
    var needsValidation = false
    var permissionRequest = true
    var toolComplete = false
    var sessionEnd = false
    var commandIdle = false

    static let defaults = NotificationFilters()
}

// MARK: - Last Tab Close Behavior

enum LastTabCloseBehavior: String, CaseIterable, Identifiable, Codable {
    case keepWindow
    case closeWindow

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .keepWindow:
            return L("tabs.lastTabClose.keepWindow", "Keep Window Open (New Tab)")
        case .closeWindow:
            return L("tabs.lastTabClose.closeWindow", "Close Window")
        }
    }
}

// MARK: - Repo Grouping Mode

enum RepoGroupingMode: String, CaseIterable, Identifiable, Codable {
    case off
    case auto
    case manual

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .off: return L("tabs.repoGrouping.off", "Off")
        case .auto: return L("tabs.repoGrouping.auto", "Automatic")
        case .manual: return L("tabs.repoGrouping.manual", "Manual")
        }
    }
}

// MARK: - Tab Switch Shortcut Mode

/// Which keys jump directly to a tab by position. `commandNumber` covers ⌘1–9;
/// `functionKey` covers F1–F12 (up to 12 tabs, at the cost of overriding the
/// function keys inside the terminal); `both` enables them simultaneously.
enum TabSwitchShortcutMode: String, CaseIterable, Identifiable, Codable {
    case commandNumber
    case functionKey
    case both

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .commandNumber: return L("tabs.switchShortcut.commandNumber", "⌘1–9")
        case .functionKey: return L("tabs.switchShortcut.functionKey", "F1–F12")
        case .both: return L("tabs.switchShortcut.both", "⌘1–9 + F1–F12")
        }
    }

    /// Whether ⌘1–9 jumps to a tab in this mode.
    var allowsCommandNumber: Bool {
        self == .commandNumber || self == .both
    }

    /// Whether F1–F12 jumps to a tab in this mode.
    var allowsFunctionKeys: Bool {
        self == .functionKey || self == .both
    }

    /// Compact shortcut hint shown in the keyboard reference row.
    var shortcutHint: String {
        switch self {
        case .commandNumber: return "⌘1-9"
        case .functionKey: return "F1-F12"
        case .both: return "⌘1-9 or F1-F12"
        }
    }
}

// MARK: - URL Handler

enum URLHandler: String, CaseIterable, Identifiable, Codable {
    case system
    case safari
    case chrome
    case firefox
    case edge
    case brave
    case arc

    var id: String {
        rawValue
    }

    var displayName: String {
        switch self {
        case .system: return L("urlHandler.system", "System Default")
        case .safari: return L("urlHandler.safari", "Safari")
        case .chrome: return L("urlHandler.chrome", "Google Chrome")
        case .firefox: return L("urlHandler.firefox", "Firefox")
        case .edge: return L("urlHandler.edge", "Microsoft Edge")
        case .brave: return L("urlHandler.brave", "Brave")
        case .arc: return L("urlHandler.arc", "Arc")
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .system:
            return nil
        case .safari:
            return "com.apple.Safari"
        case .chrome:
            return "com.google.Chrome"
        case .firefox:
            return "org.mozilla.firefox"
        case .edge:
            return "com.microsoft.edgemac"
        case .brave:
            return "com.brave.Browser"
        case .arc:
            return "company.thebrowser.Browser"
        }
    }
}

// MARK: - Active Polling Rate Cap

/// Upper bound on how fast the active terminal tab drives its render loop.
/// Default `.displayNative` keeps the existing behavior (CVDisplayLink at screen
/// refresh, up to 120 Hz on ProMotion). Lower caps switch to a timer-driven loop
/// at the selected rate for users who want to trade fluidity for battery.
/// Adaptive idle throttling applies on top regardless of the cap.
enum ActivePollingRateCap: String, CaseIterable, Identifiable, Codable {
    case displayNative
    case hz60
    case hz30

    var id: String {
        rawValue
    }

    /// Upper bound in Hz, or `nil` when the cap is "display native".
    var capHz: Int? {
        switch self {
        case .displayNative: return nil
        case .hz60: return 60
        case .hz30: return 30
        }
    }

    var displayName: String {
        switch self {
        case .displayNative: return L("activePollingRateCap.displayNative", "Display Native")
        case .hz60: return L("activePollingRateCap.hz60", "60 Hz")
        case .hz30: return L("activePollingRateCap.hz30", "30 Hz")
        }
    }
}

// MARK: - Shell Event Configuration

/// Configuration for shell event detection (patterns, thresholds, etc.)
struct ShellEventConfig: Codable, Equatable {
    /// Patterns to match in command output (regex strings)
    var outputPatterns: [ShellOutputPattern] = []
    /// Exit codes to specifically watch for
    var watchedExitCodes: [Int] = [1, 2, 126, 127, 128, 130, 137, 139, 143]
    /// Threshold in seconds for "long-running" command detection
    var longRunningThresholdSeconds = 60
    /// Enable directory change notifications
    var notifyOnDirectoryChange = false
    /// Enable git branch change notifications
    var notifyOnGitBranchChange = false
    /// Enable all command completion notifications (not just failures)
    var notifyOnAllCommandCompletion = false

    static let `default` = ShellEventConfig()
}

/// A pattern to match in shell output
struct ShellOutputPattern: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var name: String
    var pattern: String // regex pattern
    var isEnabled = true
    var notificationType = "pattern_match" // maps to trigger type

    static let defaults: [ShellOutputPattern] = [
        ShellOutputPattern(name: L("shell.pattern.error", "Error"), pattern: "(?i)\\b(error|failed|failure)\\b", isEnabled: false),
        ShellOutputPattern(name: L("shell.pattern.warning", "Warning"), pattern: "(?i)\\bwarning\\b", isEnabled: false),
        ShellOutputPattern(name: L("shell.pattern.buildSuccess", "Build Success"), pattern: "(?i)\\b(build succeeded|compilation successful)\\b", isEnabled: false),
        ShellOutputPattern(name: L("shell.pattern.testPassed", "Test Passed"), pattern: "(?i)\\b(tests? passed|all tests pass)\\b", isEnabled: false),
        ShellOutputPattern(name: L("shell.pattern.testFailed", "Test Failed"), pattern: "(?i)\\b(tests? failed|test failure)\\b", isEnabled: false)
    ]
}

// MARK: - App Event Detection Config

/// Configuration for app-level event detection
struct AppEventConfig: Codable, Equatable {
    var scheduledEvents: [ScheduledEvent] = []
    var inactivityThresholdMinutes = 0 // 0 = disabled
    var memoryThresholdMB = 0 // 0 = disabled
    var memoryHysteresisMB = 50 // Must drop this much below threshold before re-alerting
    var notifyOnTabOpen = false // Tab open notifications (can be noisy)
    var notifyOnTabClose = false // Tab close notifications (can be noisy)

    static let `default` = AppEventConfig()
}

/// A scheduled event that fires at configured times
struct ScheduledEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var scheduleType: ScheduleType = .interval
    var intervalMinutes = 60 // For interval type
    var dailyTime = Date() // For daily type
    var hourlyMinute = 0 // For hourly type (0-59)
    var isEnabled = true

    enum ScheduleType: String, Codable, CaseIterable {
        case interval
        case daily
        case hourly
    }
}

// MARK: - Custom AI Detection Rules

struct CustomAIDetectionRule: Codable, Identifiable, Equatable {
    var id = UUID()
    var pattern: String
    var displayName: String
    var colorName: String

    var tabColor: TabColor {
        TabColor(rawValue: colorName) ?? .gray
    }
}

enum DangerousCommandHighlightScope: String, CaseIterable, Codable {
    case none
    case aiOutputs = "ai_outputs"
    case allOutputs = "all_outputs"
}

enum DangerousCommandProtectionLevel: String, CaseIterable, Codable {
    case verboseLogging = "verbose_logging"
    case warning
    case blocking
}

// MCPPermissionMode is defined in Chau7Core/MCPPermissionMode.swift

// MARK: - Feature Settings (Centralized configuration for all features)

/// Centralized feature flags and settings for Chau7.
/// All features can be toggled in Settings and values are persisted in UserDefaults.
@Observable
final class FeatureSettings {
    static let shared = FeatureSettings()

    private struct IntegrationSettings {
        var shellEventConfig: ShellEventConfig
        var appEventConfig: AppEventConfig
        var hasRequestedNotificationPermission: Bool
        var errorExplainEnabled: Bool
    }

    // MARK: - Font Settings (forwarded to TerminalAppearanceStore)

    /// The terminal appearance domain lives in its own store; these facade
    /// properties keep existing consumers source-compatible.
    @ObservationIgnored private let appearanceStore = TerminalAppearanceStore()

    var fontFamily: String {
        get { appearanceStore.fontFamily }
        set { appearanceStore.fontFamily = newValue }
    }

    var fontWeight: Int {
        get { appearanceStore.fontWeight }
        set { appearanceStore.fontWeight = newValue }
    }

    var fontSize: Int {
        get { appearanceStore.fontSize }
        set { appearanceStore.fontSize = newValue }
    }

    var customFontFamily: String {
        get { appearanceStore.customFontFamily }
        set { appearanceStore.customFontFamily = newValue }
    }

    var defaultZoomPercent: Int {
        get { appearanceStore.defaultZoomPercent }
        set { appearanceStore.defaultZoomPercent = newValue }
    }

    static var availableFonts: [String] {
        shared.appearanceStore.availableFonts
    }

    // MARK: - Color Scheme Settings (forwarded to TerminalAppearanceStore)

    var colorSchemeName: String {
        get { appearanceStore.colorSchemeName }
        set { appearanceStore.colorSchemeName = newValue }
    }

    var customColorScheme: TerminalColorScheme? {
        get { appearanceStore.customColorScheme }
        set { appearanceStore.customColorScheme = newValue }
    }

    var currentColorScheme: TerminalColorScheme {
        appearanceStore.currentColorScheme
    }

    // MARK: - Shell Settings (forwarded to ShellSettingsStore)

    @ObservationIgnored private let shellStore = ShellSettingsStore()

    var shellType: ShellType {
        get { shellStore.shellType }
        set { shellStore.shellType = newValue }
    }

    var customShellPath: String {
        get { shellStore.customShellPath }
        set { shellStore.customShellPath = newValue }
    }

    var startupCommand: String {
        get { shellStore.startupCommand }
        set { shellStore.startupCommand = newValue }
    }

    var isLsColorsEnabled: Bool {
        get { shellStore.isLsColorsEnabled }
        set { shellStore.isLsColorsEnabled = newValue }
    }

    // MARK: - Keyboard Shortcuts (forwarded to ShortcutSettingsStore)

    @ObservationIgnored private let shortcutStore = ShortcutSettingsStore()

    var customShortcuts: [KeyboardShortcut] {
        get { shortcutStore.customShortcuts }
        set { shortcutStore.customShortcuts = newValue }
    }

    /// Bumped whenever `customShortcuts` changes, so observers (KeybindingsManager)
    /// can detect changes with a cheap Int compare per key event instead of
    /// rebuilding and comparing a signature string.
    var customShortcutsGeneration: Int {
        shortcutStore.customShortcutsGeneration
    }

    var isShortcutHelperHintEnabled: Bool {
        get { shortcutStore.isShortcutHelperHintEnabled }
        set { shortcutStore.isShortcutHelperHintEnabled = newValue }
    }

    var autoSubmitRestorePrefill: Bool {
        didSet { UserDefaults.standard.set(autoSubmitRestorePrefill, forKey: Keys.autoSubmitRestorePrefill) }
    }

    func shortcut(for action: String) -> KeyboardShortcut? {
        shortcutStore.shortcut(for: action)
    }

    func updateShortcut(_ shortcut: KeyboardShortcut) {
        shortcutStore.updateShortcut(shortcut)
    }

    func shortcutConflicts(for shortcut: KeyboardShortcut) -> [KeyboardShortcut] {
        shortcutStore.shortcutConflicts(for: shortcut)
    }

    /// Export keybindings to JSON data (for save-to-file workflows).
    func exportKeybindings() -> Data? {
        shortcutStore.exportKeybindings()
    }

    /// Import keybindings from JSON data. Returns true on success.
    @discardableResult
    func importKeybindings(from data: Data) -> Bool {
        shortcutStore.importKeybindings(from: data)
    }

    func resetShortcutsToDefaults() {
        shortcutStore.applyPreset(keybindingPreset)
    }

    func applyKeybindingPreset(_ preset: String) {
        shortcutStore.applyPreset(preset)
    }

    // MARK: - Notification Settings

    /// The notification domain lives in its own store; this facade property
    /// keeps the 90+ existing consumers source-compatible. Observation
    /// composes across the forwarding: reads register on the store's
    /// `settings`, so SwiftUI updates flow unchanged.
    @ObservationIgnored private let notificationStore = NotificationSettingsStore()

    var notificationSettings: NotificationSettings {
        get { notificationStore.settings }
        set { notificationStore.settings = newValue }
    }

    /// Backward-compatible computed forwarders — existing code continues to work unchanged
    var notificationTriggerState: NotificationTriggerState {
        get { notificationSettings.triggerState }
        set { notificationSettings.triggerState = newValue }
    }

    var notificationFilters: NotificationFilters {
        get { notificationSettings.filters }
        set { notificationSettings.filters = newValue }
    }

    var triggerActionBindings: [String: [NotificationActionConfig]] {
        get { notificationSettings.triggerActionBindings }
        set { notificationSettings.triggerActionBindings = newValue }
    }

    var notificationRateLimitConfig: NotificationRateLimiter.Config {
        get { notificationSettings.rateLimitConfig }
        set { notificationSettings.rateLimitConfig = newValue }
    }

    var triggerConditions: [String: TriggerCondition] {
        get { notificationSettings.triggerConditions }
        set { notificationSettings.triggerConditions = newValue }
    }

    /// Get the condition for a trigger (falls back to default)
    func conditionForTrigger(_ triggerId: String) -> TriggerCondition {
        triggerConditions[triggerId] ?? .default
    }

    /// Set the condition for a trigger
    func setConditionForTrigger(_ triggerId: String, condition: TriggerCondition) {
        var conditions = triggerConditions
        if condition == .default {
            conditions.removeValue(forKey: triggerId)
        } else {
            conditions[triggerId] = condition
        }
        triggerConditions = conditions
    }

    /// Get actions for a specific trigger, with default "showNotification" if none configured
    func actionsForTrigger(_ triggerId: String) -> [NotificationActionConfig] {
        if let actions = triggerActionBindings[triggerId], !actions.isEmpty {
            return actions
        }
        // Default action: show notification
        return [NotificationActionConfig(actionType: .showNotification, enabled: true)]
    }

    /// Set actions for a trigger
    func setActionsForTrigger(_ triggerId: String, actions: [NotificationActionConfig]) {
        var bindings = triggerActionBindings
        if actions.isEmpty {
            bindings.removeValue(forKey: triggerId)
        } else {
            bindings[triggerId] = actions
        }
        triggerActionBindings = bindings
    }

    /// Add an action to a trigger
    func addActionToTrigger(_ triggerId: String, action: NotificationActionConfig) {
        var actions = triggerActionBindings[triggerId] ?? []
        actions.append(action)
        triggerActionBindings[triggerId] = actions
    }

    /// Remove an action from a trigger
    func removeActionFromTrigger(_ triggerId: String, actionId: UUID) {
        guard var actions = triggerActionBindings[triggerId] else { return }
        actions.removeAll { $0.id == actionId }
        if actions.isEmpty {
            triggerActionBindings.removeValue(forKey: triggerId)
        } else {
            triggerActionBindings[triggerId] = actions
        }
    }

    /// Update an action in a trigger
    func updateActionInTrigger(_ triggerId: String, action: NotificationActionConfig) {
        guard var actions = triggerActionBindings[triggerId] else { return }
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
            triggerActionBindings[triggerId] = actions
        }
    }

    func setActionEnabled(_ enabled: Bool, triggerId: String, actionId: UUID) {
        guard var actions = triggerActionBindings[triggerId],
              let index = actions.firstIndex(where: { $0.id == actionId }) else { return }
        let action = actions[index]
        actions[index] = NotificationActionConfig(
            id: action.id,
            actionType: action.actionType,
            enabled: enabled,
            config: action.config
        )
        triggerActionBindings[triggerId] = actions
    }

    // MARK: - Group-Level Action/Condition Management

    var groupActionBindings: [String: [NotificationActionConfig]] {
        get { notificationSettings.groupActionBindings }
        set { notificationSettings.groupActionBindings = newValue }
    }

    var groupConditions: [String: TriggerCondition] {
        get { notificationSettings.groupConditions }
        set { notificationSettings.groupConditions = newValue }
    }

    func actionsForGroup(_ groupTriggerId: String) -> [NotificationActionConfig] {
        if let actions = groupActionBindings[groupTriggerId], !actions.isEmpty {
            return actions
        }
        return [NotificationActionConfig(actionType: .showNotification, enabled: true)]
    }

    func addActionToGroup(_ groupTriggerId: String, action: NotificationActionConfig) {
        var actions = groupActionBindings[groupTriggerId] ?? []
        actions.append(action)
        groupActionBindings[groupTriggerId] = actions
    }

    func removeActionFromGroup(_ groupTriggerId: String, actionId: UUID) {
        guard var actions = groupActionBindings[groupTriggerId] else { return }
        actions.removeAll { $0.id == actionId }
        if actions.isEmpty {
            groupActionBindings.removeValue(forKey: groupTriggerId)
        } else {
            groupActionBindings[groupTriggerId] = actions
        }
    }

    func updateActionInGroup(_ groupTriggerId: String, action: NotificationActionConfig) {
        guard var actions = groupActionBindings[groupTriggerId] else { return }
        if let index = actions.firstIndex(where: { $0.id == action.id }) {
            actions[index] = action
            groupActionBindings[groupTriggerId] = actions
        }
    }

    func setGroupActionEnabled(_ enabled: Bool, groupId: String, actionId: UUID) {
        guard var actions = groupActionBindings[groupId],
              let index = actions.firstIndex(where: { $0.id == actionId }) else { return }
        let action = actions[index]
        actions[index] = NotificationActionConfig(
            id: action.id,
            actionType: action.actionType,
            enabled: enabled,
            config: action.config
        )
        groupActionBindings[groupId] = actions
    }

    // MARK: - Find Defaults (NEW)

    var findCaseSensitiveDefault: Bool {
        didSet { UserDefaults.standard.set(findCaseSensitiveDefault, forKey: Keys.findCaseSensitiveDefault) }
    }

    var findRegexDefault: Bool {
        didSet { UserDefaults.standard.set(findRegexDefault, forKey: Keys.findRegexDefault) }
    }

    // MARK: - Tab Behavior (forwarded to TabDisplaySettingsStore)

    /// The tab behavior/display/hover-card domain lives in its own store;
    /// these facade properties keep existing consumers source-compatible.
    /// Assigned in `init` (not inline) so the RTK → CTO key migration runs
    /// before the store loads `showTabCTOIndicator`.
    @ObservationIgnored private let tabDisplayStore: TabDisplaySettingsStore

    var lastTabCloseBehavior: LastTabCloseBehavior {
        get { tabDisplayStore.lastTabCloseBehavior }
        set { tabDisplayStore.lastTabCloseBehavior = newValue }
    }

    /// Where to insert new tabs: "end" or "after" (after current tab)
    var newTabPosition: String {
        get { tabDisplayStore.newTabPosition }
        set { tabDisplayStore.newTabPosition = newValue }
    }

    /// When enabled, new tabs inherit the current tab's directory.
    var newTabsUseCurrentDirectory: Bool {
        get { tabDisplayStore.newTabsUseCurrentDirectory }
        set { tabDisplayStore.newTabsUseCurrentDirectory = newValue }
    }

    var alwaysShowTabBar: Bool {
        get { tabDisplayStore.alwaysShowTabBar }
        set { tabDisplayStore.alwaysShowTabBar = newValue }
    }

    /// When true, the toolbar stays visible in fullscreen (like Chrome's "Always Show Toolbar in Full Screen")
    var alwaysShowToolbarInFullscreen: Bool {
        get { tabDisplayStore.alwaysShowToolbarInFullscreen }
        set { tabDisplayStore.alwaysShowToolbarInFullscreen = newValue }
    }

    /// When true, shows a warning dialog before closing a tab with a running process
    var warnOnCloseWithRunningProcess: Bool {
        get { tabDisplayStore.warnOnCloseWithRunningProcess }
        set { tabDisplayStore.warnOnCloseWithRunningProcess = newValue }
    }

    /// When true, always shows a warning dialog before closing any tab
    var alwaysWarnOnTabClose: Bool {
        get { tabDisplayStore.alwaysWarnOnTabClose }
        set { tabDisplayStore.alwaysWarnOnTabClose = newValue }
    }

    /// Collect tabs idle for 10+ minutes into a dropdown at the start of the tab bar
    var groupIdleTabs: Bool {
        get { tabDisplayStore.groupIdleTabs }
        set { tabDisplayStore.groupIdleTabs = newValue }
    }

    var idleTabThresholdMinutes: Int {
        get { tabDisplayStore.idleTabThresholdMinutes }
        set { tabDisplayStore.idleTabThresholdMinutes = newValue }
    }

    /// How many days of AI telemetry (runs plus their full turn transcripts and
    /// tool-call I/O) to keep in `runs.db`. `0` keeps everything forever.
    /// Pruning runs at launch during deferred maintenance; see `TelemetryStore`.
    var telemetryRetentionDays: Int =
        UserDefaults.standard.object(forKey: TelemetryRetention.defaultsKey) as? Int ?? TelemetryRetention.defaultDays {
        didSet {
            let clamped = telemetryRetentionDays < 0 ? 0 : min(telemetryRetentionDays, TelemetryRetention.maxDays)
            if telemetryRetentionDays != clamped {
                telemetryRetentionDays = clamped
                return
            }
            UserDefaults.standard.set(telemetryRetentionDays, forKey: TelemetryRetention.defaultsKey)
        }
    }

    /// Idle tab threshold in seconds (derived from minutes setting)
    var idleTabThresholdSeconds: TimeInterval {
        TimeInterval(max(1, idleTabThresholdMinutes) * 60)
    }

    var repoGroupingMode: RepoGroupingMode = {
        guard let raw = UserDefaults.standard.string(forKey: "tabs.repoGroupingMode"),
              let mode = RepoGroupingMode(rawValue: raw) else { return .off }
        return mode
    }() {
        didSet {
            UserDefaults.standard.set(repoGroupingMode.rawValue, forKey: "tabs.repoGroupingMode")
            NotificationCenter.default.post(name: .repoGroupingModeChanged, object: self)
        }
    }

    /// Which keys jump to a tab by position (⌘1–9 vs F1–F12). Read live by
    /// AppDelegate's key monitor, so changes take effect on the next keystroke.
    var tabSwitchShortcutMode: TabSwitchShortcutMode {
        get { tabDisplayStore.tabSwitchShortcutMode }
        set { tabDisplayStore.tabSwitchShortcutMode = newValue }
    }

    // MARK: - App Chrome (forwarded to AppChromeSettingsStore)

    /// The app-level chrome domain (theme, language, window mode/opacity,
    /// launch at login, ligatures) lives in its own store; these facade
    /// properties keep existing consumers source-compatible.
    @ObservationIgnored private let appChromeStore = AppChromeSettingsStore()

    var menuBarOnlyMode: Bool {
        get { appChromeStore.menuBarOnlyMode }
        set { appChromeStore.menuBarOnlyMode = newValue }
    }

    /// When true, the terminal window floats above other apps (.floating level).
    var windowFloating: Bool {
        get { appChromeStore.windowFloating }
        set { appChromeStore.windowFloating = newValue }
    }

    var windowOpacity: Double {
        get { appChromeStore.windowOpacity }
        set { appChromeStore.windowOpacity = newValue }
    }

    var appTheme: AppTheme {
        get { appChromeStore.appTheme }
        set { appChromeStore.appTheme = newValue }
    }

    var appLanguage: AppLanguage {
        get { appChromeStore.appLanguage }
        set { appChromeStore.appLanguage = newValue }
    }

    var launchAtLogin: Bool {
        get { appChromeStore.launchAtLogin }
        set { appChromeStore.launchAtLogin = newValue }
    }

    /// Enable font ligature rendering (e.g., =>, ->, === in Fira Code, JetBrains Mono).
    var enableLigatures: Bool {
        get { appChromeStore.enableLigatures }
        set { appChromeStore.enableLigatures = newValue }
    }

    // MARK: - iCloud Sync (NEW)

    var iCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(iCloudSyncEnabled, forKey: Keys.iCloudSyncEnabled)
            if iCloudSyncEnabled {
                syncToiCloud()
            }
        }
    }

    // MARK: - Productivity Features (forwarded to ProductivitySettingsStore)

    /// The productivity feature cluster (broadcast, clipboard history,
    /// bookmarks, snippets, copy-on-select, timestamps, badges, cmd-click
    /// paths, option-click cursor, auto tab themes, custom AI detection)
    /// lives in its own store; these facade properties keep existing
    /// consumers source-compatible.
    @ObservationIgnored private let productivityStore = ProductivitySettingsStore()

    var isAutoTabThemeEnabled: Bool {
        get { productivityStore.isAutoTabThemeEnabled }
        set { productivityStore.isAutoTabThemeEnabled = newValue }
    }

    /// AI model to tab color mapping — generated from AIToolRegistry.
    static let aiModelColors: [String: TabColor] = {
        var map: [String: TabColor] = [:]
        for (key, colorName) in AIToolRegistry.tabColorMap {
            if let color = TabColor(rawValue: colorName) {
                map[key] = color
            }
        }
        return map
    }()

    var isCopyOnSelectEnabled: Bool {
        get { productivityStore.isCopyOnSelectEnabled }
        set { productivityStore.isCopyOnSelectEnabled = newValue }
    }

    var isLineTimestampsEnabled: Bool {
        get { productivityStore.isLineTimestampsEnabled }
        set { productivityStore.isLineTimestampsEnabled = newValue }
    }

    var timestampFormat: String {
        get { productivityStore.timestampFormat }
        set { productivityStore.timestampFormat = newValue }
    }

    // MARK: - Tab Display Customization (forwarded to TabDisplaySettingsStore)

    /// Show AI product logos and dev server icons in tabs
    var showTabIcons: Bool {
        get { tabDisplayStore.showTabIcons }
        set { tabDisplayStore.showTabIcons = newValue }
    }

    /// Show the working directory path next to the tab title
    var showTabPath: Bool {
        get { tabDisplayStore.showTabPath }
        set { tabDisplayStore.showTabPath = newValue }
    }

    /// Show the git branch indicator in tabs
    var showTabGitIndicator: Bool {
        get { tabDisplayStore.showTabGitIndicator }
        set { tabDisplayStore.showTabGitIndicator = newValue }
    }

    /// Show the CTO bolt icon in tabs (independent of CTO being enabled)
    var showTabCTOIndicator: Bool {
        get { tabDisplayStore.showTabCTOIndicator }
        set { tabDisplayStore.showTabCTOIndicator = newValue }
    }

    /// Allow toggling per-tab CTO override directly from tab indicator clicks.
    /// Disable this to prevent accidental misclicks while still showing override state.
    var allowTabCTOToggle: Bool {
        get { tabDisplayStore.allowTabCTOToggle }
        set { tabDisplayStore.allowTabCTOToggle = newValue }
    }

    /// Show the broadcast indicator in tabs
    var showTabBroadcastIndicator: Bool {
        get { tabDisplayStore.showTabBroadcastIndicator }
        set { tabDisplayStore.showTabBroadcastIndicator = newValue }
    }

    // MARK: - Hover Card Sections (forwarded to TabDisplaySettingsStore)

    var hoverCardShowDirectory: Bool {
        get { tabDisplayStore.hoverCardShowDirectory }
        set { tabDisplayStore.hoverCardShowDirectory = newValue }
    }

    var hoverCardShowGitBranch: Bool {
        get { tabDisplayStore.hoverCardShowGitBranch }
        set { tabDisplayStore.hoverCardShowGitBranch = newValue }
    }

    var hoverCardShowShellIntegration: Bool {
        get { tabDisplayStore.hoverCardShowShellIntegration }
        set { tabDisplayStore.hoverCardShowShellIntegration = newValue }
    }

    var hoverCardShowDevServer: Bool {
        get { tabDisplayStore.hoverCardShowDevServer }
        set { tabDisplayStore.hoverCardShowDevServer = newValue }
    }

    var hoverCardShowLastCommand: Bool {
        get { tabDisplayStore.hoverCardShowLastCommand }
        set { tabDisplayStore.hoverCardShowLastCommand = newValue }
    }

    var hoverCardShowAISession: Bool {
        get { tabDisplayStore.hoverCardShowAISession }
        set { tabDisplayStore.hoverCardShowAISession = newValue }
    }

    var hoverCardShowRepoStats: Bool {
        get { tabDisplayStore.hoverCardShowRepoStats }
        set { tabDisplayStore.hoverCardShowRepoStats = newValue }
    }

    var hoverCardShowProcesses: Bool {
        get { tabDisplayStore.hoverCardShowProcesses }
        set { tabDisplayStore.hoverCardShowProcesses = newValue }
    }

    var hoverCardShowTokenOptimization: Bool {
        get { tabDisplayStore.hoverCardShowTokenOptimization }
        set { tabDisplayStore.hoverCardShowTokenOptimization = newValue }
    }

    var hoverCardShowBroadcast: Bool {
        get { tabDisplayStore.hoverCardShowBroadcast }
        set { tabDisplayStore.hoverCardShowBroadcast = newValue }
    }

    var hoverCardShowConflicts: Bool {
        get { tabDisplayStore.hoverCardShowConflicts }
        set { tabDisplayStore.hoverCardShowConflicts = newValue }
    }

    var hoverCardShowNotificationState: Bool {
        get { tabDisplayStore.hoverCardShowNotificationState }
        set { tabDisplayStore.hoverCardShowNotificationState = newValue }
    }

    var hoverCardShowFooter: Bool {
        get { tabDisplayStore.hoverCardShowFooter }
        set { tabDisplayStore.hoverCardShowFooter = newValue }
    }

    /// When enabled, only the custom title is shown (hides all other tab elements
    /// except the close button). Has no effect on tabs without a custom title.
    var customTitleOnly: Bool {
        get { tabDisplayStore.customTitleOnly }
        set { tabDisplayStore.customTitleOnly = newValue }
    }

    var isLastCommandBadgeEnabled: Bool {
        get { productivityStore.isLastCommandBadgeEnabled }
        set { productivityStore.isLastCommandBadgeEnabled = newValue }
    }

    var isCmdClickPathsEnabled: Bool {
        get { productivityStore.isCmdClickPathsEnabled }
        set { productivityStore.isCmdClickPathsEnabled = newValue }
    }

    /// Open Cmd+Click file paths in internal editor (right panel) instead of external editor
    var cmdClickOpensInternalEditor: Bool {
        get { productivityStore.cmdClickOpensInternalEditor }
        set { productivityStore.cmdClickOpensInternalEditor = newValue }
    }

    /// Option+click to position cursor in the command line (like iTerm2)
    var isOptionClickCursorEnabled: Bool {
        get { productivityStore.isOptionClickCursorEnabled }
        set { productivityStore.isOptionClickCursorEnabled = newValue }
    }

    /// Allow terminal apps (vim, tmux, Codex, etc.) to capture mouse events.
    /// When enabled, hold Shift while clicking/dragging to force text selection.
    /// When disabled, mouse events always perform text selection.
    var isMouseReportingEnabled: Bool {
        didSet { UserDefaults.standard.set(isMouseReportingEnabled, forKey: Keys.mouseReporting) }
    }

    /// Use Metal GPU rendering for the terminal.
    /// Renders terminal cells on the GPU instead of CoreGraphics.
    /// Changes take effect for new tabs only.
    var useMetalRenderer: Bool {
        didSet { UserDefaults.standard.set(useMetalRenderer, forKey: Keys.useMetalRenderer) }
    }

    /// Click on input line to position cursor (like modern text editors).
    /// Single click moves cursor, click+drag selects text.
    var isClickToPositionEnabled: Bool {
        didSet { UserDefaults.standard.set(isClickToPositionEnabled, forKey: Keys.clickToPosition) }
    }

    var defaultEditor: String {
        get { productivityStore.defaultEditor }
        set { productivityStore.defaultEditor = newValue }
    }

    var urlHandler: URLHandler {
        didSet { UserDefaults.standard.set(urlHandler.rawValue, forKey: Keys.urlHandler) }
    }

    /// Caps how fast the active tab's render loop runs. `.displayNative` keeps
    /// CVDisplayLink at the screen's native refresh; other cases force a timer-
    /// driven loop. Changes broadcast `activePollingRateCapChanged` so live
    /// terminal views can rebuild their loop.
    var activePollingRateCap: ActivePollingRateCap {
        didSet {
            guard activePollingRateCap != oldValue else { return }
            UserDefaults.standard.set(activePollingRateCap.rawValue, forKey: Keys.activePollingRateCap)
            NotificationCenter.default.post(name: .activePollingRateCapChanged, object: nil)
        }
    }

    /// Max grid-sync/draw rate (fps) for visible-but-not-focused terminal views
    /// (e.g. the selected tab of a non-key window on a second screen). The
    /// focused view follows `activePollingRateCap`; non-focused visible views
    /// stay event-driven (responsive) but only present at this rate, cutting
    /// GPU + grid-sync cost for content the user isn't interacting with.
    /// Read live on the render hot path. Default 42.
    var inactiveViewMaxFPS: Int = UserDefaults.standard.object(forKey: "rendering.inactiveViewMaxFPS") as? Int ?? 42 {
        didSet { UserDefaults.standard.set(inactiveViewMaxFPS, forKey: "rendering.inactiveViewMaxFPS") }
    }

    // MARK: - Custom AI Detection (forwarded to ProductivitySettingsStore)

    var customAIDetectionRules: [CustomAIDetectionRule] {
        get { productivityStore.customAIDetectionRules }
        set { productivityStore.customAIDetectionRules = newValue }
    }

    // MARK: - F13/F16/F17/F21 (forwarded to ProductivitySettingsStore)

    var isBroadcastEnabled: Bool {
        get { productivityStore.isBroadcastEnabled }
        set { productivityStore.isBroadcastEnabled = newValue }
    }

    var isClipboardHistoryEnabled: Bool {
        get { productivityStore.isClipboardHistoryEnabled }
        set { productivityStore.isClipboardHistoryEnabled = newValue }
    }

    var clipboardHistoryMaxItems: Int {
        get { productivityStore.clipboardHistoryMaxItems }
        set { productivityStore.clipboardHistoryMaxItems = newValue }
    }

    var isBookmarksEnabled: Bool {
        get { productivityStore.isBookmarksEnabled }
        set { productivityStore.isBookmarksEnabled = newValue }
    }

    var maxBookmarksPerTab: Int {
        get { productivityStore.maxBookmarksPerTab }
        set { productivityStore.maxBookmarksPerTab = newValue }
    }

    var isSnippetsEnabled: Bool {
        get { productivityStore.isSnippetsEnabled }
        set { productivityStore.isSnippetsEnabled = newValue }
    }

    var isRepoSnippetsEnabled: Bool {
        get { productivityStore.isRepoSnippetsEnabled }
        set { productivityStore.isRepoSnippetsEnabled = newValue }
    }

    /// Cross-cutting security toggle — stays on the facade rather than moving
    /// into ProductivitySettingsStore.
    var allowProtectedFolderAccess: Bool {
        didSet { UserDefaults.standard.set(allowProtectedFolderAccess, forKey: Keys.allowProtectedFolderAccess) }
    }

    /// Cross-cutting repo state (paired with KnownRepoIdentityStore) — stays
    /// on the facade rather than moving into ProductivitySettingsStore.
    var recentRepoRoots: [String] {
        didSet { UserDefaults.standard.set(recentRepoRoots, forKey: Keys.recentRepoRoots) }
    }

    var repoSnippetPath: String {
        get { productivityStore.repoSnippetPath }
        set { productivityStore.repoSnippetPath = newValue }
    }

    var snippetInsertMode: String {
        get { productivityStore.snippetInsertMode }
        set { productivityStore.snippetInsertMode = newValue }
    }

    var snippetPlaceholdersEnabled: Bool {
        get { productivityStore.snippetPlaceholdersEnabled }
        set { productivityStore.snippetPlaceholdersEnabled = newValue }
    }

    func recordRecentRepo(_ path: String, branch: String? = nil) {
        let normalized = URL(fileURLWithPath: path).standardized.path
        var updated = recentRepoRoots.filter { $0 != normalized }
        updated.insert(normalized, at: 0)
        if updated.count > 20 {
            updated.removeLast(updated.count - 20)
        }
        recentRepoRoots = updated
        KnownRepoIdentityStore.shared.record(rootPath: normalized, branch: branch)
    }

    // MARK: - F08: Smart Syntax Highlighting

    var isSyntaxHighlightEnabled: Bool {
        didSet { UserDefaults.standard.set(isSyntaxHighlightEnabled, forKey: Keys.syntaxHighlight) }
    }

    var isClickableURLsEnabled: Bool {
        didSet { UserDefaults.standard.set(isClickableURLsEnabled, forKey: Keys.clickableURLs) }
    }

    // MARK: - Inline Images (iTerm2 imgcat protocol)

    var isInlineImagesEnabled: Bool {
        didSet { UserDefaults.standard.set(isInlineImagesEnabled, forKey: Keys.inlineImages) }
    }

    var isJSONPrettyPrintEnabled: Bool {
        didSet { UserDefaults.standard.set(isJSONPrettyPrintEnabled, forKey: Keys.jsonPrettyPrint) }
    }

    // MARK: - F07: Semantic Scrollback Search

    var isSemanticSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(isSemanticSearchEnabled, forKey: Keys.semanticSearch) }
    }

    // MARK: - F02: Split Panes

    var isSplitPanesEnabled: Bool {
        didSet { UserDefaults.standard.set(isSplitPanesEnabled, forKey: Keys.splitPanes) }
    }

    // MARK: - Immediate Display Flush (Latency Optimization)

    // MARK: - Smart Scroll (Auto-Scroll Control)

    /// When enabled, new terminal output will NOT auto-scroll to the bottom if the user
    /// has scrolled up. The user's scroll position is preserved until they manually scroll
    /// back to the bottom. Default: true (smart behavior enabled).
    var isSmartScrollEnabled: Bool {
        didSet { UserDefaults.standard.set(isSmartScrollEnabled, forKey: Keys.smartScrollEnabled) }
    }

    // MARK: - F11: Keybindings

    var keybindingPreset: String {
        didSet { UserDefaults.standard.set(keybindingPreset, forKey: Keys.keybindingPreset) }
    }

    // MARK: - Overlay Positions

    var overlayPositionsVersion = 0

    // MARK: - General Terminal Settings

    /// The general terminal behavior domain lives in its own store; these
    /// facade properties keep existing consumers source-compatible.
    @ObservationIgnored private let terminalBehaviorStore = TerminalBehaviorStore()

    var cursorStyle: String {
        get { terminalBehaviorStore.cursorStyle }
        set { terminalBehaviorStore.cursorStyle = newValue }
    }

    var cursorBlink: Bool {
        get { terminalBehaviorStore.cursorBlink }
        set { terminalBehaviorStore.cursorBlink = newValue }
    }

    var cursorBlinkRate: Double {
        get { terminalBehaviorStore.cursorBlinkRate }
        set { terminalBehaviorStore.cursorBlinkRate = newValue }
    }

    var cursorColor: String {
        get { terminalBehaviorStore.cursorColor }
        set { terminalBehaviorStore.cursorColor = newValue }
    }

    var unicodeAmbiguousWidth: Int {
        get { terminalBehaviorStore.unicodeAmbiguousWidth }
        set { terminalBehaviorStore.unicodeAmbiguousWidth = newValue }
    }

    var scrollbackLines: Int {
        get { terminalBehaviorStore.scrollbackLines }
        set { terminalBehaviorStore.scrollbackLines = newValue }
    }

    var shellHistoryMaxLines: Int {
        get { terminalBehaviorStore.shellHistoryMaxLines }
        set { terminalBehaviorStore.shellHistoryMaxLines = newValue }
    }

    var restoredScrollbackLines: Int {
        get { terminalBehaviorStore.restoredScrollbackLines }
        set { terminalBehaviorStore.restoredScrollbackLines = newValue }
    }

    var runtimeEventJournalCapacity: Int {
        get { terminalBehaviorStore.runtimeEventJournalCapacity }
        set { terminalBehaviorStore.runtimeEventJournalCapacity = newValue }
    }

    var runtimeOutputChunkLimit: Int {
        get { terminalBehaviorStore.runtimeOutputChunkLimit }
        set { terminalBehaviorStore.runtimeOutputChunkLimit = newValue }
    }

    var runtimeCostThresholdsUSD: [Double] {
        get { terminalBehaviorStore.runtimeCostThresholdsUSD }
        set { terminalBehaviorStore.runtimeCostThresholdsUSD = newValue }
    }

    var isUsageMonitoringEnabled: Bool {
        get { terminalBehaviorStore.isUsageMonitoringEnabled }
        set { terminalBehaviorStore.isUsageMonitoringEnabled = newValue }
    }

    var isClaudeStatusLineQuotaCaptureEnabled: Bool {
        get { terminalBehaviorStore.isClaudeStatusLineQuotaCaptureEnabled }
        set { terminalBehaviorStore.isClaudeStatusLineQuotaCaptureEnabled = newValue }
    }

    var isUsageQuotaWarningsEnabled: Bool {
        get { terminalBehaviorStore.isUsageQuotaWarningsEnabled }
        set { terminalBehaviorStore.isUsageQuotaWarningsEnabled = newValue }
    }

    var bellEnabled: Bool {
        get { terminalBehaviorStore.bellEnabled }
        set { terminalBehaviorStore.bellEnabled = newValue }
    }

    var bellSound: String {
        get { terminalBehaviorStore.bellSound }
        set { terminalBehaviorStore.bellSound = newValue }
    }

    var bellVisual: Bool {
        get { terminalBehaviorStore.bellVisual }
        set { terminalBehaviorStore.bellVisual = newValue }
    }

    var bellRateLimitSeconds: Double {
        get { terminalBehaviorStore.bellRateLimitSeconds }
        set { terminalBehaviorStore.bellRateLimitSeconds = newValue }
    }

    var dangerousCommandHighlightScope: DangerousCommandHighlightScope {
        get { terminalBehaviorStore.dangerousCommandHighlightScope }
        set { terminalBehaviorStore.dangerousCommandHighlightScope = newValue }
    }

    var dangerousCommandPatterns: [String] {
        get { terminalBehaviorStore.dangerousCommandPatterns }
        set { terminalBehaviorStore.dangerousCommandPatterns = newValue }
    }

    var dangerousCommandProtectChau7Enabled: Bool {
        get { terminalBehaviorStore.dangerousCommandProtectChau7Enabled }
        set { terminalBehaviorStore.dangerousCommandProtectChau7Enabled = newValue }
    }

    var dangerousCommandProtectChau7Level: DangerousCommandProtectionLevel {
        get { terminalBehaviorStore.dangerousCommandProtectChau7Level }
        set { terminalBehaviorStore.dangerousCommandProtectChau7Level = newValue }
    }

    var dangerousCommandProtectedProcessPatterns: [String] {
        get { terminalBehaviorStore.dangerousCommandProtectedProcessPatterns }
        set { terminalBehaviorStore.dangerousCommandProtectedProcessPatterns = newValue }
    }

    func dangerousCommandSelfProtectionContext(
        extraProtectedPIDs: Set<Int32> = [],
        observedProcessNames: [String] = []
    ) -> SelfProtectiveCommandContext {
        var protectedPIDs = extraProtectedPIDs
        protectedPIDs.insert(ProcessInfo.processInfo.processIdentifier)

        var protectedNames = Set(dangerousCommandProtectedProcessPatterns)
        if let bundleID = Bundle.main.bundleIdentifier, !bundleID.isEmpty {
            protectedNames.insert(bundleID)
        }

        let normalizedConfigured = dangerousCommandProtectedProcessPatterns.map {
            SelfProtectiveCommandDetection.normalizeToken($0)
        }.filter { !$0.isEmpty }

        for processName in observedProcessNames {
            let normalized = SelfProtectiveCommandDetection.normalizeToken(processName)
            guard !normalized.isEmpty else { continue }
            if normalizedConfigured.contains(where: { normalized.contains($0) || $0.contains(normalized) }) {
                protectedNames.insert(processName)
            }
        }

        return SelfProtectiveCommandContext(
            protectedPIDs: protectedPIDs,
            protectedProcessNames: protectedNames
        )
    }

    var dangerousOutputHighlightIdleDelayMs: Int {
        get { terminalBehaviorStore.dangerousOutputHighlightIdleDelayMs }
        set { terminalBehaviorStore.dangerousOutputHighlightIdleDelayMs = newValue }
    }

    var dangerousOutputHighlightMaxIntervalMs: Int {
        get { terminalBehaviorStore.dangerousOutputHighlightMaxIntervalMs }
        set { terminalBehaviorStore.dangerousOutputHighlightMaxIntervalMs = newValue }
    }

    var dangerousOutputHighlightLowPowerEnabled: Bool {
        get { terminalBehaviorStore.dangerousOutputHighlightLowPowerEnabled }
        set { terminalBehaviorStore.dangerousOutputHighlightLowPowerEnabled = newValue }
    }

    var defaultStartDirectory: String {
        get { terminalBehaviorStore.defaultStartDirectory }
        set { terminalBehaviorStore.defaultStartDirectory = newValue }
    }

    // MARK: - API Analytics Settings

    var isAPIAnalyticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAPIAnalyticsEnabled, forKey: Keys.apiAnalyticsEnabled)
            NotificationCenter.default.post(name: .apiAnalyticsSettingsChanged, object: nil)
        }
    }

    var apiAnalyticsPort: Int {
        didSet {
            let clamped = max(1024, min(apiAnalyticsPort, 65535))
            if apiAnalyticsPort != clamped {
                apiAnalyticsPort = clamped
                return
            }
            UserDefaults.standard.set(apiAnalyticsPort, forKey: Keys.apiAnalyticsPort)
        }
    }

    var apiAnalyticsLogPrompts: Bool {
        didSet {
            UserDefaults.standard.set(apiAnalyticsLogPrompts, forKey: Keys.apiAnalyticsLogPrompts)
        }
    }

    /// Redirect OpenAI traffic through the proxy. Disable for subscription-based
    /// Codex which requires WebSocket transport incompatible with HTTP proxying.
    var apiAnalyticsIncludeOpenAI: Bool {
        didSet {
            UserDefaults.standard.set(apiAnalyticsIncludeOpenAI, forKey: Keys.apiAnalyticsIncludeOpenAI)
        }
    }

    // MARK: - MCP / Remote / CTO (forwarded to MCPRemoteSettingsStore)

    /// The MCP + remote control + CTO integration domain lives in its own
    /// store; these facade properties keep existing consumers
    /// source-compatible. Assigned in `init` (not inline) because the store's
    /// init runs the RTK → CTO key migration, which must happen before
    /// `tabDisplayStore` loads `showTabCTOIndicator`.
    @ObservationIgnored private let mcpRemoteStore: MCPRemoteSettingsStore

    var tokenOptimizationMode: TokenOptimizationMode {
        get { mcpRemoteStore.tokenOptimizationMode }
        set { mcpRemoteStore.tokenOptimizationMode = newValue }
    }

    var mcpEnabled: Bool {
        get { mcpRemoteStore.mcpEnabled }
        set { mcpRemoteStore.mcpEnabled = newValue }
    }

    var mcpMaxTabs: Int {
        get { mcpRemoteStore.mcpMaxTabs }
        set { mcpRemoteStore.mcpMaxTabs = newValue }
    }

    var mcpRequiresApproval: Bool {
        get { mcpRemoteStore.mcpRequiresApproval }
        set { mcpRemoteStore.mcpRequiresApproval = newValue }
    }

    var mcpShowTabIndicator: Bool {
        get { mcpRemoteStore.mcpShowTabIndicator }
        set { mcpRemoteStore.mcpShowTabIndicator = newValue }
    }

    var mcpPermissionMode: MCPPermissionMode {
        get { mcpRemoteStore.mcpPermissionMode }
        set { mcpRemoteStore.mcpPermissionMode = newValue }
    }

    var mcpAllowedCommands: [String] {
        get { mcpRemoteStore.mcpAllowedCommands }
        set { mcpRemoteStore.mcpAllowedCommands = newValue }
    }

    var mcpBlockedCommands: [String] {
        get { mcpRemoteStore.mcpBlockedCommands }
        set { mcpRemoteStore.mcpBlockedCommands = newValue }
    }

    var mcpProfiles: [MCPProfile] {
        get { mcpRemoteStore.mcpProfiles }
        set { mcpRemoteStore.mcpProfiles = newValue }
    }

    /// Add a command to the allowed list of a specific profile, or to the global list.
    func addToAllowedCommands(_ command: String, profileID: UUID? = nil) {
        let normalized = command.lowercased()
        if let profileID = profileID,
           let index = mcpProfiles.firstIndex(where: { $0.id == profileID }) {
            if !mcpProfiles[index].allowedCommands.contains(normalized) {
                mcpProfiles[index].allowedCommands.append(normalized)
            }
        } else {
            if !mcpAllowedCommands.contains(normalized) {
                mcpAllowedCommands.append(normalized)
            }
        }
    }

    var isRemoteEnabled: Bool {
        get { mcpRemoteStore.isRemoteEnabled }
        set { mcpRemoteStore.isRemoteEnabled = newValue }
    }

    var remoteRelayURL: String {
        get { mcpRemoteStore.remoteRelayURL }
        set { mcpRemoteStore.remoteRelayURL = newValue }
    }

    // MARK: - Shell Event Detection Settings

    var shellEventConfig: ShellEventConfig {
        didSet {
            if let data = JSONOperations.encode(shellEventConfig, context: "shellEventConfig") {
                UserDefaults.standard.set(data, forKey: Keys.shellEventConfig)
            }
        }
    }

    var appEventConfig: AppEventConfig {
        didSet {
            if let data = JSONOperations.encode(appEventConfig, context: "appEventConfig") {
                UserDefaults.standard.set(data, forKey: Keys.appEventConfig)
            }
        }
    }

    /// Tracks whether we've already asked for notification permissions (persisted).
    /// This prevents repeated automatic prompts while still allowing manual requests.
    var hasRequestedNotificationPermission: Bool {
        didSet {
            UserDefaults.standard.set(hasRequestedNotificationPermission, forKey: Keys.hasRequestedNotificationPermission)
        }
    }

    // MARK: - LLM / Error Explanation

    var errorExplainEnabled: Bool {
        didSet { UserDefaults.standard.set(errorExplainEnabled, forKey: Keys.errorExplainEnabled) }
    }

    // MARK: - CTO Integration (forwarded to MCPRemoteSettingsStore)

    var isCTOEnabled: Bool {
        get { mcpRemoteStore.isCTOEnabled }
        set { mcpRemoteStore.isCTOEnabled = newValue }
    }

    var ctoPrefix: String {
        get { mcpRemoteStore.ctoPrefix }
        set { mcpRemoteStore.ctoPrefix = newValue }
    }

    var ctoTabOverrides: [String: Bool] {
        get { mcpRemoteStore.ctoTabOverrides }
        set { mcpRemoteStore.ctoTabOverrides = newValue }
    }

    func isCTOEnabled(forTabIdentifier tabIdentifier: String?) -> Bool {
        guard let normalized = normalizeTabIdentifier(tabIdentifier),
              let override = ctoTabOverrides[normalized] else {
            return isCTOEnabled
        }
        return override
    }

    func ctoOverride(forTabIdentifier tabIdentifier: String?) -> Bool? {
        guard let normalized = normalizeTabIdentifier(tabIdentifier) else { return nil }
        return ctoTabOverrides[normalized]
    }

    func setCTOOverride(_ enabled: Bool, forTabIdentifier tabIdentifier: String?) {
        guard let normalized = normalizeTabIdentifier(tabIdentifier) else { return }
        ctoTabOverrides[normalized] = enabled
    }

    func clearCTOOverride(forTabIdentifier tabIdentifier: String?) {
        guard let normalized = normalizeTabIdentifier(tabIdentifier) else { return }
        ctoTabOverrides.removeValue(forKey: normalized)
    }

    // MARK: - Bug Report Contact Info

    var bugReportContactName: String {
        didSet { UserDefaults.standard.set(bugReportContactName, forKey: Keys.bugReportContactName) }
    }

    var bugReportContactHandle: String {
        didSet { UserDefaults.standard.set(bugReportContactHandle, forKey: Keys.bugReportContactHandle) }
    }

    var bugReportIssueEndpoint: String {
        didSet { UserDefaults.standard.set(bugReportIssueEndpoint, forKey: Keys.bugReportIssueEndpoint) }
    }

    // MARK: - Profile Version Counter

    /// Bumped on every write to savedProfiles / activeProfileId so @Observable picks up changes.
    /// Must live in the main class body (not an extension) because extensions cannot have stored properties.
    private var _profileVersion = 0

    // MARK: - Keys

    private enum Keys {
        /// Font (NEW)
        /// Color Scheme (NEW)
        /// Shell (NEW)
        /// Keyboard Shortcuts (NEW)
        static let autoSubmitRestorePrefill = "restore.autoSubmitPrefill"
        // Hover Card Sections live in TabDisplaySettingsStore.Keys
        // Notification Filters (NEW)
        // Find Defaults (NEW)
        static let findCaseSensitiveDefault = "search.defaultCaseSensitive"
        static let findRegexDefault = "search.defaultRegex"
        /// Tab Behavior lives in TabDisplaySettingsStore.Keys
        /// App chrome (theme, language, launch at login, window mode/opacity,
        /// ligatures) lives in AppChromeSettingsStore.Keys
        /// iCloud Sync (NEW)
        static let iCloudSyncEnabled = "sync.iCloudEnabled"
        /// Productivity features (F03/F05/F13/F16/F17/F18/F19/F20/F21 +
        /// custom AI detection) live in ProductivitySettingsStore.Keys
        static let mouseReporting = "feature.mouseReporting"
        static let useMetalRenderer = "feature.useMetalRenderer"
        static let clickToPosition = "feature.clickToPosition"
        static let urlHandler = "feature.urlHandler"
        static let activePollingRateCap = "feature.activePollingRateCap"
        static let allowProtectedFolderAccess = "feature.allowProtectedFolderAccess"
        static let recentRepoRoots = "feature.recentRepoRoots"
        // F08
        static let syntaxHighlight = "feature.syntaxHighlight"
        static let clickableURLs = "feature.clickableURLs"
        static let inlineImages = "feature.inlineImages"
        static let jsonPrettyPrint = "feature.jsonPrettyPrint"
        /// F07
        static let semanticSearch = "feature.semanticSearch"
        /// F02
        static let splitPanes = "feature.splitPanes"
        /// Smart Scroll
        static let smartScrollEnabled = "feature.smartScrollEnabled"
        /// F11
        static let keybindingPreset = "feature.keybindingPreset"
        /// Overlay Positions
        static let overlayPositionsMap = "overlay.positions.map"
        // API Analytics
        static let apiAnalyticsEnabled = "analytics.api.enabled"
        static let apiAnalyticsPort = "analytics.api.port"
        static let apiAnalyticsLogPrompts = "analytics.api.logPrompts"
        static let apiAnalyticsIncludeOpenAI = "analytics.api.includeOpenAI"
        // Token Optimization (CTO), MCP, and Remote Control live in
        // MCPRemoteSettingsStore.Keys
        // Bug Report
        static let bugReportContactName = "bugReport.contactName"
        static let bugReportContactHandle = "bugReport.contactHandle"
        static let bugReportIssueEndpoint = "bugReport.issueEndpoint"
        /// Shell Event Detection
        static let shellEventConfig = "shell.eventConfig"
        /// App Event Detection
        static let appEventConfig = "app.eventConfig"
        /// Notification Permission (persistent tracking)
        static let hasRequestedNotificationPermission = "notifications.hasRequestedPermission"
        /// LLM / Error Explanation
        static let errorExplainEnabled = "feature.errorExplainEnabled"
        // CTO Integration lives in MCPRemoteSettingsStore.Keys
    }

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard

        // MCP/remote/CTO settings live in MCPRemoteSettingsStore; its init
        // runs the one-time RTK → CTO key migration, so it must be created
        // first.
        self.mcpRemoteStore = MCPRemoteSettingsStore()

        // Tab behavior/display/hover-card settings live in
        // TabDisplaySettingsStore; created after the migration above so the
        // store loads the migrated CTO indicator value.
        self.tabDisplayStore = TabDisplaySettingsStore()

        // Keyboard shortcuts live in ShortcutSettingsStore.
        self.autoSubmitRestorePrefill = defaults.object(forKey: Keys.autoSubmitRestorePrefill) as? Bool ?? false

        // Find Defaults (NEW)
        self.findCaseSensitiveDefault = defaults.object(forKey: Keys.findCaseSensitiveDefault) as? Bool ?? false
        self.findRegexDefault = defaults.object(forKey: Keys.findRegexDefault) as? Bool ?? false

        // App chrome (theme, language, window mode/opacity, launch at login,
        // ligatures) lives in AppChromeSettingsStore.

        // iCloud Sync (NEW)
        self.iCloudSyncEnabled = defaults.object(forKey: Keys.iCloudSyncEnabled) as? Bool ?? false

        // Productivity features (F03/F05/F13/F16/F17/F18/F19/F20/F21 +
        // custom AI detection) live in ProductivitySettingsStore.
        // Mouse reporting: disabled by default so text selection always works
        // Users can enable if they want vim/tmux mouse support (hold Shift to bypass)
        self.isMouseReportingEnabled = defaults.object(forKey: Keys.mouseReporting) as? Bool ?? false
        // Metal renderer: enabled by default (GPU-accelerated with cursor/text blink, Retina scaling)
        self.useMetalRenderer = defaults.object(forKey: Keys.useMetalRenderer) as? Bool ?? true
        // Click-to-position: enabled by default (like modern text editors)
        self.isClickToPositionEnabled = defaults.object(forKey: Keys.clickToPosition) as? Bool ?? true
        if let handlerRaw = defaults.string(forKey: Keys.urlHandler),
           let handler = URLHandler(rawValue: handlerRaw) {
            self.urlHandler = handler
        } else {
            self.urlHandler = .system
        }
        if let rateCapRaw = defaults.string(forKey: Keys.activePollingRateCap),
           let rateCap = ActivePollingRateCap(rawValue: rateCapRaw) {
            self.activePollingRateCap = rateCap
        } else {
            self.activePollingRateCap = .displayNative
        }

        // Cross-cutting security/repo state (the rest of F21 lives in
        // ProductivitySettingsStore)
        self.allowProtectedFolderAccess = defaults.object(forKey: Keys.allowProtectedFolderAccess) as? Bool ?? false
        self.recentRepoRoots = defaults.stringArray(forKey: Keys.recentRepoRoots) ?? []

        // F08: Syntax Highlighting (default: enabled)
        self.isSyntaxHighlightEnabled = defaults.object(forKey: Keys.syntaxHighlight) as? Bool ?? true
        self.isClickableURLsEnabled = defaults.object(forKey: Keys.clickableURLs) as? Bool ?? true
        self.isInlineImagesEnabled = defaults.object(forKey: Keys.inlineImages) as? Bool ?? true
        self.isJSONPrettyPrintEnabled = defaults.object(forKey: Keys.jsonPrettyPrint) as? Bool ?? false

        // F07: Semantic Search (default: disabled - requires shell integration)
        self.isSemanticSearchEnabled = defaults.object(forKey: Keys.semanticSearch) as? Bool ?? false

        // F02: Split Panes (default: enabled)
        self.isSplitPanesEnabled = defaults.object(forKey: Keys.splitPanes) as? Bool ?? true

        // Smart Scroll (default: enabled - preserves user's scroll position on new output)
        self.isSmartScrollEnabled = defaults.object(forKey: Keys.smartScrollEnabled) as? Bool ?? true

        // F11: Keybindings (default: "default")
        self.keybindingPreset = defaults.string(forKey: Keys.keybindingPreset) ?? "default"

        // API Analytics (default: disabled)
        self.isAPIAnalyticsEnabled = defaults.object(forKey: Keys.apiAnalyticsEnabled) as? Bool ?? false
        self.apiAnalyticsPort = defaults.object(forKey: Keys.apiAnalyticsPort) as? Int ?? AppConstants.Network.defaultProxyPort
        self.apiAnalyticsLogPrompts = defaults.object(forKey: Keys.apiAnalyticsLogPrompts) as? Bool ?? false
        self.apiAnalyticsIncludeOpenAI = defaults.object(forKey: Keys.apiAnalyticsIncludeOpenAI) as? Bool ?? true

        // Token Optimization, MCP, Remote Control, and CTO Integration live
        // in MCPRemoteSettingsStore (created at the top of this init).

        let integration = Self.integrationSettings(from: defaults)
        self.shellEventConfig = integration.shellEventConfig
        self.appEventConfig = integration.appEventConfig
        self.hasRequestedNotificationPermission = integration.hasRequestedNotificationPermission
        self.errorExplainEnabled = integration.errorExplainEnabled

        // Bug Report Contact Info
        self.bugReportContactName = defaults.string(forKey: Keys.bugReportContactName) ?? ""
        self.bugReportContactHandle = defaults.string(forKey: Keys.bugReportContactHandle) ?? ""
        self.bugReportIssueEndpoint = defaults.string(forKey: Keys.bugReportIssueEndpoint) ?? "https://issues.chau7.sh"
    }

    private static func integrationSettings(from defaults: UserDefaults) -> IntegrationSettings {
        let shellEventConfig: ShellEventConfig
        if let data = defaults.data(forKey: Keys.shellEventConfig),
           let config = JSONOperations.decode(ShellEventConfig.self, from: data, context: "shellEventConfig") {
            shellEventConfig = config
        } else {
            shellEventConfig = .default
        }

        let appEventConfig: AppEventConfig
        if let data = defaults.data(forKey: Keys.appEventConfig),
           let config = JSONOperations.decode(AppEventConfig.self, from: data, context: "appEventConfig") {
            appEventConfig = config
        } else {
            appEventConfig = .default
        }

        return IntegrationSettings(
            shellEventConfig: shellEventConfig,
            appEventConfig: appEventConfig,
            hasRequestedNotificationPermission: defaults.object(forKey: Keys.hasRequestedNotificationPermission) as? Bool ?? false,
            errorExplainEnabled: defaults.object(forKey: Keys.errorExplainEnabled) as? Bool ?? false
        )
    }

    // MARK: - Overlay Positions Cache (Performance Optimization)

    /// Cached overlay positions to avoid repeated UserDefaults parsing
    @ObservationIgnored private var cachedOverlayPositions: [String: [String: [String: Double]]]?

    func overlayOffset(for id: String, workspace: String?) -> CGSize {
        let key = overlayWorkspaceKey(workspace)
        let store = overlayPositionsStore()
        guard let workspaceStore = store[key],
              let entry = workspaceStore[id],
              let x = entry["x"],
              let y = entry["y"] else {
            return .zero
        }
        return CGSize(width: x, height: y)
    }

    func setOverlayOffset(_ offset: CGSize, for id: String, workspace: String?) {
        let key = overlayWorkspaceKey(workspace)
        var store = overlayPositionsStore()
        var workspaceStore = store[key] ?? [:]
        workspaceStore[id] = ["x": offset.width, "y": offset.height]
        store[key] = workspaceStore
        saveOverlayPositionsStore(store)
    }

    func resetOverlayOffsets(workspace: String? = nil) {
        var store = overlayPositionsStore()
        if let workspace {
            store.removeValue(forKey: overlayWorkspaceKey(workspace))
        } else {
            store.removeAll()
        }
        saveOverlayPositionsStore(store)
    }

    private func overlayPositionsStore() -> [String: [String: [String: Double]]] {
        // Return cached version if available
        if let cached = cachedOverlayPositions {
            return cached
        }

        let defaults = UserDefaults.standard
        guard let stored = defaults.dictionary(forKey: Keys.overlayPositionsMap) else {
            cachedOverlayPositions = [:]
            return [:]
        }
        var result: [String: [String: [String: Double]]] = [:]
        for (workspaceKey, value) in stored {
            guard let overlayDict = value as? [String: Any] else { continue }
            var overlayStore: [String: [String: Double]] = [:]
            for (overlayID, coordsValue) in overlayDict {
                if let coords = coordsValue as? [String: Double] {
                    overlayStore[overlayID] = coords
                }
            }
            result[workspaceKey] = overlayStore
        }
        cachedOverlayPositions = result
        return result
    }

    private func saveOverlayPositionsStore(_ store: [String: [String: [String: Double]]]) {
        cachedOverlayPositions = store // Update cache
        UserDefaults.standard.set(store, forKey: Keys.overlayPositionsMap)
        overlayPositionsVersion += 1
    }

    private func overlayWorkspaceKey(_ workspace: String?) -> String {
        let base = workspace?.trimmingCharacters(in: .whitespacesAndNewlines)
        return base?.isEmpty == false ? base! : "global"
    }

    private func normalizeTabIdentifier(_ tabIdentifier: String?) -> String? {
        guard let tabIdentifier else { return nil }
        let trimmed = tabIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Import/Export Settings (NEW)

    struct ExportableSettings: Codable {
        var fontFamily: String
        var fontSize: Int
        var defaultZoomPercent: Int?
        var colorSchemeName: String
        var customColorScheme: TerminalColorScheme?
        var shellType: String
        var customShellPath: String
        var startupCommand: String
        var isLsColorsEnabled: Bool?
        var customShortcuts: [KeyboardShortcut]
        var isShortcutHelperHintEnabled: Bool?
        var notificationTriggerState: NotificationTriggerState?
        var notificationFilters: NotificationFilters
        var triggerActionBindings: [String: [NotificationActionConfig]]?
        var notificationRateLimitConfig: NotificationRateLimiter.Config?
        var triggerConditions: [String: TriggerCondition]?
        var groupActionBindings: [String: [NotificationActionConfig]]?
        var groupConditions: [String: TriggerCondition]?
        var findCaseSensitiveDefault: Bool?
        var findRegexDefault: Bool?
        var lastTabCloseBehavior: String?
        var newTabPosition: String?
        var newTabsUseCurrentDirectory: Bool?
        var alwaysShowTabBar: Bool?
        var alwaysShowToolbarInFullscreen: Bool?
        var appTheme: String?
        var launchAtLogin: Bool?
        var appLanguage: String?
        var windowOpacity: Double
        var cursorStyle: String
        var cursorBlink: Bool
        var scrollbackLines: Int
        var shellHistoryMaxLines: Int?
        var restoredScrollbackLines: Int
        var bellEnabled: Bool
        var bellSound: String
        var isDangerousCommandHighlightEnabled: Bool?
        var dangerousCommandHighlightScope: String?
        var dangerousCommandPatterns: [String]?
        var dangerousCommandProtectChau7Enabled: Bool?
        var dangerousCommandProtectChau7Level: String?
        var dangerousCommandProtectedProcessPatterns: [String]?
        var dangerousOutputHighlightIdleDelayMs: Int?
        var dangerousOutputHighlightMaxIntervalMs: Int?
        var dangerousOutputHighlightLowPowerEnabled: Bool?
        var defaultStartDirectory: String
        var isAutoTabThemeEnabled: Bool
        var showTabIcons: Bool?
        var showTabPath: Bool?
        var showTabGitIndicator: Bool?
        var showTabCTOIndicator: Bool?
        var allowTabCTOToggle: Bool?
        var showTabBroadcastIndicator: Bool?
        // Hover Card
        var hoverCardShowDirectory: Bool?
        var hoverCardShowGitBranch: Bool?
        var hoverCardShowShellIntegration: Bool?
        var hoverCardShowDevServer: Bool?
        var hoverCardShowLastCommand: Bool?
        var hoverCardShowAISession: Bool?
        var hoverCardShowRepoStats: Bool?
        var hoverCardShowProcesses: Bool?
        var hoverCardShowTokenOptimization: Bool?
        var hoverCardShowBroadcast: Bool?
        var hoverCardShowConflicts: Bool?
        var hoverCardShowNotificationState: Bool?
        var hoverCardShowFooter: Bool?
        var customTitleOnly: Bool?
        var isCopyOnSelectEnabled: Bool
        var isLineTimestampsEnabled: Bool
        var timestampFormat: String
        var isLastCommandBadgeEnabled: Bool
        var isCmdClickPathsEnabled: Bool
        var cmdClickOpensInternalEditor: Bool? // Optional for backward compatibility
        var isOptionClickCursorEnabled: Bool
        var defaultEditor: String
        var urlHandler: String?
        var activePollingRateCap: String?
        var customAIDetectionRules: [CustomAIDetectionRule]?
        var isBroadcastEnabled: Bool
        var isClipboardHistoryEnabled: Bool
        var clipboardHistoryMaxItems: Int
        var isBookmarksEnabled: Bool
        var maxBookmarksPerTab: Int
        var isSnippetsEnabled: Bool
        var isRepoSnippetsEnabled: Bool
        var allowProtectedFolderAccess: Bool?
        var recentRepoRoots: [String]?
        var repoSnippetPath: String
        var snippetInsertMode: String
        var snippetPlaceholdersEnabled: Bool
        var isSyntaxHighlightEnabled: Bool
        var isClickableURLsEnabled: Bool
        var isInlineImagesEnabled: Bool
        var isJSONPrettyPrintEnabled: Bool
        var isSemanticSearchEnabled: Bool
        var isSplitPanesEnabled: Bool
        var keybindingPreset: String
        var mcpEnabled: Bool?
        var mcpMaxTabs: Int?
        var mcpRequiresApproval: Bool?
        var mcpShowTabIndicator: Bool?
        var mcpPermissionMode: String?
        var mcpAllowedCommands: [String]?
        var mcpBlockedCommands: [String]?
        var mcpProfiles: [MCPProfile]?
        var isRemoteEnabled: Bool?
        var remoteRelayURL: String?
        var isCTOEnabled = false
        var ctoPrefix = ""
        var ctoTabOverrides = [String: Bool]()
        var exportVersion = 1
        /// When this blob was exported. Drives the iCloud freshness guard so
        /// an old device's blob can never clobber newer local settings.
        /// Optional: pre-timestamp exports decode as nil.
        var exportedAt: Date?
    }

    /// Highest export format this build can apply. Imports with a newer
    /// version are refused rather than partially decoded-and-resaved (which
    /// would silently destroy fields this build doesn't know about).
    static let maxSupportedSettingsExportVersion = 1

    func exportSettings() -> Data? {
        var exportable = ExportableSettings(
            fontFamily: fontFamily,
            fontSize: fontSize,
            defaultZoomPercent: defaultZoomPercent,
            colorSchemeName: colorSchemeName,
            customColorScheme: customColorScheme,
            shellType: shellType.rawValue,
            customShellPath: customShellPath,
            startupCommand: startupCommand,
            isLsColorsEnabled: isLsColorsEnabled,
            customShortcuts: customShortcuts,
            isShortcutHelperHintEnabled: isShortcutHelperHintEnabled,
            notificationTriggerState: notificationTriggerState,
            notificationFilters: notificationFilters,
            triggerActionBindings: triggerActionBindings.isEmpty ? nil : triggerActionBindings,
            notificationRateLimitConfig: notificationRateLimitConfig,
            triggerConditions: triggerConditions.isEmpty ? nil : triggerConditions,
            groupActionBindings: groupActionBindings.isEmpty ? nil : groupActionBindings,
            groupConditions: groupConditions.isEmpty ? nil : groupConditions,
            findCaseSensitiveDefault: findCaseSensitiveDefault,
            findRegexDefault: findRegexDefault,
            lastTabCloseBehavior: lastTabCloseBehavior.rawValue,
            newTabPosition: newTabPosition,
            newTabsUseCurrentDirectory: newTabsUseCurrentDirectory,
            alwaysShowTabBar: alwaysShowTabBar,
            alwaysShowToolbarInFullscreen: alwaysShowToolbarInFullscreen,
            appTheme: appTheme.rawValue,
            launchAtLogin: launchAtLogin,
            appLanguage: appLanguage.rawValue,
            windowOpacity: windowOpacity,
            cursorStyle: cursorStyle,
            cursorBlink: cursorBlink,
            scrollbackLines: scrollbackLines,
            shellHistoryMaxLines: shellHistoryMaxLines,
            restoredScrollbackLines: restoredScrollbackLines,
            bellEnabled: bellEnabled,
            bellSound: bellSound,
            isDangerousCommandHighlightEnabled: dangerousCommandHighlightScope != .none,
            dangerousCommandHighlightScope: dangerousCommandHighlightScope.rawValue,
            dangerousCommandPatterns: dangerousCommandPatterns,
            dangerousCommandProtectChau7Enabled: dangerousCommandProtectChau7Enabled,
            dangerousCommandProtectChau7Level: dangerousCommandProtectChau7Level.rawValue,
            dangerousCommandProtectedProcessPatterns: dangerousCommandProtectedProcessPatterns,
            dangerousOutputHighlightIdleDelayMs: dangerousOutputHighlightIdleDelayMs,
            dangerousOutputHighlightMaxIntervalMs: dangerousOutputHighlightMaxIntervalMs,
            dangerousOutputHighlightLowPowerEnabled: dangerousOutputHighlightLowPowerEnabled,
            defaultStartDirectory: defaultStartDirectory,
            isAutoTabThemeEnabled: isAutoTabThemeEnabled,
            showTabIcons: showTabIcons,
            showTabPath: showTabPath,
            showTabGitIndicator: showTabGitIndicator,
            showTabCTOIndicator: showTabCTOIndicator,
            allowTabCTOToggle: allowTabCTOToggle,
            showTabBroadcastIndicator: showTabBroadcastIndicator,
            hoverCardShowDirectory: hoverCardShowDirectory,
            hoverCardShowGitBranch: hoverCardShowGitBranch,
            hoverCardShowShellIntegration: hoverCardShowShellIntegration,
            hoverCardShowDevServer: hoverCardShowDevServer,
            hoverCardShowLastCommand: hoverCardShowLastCommand,
            hoverCardShowAISession: hoverCardShowAISession,
            hoverCardShowRepoStats: hoverCardShowRepoStats,
            hoverCardShowProcesses: hoverCardShowProcesses,
            hoverCardShowTokenOptimization: hoverCardShowTokenOptimization,
            hoverCardShowBroadcast: hoverCardShowBroadcast,
            hoverCardShowConflicts: hoverCardShowConflicts,
            hoverCardShowNotificationState: hoverCardShowNotificationState,
            hoverCardShowFooter: hoverCardShowFooter,
            customTitleOnly: customTitleOnly,
            isCopyOnSelectEnabled: isCopyOnSelectEnabled,
            isLineTimestampsEnabled: isLineTimestampsEnabled,
            timestampFormat: timestampFormat,
            isLastCommandBadgeEnabled: isLastCommandBadgeEnabled,
            isCmdClickPathsEnabled: isCmdClickPathsEnabled,
            cmdClickOpensInternalEditor: cmdClickOpensInternalEditor,
            isOptionClickCursorEnabled: isOptionClickCursorEnabled,
            defaultEditor: defaultEditor,
            urlHandler: urlHandler.rawValue,
            activePollingRateCap: activePollingRateCap.rawValue,
            customAIDetectionRules: customAIDetectionRules,
            isBroadcastEnabled: isBroadcastEnabled,
            isClipboardHistoryEnabled: isClipboardHistoryEnabled,
            clipboardHistoryMaxItems: clipboardHistoryMaxItems,
            isBookmarksEnabled: isBookmarksEnabled,
            maxBookmarksPerTab: maxBookmarksPerTab,
            isSnippetsEnabled: isSnippetsEnabled,
            isRepoSnippetsEnabled: isRepoSnippetsEnabled,
            allowProtectedFolderAccess: allowProtectedFolderAccess,
            recentRepoRoots: recentRepoRoots,
            repoSnippetPath: repoSnippetPath,
            snippetInsertMode: snippetInsertMode,
            snippetPlaceholdersEnabled: snippetPlaceholdersEnabled,
            isSyntaxHighlightEnabled: isSyntaxHighlightEnabled,
            isClickableURLsEnabled: isClickableURLsEnabled,
            isInlineImagesEnabled: isInlineImagesEnabled,
            isJSONPrettyPrintEnabled: isJSONPrettyPrintEnabled,
            isSemanticSearchEnabled: isSemanticSearchEnabled,
            isSplitPanesEnabled: isSplitPanesEnabled,
            keybindingPreset: keybindingPreset,
            mcpEnabled: mcpEnabled,
            mcpMaxTabs: mcpMaxTabs,
            mcpRequiresApproval: mcpRequiresApproval,
            mcpShowTabIndicator: mcpShowTabIndicator,
            mcpPermissionMode: mcpPermissionMode.rawValue,
            mcpAllowedCommands: mcpAllowedCommands,
            mcpBlockedCommands: mcpBlockedCommands,
            mcpProfiles: mcpProfiles,
            isRemoteEnabled: isRemoteEnabled,
            remoteRelayURL: remoteRelayURL,
            isCTOEnabled: isCTOEnabled,
            ctoPrefix: ctoPrefix,
            ctoTabOverrides: ctoTabOverrides
        )
        exportable.exportedAt = Date()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return JSONOperations.encode(exportable, context: "settings export")
    }

    func importSettings(from data: Data) -> Bool {
        guard let imported = JSONOperations.decode(ExportableSettings.self, from: data, context: "settings import") else {
            Log.error("Failed to import settings: invalid data format")
            return false
        }
        guard imported.exportVersion <= Self.maxSupportedSettingsExportVersion else {
            Log.error("Refusing settings import: export version \(imported.exportVersion) is newer than supported \(Self.maxSupportedSettingsExportVersion)")
            return false
        }

        fontFamily = imported.fontFamily
        fontSize = imported.fontSize
        defaultZoomPercent = imported.defaultZoomPercent ?? 100
        colorSchemeName = imported.colorSchemeName
        customColorScheme = imported.customColorScheme
        if let shell = ShellType(rawValue: imported.shellType) {
            shellType = shell
        }
        customShellPath = imported.customShellPath
        startupCommand = imported.startupCommand
        isLsColorsEnabled = imported.isLsColorsEnabled ?? true
        customShortcuts = imported.customShortcuts
        isShortcutHelperHintEnabled = imported.isShortcutHelperHintEnabled ?? true
        // Notification settings — assemble struct from imported fields
        var importedTriggerState: NotificationTriggerState
        if let state = imported.notificationTriggerState {
            importedTriggerState = state
            importedTriggerState.normalize()
        } else {
            importedTriggerState = NotificationSettingsStore.triggerState(from: imported.notificationFilters)
        }
        notificationSettings = NotificationSettings(
            triggerState: importedTriggerState,
            filters: NotificationSettingsStore.legacyNotificationFilters(from: importedTriggerState),
            triggerActionBindings: imported.triggerActionBindings ?? notificationSettings.triggerActionBindings,
            rateLimitConfig: imported.notificationRateLimitConfig ?? notificationSettings.rateLimitConfig,
            triggerConditions: imported.triggerConditions ?? notificationSettings.triggerConditions,
            groupActionBindings: imported.groupActionBindings ?? notificationSettings.groupActionBindings,
            groupConditions: imported.groupConditions ?? notificationSettings.groupConditions
        )
        findCaseSensitiveDefault = imported.findCaseSensitiveDefault ?? false
        findRegexDefault = imported.findRegexDefault ?? false
        // Fields absent from the payload keep their current local value —
        // resetting to hardcoded defaults let an older export wipe settings
        // it never knew about.
        if let behaviorRaw = imported.lastTabCloseBehavior,
           let behavior = LastTabCloseBehavior(rawValue: behaviorRaw) {
            lastTabCloseBehavior = behavior
        }
        newTabPosition = imported.newTabPosition ?? "end"
        newTabsUseCurrentDirectory = imported.newTabsUseCurrentDirectory ?? true
        alwaysShowTabBar = imported.alwaysShowTabBar ?? true
        alwaysShowToolbarInFullscreen = imported.alwaysShowToolbarInFullscreen ?? false
        if let themeRaw = imported.appTheme,
           let theme = AppTheme(rawValue: themeRaw) {
            appTheme = theme
        }
        launchAtLogin = imported.launchAtLogin ?? launchAtLogin
        if let langRaw = imported.appLanguage,
           let lang = AppLanguage(rawValue: langRaw) {
            appLanguage = lang
        }
        windowOpacity = imported.windowOpacity
        cursorStyle = imported.cursorStyle
        cursorBlink = imported.cursorBlink
        scrollbackLines = imported.scrollbackLines
        if let shellHistoryMaxLines = imported.shellHistoryMaxLines {
            self.shellHistoryMaxLines = shellHistoryMaxLines
        }
        restoredScrollbackLines = imported.restoredScrollbackLines
        bellEnabled = imported.bellEnabled
        bellSound = imported.bellSound
        if let raw = imported.dangerousCommandHighlightScope,
           let scope = DangerousCommandHighlightScope(rawValue: raw) {
            dangerousCommandHighlightScope = scope
        } else if let enabled = imported.isDangerousCommandHighlightEnabled {
            dangerousCommandHighlightScope = enabled ? .allOutputs : .none
        }
        dangerousCommandPatterns = imported.dangerousCommandPatterns ?? dangerousCommandPatterns
        dangerousCommandProtectChau7Enabled = imported.dangerousCommandProtectChau7Enabled ?? dangerousCommandProtectChau7Enabled
        if let raw = imported.dangerousCommandProtectChau7Level,
           let level = DangerousCommandProtectionLevel(rawValue: raw) {
            dangerousCommandProtectChau7Level = level
        }
        dangerousCommandProtectedProcessPatterns = imported.dangerousCommandProtectedProcessPatterns ?? dangerousCommandProtectedProcessPatterns
        if let idleDelay = imported.dangerousOutputHighlightIdleDelayMs {
            dangerousOutputHighlightIdleDelayMs = idleDelay
        }
        if let maxInterval = imported.dangerousOutputHighlightMaxIntervalMs {
            dangerousOutputHighlightMaxIntervalMs = maxInterval
        }
        if let lowPower = imported.dangerousOutputHighlightLowPowerEnabled {
            dangerousOutputHighlightLowPowerEnabled = lowPower
        }
        defaultStartDirectory = imported.defaultStartDirectory
        isAutoTabThemeEnabled = imported.isAutoTabThemeEnabled
        showTabIcons = imported.showTabIcons ?? true
        showTabPath = imported.showTabPath ?? true
        showTabGitIndicator = imported.showTabGitIndicator ?? true
        showTabCTOIndicator = imported.showTabCTOIndicator ?? true
        allowTabCTOToggle = imported.allowTabCTOToggle ?? true
        showTabBroadcastIndicator = imported.showTabBroadcastIndicator ?? true
        if let v = imported.hoverCardShowDirectory { hoverCardShowDirectory = v }
        if let v = imported.hoverCardShowGitBranch { hoverCardShowGitBranch = v }
        if let v = imported.hoverCardShowShellIntegration { hoverCardShowShellIntegration = v }
        if let v = imported.hoverCardShowDevServer { hoverCardShowDevServer = v }
        if let v = imported.hoverCardShowLastCommand { hoverCardShowLastCommand = v }
        if let v = imported.hoverCardShowAISession { hoverCardShowAISession = v }
        if let v = imported.hoverCardShowRepoStats { hoverCardShowRepoStats = v }
        if let v = imported.hoverCardShowProcesses { hoverCardShowProcesses = v }
        if let v = imported.hoverCardShowTokenOptimization { hoverCardShowTokenOptimization = v }
        if let v = imported.hoverCardShowBroadcast { hoverCardShowBroadcast = v }
        if let v = imported.hoverCardShowConflicts { hoverCardShowConflicts = v }
        if let v = imported.hoverCardShowNotificationState { hoverCardShowNotificationState = v }
        if let v = imported.hoverCardShowFooter { hoverCardShowFooter = v }
        customTitleOnly = imported.customTitleOnly ?? false
        isCopyOnSelectEnabled = imported.isCopyOnSelectEnabled
        isLineTimestampsEnabled = imported.isLineTimestampsEnabled
        timestampFormat = imported.timestampFormat
        isLastCommandBadgeEnabled = imported.isLastCommandBadgeEnabled
        isCmdClickPathsEnabled = imported.isCmdClickPathsEnabled
        cmdClickOpensInternalEditor = imported.cmdClickOpensInternalEditor ?? true // Default for old settings
        isOptionClickCursorEnabled = imported.isOptionClickCursorEnabled
        defaultEditor = imported.defaultEditor
        if let handlerRaw = imported.urlHandler,
           let handler = URLHandler(rawValue: handlerRaw) {
            urlHandler = handler
        }
        if let rateCapRaw = imported.activePollingRateCap,
           let rateCap = ActivePollingRateCap(rawValue: rateCapRaw) {
            activePollingRateCap = rateCap
        }
        customAIDetectionRules = imported.customAIDetectionRules ?? customAIDetectionRules
        isBroadcastEnabled = imported.isBroadcastEnabled
        isClipboardHistoryEnabled = imported.isClipboardHistoryEnabled
        clipboardHistoryMaxItems = imported.clipboardHistoryMaxItems
        isBookmarksEnabled = imported.isBookmarksEnabled
        maxBookmarksPerTab = imported.maxBookmarksPerTab
        isSnippetsEnabled = imported.isSnippetsEnabled
        isRepoSnippetsEnabled = imported.isRepoSnippetsEnabled
        allowProtectedFolderAccess = imported.allowProtectedFolderAccess ?? false
        if let recent = imported.recentRepoRoots {
            recentRepoRoots = recent
            KnownRepoIdentityStore.shared.mergeRecentRoots(recent)
        }
        repoSnippetPath = imported.repoSnippetPath
        snippetInsertMode = imported.snippetInsertMode
        snippetPlaceholdersEnabled = imported.snippetPlaceholdersEnabled
        isSyntaxHighlightEnabled = imported.isSyntaxHighlightEnabled
        isClickableURLsEnabled = imported.isClickableURLsEnabled
        isInlineImagesEnabled = imported.isInlineImagesEnabled
        isJSONPrettyPrintEnabled = imported.isJSONPrettyPrintEnabled
        isSemanticSearchEnabled = imported.isSemanticSearchEnabled
        isSplitPanesEnabled = imported.isSplitPanesEnabled
        keybindingPreset = imported.keybindingPreset
        if let v = imported.mcpEnabled { mcpEnabled = v }
        if let v = imported.mcpMaxTabs { mcpMaxTabs = v }
        if let v = imported.mcpRequiresApproval { mcpRequiresApproval = v }
        if let v = imported.mcpShowTabIndicator { mcpShowTabIndicator = v }
        if let v = imported.mcpPermissionMode, let mode = MCPPermissionMode(rawValue: v) { mcpPermissionMode = mode }
        if let v = imported.mcpAllowedCommands { mcpAllowedCommands = v }
        if let v = imported.mcpBlockedCommands { mcpBlockedCommands = v }
        if let v = imported.mcpProfiles { mcpProfiles = v }
        if let remoteEnabled = imported.isRemoteEnabled {
            isRemoteEnabled = remoteEnabled
        }
        if let relayURL = imported.remoteRelayURL {
            remoteRelayURL = relayURL
        }
        isCTOEnabled = imported.isCTOEnabled
        ctoPrefix = imported.ctoPrefix
        ctoTabOverrides = imported.ctoTabOverrides

        return true
    }

    // MARK: - Reset to Defaults (NEW)

    func resetAllToDefaults() {
        // Extracted domains reset through their stores, deriving from each
        // loader's fallbacks so defaults exist exactly once per domain.
        appearanceStore.resetToDefaults()
        shellStore.resetToDefaults()
        keybindingPreset = "default"
        shortcutStore.resetToDefaults()
        notificationStore.resetToDefaults()
        findCaseSensitiveDefault = false
        findRegexDefault = false
        tabDisplayStore.resetToDefaults()

        // App chrome (theme, language, window mode/opacity, launch at login,
        // ligatures)
        appChromeStore.resetToDefaults()
        // The store's launch-at-login fallback mirrors the installed login
        // item; a full reset must force it off.
        launchAtLogin = false

        // Terminal
        terminalBehaviorStore.resetToDefaults()

        // Features
        productivityStore.resetToDefaults()
        urlHandler = .system
        activePollingRateCap = .displayNative
        allowProtectedFolderAccess = false
        recentRepoRoots = []
        KnownRepoIdentityStore.shared.reset()
        isSyntaxHighlightEnabled = true
        isClickableURLsEnabled = true
        isInlineImagesEnabled = true
        isJSONPrettyPrintEnabled = false
        isSemanticSearchEnabled = false
        isSplitPanesEnabled = true
        mcpRemoteStore.resetToDefaults()
        keybindingPreset = "default"

        // Overlay positions
        resetOverlayOffsets()
    }

    func resetAppearanceToDefaults() {
        resetFontColorsToDefaults()
        resetDisplayToDefaults()
    }

    func resetFontColorsToDefaults() {
        appearanceStore.resetToDefaults()
        windowOpacity = 1.0
        appTheme = .system
        enableLigatures = false
    }

    func resetDisplayToDefaults() {
        isSyntaxHighlightEnabled = true
        isClickableURLsEnabled = true
        isInlineImagesEnabled = true
        isJSONPrettyPrintEnabled = false
        isLineTimestampsEnabled = false
        timestampFormat = "HH:mm:ss"
        isSplitPanesEnabled = true
    }

    func resetTerminalToDefaults() {
        terminalBehaviorStore.resetToDefaults()
        shellStore.resetToDefaults()
        activePollingRateCap = .displayNative
        inactiveViewMaxFPS = 42
    }

    func resetInputToDefaults() {
        keybindingPreset = "default"
        shortcutStore.resetToDefaults()
        isCopyOnSelectEnabled = true
        isCmdClickPathsEnabled = true
        cmdClickOpensInternalEditor = true
        defaultEditor = ""
        urlHandler = .system
        isOptionClickCursorEnabled = true
        isMouseReportingEnabled = false
        isClickToPositionEnabled = true
        isBroadcastEnabled = false
    }

    func resetTabsToDefaults() {
        tabDisplayStore.resetToDefaults()
        repoGroupingMode = .off
        isLastCommandBadgeEnabled = true
        isAutoTabThemeEnabled = true
    }

    func resetProductivityToDefaults() {
        isSnippetsEnabled = true
        isRepoSnippetsEnabled = true
        allowProtectedFolderAccess = false
        recentRepoRoots = []
        KnownRepoIdentityStore.shared.reset()
        repoSnippetPath = ".chau7/snippets"
        snippetInsertMode = "expand"
        snippetPlaceholdersEnabled = true
        isClipboardHistoryEnabled = true
        clipboardHistoryMaxItems = 50
        isBookmarksEnabled = true
        maxBookmarksPerTab = 20
        isSemanticSearchEnabled = false
        findCaseSensitiveDefault = false
        findRegexDefault = false
    }

    // MARK: - iCloud Sync (NEW)

    private var iCloudKey: String {
        let bundleID = Bundle.main.bundleIdentifier ?? "com.chau7"
        return "\(bundleID).settings"
    }

    @ObservationIgnored private var iCloudSyncWorkItem: DispatchWorkItem?
    @ObservationIgnored private let iCloudSyncDebounceInterval: TimeInterval = 2.0 // 2 seconds debounce
    /// `exportedAt` of the last settings blob this Mac pushed to or applied
    /// from iCloud (epoch seconds). The freshness guard refuses blobs that
    /// aren't strictly newer, so an old device can't clobber newer settings.
    private static let lastSyncedSettingsExportedAtKey = "icloud.settings.lastSyncedExportedAt"

    private func recordSyncedSettingsTimestamp(_ date: Date) {
        UserDefaults.standard.set(date.timeIntervalSince1970, forKey: Self.lastSyncedSettingsExportedAtKey)
    }

    private func pushSettingsToiCloud(_ data: Data, label: String) {
        NSUbiquitousKeyValueStore.default.set(data, forKey: iCloudKey)
        NSUbiquitousKeyValueStore.default.synchronize()
        recordSyncedSettingsTimestamp(Date())
        Log.info("Settings synced to iCloud (\(label))")
    }

    func syncToiCloud() {
        guard !RuntimeIsolation.isIsolatedTestMode() else { return }
        guard iCloudSyncEnabled else { return }

        // Cancel previous pending sync
        iCloudSyncWorkItem?.cancel()

        // Create new debounced sync
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, iCloudSyncEnabled else { return }
            guard let data = exportSettings() else { return }
            pushSettingsToiCloud(data, label: "debounced")
        }

        iCloudSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + iCloudSyncDebounceInterval, execute: workItem)
    }

    /// Force immediate sync without debouncing (e.g., on app quit)
    func forceSyncToiCloud() {
        guard !RuntimeIsolation.isIsolatedTestMode() else { return }
        guard iCloudSyncEnabled else { return }
        iCloudSyncWorkItem?.cancel()
        guard let data = exportSettings() else { return }
        pushSettingsToiCloud(data, label: "forced")
    }

    func syncFromiCloud() {
        guard !RuntimeIsolation.isIsolatedTestMode() else { return }
        guard iCloudSyncEnabled else { return }
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: iCloudKey) else {
            Log.info("No iCloud settings found")
            return
        }
        // Freshness guard: whole-blob last-writer-wins with no comparison let
        // an old device's blob silently clobber newer local settings. Apply
        // only blobs strictly newer than what this Mac last pushed/applied.
        if let incoming = JSONOperations.decode(ExportableSettings.self, from: data, context: "settings iCloud peek"),
           let incomingExportedAt = incoming.exportedAt {
            let lastSynced = UserDefaults.standard.double(forKey: Self.lastSyncedSettingsExportedAtKey)
            if lastSynced > 0, incomingExportedAt.timeIntervalSince1970 <= lastSynced {
                Log.info("Skipping iCloud settings import: incoming export is not newer than the last synced state")
                return
            }
            if importSettings(from: data) {
                recordSyncedSettingsTimestamp(incomingExportedAt)
                Log.info("Settings restored from iCloud")
            } else {
                Log.warn("Failed to restore settings from iCloud")
            }
            return
        }
        // Pre-timestamp blob: keep legacy apply-always behavior.
        if importSettings(from: data) {
            Log.info("Settings restored from iCloud (legacy untimestamped blob)")
        } else {
            Log.warn("Failed to restore settings from iCloud")
        }
    }

    func setupiCloudSync() {
        guard !RuntimeIsolation.isIsolatedTestMode() else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iCloudSettingsChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    @objc private func iCloudSettingsChanged(_ notification: Notification) {
        guard !RuntimeIsolation.isIsolatedTestMode() else { return }
        guard iCloudSyncEnabled else { return }
        DispatchQueue.main.async { [weak self] in
            self?.syncFromiCloud()
        }
    }
}

// MARK: - Settings Profile

struct SettingsProfile: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var icon: String // SF Symbol name
    var createdAt: Date
    var settings: FeatureSettings.ExportableSettings

    init(name: String, icon: String = "person.fill", settings: FeatureSettings.ExportableSettings) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.createdAt = Date()
        self.settings = settings
    }

    /// Custom Equatable - compare by ID since ExportableSettings does not conform to Equatable
    static func == (lhs: SettingsProfile, rhs: SettingsProfile) -> Bool {
        lhs.id == rhs.id
    }

    static let defaultProfiles: [SettingsProfile] = [
        SettingsProfile(name: "Default", icon: "house.fill", settings: FeatureSettings.defaultExportableSettings)
    ]

    static let availableIcons: [String] = [
        "house.fill", "person.fill", "briefcase.fill", "building.2.fill",
        "laptopcomputer", "desktopcomputer", "display", "tv.fill",
        "moon.fill", "sun.max.fill", "leaf.fill", "bolt.fill",
        "sparkles", "flame.fill", "paintbrush.fill", "hammer.fill"
    ]
}

// MARK: - Profile Management

extension FeatureSettings {
    private static let profilesKey = "settings.profiles"
    private static let activeProfileKey = "settings.activeProfile"

    static var defaultExportableSettings: ExportableSettings {
        let home = RuntimeIsolation.homePath()
        return ExportableSettings(
            fontFamily: "SF Mono",
            fontSize: 11,
            defaultZoomPercent: 100,
            colorSchemeName: "Default",
            customColorScheme: nil,
            shellType: "system",
            customShellPath: "",
            startupCommand: "",
            isLsColorsEnabled: true,
            customShortcuts: KeyboardShortcut.shortcuts(for: "default"),
            isShortcutHelperHintEnabled: true,
            notificationTriggerState: NotificationTriggerState(),
            notificationFilters: .defaults,
            notificationRateLimitConfig: .default,
            triggerConditions: nil,
            groupActionBindings: nil,
            groupConditions: nil,
            findCaseSensitiveDefault: false,
            findRegexDefault: false,
            lastTabCloseBehavior: "keepWindow",
            newTabPosition: "end",
            newTabsUseCurrentDirectory: true,
            alwaysShowTabBar: true,
            appTheme: "system",
            launchAtLogin: false,
            appLanguage: "system",
            windowOpacity: 1.0,
            cursorStyle: "block",
            cursorBlink: true,
            scrollbackLines: 10000,
            restoredScrollbackLines: 500,
            bellEnabled: true,
            bellSound: "default",
            defaultStartDirectory: home,
            isAutoTabThemeEnabled: true,
            showTabIcons: true,
            showTabPath: true,
            showTabGitIndicator: true,
            showTabCTOIndicator: true,
            allowTabCTOToggle: true,
            showTabBroadcastIndicator: true,
            hoverCardShowDirectory: true,
            hoverCardShowGitBranch: true,
            hoverCardShowShellIntegration: false,
            hoverCardShowDevServer: true,
            hoverCardShowLastCommand: true,
            hoverCardShowAISession: true,
            hoverCardShowRepoStats: true,
            hoverCardShowProcesses: true,
            hoverCardShowTokenOptimization: false,
            hoverCardShowBroadcast: false,
            hoverCardShowConflicts: true,
            hoverCardShowNotificationState: true,
            hoverCardShowFooter: true,
            customTitleOnly: false,
            isCopyOnSelectEnabled: false,
            isLineTimestampsEnabled: false,
            timestampFormat: "HH:mm:ss",
            isLastCommandBadgeEnabled: true,
            isCmdClickPathsEnabled: true,
            cmdClickOpensInternalEditor: true,
            isOptionClickCursorEnabled: true,
            defaultEditor: "",
            urlHandler: "system",
            activePollingRateCap: "displayNative",
            customAIDetectionRules: [],
            isBroadcastEnabled: false,
            isClipboardHistoryEnabled: true,
            clipboardHistoryMaxItems: 50,
            isBookmarksEnabled: true,
            maxBookmarksPerTab: 20,
            isSnippetsEnabled: true,
            isRepoSnippetsEnabled: true,
            allowProtectedFolderAccess: false,
            repoSnippetPath: ".chau7/snippets",
            snippetInsertMode: "expand",
            snippetPlaceholdersEnabled: true,
            isSyntaxHighlightEnabled: true,
            isClickableURLsEnabled: true,
            isInlineImagesEnabled: true,
            isJSONPrettyPrintEnabled: false,
            isSemanticSearchEnabled: false,
            isSplitPanesEnabled: true,
            keybindingPreset: "default",
            mcpEnabled: true,
            mcpMaxTabs: 4,
            mcpRequiresApproval: false,
            mcpShowTabIndicator: true,
            mcpPermissionMode: MCPPermissionMode.allowAll.rawValue,
            mcpAllowedCommands: [],
            mcpBlockedCommands: [],
            mcpProfiles: [],
            isRemoteEnabled: false,
            remoteRelayURL: "wss://relay.chau7.sh/connect",
            isCTOEnabled: false,
            ctoPrefix: "",
            ctoTabOverrides: [:]
        )
    }

    var savedProfiles: [SettingsProfile] {
        get {
            _ = _profileVersion // read-access triggers observation
            guard let data = UserDefaults.standard.data(forKey: Self.profilesKey),
                  let profiles = JSONOperations.decode([SettingsProfile].self, from: data, context: "savedProfiles") else {
                return SettingsProfile.defaultProfiles
            }
            return profiles
        }
        set {
            if let data = JSONOperations.encode(newValue, context: "savedProfiles") {
                UserDefaults.standard.set(data, forKey: Self.profilesKey)
            }
            _profileVersion += 1
        }
    }

    var activeProfileId: UUID? {
        get {
            _ = _profileVersion // read-access triggers observation
            guard let idString = UserDefaults.standard.string(forKey: Self.activeProfileKey) else { return nil }
            return UUID(uuidString: idString)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: Self.activeProfileKey)
            _profileVersion += 1
        }
    }

    var activeProfile: SettingsProfile? {
        guard let id = activeProfileId else { return nil }
        return savedProfiles.first { $0.id == id }
    }

    func createProfile(name: String, icon: String = "person.fill") -> SettingsProfile {
        guard let currentSettings = exportSettings(),
              let exportable = JSONOperations.decode(ExportableSettings.self, from: currentSettings, context: "createProfile") else {
            Log.warn("Failed to create profile from current settings, using defaults")
            return SettingsProfile(name: name, icon: icon, settings: Self.defaultExportableSettings)
        }
        let profile = SettingsProfile(name: name, icon: icon, settings: exportable)
        var profiles = savedProfiles
        profiles.append(profile)
        savedProfiles = profiles
        return profile
    }

    func updateProfile(_ profile: SettingsProfile) {
        var profiles = savedProfiles
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
            savedProfiles = profiles
        }
    }

    func deleteProfile(id: UUID) {
        var profiles = savedProfiles
        profiles.removeAll { $0.id == id }
        savedProfiles = profiles
        if activeProfileId == id {
            activeProfileId = nil
        }
    }

    func loadProfile(_ profile: SettingsProfile) {
        guard let data = JSONOperations.encode(profile.settings, context: "load profile \(profile.name)") else {
            Log.error("Failed to load profile \(profile.name): encoding failed")
            return
        }
        _ = importSettings(from: data)
        activeProfileId = profile.id
        NotificationCenter.default.post(name: .settingsProfileChanged, object: profile)
    }

    func saveCurrentToProfile(_ profile: SettingsProfile) {
        guard let currentSettings = exportSettings(),
              let exportable = JSONOperations.decode(ExportableSettings.self, from: currentSettings, context: "save to profile \(profile.name)") else {
            return
        }
        var updatedProfile = profile
        updatedProfile.settings = exportable
        updateProfile(updatedProfile)
    }
}
