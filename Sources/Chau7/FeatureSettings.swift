import Foundation
import AppKit
import SwiftUI
import Chau7Core

// Import Localization for AppLanguage
// Note: AppLanguage is defined in Localization.swift
// Note: TerminalColorScheme is defined in TerminalColorScheme.swift

// MARK: - Keyboard Shortcut

struct KeyboardShortcut: Codable, Identifiable, Equatable {
    var id: String { action }
    let action: String
    var key: String
    var modifiers: [String]  // ["cmd", "shift", "ctrl", "opt"]

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
        KeyboardShortcut(action: "findPrevious", key: "g", modifiers: ["cmd", "opt"]),
        KeyboardShortcut(action: "clear", key: "k", modifiers: ["cmd", "opt"]),
        KeyboardShortcut(action: "snippets", key: "s", modifiers: ["cmd", "opt"]),
        KeyboardShortcut(action: "renameTab", key: "r", modifiers: ["cmd", "opt"]),
        KeyboardShortcut(action: "debugConsole", key: "l", modifiers: ["cmd", "opt"]),
        KeyboardShortcut(action: "splitHorizontal", key: "h", modifiers: ["cmd", "opt"]),
        KeyboardShortcut(action: "splitVertical", key: "v", modifiers: ["cmd", "opt"]),
        // Recovery shortcut
        KeyboardShortcut(action: "refreshTabBar", key: "r", modifiers: ["cmd", "shift"]),
    ]

    static func shortcuts(for preset: String) -> [KeyboardShortcut] {
        switch preset {
        case "vim":
            return applyOverrides(
                to: defaultShortcuts,
                overrides: [
                    "nextTab": KeyboardShortcut(action: "nextTab", key: "l", modifiers: ["ctrl"]),
                    "previousTab": KeyboardShortcut(action: "previousTab", key: "h", modifiers: ["ctrl"]),
                ]
            )
        case "emacs":
            return applyOverrides(
                to: defaultShortcuts,
                overrides: [
                    "nextTab": KeyboardShortcut(action: "nextTab", key: "n", modifiers: ["ctrl"]),
                    "previousTab": KeyboardShortcut(action: "previousTab", key: "p", modifiers: ["ctrl"]),
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
        case "newTab": return "New Tab"
        case "closeTab": return "Close Tab"
        case "nextTab": return "Next Tab"
        case "previousTab": return "Previous Tab"
        case "find": return "Find"
        case "findNext": return "Find Next"
        case "findPrevious": return "Find Previous"
        case "copy": return "Copy"
        case "paste": return "Paste"
        case "clear": return "Clear Scrollback"
        case "zoomIn": return "Zoom In"
        case "zoomOut": return "Zoom Out"
        case "zoomReset": return "Reset Zoom"
        case "snippets": return "Open Snippets"
        case "renameTab": return "Rename Tab"
        case "debugConsole": return "Debug Console"
        case "newWindow": return "New Window"
        case "splitHorizontal": return "Split Horizontal"
        case "splitVertical": return "Split Vertical"
        default: return action
        }
    }
}

// MARK: - Shell Type

enum ShellType: String, CaseIterable, Identifiable {
    case system = "system"
    case zsh = "/bin/zsh"
    case bash = "/bin/bash"
    case fish = "/opt/homebrew/bin/fish"
    case fishIntel = "/usr/local/bin/fish"
    case custom = "custom"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System Default"
        case .zsh: return "Zsh"
        case .bash: return "Bash"
        case .fish: return "Fish (Apple Silicon)"
        case .fishIntel: return "Fish (Intel)"
        case .custom: return "Custom..."
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

// MARK: - Notification Event Types

struct NotificationFilters: Codable, Equatable {
    var taskFinished: Bool = true
    var taskFailed: Bool = true
    var needsValidation: Bool = true
    var permissionRequest: Bool = true
    var toolComplete: Bool = false
    var sessionEnd: Bool = false
    var commandIdle: Bool = true

    static let defaults = NotificationFilters()
}

// MARK: - Last Tab Close Behavior

private extension FeatureSettings {
    static func triggerState(from filters: NotificationFilters) -> NotificationTriggerState {
        var state = NotificationTriggerState()
        for trigger in NotificationTriggerCatalog.all {
            switch trigger.type {
            case "finished":
                state.setEnabled(filters.taskFinished, for: trigger)
            case "failed":
                state.setEnabled(filters.taskFailed, for: trigger)
            case "needs_validation":
                state.setEnabled(filters.needsValidation, for: trigger)
            case "permission":
                state.setEnabled(filters.permissionRequest, for: trigger)
            case "tool_complete":
                state.setEnabled(filters.toolComplete, for: trigger)
            case "session_end":
                state.setEnabled(filters.sessionEnd, for: trigger)
            case "idle":
                state.setEnabled(filters.commandIdle, for: trigger)
            default:
                continue
            }
        }
        return state
    }

    static func legacyNotificationFilters(from state: NotificationTriggerState) -> NotificationFilters {
        func anyEnabled(_ type: String) -> Bool {
            let triggers = NotificationTriggerCatalog.all.filter { $0.type == type && !$0.isWildcard }
            guard !triggers.isEmpty else { return true }
            return triggers.contains { state.isEnabled(for: $0) }
        }

        return NotificationFilters(
            taskFinished: anyEnabled("finished"),
            taskFailed: anyEnabled("failed"),
            needsValidation: anyEnabled("needs_validation"),
            permissionRequest: anyEnabled("permission"),
            toolComplete: anyEnabled("tool_complete"),
            sessionEnd: anyEnabled("session_end"),
            commandIdle: anyEnabled("idle")
        )
    }
}

enum LastTabCloseBehavior: String, CaseIterable, Identifiable, Codable {
    case keepWindow
    case closeWindow

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .keepWindow:
            return "Keep Window Open (New Tab)"
        case .closeWindow:
            return "Close Window"
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

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return "System Default"
        case .safari: return "Safari"
        case .chrome: return "Google Chrome"
        case .firefox: return "Firefox"
        case .edge: return "Microsoft Edge"
        case .brave: return "Brave"
        case .arc: return "Arc"
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

// MARK: - Shell Event Configuration

/// Configuration for shell event detection (patterns, thresholds, etc.)
struct ShellEventConfig: Codable, Equatable {
    /// Patterns to match in command output (regex strings)
    var outputPatterns: [ShellOutputPattern] = []
    /// Exit codes to specifically watch for
    var watchedExitCodes: [Int] = [1, 2, 126, 127, 128, 130, 137, 139, 143]
    /// Threshold in seconds for "long-running" command detection
    var longRunningThresholdSeconds: Int = 60
    /// Enable directory change notifications
    var notifyOnDirectoryChange: Bool = false
    /// Enable git branch change notifications
    var notifyOnGitBranchChange: Bool = false
    /// Enable all command completion notifications (not just failures)
    var notifyOnAllCommandCompletion: Bool = false

    static let `default` = ShellEventConfig()
}

/// A pattern to match in shell output
struct ShellOutputPattern: Codable, Identifiable, Equatable, Hashable {
    var id: UUID = UUID()
    var name: String
    var pattern: String  // regex pattern
    var isEnabled: Bool = true
    var notificationType: String = "pattern_match"  // maps to trigger type

    static let defaults: [ShellOutputPattern] = [
        ShellOutputPattern(name: "Error", pattern: "(?i)\\b(error|failed|failure)\\b", isEnabled: false),
        ShellOutputPattern(name: "Warning", pattern: "(?i)\\bwarning\\b", isEnabled: false),
        ShellOutputPattern(name: "Build Success", pattern: "(?i)\\b(build succeeded|compilation successful)\\b", isEnabled: false),
        ShellOutputPattern(name: "Test Passed", pattern: "(?i)\\b(tests? passed|all tests pass)\\b", isEnabled: false),
        ShellOutputPattern(name: "Test Failed", pattern: "(?i)\\b(tests? failed|test failure)\\b", isEnabled: false),
    ]
}

// MARK: - App Event Detection Config

/// Configuration for app-level event detection
struct AppEventConfig: Codable, Equatable {
    var scheduledEvents: [ScheduledEvent] = []
    var inactivityThresholdMinutes: Int = 0  // 0 = disabled
    var memoryThresholdMB: Int = 0  // 0 = disabled
    var memoryHysteresisMB: Int = 50  // Must drop this much below threshold before re-alerting
    var notifyOnTabOpen: Bool = false  // Tab open notifications (can be noisy)
    var notifyOnTabClose: Bool = false  // Tab close notifications (can be noisy)

    static let `default` = AppEventConfig()
}

/// A scheduled event that fires at configured times
struct ScheduledEvent: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var scheduleType: ScheduleType = .interval
    var intervalMinutes: Int = 60  // For interval type
    var dailyTime: Date = Date()   // For daily type
    var hourlyMinute: Int = 0      // For hourly type (0-59)
    var isEnabled: Bool = true

    enum ScheduleType: String, Codable, CaseIterable {
        case interval = "interval"
        case daily = "daily"
        case hourly = "hourly"
    }
}

// MARK: - Custom AI Detection Rules

struct CustomAIDetectionRule: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var pattern: String
    var displayName: String
    var colorName: String

    var tabColor: TabColor {
        TabColor(rawValue: colorName) ?? .gray
    }
}

// MARK: - Feature Settings (Centralized configuration for all features)

/// Centralized feature flags and settings for Chau7.
/// All features can be toggled in Settings and values are persisted in UserDefaults.
/// - Note: Thread Safety - @Published properties must be modified on main thread.
///   This class is typically accessed from UI code on the main thread.
final class FeatureSettings: ObservableObject {
    static let shared = FeatureSettings()

    // MARK: - Font Settings (NEW)

    @Published var fontFamily: String {
        didSet {
            UserDefaults.standard.set(fontFamily, forKey: Keys.fontFamily)
            NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
        }
    }

    @Published var fontSize: Int {
        didSet {
            let clamped = max(8, min(fontSize, 72))
            if fontSize != clamped {
                fontSize = clamped
                return
            }
            UserDefaults.standard.set(fontSize, forKey: Keys.fontSize)
            NotificationCenter.default.post(name: .terminalFontChanged, object: nil)
        }
    }

    @Published var defaultZoomPercent: Int {
        didSet {
            let clamped = max(50, min(defaultZoomPercent, 200))
            if defaultZoomPercent != clamped {
                defaultZoomPercent = clamped
                return
            }
            UserDefaults.standard.set(defaultZoomPercent, forKey: Keys.defaultZoomPercent)
            NotificationCenter.default.post(name: .terminalZoomChanged, object: nil)
        }
    }

    /// Available monospace fonts for the terminal, filtered by system availability.
    /// Includes system fonts, popular open-source fonts, and premium fonts.
    static let availableFonts: [String] = {
        let monospacedFonts = [
            // macOS System Fonts
            "Menlo",
            "Monaco",
            "SF Mono",
            "Courier New",

            // Microsoft Fonts
            "Cascadia Code",      // Modern Windows Terminal font with ligatures
            "Cascadia Mono",      // Cascadia without ligatures
            "Consolas",

            // JetBrains
            "JetBrains Mono",     // Popular IDE font with ligatures

            // Adobe/Google Fonts
            "Source Code Pro",
            "Roboto Mono",

            // Mozilla
            "Fira Code",          // Popular font with ligatures
            "Fira Mono",          // Fira without ligatures

            // IBM
            "IBM Plex Mono",

            // GitHub
            "Monaspace Neon",     // GitHub's new font family
            "Monaspace Argon",
            "Monaspace Xenon",
            "Monaspace Radon",
            "Monaspace Krypton",

            // Vercel
            "Geist Mono",         // Modern, clean terminal font

            // Other Popular Open Source
            "Hack",               // Designed for source code
            "Inconsolata",        // Humanist monospace
            "Anonymous Pro",
            "Ubuntu Mono",
            "Droid Sans Mono",
            "DejaVu Sans Mono",
            "Liberation Mono",
            "PT Mono",
            "Oxygen Mono",
            "Space Mono",         // Google Fonts - quirky
            "Overpass Mono",
            "Share Tech Mono",
            "Cousine",
            "Cutive Mono",

            // Iosevka Family (highly customizable)
            "Iosevka",
            "Iosevka Term",
            "Iosevka Fixed",

            // Victor Mono (cursive italics)
            "Victor Mono",

            // Fantasque Sans Mono (playful)
            "Fantasque Sans Mono",

            // Input (customizable)
            "Input Mono",
            "Input Mono Narrow",
            "Input Mono Condensed",

            // Recursive (variable font)
            "Recursive Mono Linear",
            "Rec Mono Linear",

            // Comic/Fun
            "Comic Mono",         // Comic Sans but monospace

            // Maple Mono
            "Maple Mono",
            "Maple Mono NF",      // Nerd Font version

            // Commit Mono
            "Commit Mono",

            // Nerd Font variants (include powerline symbols)
            "MesloLGS NF",        // Popular for Oh My Zsh
            "MesloLGM NF",
            "MesloLGL NF",
            "Hack Nerd Font",
            "FiraCode Nerd Font",
            "JetBrainsMono Nerd Font",
            "CaskaydiaCove Nerd Font",
            "Iosevka Nerd Font",
            "UbuntuMono Nerd Font",
            "RobotoMono Nerd Font",
            "SourceCodePro Nerd Font",
            "Symbols Nerd Font",

            // Premium/Commercial fonts (user must install)
            "Operator Mono",      // Hoefler&Co - cursive italics
            "Dank Mono",          // Stylish with ligatures
            "MonoLisa",           // Designed for long coding sessions
            "Berkeley Mono",      // Retro feel
            "Gintronic",          // Modern geometric
            "Pragmata Pro",       // Compact and dense
            "Cartograph CF",      // Warm, readable
            "Codelia",            // Playful
            "Comic Code",         // Professional Comic Sans
            "Ellograph CF",       // Elegant
            "Lilex",              // Modern and clean

            // Coding-specific fonts
            "Sudo",
            "Agave",
            "Cozette",            // Bitmap-style
            "Terminus",           // Classic bitmap
            "Tamzen",
            "Tamsyn",
            "GoMono",             // Go language official font
            "Noto Sans Mono",     // Google's universal font
            "Intel One Mono",     // Intel's open source font
        ]
        let fontManager = NSFontManager.shared
        return monospacedFonts.filter { fontManager.font(withFamily: $0, traits: [], weight: 5, size: 12) != nil }
    }()

    // MARK: - Color Scheme Settings (NEW)

    @Published var colorSchemeName: String {
        didSet {
            UserDefaults.standard.set(colorSchemeName, forKey: Keys.colorSchemeName)
            NotificationCenter.default.post(name: .terminalColorsChanged, object: nil)
        }
    }

    @Published var customColorScheme: TerminalColorScheme? {
        didSet {
            if let scheme = customColorScheme,
               let data = JSONOperations.encode(scheme, context: "customColorScheme") {
                UserDefaults.standard.set(data, forKey: Keys.customColorScheme)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.customColorScheme)
            }
            NotificationCenter.default.post(name: .terminalColorsChanged, object: nil)
        }
    }

    var currentColorScheme: TerminalColorScheme {
        if colorSchemeName == "Custom", let custom = customColorScheme {
            return custom
        }
        return TerminalColorScheme.allPresets.first { $0.name == colorSchemeName } ?? .default
    }

    // MARK: - Shell Settings (NEW)

    @Published var shellType: ShellType {
        didSet { UserDefaults.standard.set(shellType.rawValue, forKey: Keys.shellType) }
    }

    @Published var customShellPath: String {
        didSet { UserDefaults.standard.set(customShellPath, forKey: Keys.customShellPath) }
    }

    @Published var startupCommand: String {
        didSet { UserDefaults.standard.set(startupCommand, forKey: Keys.startupCommand) }
    }

    @Published var isLsColorsEnabled: Bool {
        didSet { UserDefaults.standard.set(isLsColorsEnabled, forKey: Keys.lsColorsEnabled) }
    }

    // MARK: - Keyboard Shortcuts (NEW)

    @Published var customShortcuts: [KeyboardShortcut] {
        didSet {
            if let data = JSONOperations.encode(customShortcuts, context: "customShortcuts") {
                UserDefaults.standard.set(data, forKey: Keys.customShortcuts)
            }
        }
    }
    @Published var isShortcutHelperHintEnabled: Bool {
        didSet { UserDefaults.standard.set(isShortcutHelperHintEnabled, forKey: Keys.shortcutHelperHint) }
    }

    func shortcut(for action: String) -> KeyboardShortcut? {
        customShortcuts.first { $0.action == action }
    }

    func updateShortcut(_ shortcut: KeyboardShortcut) {
        if let index = customShortcuts.firstIndex(where: { $0.action == shortcut.action }) {
            customShortcuts[index] = shortcut
        }
    }

    func shortcutConflicts(for shortcut: KeyboardShortcut) -> [KeyboardShortcut] {
        customShortcuts.filter {
            $0.action != shortcut.action &&
            $0.key == shortcut.key &&
            Set($0.modifiers) == Set(shortcut.modifiers)
        }
    }

    func resetShortcutsToDefaults() {
        customShortcuts = KeyboardShortcut.shortcuts(for: keybindingPreset)
    }

    func applyKeybindingPreset(_ preset: String) {
        customShortcuts = KeyboardShortcut.shortcuts(for: preset)
    }

    // MARK: - Notification Filters (NEW)

    @Published var notificationTriggerState: NotificationTriggerState {
        didSet {
            var normalized = notificationTriggerState
            normalized.normalize()
            if normalized != notificationTriggerState {
                notificationTriggerState = normalized
                return
            }
            if let data = JSONOperations.encode(notificationTriggerState, context: "notificationTriggerState") {
                UserDefaults.standard.set(data, forKey: Keys.notificationTriggerState)
            }
            let legacy = Self.legacyNotificationFilters(from: notificationTriggerState)
            if legacy != notificationFilters {
                notificationFilters = legacy
            }
        }
    }

    @Published var notificationFilters: NotificationFilters {
        didSet {
            if let data = JSONOperations.encode(notificationFilters, context: "notificationFilters") {
                UserDefaults.standard.set(data, forKey: Keys.notificationFilters)
            }
        }
    }

    /// Trigger-to-actions bindings: maps trigger IDs to lists of configured actions
    @Published var triggerActionBindings: [String: [NotificationActionConfig]] {
        didSet {
            if let data = JSONOperations.encode(triggerActionBindings, context: "triggerActionBindings") {
                UserDefaults.standard.set(data, forKey: Keys.triggerActionBindings)
            }
        }
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

    // MARK: - Find Defaults (NEW)

    @Published var findCaseSensitiveDefault: Bool {
        didSet { UserDefaults.standard.set(findCaseSensitiveDefault, forKey: Keys.findCaseSensitiveDefault) }
    }

    @Published var findRegexDefault: Bool {
        didSet { UserDefaults.standard.set(findRegexDefault, forKey: Keys.findRegexDefault) }
    }

    // MARK: - Tab Behavior

    @Published var lastTabCloseBehavior: LastTabCloseBehavior {
        didSet { UserDefaults.standard.set(lastTabCloseBehavior.rawValue, forKey: Keys.lastTabCloseBehavior) }
    }

    /// Where to insert new tabs: "end" or "after" (after current tab)
    @Published var newTabPosition: String {
        didSet { UserDefaults.standard.set(newTabPosition, forKey: Keys.newTabPosition) }
    }

    /// When enabled, new tabs inherit the current tab's directory.
    @Published var newTabsUseCurrentDirectory: Bool {
        didSet { UserDefaults.standard.set(newTabsUseCurrentDirectory, forKey: Keys.newTabsUseCurrentDirectory) }
    }

    @Published var alwaysShowTabBar: Bool {
        didSet { UserDefaults.standard.set(alwaysShowTabBar, forKey: Keys.alwaysShowTabBar) }
    }

    /// When true, the toolbar stays visible in fullscreen (like Chrome's "Always Show Toolbar in Full Screen")
    @Published var alwaysShowToolbarInFullscreen: Bool {
        didSet {
            UserDefaults.standard.set(alwaysShowToolbarInFullscreen, forKey: Keys.alwaysShowToolbarInFullscreen)
            NotificationCenter.default.post(name: .fullscreenToolbarSettingChanged, object: nil)
        }
    }

    /// When true, shows a warning dialog before closing a tab with a running process
    @Published var warnOnCloseWithRunningProcess: Bool {
        didSet { UserDefaults.standard.set(warnOnCloseWithRunningProcess, forKey: Keys.warnOnCloseWithProcess) }
    }

    /// When true, always shows a warning dialog before closing any tab
    @Published var alwaysWarnOnTabClose: Bool {
        didSet { UserDefaults.standard.set(alwaysWarnOnTabClose, forKey: Keys.alwaysWarnOnTabClose) }
    }

    // MARK: - Window Transparency

    @Published var windowOpacity: Double {
        didSet {
            let clamped = max(0.3, min(windowOpacity, 1.0))
            if windowOpacity != clamped {
                windowOpacity = clamped
                return
            }
            UserDefaults.standard.set(windowOpacity, forKey: Keys.windowOpacity)
            NotificationCenter.default.post(name: .terminalOpacityChanged, object: nil)
        }
    }

    // MARK: - App Theme

    @Published var appTheme: AppTheme {
        didSet {
            UserDefaults.standard.set(appTheme.rawValue, forKey: Keys.appTheme)
            NotificationCenter.default.post(name: .appThemeChanged, object: nil)
        }
    }

    // MARK: - Language Setting

    @Published var appLanguage: AppLanguage {
        didSet {
            UserDefaults.standard.set(appLanguage.rawValue, forKey: Keys.appLanguage)
            LocalizationManager.shared.currentLanguage = appLanguage
        }
    }

    // MARK: - Launch at Login

    @Published var launchAtLogin: Bool {
        didSet {
            UserDefaults.standard.set(launchAtLogin, forKey: Keys.launchAtLogin)
            if oldValue != launchAtLogin {
                LaunchAtLoginManager.setEnabled(launchAtLogin)
            }
        }
    }

    // MARK: - iCloud Sync (NEW)

    @Published var iCloudSyncEnabled: Bool {
        didSet {
            UserDefaults.standard.set(iCloudSyncEnabled, forKey: Keys.iCloudSyncEnabled)
            if iCloudSyncEnabled {
                syncToiCloud()
            }
        }
    }

    // MARK: - F05: Auto Tab Themes by AI Model

    @Published var isAutoTabThemeEnabled: Bool {
        didSet { UserDefaults.standard.set(isAutoTabThemeEnabled, forKey: Keys.autoTabTheme) }
    }

    /// AI model to tab color mapping
    static let aiModelColors: [String: TabColor] = [
        "claude": .purple,
        "claude-code": .purple,
        "claude-cli": .purple,
        "codex": .green,
        "openai": .green,
        "gpt": .green,
        "gemini": .blue,
        "bard": .blue,
        "copilot": .orange,
        "cursor": .teal,
        "aider": .pink,
        "continue": .yellow
    ]

    // MARK: - F18: Copy-on-Select

    @Published var isCopyOnSelectEnabled: Bool {
        didSet { UserDefaults.standard.set(isCopyOnSelectEnabled, forKey: Keys.copyOnSelect) }
    }

    // MARK: - F19: Line Timestamps

    @Published var isLineTimestampsEnabled: Bool {
        didSet { UserDefaults.standard.set(isLineTimestampsEnabled, forKey: Keys.lineTimestamps) }
    }

    @Published var timestampFormat: String {
        didSet { UserDefaults.standard.set(timestampFormat, forKey: Keys.timestampFormat) }
    }

    // MARK: - F20: Last Command Badge

    @Published var isLastCommandBadgeEnabled: Bool {
        didSet { UserDefaults.standard.set(isLastCommandBadgeEnabled, forKey: Keys.lastCommandBadge) }
    }

    // MARK: - F03: Cmd+Click Paths

    @Published var isCmdClickPathsEnabled: Bool {
        didSet { UserDefaults.standard.set(isCmdClickPathsEnabled, forKey: Keys.cmdClickPaths) }
    }

    /// Option+click to position cursor in the command line (like iTerm2)
    @Published var isOptionClickCursorEnabled: Bool {
        didSet { UserDefaults.standard.set(isOptionClickCursorEnabled, forKey: Keys.optionClickCursor) }
    }

    /// Allow terminal apps (vim, tmux, Codex, etc.) to capture mouse events.
    /// When enabled, hold Shift while clicking/dragging to force text selection.
    /// When disabled, mouse events always perform text selection.
    @Published var isMouseReportingEnabled: Bool {
        didSet { UserDefaults.standard.set(isMouseReportingEnabled, forKey: Keys.mouseReporting) }
    }

    /// Click on input line to position cursor (like modern text editors).
    /// Single click moves cursor, click+drag selects text.
    @Published var isClickToPositionEnabled: Bool {
        didSet { UserDefaults.standard.set(isClickToPositionEnabled, forKey: Keys.clickToPosition) }
    }

    @Published var defaultEditor: String {
        didSet { UserDefaults.standard.set(defaultEditor, forKey: Keys.defaultEditor) }
    }

    @Published var urlHandler: URLHandler {
        didSet { UserDefaults.standard.set(urlHandler.rawValue, forKey: Keys.urlHandler) }
    }

    // MARK: - Custom AI Detection (NEW)

    @Published var customAIDetectionRules: [CustomAIDetectionRule] {
        didSet {
            if let data = JSONOperations.encode(customAIDetectionRules, context: "customAIDetectionRules") {
                UserDefaults.standard.set(data, forKey: Keys.customAIDetectionRules)
            }
        }
    }

    // MARK: - F13: Broadcast Input

    @Published var isBroadcastEnabled: Bool {
        didSet { UserDefaults.standard.set(isBroadcastEnabled, forKey: Keys.broadcastEnabled) }
    }

    // MARK: - F16: Clipboard History

    @Published var isClipboardHistoryEnabled: Bool {
        didSet { UserDefaults.standard.set(isClipboardHistoryEnabled, forKey: Keys.clipboardHistory) }
    }

    @Published var clipboardHistoryMaxItems: Int {
        didSet {
            let clamped = max(1, min(clipboardHistoryMaxItems, 500))
            if clipboardHistoryMaxItems != clamped {
                clipboardHistoryMaxItems = clamped
                return
            }
            UserDefaults.standard.set(clipboardHistoryMaxItems, forKey: Keys.clipboardHistoryMax)
        }
    }

    // MARK: - F17: Bookmarks

    @Published var isBookmarksEnabled: Bool {
        didSet { UserDefaults.standard.set(isBookmarksEnabled, forKey: Keys.bookmarksEnabled) }
    }

    @Published var maxBookmarksPerTab: Int {
        didSet {
            let clamped = max(1, min(maxBookmarksPerTab, 200))
            if maxBookmarksPerTab != clamped {
                maxBookmarksPerTab = clamped
                return
            }
            UserDefaults.standard.set(maxBookmarksPerTab, forKey: Keys.maxBookmarks)
        }
    }

    // MARK: - F21: Snippets

    @Published var isSnippetsEnabled: Bool {
        didSet { UserDefaults.standard.set(isSnippetsEnabled, forKey: Keys.snippetsEnabled) }
    }

    @Published var isRepoSnippetsEnabled: Bool {
        didSet { UserDefaults.standard.set(isRepoSnippetsEnabled, forKey: Keys.repoSnippetsEnabled) }
    }

    @Published var repoSnippetPath: String {
        didSet {
            let trimmed = repoSnippetPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if repoSnippetPath != trimmed {
                repoSnippetPath = trimmed
                return
            }
            UserDefaults.standard.set(repoSnippetPath, forKey: Keys.repoSnippetPath)
        }
    }

    @Published var snippetInsertMode: String {
        didSet { UserDefaults.standard.set(snippetInsertMode, forKey: Keys.snippetInsertMode) }
    }

    @Published var snippetPlaceholdersEnabled: Bool {
        didSet { UserDefaults.standard.set(snippetPlaceholdersEnabled, forKey: Keys.snippetPlaceholders) }
    }

    // MARK: - F08: Smart Syntax Highlighting

    @Published var isSyntaxHighlightEnabled: Bool {
        didSet { UserDefaults.standard.set(isSyntaxHighlightEnabled, forKey: Keys.syntaxHighlight) }
    }

    @Published var isClickableURLsEnabled: Bool {
        didSet { UserDefaults.standard.set(isClickableURLsEnabled, forKey: Keys.clickableURLs) }
    }

    // MARK: - Inline Images (iTerm2 imgcat protocol)

    @Published var isInlineImagesEnabled: Bool {
        didSet { UserDefaults.standard.set(isInlineImagesEnabled, forKey: Keys.inlineImages) }
    }

    @Published var isJSONPrettyPrintEnabled: Bool {
        didSet { UserDefaults.standard.set(isJSONPrettyPrintEnabled, forKey: Keys.jsonPrettyPrint) }
    }

    // MARK: - F07: Semantic Scrollback Search

    @Published var isSemanticSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(isSemanticSearchEnabled, forKey: Keys.semanticSearch) }
    }

    // MARK: - F02: Split Panes

    @Published var isSplitPanesEnabled: Bool {
        didSet { UserDefaults.standard.set(isSplitPanesEnabled, forKey: Keys.splitPanes) }
    }

    // MARK: - Immediate Display Flush (Latency Optimization)

    /// Enables immediate display flush after input for reduced perceived latency.
    /// Forces CATransaction.flush() after each keystroke to ensure pending display
    /// updates are rendered immediately rather than waiting for the next frame.
    @Published var isLocalEchoEnabled: Bool {
        didSet { UserDefaults.standard.set(isLocalEchoEnabled, forKey: Keys.localEchoEnabled) }
    }

    // MARK: - Smart Scroll (Auto-Scroll Control)

    /// When enabled, new terminal output will NOT auto-scroll to the bottom if the user
    /// has scrolled up. The user's scroll position is preserved until they manually scroll
    /// back to the bottom. Default: true (smart behavior enabled).
    @Published var isSmartScrollEnabled: Bool {
        didSet { UserDefaults.standard.set(isSmartScrollEnabled, forKey: Keys.smartScrollEnabled) }
    }

    // MARK: - F11: Keybindings

    @Published var keybindingPreset: String {
        didSet { UserDefaults.standard.set(keybindingPreset, forKey: Keys.keybindingPreset) }
    }

    // MARK: - Overlay Positions

    @Published var overlayPositionsVersion: Int = 0

    // MARK: - General Terminal Settings

    @Published var cursorStyle: String {
        didSet { UserDefaults.standard.set(cursorStyle, forKey: Keys.cursorStyle) }
    }

    @Published var cursorBlink: Bool {
        didSet { UserDefaults.standard.set(cursorBlink, forKey: Keys.cursorBlink) }
    }

    @Published var scrollbackLines: Int {
        didSet {
            let clamped = max(100, min(scrollbackLines, 100_000))
            if scrollbackLines != clamped {
                scrollbackLines = clamped
                return
            }
            UserDefaults.standard.set(scrollbackLines, forKey: Keys.scrollbackLines)
        }
    }

    @Published var bellEnabled: Bool {
        didSet { UserDefaults.standard.set(bellEnabled, forKey: Keys.bellEnabled) }
    }

    @Published var bellSound: String {
        didSet { UserDefaults.standard.set(bellSound, forKey: Keys.bellSound) }
    }

    @Published var defaultStartDirectory: String {
        didSet {
            let trimmed = defaultStartDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = trimmed.isEmpty
                ? FileManager.default.homeDirectoryForCurrentUser.path
                : trimmed
            if defaultStartDirectory != normalized {
                defaultStartDirectory = normalized
                return
            }
            UserDefaults.standard.set(defaultStartDirectory, forKey: Keys.defaultStartDirectory)
        }
    }

    // MARK: - API Analytics Settings

    @Published var isAPIAnalyticsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isAPIAnalyticsEnabled, forKey: Keys.apiAnalyticsEnabled)
            NotificationCenter.default.post(name: .apiAnalyticsSettingsChanged, object: nil)
        }
    }

    @Published var apiAnalyticsPort: Int {
        didSet {
            let clamped = max(1024, min(apiAnalyticsPort, 65535))
            if apiAnalyticsPort != clamped {
                apiAnalyticsPort = clamped
                return
            }
            UserDefaults.standard.set(apiAnalyticsPort, forKey: Keys.apiAnalyticsPort)
        }
    }

    @Published var apiAnalyticsLogPrompts: Bool {
        didSet {
            UserDefaults.standard.set(apiAnalyticsLogPrompts, forKey: Keys.apiAnalyticsLogPrompts)
        }
    }

    // MARK: - Shell Event Detection Settings

    @Published var shellEventConfig: ShellEventConfig {
        didSet {
            if let data = JSONOperations.encode(shellEventConfig, context: "shellEventConfig") {
                UserDefaults.standard.set(data, forKey: Keys.shellEventConfig)
            }
        }
    }

    @Published var appEventConfig: AppEventConfig {
        didSet {
            if let data = JSONOperations.encode(appEventConfig, context: "appEventConfig") {
                UserDefaults.standard.set(data, forKey: Keys.appEventConfig)
            }
        }
    }

    // MARK: - Keys

    private enum Keys {
        // Font (NEW)
        static let fontFamily = "terminal.fontFamily"
        static let fontSize = "terminal.fontSize"
        static let defaultZoomPercent = "terminal.defaultZoomPercent"
        // Color Scheme (NEW)
        static let colorSchemeName = "terminal.colorSchemeName"
        static let customColorScheme = "terminal.customColorScheme"
        // Shell (NEW)
        static let shellType = "terminal.shellType"
        static let customShellPath = "terminal.customShellPath"
        static let startupCommand = "terminal.startupCommand"
        static let lsColorsEnabled = "terminal.lsColorsEnabled"
        // Keyboard Shortcuts (NEW)
        static let customShortcuts = "keyboard.customShortcuts"
        static let shortcutHelperHint = "keyboard.shortcutHelperHint"
        // Notification Filters (NEW)
        static let notificationTriggerState = "notifications.triggerState"
        static let notificationFilters = "notifications.filters"
        static let triggerActionBindings = "notifications.triggerActionBindings"
        // Find Defaults (NEW)
        static let findCaseSensitiveDefault = "search.defaultCaseSensitive"
        static let findRegexDefault = "search.defaultRegex"
        // Tab Behavior
        static let lastTabCloseBehavior = "tabs.lastTabCloseBehavior"
        static let newTabPosition = "tabs.newTabPosition"
        static let newTabsUseCurrentDirectory = "tabs.newTabsUseCurrentDirectory"
        static let alwaysShowTabBar = "tabs.alwaysShowTabBar"
        static let alwaysShowToolbarInFullscreen = "tabs.alwaysShowToolbarInFullscreen"
        static let warnOnCloseWithProcess = "tabs.warnOnCloseWithProcess"
        static let alwaysWarnOnTabClose = "tabs.alwaysWarnOnTabClose"
        // Window Opacity
        static let windowOpacity = "window.opacity"
        // App Theme
        static let appTheme = "app.theme"
        // Language
        static let appLanguage = "app.language"
        // Launch at login
        static let launchAtLogin = "app.launchAtLogin"
        // iCloud Sync (NEW)
        static let iCloudSyncEnabled = "sync.iCloudEnabled"
        // F05
        static let autoTabTheme = "feature.autoTabTheme"
        // F18
        static let copyOnSelect = "feature.copyOnSelect"
        // F19
        static let lineTimestamps = "feature.lineTimestamps"
        static let timestampFormat = "feature.timestampFormat"
        // F20
        static let lastCommandBadge = "feature.lastCommandBadge"
        // F03
        static let cmdClickPaths = "feature.cmdClickPaths"
        static let optionClickCursor = "feature.optionClickCursor"
        static let mouseReporting = "feature.mouseReporting"
        static let clickToPosition = "feature.clickToPosition"
        static let defaultEditor = "feature.defaultEditor"
        static let urlHandler = "feature.urlHandler"
        static let customAIDetectionRules = "ai.customDetectionRules"
        // F13
        static let broadcastEnabled = "feature.broadcastEnabled"
        // F16
        static let clipboardHistory = "feature.clipboardHistory"
        static let clipboardHistoryMax = "feature.clipboardHistoryMax"
        // F17
        static let bookmarksEnabled = "feature.bookmarksEnabled"
        static let maxBookmarks = "feature.maxBookmarks"
        // F21
        static let snippetsEnabled = "feature.snippetsEnabled"
        static let repoSnippetsEnabled = "feature.repoSnippetsEnabled"
        static let repoSnippetPath = "feature.repoSnippetPath"
        static let snippetInsertMode = "feature.snippetInsertMode"
        static let snippetPlaceholders = "feature.snippetPlaceholders"
        // F08
        static let syntaxHighlight = "feature.syntaxHighlight"
        static let clickableURLs = "feature.clickableURLs"
        static let inlineImages = "feature.inlineImages"
        static let jsonPrettyPrint = "feature.jsonPrettyPrint"
        // F07
        static let semanticSearch = "feature.semanticSearch"
        // F02
        static let splitPanes = "feature.splitPanes"
        // Local Echo (Latency Optimization)
        static let localEchoEnabled = "feature.localEchoEnabled"
        // Smart Scroll
        static let smartScrollEnabled = "feature.smartScrollEnabled"
        // F11
        static let keybindingPreset = "feature.keybindingPreset"
        // General
        static let cursorStyle = "terminal.cursorStyle"
        static let cursorBlink = "terminal.cursorBlink"
        static let scrollbackLines = "terminal.scrollbackLines"
        static let bellEnabled = "terminal.bellEnabled"
        static let bellSound = "terminal.bellSound"
        static let defaultStartDirectory = "terminal.defaultStartDirectory"
        static let overlayPositionsMap = "overlay.positions.map"
        // API Analytics
        static let apiAnalyticsEnabled = "analytics.api.enabled"
        static let apiAnalyticsPort = "analytics.api.port"
        static let apiAnalyticsLogPrompts = "analytics.api.logPrompts"
        // Shell Event Detection
        static let shellEventConfig = "shell.eventConfig"
        // App Event Detection
        static let appEventConfig = "app.eventConfig"
    }

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Font Settings (NEW)
        self.fontFamily = defaults.string(forKey: Keys.fontFamily) ?? "Menlo"
        self.fontSize = defaults.object(forKey: Keys.fontSize) as? Int ?? 13
        self.defaultZoomPercent = defaults.object(forKey: Keys.defaultZoomPercent) as? Int ?? 100

        // Color Scheme (NEW)
        self.colorSchemeName = defaults.string(forKey: Keys.colorSchemeName) ?? "Default"
        if let data = defaults.data(forKey: Keys.customColorScheme),
           let scheme = JSONOperations.decode(TerminalColorScheme.self, from: data, context: "customColorScheme") {
            self.customColorScheme = scheme
        } else {
            self.customColorScheme = nil
        }

        // Shell Settings (NEW)
        if let shellRaw = defaults.string(forKey: Keys.shellType),
           let shell = ShellType(rawValue: shellRaw) {
            self.shellType = shell
        } else {
            self.shellType = .system
        }
        self.customShellPath = defaults.string(forKey: Keys.customShellPath) ?? ""
        self.startupCommand = defaults.string(forKey: Keys.startupCommand) ?? ""
        self.isLsColorsEnabled = defaults.object(forKey: Keys.lsColorsEnabled) as? Bool ?? true

        // Keyboard Shortcuts (NEW)
        let loadedShortcuts: [KeyboardShortcut]
        if let data = defaults.data(forKey: Keys.customShortcuts),
           let shortcuts = JSONOperations.decode([KeyboardShortcut].self, from: data, context: "customShortcuts") {
            loadedShortcuts = shortcuts
        } else {
            let preset = defaults.string(forKey: Keys.keybindingPreset) ?? "default"
            loadedShortcuts = KeyboardShortcut.shortcuts(for: preset)
        }
        self.customShortcuts = Self.migratedShortcutsIfNeeded(loadedShortcuts)
        self.isShortcutHelperHintEnabled = defaults.object(forKey: Keys.shortcutHelperHint) as? Bool ?? true

        // Local Echo / Immediate Display Flush (default: disabled)
        // Initialize early to ensure all properties are set before any are accessed
        self.isLocalEchoEnabled = defaults.object(forKey: Keys.localEchoEnabled) as? Bool ?? false

        // Notification Filters (NEW)
        let loadedFilters: NotificationFilters
        if let data = defaults.data(forKey: Keys.notificationFilters),
           let filters = JSONOperations.decode(NotificationFilters.self, from: data, context: "notificationFilters") {
            loadedFilters = filters
        } else {
            loadedFilters = .defaults
        }
        self.notificationFilters = loadedFilters

        let resolvedTriggerState: NotificationTriggerState
        if let data = defaults.data(forKey: Keys.notificationTriggerState),
           let state = JSONOperations.decode(NotificationTriggerState.self, from: data, context: "notificationTriggerState") {
            var normalized = state
            normalized.normalize()
            resolvedTriggerState = normalized
        } else {
            resolvedTriggerState = Self.triggerState(from: loadedFilters)
        }
        self.notificationTriggerState = resolvedTriggerState
        self.notificationFilters = Self.legacyNotificationFilters(from: resolvedTriggerState)

        // Trigger Action Bindings
        if let data = defaults.data(forKey: Keys.triggerActionBindings),
           let bindings = JSONOperations.decode([String: [NotificationActionConfig]].self, from: data, context: "triggerActionBindings") {
            self.triggerActionBindings = bindings
        } else {
            self.triggerActionBindings = [:]
        }

        // Find Defaults (NEW)
        self.findCaseSensitiveDefault = defaults.object(forKey: Keys.findCaseSensitiveDefault) as? Bool ?? false
        self.findRegexDefault = defaults.object(forKey: Keys.findRegexDefault) as? Bool ?? false

        // Tab Close Behavior (NEW)
        if let behaviorRaw = defaults.string(forKey: Keys.lastTabCloseBehavior),
           let behavior = LastTabCloseBehavior(rawValue: behaviorRaw) {
            self.lastTabCloseBehavior = behavior
        } else {
            self.lastTabCloseBehavior = .keepWindow
        }
        self.newTabPosition = defaults.string(forKey: Keys.newTabPosition) ?? "end"
        self.newTabsUseCurrentDirectory = defaults.object(forKey: Keys.newTabsUseCurrentDirectory) as? Bool ?? true
        self.alwaysShowTabBar = defaults.object(forKey: Keys.alwaysShowTabBar) as? Bool ?? true
        self.alwaysShowToolbarInFullscreen = defaults.object(forKey: Keys.alwaysShowToolbarInFullscreen) as? Bool ?? false
        self.warnOnCloseWithRunningProcess = defaults.object(forKey: Keys.warnOnCloseWithProcess) as? Bool ?? true
        self.alwaysWarnOnTabClose = defaults.object(forKey: Keys.alwaysWarnOnTabClose) as? Bool ?? false

        // Window Opacity
        self.windowOpacity = defaults.object(forKey: Keys.windowOpacity) as? Double ?? 1.0

        // App Theme
        if let themeRaw = defaults.string(forKey: Keys.appTheme),
           let theme = AppTheme(rawValue: themeRaw) {
            self.appTheme = theme
        } else {
            self.appTheme = .system
        }

        // Language
        if let langRaw = defaults.string(forKey: Keys.appLanguage),
           let lang = AppLanguage(rawValue: langRaw) {
            self.appLanguage = lang
        } else {
            self.appLanguage = .system
        }

        // Launch at Login
        if defaults.object(forKey: Keys.launchAtLogin) != nil {
            self.launchAtLogin = defaults.object(forKey: Keys.launchAtLogin) as? Bool ?? false
        } else {
            self.launchAtLogin = LaunchAtLoginManager.isEnabled()
        }

        // iCloud Sync (NEW)
        self.iCloudSyncEnabled = defaults.object(forKey: Keys.iCloudSyncEnabled) as? Bool ?? false

        // F05: Auto Tab Theme (default: enabled)
        self.isAutoTabThemeEnabled = defaults.object(forKey: Keys.autoTabTheme) as? Bool ?? true

        // F18: Copy on Select (default: disabled)
        self.isCopyOnSelectEnabled = defaults.object(forKey: Keys.copyOnSelect) as? Bool ?? false

        // F19: Line Timestamps (default: disabled)
        self.isLineTimestampsEnabled = defaults.object(forKey: Keys.lineTimestamps) as? Bool ?? false
        self.timestampFormat = defaults.string(forKey: Keys.timestampFormat) ?? "HH:mm:ss"

        // F20: Last Command Badge (default: enabled)
        self.isLastCommandBadgeEnabled = defaults.object(forKey: Keys.lastCommandBadge) as? Bool ?? true

        // F03: Cmd+Click Paths (default: enabled)
        self.isCmdClickPathsEnabled = defaults.object(forKey: Keys.cmdClickPaths) as? Bool ?? true
        self.isOptionClickCursorEnabled = defaults.object(forKey: Keys.optionClickCursor) as? Bool ?? true
        // Mouse reporting: disabled by default so text selection always works
        // Users can enable if they want vim/tmux mouse support (hold Shift to bypass)
        self.isMouseReportingEnabled = defaults.object(forKey: Keys.mouseReporting) as? Bool ?? false
        // Click-to-position: enabled by default (like modern text editors)
        self.isClickToPositionEnabled = defaults.object(forKey: Keys.clickToPosition) as? Bool ?? true
        self.defaultEditor = defaults.string(forKey: Keys.defaultEditor) ?? ""  // Empty = use $EDITOR or system default
        if let handlerRaw = defaults.string(forKey: Keys.urlHandler),
           let handler = URLHandler(rawValue: handlerRaw) {
            self.urlHandler = handler
        } else {
            self.urlHandler = .system
        }

        // Custom AI Detection (NEW)
        if let data = defaults.data(forKey: Keys.customAIDetectionRules),
           let rules = JSONOperations.decode([CustomAIDetectionRule].self, from: data, context: "customAIDetectionRules") {
            self.customAIDetectionRules = rules
        } else {
            self.customAIDetectionRules = []
        }

        // F13: Broadcast (default: disabled)
        self.isBroadcastEnabled = defaults.object(forKey: Keys.broadcastEnabled) as? Bool ?? false

        // F16: Clipboard History (default: enabled)
        self.isClipboardHistoryEnabled = defaults.object(forKey: Keys.clipboardHistory) as? Bool ?? true
        self.clipboardHistoryMaxItems = defaults.object(forKey: Keys.clipboardHistoryMax) as? Int ?? 50

        // F17: Bookmarks (default: enabled)
        self.isBookmarksEnabled = defaults.object(forKey: Keys.bookmarksEnabled) as? Bool ?? true
        self.maxBookmarksPerTab = defaults.object(forKey: Keys.maxBookmarks) as? Int ?? 20

        // F21: Snippets (default: enabled)
        self.isSnippetsEnabled = defaults.object(forKey: Keys.snippetsEnabled) as? Bool ?? true
        self.isRepoSnippetsEnabled = defaults.object(forKey: Keys.repoSnippetsEnabled) as? Bool ?? true
        self.repoSnippetPath = defaults.string(forKey: Keys.repoSnippetPath) ?? ".chau7/snippets.json"
        self.snippetInsertMode = defaults.string(forKey: Keys.snippetInsertMode) ?? "expand"
        self.snippetPlaceholdersEnabled = defaults.object(forKey: Keys.snippetPlaceholders) as? Bool ?? true

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

        // Note: isLocalEchoEnabled is initialized earlier in the init to avoid property access errors

        // F11: Keybindings (default: "default")
        self.keybindingPreset = defaults.string(forKey: Keys.keybindingPreset) ?? "default"

        // General Terminal Settings
        self.cursorStyle = defaults.string(forKey: Keys.cursorStyle) ?? "block"
        self.cursorBlink = defaults.object(forKey: Keys.cursorBlink) as? Bool ?? true
        self.scrollbackLines = defaults.object(forKey: Keys.scrollbackLines) as? Int ?? 10000
        self.bellEnabled = defaults.object(forKey: Keys.bellEnabled) as? Bool ?? true
        self.bellSound = defaults.string(forKey: Keys.bellSound) ?? "default"
        self.defaultStartDirectory = defaults.string(forKey: Keys.defaultStartDirectory) ?? home

        // API Analytics (default: disabled)
        self.isAPIAnalyticsEnabled = defaults.object(forKey: Keys.apiAnalyticsEnabled) as? Bool ?? false
        self.apiAnalyticsPort = defaults.object(forKey: Keys.apiAnalyticsPort) as? Int ?? 18080
        self.apiAnalyticsLogPrompts = defaults.object(forKey: Keys.apiAnalyticsLogPrompts) as? Bool ?? false

        // Shell Event Detection
        if let data = defaults.data(forKey: Keys.shellEventConfig),
           let config = JSONOperations.decode(ShellEventConfig.self, from: data, context: "shellEventConfig") {
            self.shellEventConfig = config
        } else {
            self.shellEventConfig = .default
        }

        // App Event Detection
        if let data = defaults.data(forKey: Keys.appEventConfig),
           let config = JSONOperations.decode(AppEventConfig.self, from: data, context: "appEventConfig") {
            self.appEventConfig = config
        } else {
            self.appEventConfig = .default
        }
    }

    private static func migratedShortcutsIfNeeded(_ shortcuts: [KeyboardShortcut]) -> [KeyboardShortcut] {
        var updated = shortcuts
        var didUpdate = false

        if let debugIndex = updated.firstIndex(where: { $0.action == "debugConsole" }),
           let splitIndex = updated.firstIndex(where: { $0.action == "splitVertical" }) {
            let debugShortcut = updated[debugIndex]
            let splitShortcut = updated[splitIndex]
            let debugKey = debugShortcut.key.lowercased()
            let splitKey = splitShortcut.key.lowercased()
            let debugModifiers = Set(debugShortcut.modifiers.map { $0.lowercased() })
            let splitModifiers = Set(splitShortcut.modifiers.map { $0.lowercased() })

            let isLegacyConflict = debugKey == "d"
                && splitKey == "d"
                && debugModifiers == ["cmd", "shift"]
                && splitModifiers == ["cmd", "shift"]

            if isLegacyConflict {
                updated[debugIndex] = KeyboardShortcut(action: "debugConsole", key: "l", modifiers: ["cmd", "opt"])
                didUpdate = true
            }
        }

        if let nextIndex = updated.firstIndex(where: { $0.action == "nextTab" }) {
            let nextShortcut = updated[nextIndex]
            let nextModifiers = Set(nextShortcut.modifiers.map { $0.lowercased() })
            if nextShortcut.key.lowercased() == "]", nextModifiers == ["cmd", "opt"] {
                updated[nextIndex] = KeyboardShortcut(action: "nextTab", key: "]", modifiers: ["cmd", "shift"])
                didUpdate = true
            }
        }

        if let previousIndex = updated.firstIndex(where: { $0.action == "previousTab" }) {
            let previousShortcut = updated[previousIndex]
            let previousModifiers = Set(previousShortcut.modifiers.map { $0.lowercased() })
            if previousShortcut.key.lowercased() == "[", previousModifiers == ["cmd", "opt"] {
                updated[previousIndex] = KeyboardShortcut(action: "previousTab", key: "[", modifiers: ["cmd", "shift"])
                didUpdate = true
            }
        }

        return didUpdate ? updated : shortcuts
    }

    // MARK: - Overlay Positions Cache (Performance Optimization)

    /// Cached overlay positions to avoid repeated UserDefaults parsing
    private var cachedOverlayPositions: [String: [String: [String: Double]]]?

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
        cachedOverlayPositions = store  // Update cache
        UserDefaults.standard.set(store, forKey: Keys.overlayPositionsMap)
        overlayPositionsVersion += 1
    }

    private func overlayWorkspaceKey(_ workspace: String?) -> String {
        let base = workspace?.trimmingCharacters(in: .whitespacesAndNewlines)
        return base?.isEmpty == false ? base! : "global"
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
        var bellEnabled: Bool
        var bellSound: String
        var defaultStartDirectory: String
        var isAutoTabThemeEnabled: Bool
        var isCopyOnSelectEnabled: Bool
        var isLineTimestampsEnabled: Bool
        var timestampFormat: String
        var isLastCommandBadgeEnabled: Bool
        var isCmdClickPathsEnabled: Bool
        var isOptionClickCursorEnabled: Bool
        var defaultEditor: String
        var urlHandler: String?
        var customAIDetectionRules: [CustomAIDetectionRule]?
        var isBroadcastEnabled: Bool
        var isClipboardHistoryEnabled: Bool
        var clipboardHistoryMaxItems: Int
        var isBookmarksEnabled: Bool
        var maxBookmarksPerTab: Int
        var isSnippetsEnabled: Bool
        var isRepoSnippetsEnabled: Bool
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
        var exportVersion: Int = 1
    }

    func exportSettings() -> Data? {
        let exportable = ExportableSettings(
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
            bellEnabled: bellEnabled,
            bellSound: bellSound,
            defaultStartDirectory: defaultStartDirectory,
            isAutoTabThemeEnabled: isAutoTabThemeEnabled,
            isCopyOnSelectEnabled: isCopyOnSelectEnabled,
            isLineTimestampsEnabled: isLineTimestampsEnabled,
            timestampFormat: timestampFormat,
            isLastCommandBadgeEnabled: isLastCommandBadgeEnabled,
            isCmdClickPathsEnabled: isCmdClickPathsEnabled,
            isOptionClickCursorEnabled: isOptionClickCursorEnabled,
            defaultEditor: defaultEditor,
            urlHandler: urlHandler.rawValue,
            customAIDetectionRules: customAIDetectionRules,
            isBroadcastEnabled: isBroadcastEnabled,
            isClipboardHistoryEnabled: isClipboardHistoryEnabled,
            clipboardHistoryMaxItems: clipboardHistoryMaxItems,
            isBookmarksEnabled: isBookmarksEnabled,
            maxBookmarksPerTab: maxBookmarksPerTab,
            isSnippetsEnabled: isSnippetsEnabled,
            isRepoSnippetsEnabled: isRepoSnippetsEnabled,
            repoSnippetPath: repoSnippetPath,
            snippetInsertMode: snippetInsertMode,
            snippetPlaceholdersEnabled: snippetPlaceholdersEnabled,
            isSyntaxHighlightEnabled: isSyntaxHighlightEnabled,
            isClickableURLsEnabled: isClickableURLsEnabled,
            isInlineImagesEnabled: isInlineImagesEnabled,
            isJSONPrettyPrintEnabled: isJSONPrettyPrintEnabled,
            isSemanticSearchEnabled: isSemanticSearchEnabled,
            isSplitPanesEnabled: isSplitPanesEnabled,
            keybindingPreset: keybindingPreset
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return JSONOperations.encode(exportable, context: "settings export")
    }

    func importSettings(from data: Data) -> Bool {
        guard let imported = JSONOperations.decode(ExportableSettings.self, from: data, context: "settings import") else {
            Log.error("Failed to import settings: invalid data format")
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
        if let state = imported.notificationTriggerState {
            var normalized = state
            normalized.normalize()
            notificationTriggerState = normalized
        } else {
            notificationTriggerState = Self.triggerState(from: imported.notificationFilters)
        }
        notificationFilters = Self.legacyNotificationFilters(from: notificationTriggerState)
        findCaseSensitiveDefault = imported.findCaseSensitiveDefault ?? false
        findRegexDefault = imported.findRegexDefault ?? false
        if let behaviorRaw = imported.lastTabCloseBehavior,
           let behavior = LastTabCloseBehavior(rawValue: behaviorRaw) {
            lastTabCloseBehavior = behavior
        } else {
            lastTabCloseBehavior = .keepWindow
        }
        newTabPosition = imported.newTabPosition ?? "end"
        newTabsUseCurrentDirectory = imported.newTabsUseCurrentDirectory ?? true
        alwaysShowTabBar = imported.alwaysShowTabBar ?? true
        alwaysShowToolbarInFullscreen = imported.alwaysShowToolbarInFullscreen ?? false
        if let themeRaw = imported.appTheme,
           let theme = AppTheme(rawValue: themeRaw) {
            appTheme = theme
        } else {
            appTheme = .system
        }
        launchAtLogin = imported.launchAtLogin ?? launchAtLogin
        if let langRaw = imported.appLanguage,
           let lang = AppLanguage(rawValue: langRaw) {
            appLanguage = lang
        } else {
            appLanguage = .system
        }
        windowOpacity = imported.windowOpacity
        cursorStyle = imported.cursorStyle
        cursorBlink = imported.cursorBlink
        scrollbackLines = imported.scrollbackLines
        bellEnabled = imported.bellEnabled
        bellSound = imported.bellSound
        defaultStartDirectory = imported.defaultStartDirectory
        isAutoTabThemeEnabled = imported.isAutoTabThemeEnabled
        isCopyOnSelectEnabled = imported.isCopyOnSelectEnabled
        isLineTimestampsEnabled = imported.isLineTimestampsEnabled
        timestampFormat = imported.timestampFormat
        isLastCommandBadgeEnabled = imported.isLastCommandBadgeEnabled
        isCmdClickPathsEnabled = imported.isCmdClickPathsEnabled
        isOptionClickCursorEnabled = imported.isOptionClickCursorEnabled
        defaultEditor = imported.defaultEditor
        if let handlerRaw = imported.urlHandler,
           let handler = URLHandler(rawValue: handlerRaw) {
            urlHandler = handler
        } else {
            urlHandler = .system
        }
        customAIDetectionRules = imported.customAIDetectionRules ?? []
        isBroadcastEnabled = imported.isBroadcastEnabled
        isClipboardHistoryEnabled = imported.isClipboardHistoryEnabled
        clipboardHistoryMaxItems = imported.clipboardHistoryMaxItems
        isBookmarksEnabled = imported.isBookmarksEnabled
        maxBookmarksPerTab = imported.maxBookmarksPerTab
        isSnippetsEnabled = imported.isSnippetsEnabled
        isRepoSnippetsEnabled = imported.isRepoSnippetsEnabled
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

        return true
    }

    // MARK: - Reset to Defaults (NEW)

    func resetAllToDefaults() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Font
        fontFamily = "Menlo"
        fontSize = 13
        defaultZoomPercent = 100

        // Colors
        colorSchemeName = "Default"
        customColorScheme = nil

        // Shell
        shellType = .system
        customShellPath = ""
        startupCommand = ""
        isLsColorsEnabled = true

        // Shortcuts
        keybindingPreset = "default"
        customShortcuts = KeyboardShortcut.shortcuts(for: keybindingPreset)
        isShortcutHelperHintEnabled = true

        // Notifications
        notificationTriggerState = NotificationTriggerState()
        notificationFilters = Self.legacyNotificationFilters(from: notificationTriggerState)
        findCaseSensitiveDefault = false
        findRegexDefault = false
        lastTabCloseBehavior = .keepWindow
        newTabPosition = "end"
        newTabsUseCurrentDirectory = true
        alwaysShowTabBar = true
        alwaysShowToolbarInFullscreen = false

        // Language
        appLanguage = .system

        // Window
        windowOpacity = 1.0
        appTheme = .system

        // Launch at login
        launchAtLogin = false

        // Terminal
        cursorStyle = "block"
        cursorBlink = true
        scrollbackLines = 10000
        bellEnabled = true
        bellSound = "default"
        defaultStartDirectory = home

        // Features
        isAutoTabThemeEnabled = true
        isCopyOnSelectEnabled = false
        isLineTimestampsEnabled = false
        timestampFormat = "HH:mm:ss"
        isLastCommandBadgeEnabled = true
        isCmdClickPathsEnabled = true
        isOptionClickCursorEnabled = true
        defaultEditor = ""
        urlHandler = .system
        customAIDetectionRules = []
        isBroadcastEnabled = false
        isClipboardHistoryEnabled = true
        clipboardHistoryMaxItems = 50
        isBookmarksEnabled = true
        maxBookmarksPerTab = 20
        isSnippetsEnabled = true
        isRepoSnippetsEnabled = true
        repoSnippetPath = ".chau7/snippets.json"
        snippetInsertMode = "expand"
        snippetPlaceholdersEnabled = true
        isSyntaxHighlightEnabled = true
        isClickableURLsEnabled = true
        isInlineImagesEnabled = true
        isJSONPrettyPrintEnabled = false
        isSemanticSearchEnabled = false
        isSplitPanesEnabled = true
        keybindingPreset = "default"

        // Overlay positions
        resetOverlayOffsets()
    }

    func resetAppearanceToDefaults() {
        fontFamily = "Menlo"
        fontSize = 13
        defaultZoomPercent = 100
        colorSchemeName = "Default"
        customColorScheme = nil
        windowOpacity = 1.0
        appTheme = .system
        isAutoTabThemeEnabled = true
    }

    func resetTerminalToDefaults() {
        cursorStyle = "block"
        cursorBlink = true
        scrollbackLines = 10000
        bellEnabled = true
        bellSound = "default"
        defaultStartDirectory = FileManager.default.homeDirectoryForCurrentUser.path
        shellType = .system
        customShellPath = ""
        startupCommand = ""
        isLsColorsEnabled = true
    }

    func resetInputToDefaults() {
        keybindingPreset = "default"
        customShortcuts = KeyboardShortcut.shortcuts(for: keybindingPreset)
        isShortcutHelperHintEnabled = true
        isCopyOnSelectEnabled = false
        isCmdClickPathsEnabled = true
        defaultEditor = ""
        urlHandler = .system
        isBroadcastEnabled = false
    }

    func resetProductivityToDefaults() {
        isSnippetsEnabled = true
        isRepoSnippetsEnabled = true
        repoSnippetPath = ".chau7/snippets.json"
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

    private let iCloudKey = "com.chau7.settings"
    private var iCloudSyncWorkItem: DispatchWorkItem?
    private let iCloudSyncDebounceInterval: TimeInterval = 2.0  // 2 seconds debounce

    func syncToiCloud() {
        guard iCloudSyncEnabled else { return }

        // Cancel previous pending sync
        iCloudSyncWorkItem?.cancel()

        // Create new debounced sync
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, self.iCloudSyncEnabled else { return }
            guard let data = self.exportSettings() else { return }
            NSUbiquitousKeyValueStore.default.set(data, forKey: self.iCloudKey)
            NSUbiquitousKeyValueStore.default.synchronize()
            Log.info("Settings synced to iCloud (debounced)")
        }

        iCloudSyncWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + iCloudSyncDebounceInterval, execute: workItem)
    }

    /// Force immediate sync without debouncing (e.g., on app quit)
    func forceSyncToiCloud() {
        guard iCloudSyncEnabled else { return }
        iCloudSyncWorkItem?.cancel()
        guard let data = exportSettings() else { return }
        NSUbiquitousKeyValueStore.default.set(data, forKey: iCloudKey)
        NSUbiquitousKeyValueStore.default.synchronize()
        Log.info("Settings force synced to iCloud")
    }

    func syncFromiCloud() {
        guard iCloudSyncEnabled else { return }
        guard let data = NSUbiquitousKeyValueStore.default.data(forKey: iCloudKey) else {
            Log.info("No iCloud settings found")
            return
        }
        if importSettings(from: data) {
            Log.info("Settings restored from iCloud")
        } else {
            Log.warn("Failed to restore settings from iCloud")
        }
    }

    func setupiCloudSync() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(iCloudSettingsChanged),
            name: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: NSUbiquitousKeyValueStore.default
        )
        NSUbiquitousKeyValueStore.default.synchronize()
    }

    @objc private func iCloudSettingsChanged(_ notification: Notification) {
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
    var icon: String  // SF Symbol name
    var createdAt: Date
    var settings: FeatureSettings.ExportableSettings

    init(name: String, icon: String = "person.fill", settings: FeatureSettings.ExportableSettings) {
        self.id = UUID()
        self.name = name
        self.icon = icon
        self.createdAt = Date()
        self.settings = settings
    }

    // Custom Equatable - compare by ID since ExportableSettings does not conform to Equatable
    static func == (lhs: SettingsProfile, rhs: SettingsProfile) -> Bool {
        lhs.id == rhs.id
    }

    static let defaultProfiles: [SettingsProfile] = [
        SettingsProfile(name: "Default", icon: "house.fill", settings: FeatureSettings.defaultExportableSettings),
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
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ExportableSettings(
            fontFamily: "Menlo",
            fontSize: 13,
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
            bellEnabled: true,
            bellSound: "default",
            defaultStartDirectory: home,
            isAutoTabThemeEnabled: true,
            isCopyOnSelectEnabled: false,
            isLineTimestampsEnabled: false,
            timestampFormat: "HH:mm:ss",
            isLastCommandBadgeEnabled: true,
            isCmdClickPathsEnabled: true,
            isOptionClickCursorEnabled: true,
            defaultEditor: "",
            urlHandler: "system",
            customAIDetectionRules: [],
            isBroadcastEnabled: false,
            isClipboardHistoryEnabled: true,
            clipboardHistoryMaxItems: 50,
            isBookmarksEnabled: true,
            maxBookmarksPerTab: 20,
            isSnippetsEnabled: true,
            isRepoSnippetsEnabled: true,
            repoSnippetPath: ".chau7/snippets.json",
            snippetInsertMode: "expand",
            snippetPlaceholdersEnabled: true,
            isSyntaxHighlightEnabled: true,
            isClickableURLsEnabled: true,
            isInlineImagesEnabled: true,
            isJSONPrettyPrintEnabled: false,
            isSemanticSearchEnabled: false,
            isSplitPanesEnabled: true,
            keybindingPreset: "default"
        )
    }

    var savedProfiles: [SettingsProfile] {
        get {
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
            objectWillChange.send()
        }
    }

    var activeProfileId: UUID? {
        get {
            guard let idString = UserDefaults.standard.string(forKey: Self.activeProfileKey) else { return nil }
            return UUID(uuidString: idString)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: Self.activeProfileKey)
            objectWillChange.send()
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
