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

private func localizedKeywords(_ key: String, _ defaultValue: String) -> [String] {
    L(key, defaultValue)
        .split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
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
    case tokenOptimization
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
        case .tokenOptimization: return L("settings.tokenOptimization", "Token Optimization")
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
        case .tokenOptimization: return "bolt.horizontal.circle"
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
        case .tokenOptimization: return L("settings.tokenOptimization.description", "Reduce token usage for AI CLI commands")
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
        SearchableSetting(
            id: "language",
            section: .general,
            title: L("settings.search.language.title", "Language"),
            keywords: localizedKeywords(
                "settings.search.language.keywords",
                "language,langue,français,english,i18n,localization,translation"
            ),
            description: L("settings.search.language.description", "Application display language")
        ),
        SearchableSetting(
            id: "launch",
            section: .general,
            title: L("settings.search.launch.title", "Launch at Login"),
            keywords: localizedKeywords(
                "settings.search.launch.keywords",
                "startup,login,autostart,boot"
            ),
            description: L("settings.search.launch.description", "Automatically start Chau7 when you log in")
        ),
        SearchableSetting(
            id: "defaultDir",
            section: .general,
            title: L("settings.search.defaultDir.title", "Default Directory"),
            keywords: localizedKeywords(
                "settings.search.defaultDir.keywords",
                "path,folder,start,working"
            ),
            description: L("settings.search.defaultDir.description", "Starting directory for new terminal tabs")
        ),
        SearchableSetting(
            id: "icloud",
            section: .general,
            title: L("settings.search.icloud.title", "iCloud Sync"),
            keywords: localizedKeywords(
                "settings.search.icloud.keywords",
                "cloud,sync,backup,restore"
            ),
            description: L("settings.search.icloud.description", "Sync settings across Macs via iCloud")
        ),
        SearchableSetting(
            id: "profiles",
            section: .general,
            title: L("settings.search.profiles.title", "Settings Profiles"),
            keywords: localizedKeywords(
                "settings.search.profiles.keywords",
                "profile,work,personal,switch,preset"
            ),
            description: L("settings.search.profiles.description", "Create and switch between named setting profiles")
        ),
        SearchableSetting(
            id: "export",
            section: .general,
            title: L("settings.search.export.title", "Export/Import Settings"),
            keywords: localizedKeywords(
                "settings.search.export.keywords",
                "backup,restore,json,save,load"
            ),
            description: L("settings.search.export.description", "Export or import settings as JSON")
        ),
        SearchableSetting(
            id: "remote",
            section: .remote,
            title: L("settings.search.remote.title", "Remote Control"),
            keywords: localizedKeywords(
                "settings.search.remote.keywords",
                "remote,ios,relay,pairing,qr"
            ),
            description: L("settings.search.remote.description", "Pair an iPhone and view terminal output remotely")
        ),

        // Appearance
        SearchableSetting(
            id: "fontFamily",
            section: .appearance,
            title: L("settings.search.fontFamily.title", "Font Family"),
            keywords: localizedKeywords(
                "settings.search.fontFamily.keywords",
                "typeface,menlo,monaco,monospace,text"
            ),
            description: L("settings.search.fontFamily.description", "Choose the terminal font")
        ),
        SearchableSetting(
            id: "fontSize",
            section: .appearance,
            title: L("settings.search.fontSize.title", "Font Size"),
            keywords: localizedKeywords(
                "settings.search.fontSize.keywords",
                "text,size,big,small,zoom"
            ),
            description: L("settings.search.fontSize.description", "Terminal font size in points")
        ),
        SearchableSetting(
            id: "defaultZoom",
            section: .appearance,
            title: L("settings.search.defaultZoom.title", "Default Zoom"),
            keywords: localizedKeywords(
                "settings.search.defaultZoom.keywords",
                "scale,zoom,percent,size"
            ),
            description: L("settings.search.defaultZoom.description", "Default zoom percentage for new tabs")
        ),
        SearchableSetting(
            id: "colorScheme",
            section: .appearance,
            title: L("settings.search.colorScheme.title", "Color Scheme"),
            keywords: localizedKeywords(
                "settings.search.colorScheme.keywords",
                "theme,colors,dracula,solarized,nord,dark,light"
            ),
            description: L("settings.search.colorScheme.description", "Terminal color palette")
        ),
        SearchableSetting(
            id: "opacity",
            section: .appearance,
            title: L("settings.search.opacity.title", "Window Opacity"),
            keywords: localizedKeywords(
                "settings.search.opacity.keywords",
                "transparency,translucent,see-through,alpha"
            ),
            description: L("settings.search.opacity.description", "Terminal window transparency")
        ),
        SearchableSetting(
            id: "syntaxHighlight",
            section: .appearance,
            title: L("settings.search.syntaxHighlight.title", "Syntax Highlighting"),
            keywords: localizedKeywords(
                "settings.search.syntaxHighlight.keywords",
                "code,colors,highlight"
            ),
            description: L("settings.search.syntaxHighlight.description", "Highlight code syntax in output")
        ),
        SearchableSetting(
            id: "timestamps",
            section: .appearance,
            title: L("settings.search.timestamps.title", "Line Timestamps"),
            keywords: localizedKeywords(
                "settings.search.timestamps.keywords",
                "time,date,clock"
            ),
            description: L("settings.search.timestamps.description", "Show timestamps for terminal lines")
        ),

        // Terminal
        SearchableSetting(
            id: "shell",
            section: .terminal,
            title: L("settings.search.shell.title", "Shell"),
            keywords: localizedKeywords(
                "settings.search.shell.keywords",
                "zsh,bash,fish,terminal,command"
            ),
            description: L("settings.search.shell.description", "Choose which shell to use")
        ),
        SearchableSetting(
            id: "startupCommand",
            section: .terminal,
            title: L("settings.search.startupCommand.title", "Startup Command"),
            keywords: localizedKeywords(
                "settings.search.startupCommand.keywords",
                "init,run,execute,neofetch"
            ),
            description: L("settings.search.startupCommand.description", "Command to run when terminal starts")
        ),
        SearchableSetting(
            id: "lsColors",
            section: .terminal,
            title: L("settings.search.lsColors.title", "ls Colors"),
            keywords: localizedKeywords(
                "settings.search.lsColors.keywords",
                "ls,colors,colorize,LSCOLORS,CLICOLOR"
            ),
            description: L("settings.search.lsColors.description", "Enable colored ls output in new sessions")
        ),
        SearchableSetting(
            id: "cursor",
            section: .terminal,
            title: L("settings.search.cursor.title", "Cursor Style"),
            keywords: localizedKeywords(
                "settings.search.cursor.keywords",
                "block,underline,bar,caret"
            ),
            description: L("settings.search.cursor.description", "Terminal cursor appearance")
        ),
        SearchableSetting(
            id: "cursorBlink",
            section: .terminal,
            title: L("settings.search.cursorBlink.title", "Cursor Blink"),
            keywords: localizedKeywords(
                "settings.search.cursorBlink.keywords",
                "animate,flash,blink"
            ),
            description: L("settings.search.cursorBlink.description", "Animate cursor with blinking")
        ),
        SearchableSetting(
            id: "scrollback",
            section: .terminal,
            title: L("settings.search.scrollback.title", "Scrollback Lines"),
            keywords: localizedKeywords(
                "settings.search.scrollback.keywords",
                "history,buffer,lines,scroll"
            ),
            description: L("settings.search.scrollback.description", "Lines to keep in scrollback")
        ),
        SearchableSetting(
            id: "bell",
            section: .terminal,
            title: L("settings.search.bell.title", "Bell"),
            keywords: localizedKeywords(
                "settings.search.bell.keywords",
                "sound,beep,alert,audio"
            ),
            description: L("settings.search.bell.description", "Terminal bell sound")
        ),
        SearchableSetting(
            id: "dangerousCommands",
            section: .terminal,
            title: L("settings.search.dangerousCommands.title", "Dangerous Commands"),
            keywords: localizedKeywords(
                "settings.search.dangerousCommands.keywords",
                "dangerous,risky,destructive,rm,force,highlight,safety"
            ),
            description: L("settings.search.dangerousCommands.description", "Highlight risky commands in the terminal")
        ),

        // Input
        SearchableSetting(
            id: "shortcuts",
            section: .input,
            title: L("settings.search.shortcuts.title", "Keyboard Shortcuts"),
            keywords: localizedKeywords(
                "settings.search.shortcuts.keywords",
                "hotkey,keybinding,key,command"
            ),
            description: L("settings.search.shortcuts.description", "Customize keyboard shortcuts")
        ),
        SearchableSetting(
            id: "shortcutHelperHint",
            section: .input,
            title: L("settings.search.shortcutHelperHint.title", "Shortcut Helper Hint"),
            keywords: localizedKeywords(
                "settings.search.shortcutHelperHint.keywords",
                "hint,overlay,helper,shortcuts,corner"
            ),
            description: L("settings.search.shortcutHelperHint.description", "Show the shortcut helper hint in the terminal")
        ),
        SearchableSetting(
            id: "copyOnSelect",
            section: .input,
            title: L("settings.search.copyOnSelect.title", "Copy on Select"),
            keywords: localizedKeywords(
                "settings.search.copyOnSelect.keywords",
                "clipboard,copy,selection"
            ),
            description: L("settings.search.copyOnSelect.description", "Copy text when selected")
        ),
        SearchableSetting(
            id: "cmdClick",
            section: .input,
            title: L("settings.search.cmdClick.title", "Cmd+Click Paths"),
            keywords: localizedKeywords(
                "settings.search.cmdClick.keywords",
                "click,open,file,editor"
            ),
            description: L("settings.search.cmdClick.description", "Open file paths with Cmd+click")
        ),
        SearchableSetting(
            id: "urlHandler",
            section: .input,
            title: L("settings.search.urlHandler.title", "URL Handler"),
            keywords: localizedKeywords(
                "settings.search.urlHandler.keywords",
                "browser,url,links,open"
            ),
            description: L("settings.search.urlHandler.description", "Choose which browser opens URLs")
        ),
        SearchableSetting(
            id: "broadcast",
            section: .input,
            title: L("settings.search.broadcast.title", "Broadcast Input"),
            keywords: localizedKeywords(
                "settings.search.broadcast.keywords",
                "multi,tabs,send,input"
            ),
            description: L("settings.search.broadcast.description", "Send input to all tabs")
        ),

        // Tabs
        SearchableSetting(
            id: "lastTabClose",
            section: .tabs,
            title: L("settings.search.lastTabClose.title", "Last Tab Close"),
            keywords: localizedKeywords(
                "settings.search.lastTabClose.keywords",
                "close,window,behavior,final"
            ),
            description: L("settings.search.lastTabClose.description", "What happens when closing the last tab")
        ),
        SearchableSetting(
            id: "newTabDirectory",
            section: .tabs,
            title: L("settings.search.newTabDirectory.title", "New Tab Directory"),
            keywords: localizedKeywords(
                "settings.search.newTabDirectory.keywords",
                "current,working,directory,folder,inherit"
            ),
            description: L("settings.search.newTabDirectory.description", "Open new tabs in the active tab's directory")
        ),

        // Productivity
        SearchableSetting(
            id: "snippets",
            section: .productivity,
            title: L("settings.search.snippets.title", "Snippets"),
            keywords: localizedKeywords(
                "settings.search.snippets.keywords",
                "template,shortcut,text,expansion"
            ),
            description: L("settings.search.snippets.description", "Reusable text snippets")
        ),
        SearchableSetting(
            id: "clipboard",
            section: .productivity,
            title: L("settings.search.clipboard.title", "Clipboard History"),
            keywords: localizedKeywords(
                "settings.search.clipboard.keywords",
                "copy,paste,history"
            ),
            description: L("settings.search.clipboard.description", "Access previous clipboard items")
        ),
        SearchableSetting(
            id: "bookmarks",
            section: .productivity,
            title: L("settings.search.bookmarks.title", "Bookmarks"),
            keywords: localizedKeywords(
                "settings.search.bookmarks.keywords",
                "save,position,mark"
            ),
            description: L("settings.search.bookmarks.description", "Save terminal positions")
        ),
        SearchableSetting(
            id: "search",
            section: .productivity,
            title: L("settings.search.search.title", "Semantic Search"),
            keywords: localizedKeywords(
                "settings.search.search.keywords",
                "find,search,command"
            ),
            description: L("settings.search.search.description", "Command-aware search")
        ),
        SearchableSetting(
            id: "findDefaults",
            section: .productivity,
            title: L("settings.search.findDefaults.title", "Find Defaults"),
            keywords: localizedKeywords(
                "settings.search.findDefaults.keywords",
                "find,case,regex,default"
            ),
            description: L("settings.search.findDefaults.description", "Default settings for the find bar")
        ),

        // Windows
        SearchableSetting(
            id: "splitPanes",
            section: .windows,
            title: L("settings.search.splitPanes.title", "Split Panes"),
            keywords: localizedKeywords(
                "settings.search.splitPanes.keywords",
                "split,divide,pane,horizontal,vertical"
            ),
            description: L("settings.search.splitPanes.description", "Split terminal into panes")
        ),

        // AI Integration
        SearchableSetting(
            id: "aiDetection",
            section: .aiIntegration,
            title: L("settings.search.aiDetection.title", "AI CLI Detection"),
            keywords: localizedKeywords(
                "settings.search.aiDetection.keywords",
                "claude,codex,gemini,copilot,detect"
            ),
            description: L("settings.search.aiDetection.description", "Detect AI CLIs automatically")
        ),
        SearchableSetting(
            id: "aiCustomDetection",
            section: .aiIntegration,
            title: L("settings.search.aiCustomDetection.title", "Custom AI Detection"),
            keywords: localizedKeywords(
                "settings.search.aiCustomDetection.keywords",
                "custom,pattern,rules,detect"
            ),
            description: L("settings.search.aiCustomDetection.description", "Add custom AI CLI detection rules")
        ),
        SearchableSetting(
            id: "autoTabTheme",
            section: .aiIntegration,
            title: L("settings.search.autoTabTheme.title", "Auto Tab Themes"),
            keywords: localizedKeywords(
                "settings.search.autoTabTheme.keywords",
                "color,tab,ai,theme"
            ),
            description: L("settings.search.autoTabTheme.description", "Color tabs by AI model")
        ),

        // Token Optimization
        SearchableSetting(
            id: "tokenOptimizationMode",
            section: .tokenOptimization,
            title: L("settings.search.rtk.title", "Token Optimization Mode"),
            keywords: localizedKeywords(
                "settings.search.rtk.keywords",
                "rtk,token,optimization,reduce,compress,ai,commands"
            ),
            description: L("settings.search.rtk.description", "Control when token-optimized command output is active")
        ),

        // Notifications
        SearchableSetting(
            id: "notificationStatus",
            section: .notifications,
            title: L("settings.search.notificationStatus.title", "Notification Status"),
            keywords: localizedKeywords(
                "settings.search.notificationStatus.keywords",
                "permission,alert,system,status"
            ),
            description: L("settings.search.notificationStatus.description", "Notification permission status")
        ),
        SearchableSetting(
            id: "notificationTriggers",
            section: .notifications,
            title: L("settings.search.notificationTriggers.title", "Notification Triggers"),
            keywords: localizedKeywords(
                "settings.search.notificationTriggers.keywords",
                "filter,event,type,toggle,task,complete,failed,trigger,enable,disable"
            ),
            description: L("settings.search.notificationTriggers.description", "Enable triggers and configure actions for notifications")
        ),
        SearchableSetting(
            id: "triggerActions",
            section: .notifications,
            title: L("settings.search.triggerActions.title", "Trigger Actions"),
            keywords: localizedKeywords(
                "settings.search.triggerActions.keywords",
                "action,webhook,slack,discord,script,sound,docker,notification,play,run"
            ),
            description: L("settings.search.triggerActions.description", "Configure what happens when notification triggers fire")
        ),
        SearchableSetting(
            id: "shellThresholds",
            section: .notifications,
            title: L("settings.search.shellThresholds.title", "Shell Event Thresholds"),
            keywords: localizedKeywords(
                "settings.search.shellThresholds.keywords",
                "long running,directory,git branch,threshold,seconds,shell"
            ),
            description: L("settings.search.shellThresholds.description", "Configure shell event detection thresholds")
        ),
        SearchableSetting(
            id: "appThresholds",
            section: .notifications,
            title: L("settings.search.appThresholds.title", "App Event Thresholds"),
            keywords: localizedKeywords(
                "settings.search.appThresholds.keywords",
                "inactivity,memory,tab open,tab close,threshold,minutes"
            ),
            description: L("settings.search.appThresholds.description", "Configure app event detection thresholds")
        ),
        SearchableSetting(
            id: "aiToolNotifications",
            section: .notifications,
            title: L("settings.search.aiToolNotifications.title", "AI Tool Notifications"),
            keywords: localizedKeywords(
                "settings.search.aiToolNotifications.keywords",
                "claude,codex,cursor,windsurf,copilot,aider,cline,continue,ai"
            ),
            description: L("settings.search.aiToolNotifications.description", "Notifications from AI coding tools")
        ),
        SearchableSetting(
            id: "eventMonitoring",
            section: .notifications,
            title: L("settings.search.eventMonitoring.title", "Event Monitoring"),
            keywords: localizedKeywords(
                "settings.search.eventMonitoring.keywords",
                "monitor,watch,ai,events,log,tailer,restart"
            ),
            description: L("settings.search.eventMonitoring.description", "Monitor AI CLI events for notifications")
        ),
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
    static let terminalDangerousCommandHighlightChanged = Notification.Name("terminalDangerousCommandHighlightChanged")
    static let settingsProfileChanged = Notification.Name("settingsProfileChanged")
    static let appThemeChanged = Notification.Name("appThemeChanged")
    static let fullscreenToolbarSettingChanged = Notification.Name("fullscreenToolbarSettingChanged")
    // API Analytics
    static let apiAnalyticsSettingsChanged = Notification.Name("apiAnalyticsSettingsChanged")
    static let apiCallRecorded = Notification.Name("apiCallRecorded")
    static let proxyStatusChanged = Notification.Name("proxyStatusChanged")
    // Token Optimization (RTK)
    static let tokenOptimizationModeChanged = Notification.Name("tokenOptimizationModeChanged")
    static let rtkFlagRecalculated = Notification.Name("rtkFlagRecalculated")
}
