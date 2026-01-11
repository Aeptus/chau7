import Foundation
import AppKit
import SwiftUI

// MARK: - Color Scheme Presets

struct TerminalColorScheme: Codable, Identifiable, Equatable {
    var id: String { name }
    let name: String
    let background: String  // Hex color
    let foreground: String
    let cursor: String
    let selection: String
    let black: String
    let red: String
    let green: String
    let yellow: String
    let blue: String
    let magenta: String
    let cyan: String
    let white: String
    let brightBlack: String
    let brightRed: String
    let brightGreen: String
    let brightYellow: String
    let brightBlue: String
    let brightMagenta: String
    let brightCyan: String
    let brightWhite: String

    static let `default` = TerminalColorScheme(
        name: "Default",
        background: "#1E1E1E", foreground: "#D4D4D4", cursor: "#FFFFFF", selection: "#264F78",
        black: "#000000", red: "#CD3131", green: "#0DBC79", yellow: "#E5E510",
        blue: "#2472C8", magenta: "#BC3FBC", cyan: "#11A8CD", white: "#E5E5E5",
        brightBlack: "#666666", brightRed: "#F14C4C", brightGreen: "#23D18B", brightYellow: "#F5F543",
        brightBlue: "#3B8EEA", brightMagenta: "#D670D6", brightCyan: "#29B8DB", brightWhite: "#FFFFFF"
    )

    static let solarizedDark = TerminalColorScheme(
        name: "Solarized Dark",
        background: "#002B36", foreground: "#839496", cursor: "#93A1A1", selection: "#073642",
        black: "#073642", red: "#DC322F", green: "#859900", yellow: "#B58900",
        blue: "#268BD2", magenta: "#D33682", cyan: "#2AA198", white: "#EEE8D5",
        brightBlack: "#002B36", brightRed: "#CB4B16", brightGreen: "#586E75", brightYellow: "#657B83",
        brightBlue: "#839496", brightMagenta: "#6C71C4", brightCyan: "#93A1A1", brightWhite: "#FDF6E3"
    )

    static let solarizedLight = TerminalColorScheme(
        name: "Solarized Light",
        background: "#FDF6E3", foreground: "#657B83", cursor: "#586E75", selection: "#EEE8D5",
        black: "#073642", red: "#DC322F", green: "#859900", yellow: "#B58900",
        blue: "#268BD2", magenta: "#D33682", cyan: "#2AA198", white: "#EEE8D5",
        brightBlack: "#002B36", brightRed: "#CB4B16", brightGreen: "#586E75", brightYellow: "#657B83",
        brightBlue: "#839496", brightMagenta: "#6C71C4", brightCyan: "#93A1A1", brightWhite: "#FDF6E3"
    )

    static let dracula = TerminalColorScheme(
        name: "Dracula",
        background: "#282A36", foreground: "#F8F8F2", cursor: "#F8F8F2", selection: "#44475A",
        black: "#21222C", red: "#FF5555", green: "#50FA7B", yellow: "#F1FA8C",
        blue: "#BD93F9", magenta: "#FF79C6", cyan: "#8BE9FD", white: "#F8F8F2",
        brightBlack: "#6272A4", brightRed: "#FF6E6E", brightGreen: "#69FF94", brightYellow: "#FFFFA5",
        brightBlue: "#D6ACFF", brightMagenta: "#FF92DF", brightCyan: "#A4FFFF", brightWhite: "#FFFFFF"
    )

    static let nord = TerminalColorScheme(
        name: "Nord",
        background: "#2E3440", foreground: "#D8DEE9", cursor: "#D8DEE9", selection: "#434C5E",
        black: "#3B4252", red: "#BF616A", green: "#A3BE8C", yellow: "#EBCB8B",
        blue: "#81A1C1", magenta: "#B48EAD", cyan: "#88C0D0", white: "#E5E9F0",
        brightBlack: "#4C566A", brightRed: "#BF616A", brightGreen: "#A3BE8C", brightYellow: "#EBCB8B",
        brightBlue: "#81A1C1", brightMagenta: "#B48EAD", brightCyan: "#8FBCBB", brightWhite: "#ECEFF4"
    )

    static let monokai = TerminalColorScheme(
        name: "Monokai",
        background: "#272822", foreground: "#F8F8F2", cursor: "#F8F8F2", selection: "#49483E",
        black: "#272822", red: "#F92672", green: "#A6E22E", yellow: "#F4BF75",
        blue: "#66D9EF", magenta: "#AE81FF", cyan: "#A1EFE4", white: "#F8F8F2",
        brightBlack: "#75715E", brightRed: "#F92672", brightGreen: "#A6E22E", brightYellow: "#F4BF75",
        brightBlue: "#66D9EF", brightMagenta: "#AE81FF", brightCyan: "#A1EFE4", brightWhite: "#F9F8F5"
    )

    static let gruvboxDark = TerminalColorScheme(
        name: "Gruvbox Dark",
        background: "#282828", foreground: "#EBDBB2", cursor: "#EBDBB2", selection: "#504945",
        black: "#282828", red: "#CC241D", green: "#98971A", yellow: "#D79921",
        blue: "#458588", magenta: "#B16286", cyan: "#689D6A", white: "#A89984",
        brightBlack: "#928374", brightRed: "#FB4934", brightGreen: "#B8BB26", brightYellow: "#FABD2F",
        brightBlue: "#83A598", brightMagenta: "#D3869B", brightCyan: "#8EC07C", brightWhite: "#EBDBB2"
    )

    static let tokyoNight = TerminalColorScheme(
        name: "Tokyo Night",
        background: "#1A1B26", foreground: "#A9B1D6", cursor: "#C0CAF5", selection: "#33467C",
        black: "#15161E", red: "#F7768E", green: "#9ECE6A", yellow: "#E0AF68",
        blue: "#7AA2F7", magenta: "#BB9AF7", cyan: "#7DCFFF", white: "#A9B1D6",
        brightBlack: "#414868", brightRed: "#F7768E", brightGreen: "#9ECE6A", brightYellow: "#E0AF68",
        brightBlue: "#7AA2F7", brightMagenta: "#BB9AF7", brightCyan: "#7DCFFF", brightWhite: "#C0CAF5"
    )

    static let allPresets: [TerminalColorScheme] = [
        .default, .solarizedDark, .solarizedLight, .dracula, .nord, .monokai, .gruvboxDark, .tokyoNight
    ]

    func nsColor(for hex: String) -> NSColor {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)
        return NSColor(
            red: CGFloat((rgb & 0xFF0000) >> 16) / 255.0,
            green: CGFloat((rgb & 0x00FF00) >> 8) / 255.0,
            blue: CGFloat(rgb & 0x0000FF) / 255.0,
            alpha: 1.0
        )
    }

    var signature: String {
        [
            name, background, foreground, cursor, selection,
            black, red, green, yellow, blue, magenta, cyan, white,
            brightBlack, brightRed, brightGreen, brightYellow, brightBlue,
            brightMagenta, brightCyan, brightWhite
        ].joined(separator: "|")
    }
}

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
        KeyboardShortcut(action: "newTab", key: "t", modifiers: ["cmd"]),
        KeyboardShortcut(action: "closeTab", key: "w", modifiers: ["cmd"]),
        KeyboardShortcut(action: "nextTab", key: "]", modifiers: ["cmd", "shift"]),
        KeyboardShortcut(action: "previousTab", key: "[", modifiers: ["cmd", "shift"]),
        KeyboardShortcut(action: "find", key: "f", modifiers: ["cmd"]),
        KeyboardShortcut(action: "findNext", key: "g", modifiers: ["cmd"]),
        KeyboardShortcut(action: "findPrevious", key: "g", modifiers: ["cmd", "shift"]),
        KeyboardShortcut(action: "copy", key: "c", modifiers: ["cmd"]),
        KeyboardShortcut(action: "paste", key: "v", modifiers: ["cmd"]),
        KeyboardShortcut(action: "clear", key: "k", modifiers: ["cmd"]),
        KeyboardShortcut(action: "zoomIn", key: "=", modifiers: ["cmd"]),
        KeyboardShortcut(action: "zoomOut", key: "-", modifiers: ["cmd"]),
        KeyboardShortcut(action: "zoomReset", key: "0", modifiers: ["cmd"]),
        KeyboardShortcut(action: "snippets", key: "s", modifiers: ["cmd", "shift"]),
        KeyboardShortcut(action: "renameTab", key: "r", modifiers: ["cmd", "shift"]),
        KeyboardShortcut(action: "debugConsole", key: "d", modifiers: ["cmd", "shift"]),
        KeyboardShortcut(action: "newWindow", key: "n", modifiers: ["cmd"]),
        KeyboardShortcut(action: "splitHorizontal", key: "d", modifiers: ["cmd"]),
        KeyboardShortcut(action: "splitVertical", key: "d", modifiers: ["cmd", "shift"]),
    ]

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

/// Centralized feature flags and settings for Chau7
/// All features can be toggled in Settings and values are persisted in UserDefaults
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

    static let availableFonts: [String] = {
        let monospacedFonts = [
            "Menlo", "Monaco", "SF Mono", "Courier New", "Consolas",
            "JetBrains Mono", "Fira Code", "Source Code Pro", "IBM Plex Mono",
            "Hack", "Inconsolata", "Anonymous Pro", "Ubuntu Mono", "Roboto Mono"
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
               let data = try? JSONEncoder().encode(scheme) {
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

    // MARK: - Keyboard Shortcuts (NEW)

    @Published var customShortcuts: [KeyboardShortcut] {
        didSet {
            if let data = try? JSONEncoder().encode(customShortcuts) {
                UserDefaults.standard.set(data, forKey: Keys.customShortcuts)
            }
        }
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
        customShortcuts = KeyboardShortcut.defaultShortcuts
    }

    // MARK: - Notification Filters (NEW)

    @Published var notificationFilters: NotificationFilters {
        didSet {
            if let data = try? JSONEncoder().encode(notificationFilters) {
                UserDefaults.standard.set(data, forKey: Keys.notificationFilters)
            }
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

    @Published var defaultEditor: String {
        didSet { UserDefaults.standard.set(defaultEditor, forKey: Keys.defaultEditor) }
    }

    @Published var urlHandler: URLHandler {
        didSet { UserDefaults.standard.set(urlHandler.rawValue, forKey: Keys.urlHandler) }
    }

    // MARK: - Custom AI Detection (NEW)

    @Published var customAIDetectionRules: [CustomAIDetectionRule] {
        didSet {
            if let data = try? JSONEncoder().encode(customAIDetectionRules) {
                UserDefaults.standard.set(data, forKey: Keys.customAIDetectionRules)
            }
        }
    }

    // MARK: - F04: Quick Dropdown Terminal

    @Published var isDropdownEnabled: Bool {
        didSet { UserDefaults.standard.set(isDropdownEnabled, forKey: Keys.dropdownEnabled) }
    }

    @Published var dropdownHotkey: String {
        didSet { UserDefaults.standard.set(dropdownHotkey, forKey: Keys.dropdownHotkey) }
    }

    @Published var dropdownHeight: Double {
        didSet {
            let clamped = max(0.1, min(dropdownHeight, 1.0))
            if dropdownHeight != clamped {
                dropdownHeight = clamped
                return
            }
            UserDefaults.standard.set(dropdownHeight, forKey: Keys.dropdownHeight)
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
        // Keyboard Shortcuts (NEW)
        static let customShortcuts = "keyboard.customShortcuts"
        // Notification Filters (NEW)
        static let notificationFilters = "notifications.filters"
        // Find Defaults (NEW)
        static let findCaseSensitiveDefault = "search.defaultCaseSensitive"
        static let findRegexDefault = "search.defaultRegex"
        // Tab Behavior
        static let lastTabCloseBehavior = "tabs.lastTabCloseBehavior"
        static let newTabPosition = "tabs.newTabPosition"
        // Window Opacity
        static let windowOpacity = "window.opacity"
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
        static let defaultEditor = "feature.defaultEditor"
        static let urlHandler = "feature.urlHandler"
        static let customAIDetectionRules = "ai.customDetectionRules"
        // F04
        static let dropdownEnabled = "feature.dropdownEnabled"
        static let dropdownHotkey = "feature.dropdownHotkey"
        static let dropdownHeight = "feature.dropdownHeight"
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
        static let jsonPrettyPrint = "feature.jsonPrettyPrint"
        // F07
        static let semanticSearch = "feature.semanticSearch"
        // F02
        static let splitPanes = "feature.splitPanes"
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
           let scheme = try? JSONDecoder().decode(TerminalColorScheme.self, from: data) {
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

        // Keyboard Shortcuts (NEW)
        if let data = defaults.data(forKey: Keys.customShortcuts),
           let shortcuts = try? JSONDecoder().decode([KeyboardShortcut].self, from: data) {
            self.customShortcuts = shortcuts
        } else {
            self.customShortcuts = KeyboardShortcut.defaultShortcuts
        }

        // Notification Filters (NEW)
        if let data = defaults.data(forKey: Keys.notificationFilters),
           let filters = try? JSONDecoder().decode(NotificationFilters.self, from: data) {
            self.notificationFilters = filters
        } else {
            self.notificationFilters = .defaults
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

        // Window Opacity
        self.windowOpacity = defaults.object(forKey: Keys.windowOpacity) as? Double ?? 1.0

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
        self.defaultEditor = defaults.string(forKey: Keys.defaultEditor) ?? ""  // Empty = use $EDITOR or system default
        if let handlerRaw = defaults.string(forKey: Keys.urlHandler),
           let handler = URLHandler(rawValue: handlerRaw) {
            self.urlHandler = handler
        } else {
            self.urlHandler = .system
        }

        // Custom AI Detection (NEW)
        if let data = defaults.data(forKey: Keys.customAIDetectionRules),
           let rules = try? JSONDecoder().decode([CustomAIDetectionRule].self, from: data) {
            self.customAIDetectionRules = rules
        } else {
            self.customAIDetectionRules = []
        }

        // F04: Dropdown (default: disabled)
        self.isDropdownEnabled = defaults.object(forKey: Keys.dropdownEnabled) as? Bool ?? false
        self.dropdownHotkey = defaults.string(forKey: Keys.dropdownHotkey) ?? "ctrl+`"
        self.dropdownHeight = defaults.object(forKey: Keys.dropdownHeight) as? Double ?? 0.4  // 40% of screen

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
        self.isJSONPrettyPrintEnabled = defaults.object(forKey: Keys.jsonPrettyPrint) as? Bool ?? false

        // F07: Semantic Search (default: disabled - requires shell integration)
        self.isSemanticSearchEnabled = defaults.object(forKey: Keys.semanticSearch) as? Bool ?? false

        // F02: Split Panes (default: enabled)
        self.isSplitPanesEnabled = defaults.object(forKey: Keys.splitPanes) as? Bool ?? true

        // F11: Keybindings (default: "default")
        self.keybindingPreset = defaults.string(forKey: Keys.keybindingPreset) ?? "default"

        // General Terminal Settings
        self.cursorStyle = defaults.string(forKey: Keys.cursorStyle) ?? "block"
        self.cursorBlink = defaults.object(forKey: Keys.cursorBlink) as? Bool ?? true
        self.scrollbackLines = defaults.object(forKey: Keys.scrollbackLines) as? Int ?? 10000
        self.bellEnabled = defaults.object(forKey: Keys.bellEnabled) as? Bool ?? true
        self.bellSound = defaults.string(forKey: Keys.bellSound) ?? "default"
        self.defaultStartDirectory = defaults.string(forKey: Keys.defaultStartDirectory) ?? home
    }

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
        let defaults = UserDefaults.standard
        guard let stored = defaults.dictionary(forKey: Keys.overlayPositionsMap) else { return [:] }
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
        return result
    }

    private func saveOverlayPositionsStore(_ store: [String: [String: [String: Double]]]) {
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
        var customShortcuts: [KeyboardShortcut]
        var notificationFilters: NotificationFilters
        var findCaseSensitiveDefault: Bool?
        var findRegexDefault: Bool?
        var lastTabCloseBehavior: String?
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
        var defaultEditor: String
        var urlHandler: String?
        var customAIDetectionRules: [CustomAIDetectionRule]?
        var isDropdownEnabled: Bool
        var dropdownHotkey: String
        var dropdownHeight: Double
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
            customShortcuts: customShortcuts,
            notificationFilters: notificationFilters,
            findCaseSensitiveDefault: findCaseSensitiveDefault,
            findRegexDefault: findRegexDefault,
            lastTabCloseBehavior: lastTabCloseBehavior.rawValue,
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
            defaultEditor: defaultEditor,
            urlHandler: urlHandler.rawValue,
            customAIDetectionRules: customAIDetectionRules,
            isDropdownEnabled: isDropdownEnabled,
            dropdownHotkey: dropdownHotkey,
            dropdownHeight: dropdownHeight,
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
            isJSONPrettyPrintEnabled: isJSONPrettyPrintEnabled,
            isSemanticSearchEnabled: isSemanticSearchEnabled,
            isSplitPanesEnabled: isSplitPanesEnabled,
            keybindingPreset: keybindingPreset
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(exportable)
    }

    func importSettings(from data: Data) -> Bool {
        guard let imported = try? JSONDecoder().decode(ExportableSettings.self, from: data) else {
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
        customShortcuts = imported.customShortcuts
        notificationFilters = imported.notificationFilters
        findCaseSensitiveDefault = imported.findCaseSensitiveDefault ?? false
        findRegexDefault = imported.findRegexDefault ?? false
        if let behaviorRaw = imported.lastTabCloseBehavior,
           let behavior = LastTabCloseBehavior(rawValue: behaviorRaw) {
            lastTabCloseBehavior = behavior
        } else {
            lastTabCloseBehavior = .keepWindow
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
        defaultEditor = imported.defaultEditor
        if let handlerRaw = imported.urlHandler,
           let handler = URLHandler(rawValue: handlerRaw) {
            urlHandler = handler
        } else {
            urlHandler = .system
        }
        customAIDetectionRules = imported.customAIDetectionRules ?? []
        isDropdownEnabled = imported.isDropdownEnabled
        dropdownHotkey = imported.dropdownHotkey
        dropdownHeight = imported.dropdownHeight
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

        // Shortcuts
        customShortcuts = KeyboardShortcut.defaultShortcuts

        // Notifications
        notificationFilters = .defaults
        findCaseSensitiveDefault = false
        findRegexDefault = false
        lastTabCloseBehavior = .keepWindow
        newTabPosition = "end"

        // Window
        windowOpacity = 1.0

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
        defaultEditor = ""
        urlHandler = .system
        customAIDetectionRules = []
        isDropdownEnabled = false
        dropdownHotkey = "ctrl+`"
        dropdownHeight = 0.4
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
    }

    func resetInputToDefaults() {
        customShortcuts = KeyboardShortcut.defaultShortcuts
        keybindingPreset = "default"
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

    func syncToiCloud() {
        guard iCloudSyncEnabled else { return }
        guard let data = exportSettings() else { return }
        NSUbiquitousKeyValueStore.default.set(data, forKey: iCloudKey)
        NSUbiquitousKeyValueStore.default.synchronize()
        Log.info("Settings synced to iCloud")
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
            customShortcuts: KeyboardShortcut.defaultShortcuts,
            notificationFilters: .defaults,
            findCaseSensitiveDefault: false,
            findRegexDefault: false,
            lastTabCloseBehavior: "keepWindow",
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
            defaultEditor: "",
            urlHandler: "system",
            customAIDetectionRules: [],
            isDropdownEnabled: false,
            dropdownHotkey: "ctrl+`",
            dropdownHeight: 0.4,
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
            isJSONPrettyPrintEnabled: false,
            isSemanticSearchEnabled: false,
            isSplitPanesEnabled: true,
            keybindingPreset: "default"
        )
    }

    var savedProfiles: [SettingsProfile] {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.profilesKey),
                  let profiles = try? JSONDecoder().decode([SettingsProfile].self, from: data) else {
                return SettingsProfile.defaultProfiles
            }
            return profiles
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
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
              let exportable = try? JSONDecoder().decode(ExportableSettings.self, from: currentSettings) else {
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
        let encoder = JSONEncoder()
        guard let data = try? encoder.encode(profile.settings) else { return }
        _ = importSettings(from: data)
        activeProfileId = profile.id
        NotificationCenter.default.post(name: .settingsProfileChanged, object: profile)
    }

    func saveCurrentToProfile(_ profile: SettingsProfile) {
        guard let currentSettings = exportSettings(),
              let exportable = try? JSONDecoder().decode(ExportableSettings.self, from: currentSettings) else {
            return
        }
        var updatedProfile = profile
        updatedProfile.settings = exportable
        updateProfile(updatedProfile)
    }
}

// MARK: - Searchable Settings Metadata

struct SearchableSetting: Identifiable {
    let id: String
    let section: SettingsSection
    let title: String
    let keywords: [String]
    let description: String

    func matches(_ query: String) -> Bool {
        let lowercased = query.lowercased()
        return title.lowercased().contains(lowercased) ||
               description.lowercased().contains(lowercased) ||
               keywords.contains { $0.lowercased().contains(lowercased) }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case general
    case appearance
    case terminal
    case tabs
    case input
    case productivity
    case windows
    case aiIntegration
    case logs
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .terminal: return "Terminal"
        case .tabs: return "Tabs"
        case .input: return "Input"
        case .productivity: return "Productivity"
        case .windows: return "Windows"
        case .aiIntegration: return "AI Integration"
        case .logs: return "Logs"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .terminal: return "terminal"
        case .tabs: return "rectangle.stack"
        case .input: return "keyboard"
        case .productivity: return "bolt.fill"
        case .windows: return "macwindow.on.rectangle"
        case .aiIntegration: return "sparkles"
        case .logs: return "doc.text.magnifyingglass"
        case .about: return "info.circle"
        }
    }

    var description: String {
        switch self {
        case .general: return "Startup behavior, profiles, and backup"
        case .appearance: return "Font, colors, and display preferences"
        case .terminal: return "Shell, cursor, scrollback, and bell"
        case .tabs: return "Tab behavior and appearance"
        case .input: return "Keyboard shortcuts and mouse behavior"
        case .productivity: return "Snippets, clipboard, bookmarks, and search"
        case .windows: return "Overlay, dropdown, and split panes"
        case .aiIntegration: return "AI CLI detection and notifications"
        case .logs: return "Log files and session tracking"
        case .about: return "Version information and links"
        }
    }
}

extension FeatureSettings {
    static let searchableSettings: [SearchableSetting] = [
        // General
        SearchableSetting(id: "launch", section: .general, title: "Launch at Login",
                         keywords: ["startup", "login", "autostart", "boot"],
                         description: "Automatically start Chau7 when you log in"),
        SearchableSetting(id: "defaultDir", section: .general, title: "Default Directory",
                         keywords: ["path", "folder", "start", "working"],
                         description: "Starting directory for new terminal tabs"),
        SearchableSetting(id: "icloud", section: .general, title: "iCloud Sync",
                         keywords: ["cloud", "sync", "backup", "restore"],
                         description: "Sync settings across Macs via iCloud"),
        SearchableSetting(id: "profiles", section: .general, title: "Settings Profiles",
                         keywords: ["profile", "work", "personal", "switch", "preset"],
                         description: "Create and switch between named setting profiles"),
        SearchableSetting(id: "export", section: .general, title: "Export/Import Settings",
                         keywords: ["backup", "restore", "json", "save", "load"],
                         description: "Export or import settings as JSON"),

        // Appearance
        SearchableSetting(id: "fontFamily", section: .appearance, title: "Font Family",
                         keywords: ["typeface", "menlo", "monaco", "monospace", "text"],
                         description: "Choose the terminal font"),
        SearchableSetting(id: "fontSize", section: .appearance, title: "Font Size",
                         keywords: ["text", "size", "big", "small", "zoom"],
                         description: "Terminal font size in points"),
        SearchableSetting(id: "defaultZoom", section: .appearance, title: "Default Zoom",
                         keywords: ["scale", "zoom", "percent", "size"],
                         description: "Default zoom percentage for new tabs"),
        SearchableSetting(id: "colorScheme", section: .appearance, title: "Color Scheme",
                         keywords: ["theme", "colors", "dracula", "solarized", "nord", "dark", "light"],
                         description: "Terminal color palette"),
        SearchableSetting(id: "opacity", section: .appearance, title: "Window Opacity",
                         keywords: ["transparency", "translucent", "see-through", "alpha"],
                         description: "Terminal window transparency"),
        SearchableSetting(id: "syntaxHighlight", section: .appearance, title: "Syntax Highlighting",
                         keywords: ["code", "colors", "highlight"],
                         description: "Highlight code syntax in output"),
        SearchableSetting(id: "timestamps", section: .appearance, title: "Line Timestamps",
                         keywords: ["time", "date", "clock"],
                         description: "Show timestamps for terminal lines"),

        // Terminal
        SearchableSetting(id: "shell", section: .terminal, title: "Shell",
                         keywords: ["zsh", "bash", "fish", "terminal", "command"],
                         description: "Choose which shell to use"),
        SearchableSetting(id: "startupCommand", section: .terminal, title: "Startup Command",
                         keywords: ["init", "run", "execute", "neofetch"],
                         description: "Command to run when terminal starts"),
        SearchableSetting(id: "cursor", section: .terminal, title: "Cursor Style",
                         keywords: ["block", "underline", "bar", "caret"],
                         description: "Terminal cursor appearance"),
        SearchableSetting(id: "cursorBlink", section: .terminal, title: "Cursor Blink",
                         keywords: ["animate", "flash", "blink"],
                         description: "Animate cursor with blinking"),
        SearchableSetting(id: "scrollback", section: .terminal, title: "Scrollback Lines",
                         keywords: ["history", "buffer", "lines", "scroll"],
                         description: "Lines to keep in scrollback"),
        SearchableSetting(id: "bell", section: .terminal, title: "Bell",
                         keywords: ["sound", "beep", "alert", "audio"],
                         description: "Terminal bell sound"),

        // Input
        SearchableSetting(id: "shortcuts", section: .input, title: "Keyboard Shortcuts",
                         keywords: ["hotkey", "keybinding", "key", "command"],
                         description: "Customize keyboard shortcuts"),
        SearchableSetting(id: "copyOnSelect", section: .input, title: "Copy on Select",
                         keywords: ["clipboard", "copy", "selection"],
                         description: "Copy text when selected"),
        SearchableSetting(id: "cmdClick", section: .input, title: "Cmd+Click Paths",
                         keywords: ["click", "open", "file", "editor"],
                         description: "Open file paths with Cmd+click"),
        SearchableSetting(id: "urlHandler", section: .input, title: "URL Handler",
                         keywords: ["browser", "url", "links", "open"],
                         description: "Choose which browser opens URLs"),
        SearchableSetting(id: "broadcast", section: .input, title: "Broadcast Input",
                         keywords: ["multi", "tabs", "send", "input"],
                         description: "Send input to all tabs"),

        // Tabs
        SearchableSetting(id: "lastTabClose", section: .tabs, title: "Last Tab Close",
                         keywords: ["close", "window", "behavior", "final"],
                         description: "What happens when closing the last tab"),

        // Productivity
        SearchableSetting(id: "snippets", section: .productivity, title: "Snippets",
                         keywords: ["template", "shortcut", "text", "expansion"],
                         description: "Reusable text snippets"),
        SearchableSetting(id: "clipboard", section: .productivity, title: "Clipboard History",
                         keywords: ["copy", "paste", "history"],
                         description: "Access previous clipboard items"),
        SearchableSetting(id: "bookmarks", section: .productivity, title: "Bookmarks",
                         keywords: ["save", "position", "mark"],
                         description: "Save terminal positions"),
        SearchableSetting(id: "search", section: .productivity, title: "Semantic Search",
                         keywords: ["find", "search", "command"],
                         description: "Command-aware search"),
        SearchableSetting(id: "findDefaults", section: .productivity, title: "Find Defaults",
                         keywords: ["find", "case", "regex", "default"],
                         description: "Default settings for the find bar"),

        // Windows
        SearchableSetting(id: "dropdown", section: .windows, title: "Dropdown Terminal",
                         keywords: ["quake", "slide", "hotkey", "global"],
                         description: "Quake-style dropdown terminal"),
        SearchableSetting(id: "splitPanes", section: .windows, title: "Split Panes",
                         keywords: ["split", "divide", "pane", "horizontal", "vertical"],
                         description: "Split terminal into panes"),

        // AI Integration
        SearchableSetting(id: "aiDetection", section: .aiIntegration, title: "AI CLI Detection",
                         keywords: ["claude", "codex", "gemini", "copilot", "detect"],
                         description: "Detect AI CLIs automatically"),
        SearchableSetting(id: "aiCustomDetection", section: .aiIntegration, title: "Custom AI Detection",
                         keywords: ["custom", "pattern", "rules", "detect"],
                         description: "Add custom AI CLI detection rules"),
        SearchableSetting(id: "autoTabTheme", section: .aiIntegration, title: "Auto Tab Themes",
                         keywords: ["color", "tab", "ai", "theme"],
                         description: "Color tabs by AI model"),
        SearchableSetting(id: "notifications", section: .aiIntegration, title: "Notifications",
                         keywords: ["alert", "notify", "task", "complete"],
                         description: "AI event notifications"),
        SearchableSetting(id: "notificationFilters", section: .aiIntegration, title: "Notification Filters",
                         keywords: ["filter", "event", "type", "toggle"],
                         description: "Filter which events notify"),
    ]

    static func searchSettings(query: String) -> [(section: SettingsSection, settings: [SearchableSetting])] {
        guard !query.isEmpty else { return [] }

        let matches = searchableSettings.filter { $0.matches(query) }
        var grouped: [SettingsSection: [SearchableSetting]] = [:]

        for setting in matches {
            grouped[setting.section, default: []].append(setting)
        }

        return SettingsSection.allCases.compactMap { section in
            guard let settings = grouped[section], !settings.isEmpty else { return nil }
            return (section: section, settings: settings)
        }
    }

    static func sectionsMatching(query: String) -> Set<SettingsSection> {
        guard !query.isEmpty else { return [] }
        return Set(searchableSettings.filter { $0.matches(query) }.map { $0.section })
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let terminalFontChanged = Notification.Name("terminalFontChanged")
    static let terminalColorsChanged = Notification.Name("terminalColorsChanged")
    static let terminalOpacityChanged = Notification.Name("terminalOpacityChanged")
    static let terminalZoomChanged = Notification.Name("terminalZoomChanged")
    static let settingsProfileChanged = Notification.Name("settingsProfileChanged")
}
