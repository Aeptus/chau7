import Foundation

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
    case remote
    case aiIntegration
    case notifications
    case logs
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return L("settings.general", "General")
        case .appearance: return L("settings.appearance", "Appearance")
        case .terminal: return L("settings.terminal", "Terminal")
        case .tabs: return L("settings.tabs", "Tabs")
        case .input: return L("settings.input", "Input")
        case .productivity: return L("settings.productivity", "Productivity")
        case .windows: return L("settings.windows", "Windows")
        case .remote: return L("settings.remote", "Remote Control")
        case .aiIntegration: return L("settings.ai", "AI Integration")
        case .notifications: return L("settings.notifications", "Notifications")
        case .logs: return L("settings.logs", "Logs")
        case .about: return L("settings.about", "About")
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
        case .remote: return "antenna.radiowaves.left.and.right"
        case .aiIntegration: return "sparkles"
        case .notifications: return "bell.badge"
        case .logs: return "doc.text.magnifyingglass"
        case .about: return "info.circle"
        }
    }

    var description: String {
        switch self {
        case .general: return L("settings.general.description", "Startup behavior, profiles, and backup")
        case .appearance: return L("settings.appearance.description", "Font, colors, and display preferences")
        case .terminal: return L("settings.terminal.description", "Shell, cursor, scrollback, and bell")
        case .tabs: return L("settings.tabs.description", "Tab behavior and appearance")
        case .input: return L("settings.input.description", "Keyboard shortcuts and mouse behavior")
        case .productivity: return L("settings.productivity.description", "Snippets, clipboard, bookmarks, and search")
        case .windows: return L("settings.windows.description", "Overlay and split panes")
        case .remote: return L("settings.remote.description", "Remote access and pairing")
        case .aiIntegration: return L("settings.ai.description", "AI CLI detection and theming")
        case .notifications: return L("settings.notifications.description", "Alert preferences and event filters")
        case .logs: return L("settings.logs.description", "Log files and session tracking")
        case .about: return L("settings.about.description", "Version information and links")
        }
    }
}

// MARK: - FeatureSettings Search Extension

extension FeatureSettings {
    static let searchableSettings: [SearchableSetting] = [
        // General
        SearchableSetting(id: "language", section: .general, title: "Language",
                         keywords: ["langue", "français", "english", "i18n", "localization", "translation"],
                         description: "Application display language"),
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
        SearchableSetting(id: "remote", section: .remote, title: "Remote Control",
                         keywords: ["remote", "ios", "relay", "pairing", "qr"],
                         description: "Pair an iPhone and view terminal output remotely"),

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
        SearchableSetting(id: "lsColors", section: .terminal, title: "ls Colors",
                         keywords: ["ls", "colors", "colorize", "LSCOLORS", "CLICOLOR"],
                         description: "Enable colored ls output in new sessions"),
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
        SearchableSetting(id: "shortcutHelperHint", section: .input, title: "Shortcut Helper Hint",
                         keywords: ["hint", "overlay", "helper", "shortcuts", "corner"],
                         description: "Show the shortcut helper hint in the terminal"),
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
        SearchableSetting(id: "newTabDirectory", section: .tabs, title: "New Tab Directory",
                         keywords: ["current", "working", "directory", "folder", "inherit"],
                         description: "Open new tabs in the active tab's directory"),

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

        // Notifications
        SearchableSetting(id: "notificationStatus", section: .notifications, title: "Notification Status",
                         keywords: ["permission", "alert", "system", "status"],
                         description: "Notification permission status"),
        SearchableSetting(id: "notificationFilters", section: .notifications, title: "Notification Filters",
                         keywords: ["filter", "event", "type", "toggle", "task", "complete", "failed"],
                         description: "Filter which events trigger notifications"),
        SearchableSetting(id: "eventMonitoring", section: .notifications, title: "Event Monitoring",
                         keywords: ["monitor", "watch", "ai", "events", "log"],
                         description: "Monitor AI CLI events for notifications"),
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
    static let appThemeChanged = Notification.Name("appThemeChanged")
    static let fullscreenToolbarSettingChanged = Notification.Name("fullscreenToolbarSettingChanged")
    // API Analytics
    static let apiAnalyticsSettingsChanged = Notification.Name("apiAnalyticsSettingsChanged")
    static let apiCallRecorded = Notification.Name("apiCallRecorded")
    static let proxyStatusChanged = Notification.Name("proxyStatusChanged")
}
