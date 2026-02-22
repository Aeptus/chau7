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

// MARK: - Settings Section Groups

enum SettingsSectionGroup: String, CaseIterable, Identifiable {
    case essentials
    case lookAndFeel
    case terminal
    case inputProductivity
    case integrations
    case monitoring

    var id: String { rawValue }

    var title: String {
        switch self {
        case .essentials:        return L("settings.group.essentials", "ESSENTIALS")
        case .lookAndFeel:       return L("settings.group.lookAndFeel", "LOOK & FEEL")
        case .terminal:          return L("settings.group.terminal", "TERMINAL")
        case .inputProductivity: return L("settings.group.inputProductivity", "INPUT & PRODUCTIVITY")
        case .integrations:      return L("settings.group.integrations", "INTEGRATIONS")
        case .monitoring:        return L("settings.group.monitoring", "MONITORING")
        }
    }

    var sections: [SettingsSection] {
        switch self {
        case .essentials:        return [.general, .profilesBackup, .about]
        case .lookAndFeel:       return [.fontColors, .display, .tabs]
        case .terminal:          return [.shell, .scrollbackPerf, .dangerousCommands, .graphics, .tmux]
        case .inputProductivity: return [.keyboardMouse, .snippetsTools]
        case .integrations:      return [.aiDetection, .remoteControl, .apiProxy]
        case .monitoring:        return [.notifications, .logsHistory]
        }
    }
}

// MARK: - Settings Sections

enum SettingsSection: String, CaseIterable, Identifiable {
    // Essentials
    case general
    case profilesBackup
    case about
    // Look & Feel
    case fontColors
    case display
    case tabs
    // Terminal
    case shell
    case scrollbackPerf
    case dangerousCommands
    case graphics
    case tmux
    // Input & Productivity
    case keyboardMouse
    case snippetsTools
    // Integrations
    case aiDetection
    case remoteControl
    case apiProxy
    // Monitoring
    case notifications
    case logsHistory

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general:           return L("settings.general", "General")
        case .profilesBackup:    return L("settings.profilesBackup", "Profiles & Backup")
        case .about:             return L("settings.about", "About")
        case .fontColors:        return L("settings.fontColors", "Font & Colors")
        case .display:           return L("settings.display", "Display")
        case .tabs:              return L("settings.tabs", "Tabs")
        case .shell:             return L("settings.shell", "Shell")
        case .scrollbackPerf:    return L("settings.scrollbackPerf", "Scrollback & Performance")
        case .dangerousCommands: return L("settings.dangerousCommands", "Dangerous Commands")
        case .graphics:          return L("settings.graphics", "Graphics")
        case .tmux:              return L("settings.tmux", "Tmux")
        case .keyboardMouse:     return L("settings.keyboardMouse", "Keyboard & Mouse")
        case .snippetsTools:     return L("settings.snippetsTools", "Snippets & Tools")
        case .aiDetection:       return L("settings.aiDetection", "AI Detection")
        case .remoteControl:     return L("settings.remoteControl", "Remote Control")
        case .apiProxy:          return L("settings.apiProxy", "API Proxy")
        case .notifications:     return L("settings.notifications", "Notifications")
        case .logsHistory:       return L("settings.logsHistory", "Logs & History")
        }
    }

    var systemImage: String {
        switch self {
        case .general:           return "gearshape"
        case .profilesBackup:    return "person.2.fill"
        case .about:             return "info.circle"
        case .fontColors:        return "paintbrush"
        case .display:           return "eye"
        case .tabs:              return "rectangle.stack"
        case .shell:             return "terminal"
        case .scrollbackPerf:    return "gauge.with.dots.needle.33percent"
        case .dangerousCommands: return "exclamationmark.triangle"
        case .graphics:          return "photo"
        case .tmux:              return "rectangle.split.2x1"
        case .keyboardMouse:     return "keyboard"
        case .snippetsTools:     return "bolt.fill"
        case .aiDetection:       return "sparkles"
        case .remoteControl:     return "antenna.radiowaves.left.and.right"
        case .apiProxy:          return "network"
        case .notifications:     return "bell.badge"
        case .logsHistory:       return "doc.text.magnifyingglass"
        }
    }

    var description: String {
        switch self {
        case .general:           return L("settings.general.description", "Startup, language, and config file")
        case .profilesBackup:    return L("settings.profilesBackup.description", "Profiles, auto-switch, iCloud sync, and backup")
        case .about:             return L("settings.about.description", "Version information and links")
        case .fontColors:        return L("settings.fontColors.description", "Font, color scheme, opacity, and theme")
        case .display:           return L("settings.display.description", "Syntax highlighting, URLs, images, and layout")
        case .tabs:              return L("settings.tabs.description", "Tab behavior and appearance")
        case .shell:             return L("settings.shell.description", "Shell, cursor, and bell")
        case .scrollbackPerf:    return L("settings.scrollbackPerf.description", "Scrollback buffer, rendering, and backend")
        case .dangerousCommands: return L("settings.dangerousCommands.description", "Highlight and guard risky commands")
        case .graphics:          return L("settings.graphics.description", "Sixel and Kitty graphics protocols")
        case .tmux:              return L("settings.tmux.description", "Tmux integration and sessions")
        case .keyboardMouse:     return L("settings.keyboardMouse.description", "Keyboard shortcuts and mouse behavior")
        case .snippetsTools:     return L("settings.snippetsTools.description", "Snippets, clipboard, bookmarks, and search")
        case .aiDetection:       return L("settings.aiDetection.description", "AI CLI detection, theming, and LLM provider")
        case .remoteControl:     return L("settings.remoteControl.description", "Remote access, pairing, and SSH profiles")
        case .apiProxy:          return L("settings.apiProxy.description", "API call tracking and analytics proxy")
        case .notifications:     return L("settings.notifications.description", "Alert preferences and event filters")
        case .logsHistory:       return L("settings.logsHistory.description", "Log files, session tracking, and command history")
        }
    }

    var group: SettingsSectionGroup {
        switch self {
        case .general, .profilesBackup, .about:
            return .essentials
        case .fontColors, .display, .tabs:
            return .lookAndFeel
        case .shell, .scrollbackPerf, .dangerousCommands, .graphics, .tmux:
            return .terminal
        case .keyboardMouse, .snippetsTools:
            return .inputProductivity
        case .aiDetection, .remoteControl, .apiProxy:
            return .integrations
        case .notifications, .logsHistory:
            return .monitoring
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
            id: "configFile",
            section: .general,
            title: L("settings.search.configFile.title", "Config File"),
            keywords: localizedKeywords(
                "settings.search.configFile.keywords",
                "toml,config,file,repo,global"
            ),
            description: L("settings.search.configFile.description", "Load settings from TOML config files")
        ),

        // Profiles & Backup
        SearchableSetting(
            id: "profiles",
            section: .profilesBackup,
            title: L("settings.search.profiles.title", "Settings Profiles"),
            keywords: localizedKeywords(
                "settings.search.profiles.keywords",
                "profile,work,personal,switch,preset"
            ),
            description: L("settings.search.profiles.description", "Create and switch between named setting profiles")
        ),
        SearchableSetting(
            id: "profileAutoSwitch",
            section: .profilesBackup,
            title: L("settings.search.profileAutoSwitch.title", "Profile Auto-Switch"),
            keywords: localizedKeywords(
                "settings.search.profileAutoSwitch.keywords",
                "auto,switch,rule,directory,git,ssh"
            ),
            description: L("settings.search.profileAutoSwitch.description", "Automatically switch profiles based on rules")
        ),
        SearchableSetting(
            id: "icloud",
            section: .profilesBackup,
            title: L("settings.search.icloud.title", "iCloud Sync"),
            keywords: localizedKeywords(
                "settings.search.icloud.keywords",
                "cloud,sync,backup,restore"
            ),
            description: L("settings.search.icloud.description", "Sync settings across Macs via iCloud")
        ),
        SearchableSetting(
            id: "export",
            section: .profilesBackup,
            title: L("settings.search.export.title", "Export/Import Settings"),
            keywords: localizedKeywords(
                "settings.search.export.keywords",
                "backup,restore,json,save,load"
            ),
            description: L("settings.search.export.description", "Export or import settings as JSON")
        ),

        // Font & Colors
        SearchableSetting(
            id: "fontFamily",
            section: .fontColors,
            title: L("settings.search.fontFamily.title", "Font Family"),
            keywords: localizedKeywords(
                "settings.search.fontFamily.keywords",
                "typeface,menlo,monaco,monospace,text"
            ),
            description: L("settings.search.fontFamily.description", "Choose the terminal font")
        ),
        SearchableSetting(
            id: "fontSize",
            section: .fontColors,
            title: L("settings.search.fontSize.title", "Font Size"),
            keywords: localizedKeywords(
                "settings.search.fontSize.keywords",
                "text,size,big,small,zoom"
            ),
            description: L("settings.search.fontSize.description", "Terminal font size in points")
        ),
        SearchableSetting(
            id: "defaultZoom",
            section: .fontColors,
            title: L("settings.search.defaultZoom.title", "Default Zoom"),
            keywords: localizedKeywords(
                "settings.search.defaultZoom.keywords",
                "scale,zoom,percent,size"
            ),
            description: L("settings.search.defaultZoom.description", "Default zoom percentage for new tabs")
        ),
        SearchableSetting(
            id: "colorScheme",
            section: .fontColors,
            title: L("settings.search.colorScheme.title", "Color Scheme"),
            keywords: localizedKeywords(
                "settings.search.colorScheme.keywords",
                "theme,colors,dracula,solarized,nord,dark,light"
            ),
            description: L("settings.search.colorScheme.description", "Terminal color palette")
        ),
        SearchableSetting(
            id: "opacity",
            section: .fontColors,
            title: L("settings.search.opacity.title", "Window Opacity"),
            keywords: localizedKeywords(
                "settings.search.opacity.keywords",
                "transparency,translucent,see-through,alpha"
            ),
            description: L("settings.search.opacity.description", "Terminal window transparency")
        ),

        // Display
        SearchableSetting(
            id: "syntaxHighlight",
            section: .display,
            title: L("settings.search.syntaxHighlight.title", "Syntax Highlighting"),
            keywords: localizedKeywords(
                "settings.search.syntaxHighlight.keywords",
                "code,colors,highlight"
            ),
            description: L("settings.search.syntaxHighlight.description", "Highlight code syntax in output")
        ),
        SearchableSetting(
            id: "timestamps",
            section: .display,
            title: L("settings.search.timestamps.title", "Line Timestamps"),
            keywords: localizedKeywords(
                "settings.search.timestamps.keywords",
                "time,date,clock"
            ),
            description: L("settings.search.timestamps.description", "Show timestamps for terminal lines")
        ),
        SearchableSetting(
            id: "splitPanes",
            section: .display,
            title: L("settings.search.splitPanes.title", "Split Panes"),
            keywords: localizedKeywords(
                "settings.search.splitPanes.keywords",
                "split,divide,pane,horizontal,vertical"
            ),
            description: L("settings.search.splitPanes.description", "Split terminal into panes")
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

        // Shell
        SearchableSetting(
            id: "shell",
            section: .shell,
            title: L("settings.search.shell.title", "Shell"),
            keywords: localizedKeywords(
                "settings.search.shell.keywords",
                "zsh,bash,fish,terminal,command"
            ),
            description: L("settings.search.shell.description", "Choose which shell to use")
        ),
        SearchableSetting(
            id: "startupCommand",
            section: .shell,
            title: L("settings.search.startupCommand.title", "Startup Command"),
            keywords: localizedKeywords(
                "settings.search.startupCommand.keywords",
                "init,run,execute,neofetch"
            ),
            description: L("settings.search.startupCommand.description", "Command to run when terminal starts")
        ),
        SearchableSetting(
            id: "lsColors",
            section: .shell,
            title: L("settings.search.lsColors.title", "ls Colors"),
            keywords: localizedKeywords(
                "settings.search.lsColors.keywords",
                "ls,colors,colorize,LSCOLORS,CLICOLOR"
            ),
            description: L("settings.search.lsColors.description", "Enable colored ls output in new sessions")
        ),
        SearchableSetting(
            id: "cursor",
            section: .shell,
            title: L("settings.search.cursor.title", "Cursor Style"),
            keywords: localizedKeywords(
                "settings.search.cursor.keywords",
                "block,underline,bar,caret"
            ),
            description: L("settings.search.cursor.description", "Terminal cursor appearance")
        ),
        SearchableSetting(
            id: "cursorBlink",
            section: .shell,
            title: L("settings.search.cursorBlink.title", "Cursor Blink"),
            keywords: localizedKeywords(
                "settings.search.cursorBlink.keywords",
                "animate,flash,blink"
            ),
            description: L("settings.search.cursorBlink.description", "Animate cursor with blinking")
        ),
        SearchableSetting(
            id: "bell",
            section: .shell,
            title: L("settings.search.bell.title", "Bell"),
            keywords: localizedKeywords(
                "settings.search.bell.keywords",
                "sound,beep,alert,audio"
            ),
            description: L("settings.search.bell.description", "Terminal bell sound")
        ),

        // Scrollback & Performance
        SearchableSetting(
            id: "scrollback",
            section: .scrollbackPerf,
            title: L("settings.search.scrollback.title", "Scrollback Lines"),
            keywords: localizedKeywords(
                "settings.search.scrollback.keywords",
                "history,buffer,lines,scroll"
            ),
            description: L("settings.search.scrollback.description", "Lines to keep in scrollback")
        ),
        SearchableSetting(
            id: "localEcho",
            section: .scrollbackPerf,
            title: L("settings.search.localEcho.title", "Local Echo"),
            keywords: localizedKeywords(
                "settings.search.localEcho.keywords",
                "echo,typing,latency,input"
            ),
            description: L("settings.search.localEcho.description", "Render typed characters immediately")
        ),
        SearchableSetting(
            id: "terminalBackend",
            section: .scrollbackPerf,
            title: L("settings.search.terminalBackend.title", "Terminal Backend"),
            keywords: localizedKeywords(
                "settings.search.terminalBackend.keywords",
                "rust,metal,gpu,renderer"
            ),
            description: L("settings.search.terminalBackend.description", "Choose terminal rendering backend")
        ),

        // Dangerous Commands
        SearchableSetting(
            id: "dangerousCommands",
            section: .dangerousCommands,
            title: L("settings.search.dangerousCommands.title", "Dangerous Commands"),
            keywords: localizedKeywords(
                "settings.search.dangerousCommands.keywords",
                "dangerous,risky,destructive,rm,force,highlight,safety"
            ),
            description: L("settings.search.dangerousCommands.description", "Highlight risky commands in the terminal")
        ),

        // Graphics
        SearchableSetting(
            id: "sixel",
            section: .graphics,
            title: L("settings.search.sixel.title", "Sixel Graphics"),
            keywords: localizedKeywords(
                "settings.search.sixel.keywords",
                "sixel,image,graphics,protocol"
            ),
            description: L("settings.search.sixel.description", "Sixel graphics protocol support")
        ),
        SearchableSetting(
            id: "kittyGraphics",
            section: .graphics,
            title: L("settings.search.kittyGraphics.title", "Kitty Graphics"),
            keywords: localizedKeywords(
                "settings.search.kittyGraphics.keywords",
                "kitty,image,graphics,protocol"
            ),
            description: L("settings.search.kittyGraphics.description", "Kitty graphics protocol support")
        ),

        // Tmux
        SearchableSetting(
            id: "tmuxIntegration",
            section: .tmux,
            title: L("settings.search.tmuxIntegration.title", "Tmux Integration"),
            keywords: localizedKeywords(
                "settings.search.tmuxIntegration.keywords",
                "tmux,multiplexer,session,attach"
            ),
            description: L("settings.search.tmuxIntegration.description", "Tmux session management and integration")
        ),

        // Keyboard & Mouse
        SearchableSetting(
            id: "shortcuts",
            section: .keyboardMouse,
            title: L("settings.search.shortcuts.title", "Keyboard Shortcuts"),
            keywords: localizedKeywords(
                "settings.search.shortcuts.keywords",
                "hotkey,keybinding,key,command"
            ),
            description: L("settings.search.shortcuts.description", "Customize keyboard shortcuts")
        ),
        SearchableSetting(
            id: "shortcutHelperHint",
            section: .keyboardMouse,
            title: L("settings.search.shortcutHelperHint.title", "Shortcut Helper Hint"),
            keywords: localizedKeywords(
                "settings.search.shortcutHelperHint.keywords",
                "hint,overlay,helper,shortcuts,corner"
            ),
            description: L("settings.search.shortcutHelperHint.description", "Show the shortcut helper hint in the terminal")
        ),
        SearchableSetting(
            id: "copyOnSelect",
            section: .keyboardMouse,
            title: L("settings.search.copyOnSelect.title", "Copy on Select"),
            keywords: localizedKeywords(
                "settings.search.copyOnSelect.keywords",
                "clipboard,copy,selection"
            ),
            description: L("settings.search.copyOnSelect.description", "Copy text when selected")
        ),
        SearchableSetting(
            id: "cmdClick",
            section: .keyboardMouse,
            title: L("settings.search.cmdClick.title", "Cmd+Click Paths"),
            keywords: localizedKeywords(
                "settings.search.cmdClick.keywords",
                "click,open,file,editor"
            ),
            description: L("settings.search.cmdClick.description", "Open file paths with Cmd+click")
        ),
        SearchableSetting(
            id: "urlHandler",
            section: .keyboardMouse,
            title: L("settings.search.urlHandler.title", "URL Handler"),
            keywords: localizedKeywords(
                "settings.search.urlHandler.keywords",
                "browser,url,links,open"
            ),
            description: L("settings.search.urlHandler.description", "Choose which browser opens URLs")
        ),
        SearchableSetting(
            id: "broadcast",
            section: .keyboardMouse,
            title: L("settings.search.broadcast.title", "Broadcast Input"),
            keywords: localizedKeywords(
                "settings.search.broadcast.keywords",
                "multi,tabs,send,input"
            ),
            description: L("settings.search.broadcast.description", "Send input to all tabs")
        ),

        // Snippets & Tools
        SearchableSetting(
            id: "snippets",
            section: .snippetsTools,
            title: L("settings.search.snippets.title", "Snippets"),
            keywords: localizedKeywords(
                "settings.search.snippets.keywords",
                "template,shortcut,text,expansion"
            ),
            description: L("settings.search.snippets.description", "Reusable text snippets")
        ),
        SearchableSetting(
            id: "clipboard",
            section: .snippetsTools,
            title: L("settings.search.clipboard.title", "Clipboard History"),
            keywords: localizedKeywords(
                "settings.search.clipboard.keywords",
                "copy,paste,history"
            ),
            description: L("settings.search.clipboard.description", "Access previous clipboard items")
        ),
        SearchableSetting(
            id: "bookmarks",
            section: .snippetsTools,
            title: L("settings.search.bookmarks.title", "Bookmarks"),
            keywords: localizedKeywords(
                "settings.search.bookmarks.keywords",
                "save,position,mark"
            ),
            description: L("settings.search.bookmarks.description", "Save terminal positions")
        ),
        SearchableSetting(
            id: "search",
            section: .snippetsTools,
            title: L("settings.search.search.title", "Semantic Search"),
            keywords: localizedKeywords(
                "settings.search.search.keywords",
                "find,search,command"
            ),
            description: L("settings.search.search.description", "Command-aware search")
        ),
        SearchableSetting(
            id: "findDefaults",
            section: .snippetsTools,
            title: L("settings.search.findDefaults.title", "Find Defaults"),
            keywords: localizedKeywords(
                "settings.search.findDefaults.keywords",
                "find,case,regex,default"
            ),
            description: L("settings.search.findDefaults.description", "Default settings for the find bar")
        ),

        // AI Detection
        SearchableSetting(
            id: "aiDetection",
            section: .aiDetection,
            title: L("settings.search.aiDetection.title", "AI CLI Detection"),
            keywords: localizedKeywords(
                "settings.search.aiDetection.keywords",
                "claude,codex,gemini,copilot,detect"
            ),
            description: L("settings.search.aiDetection.description", "Detect AI CLIs automatically")
        ),
        SearchableSetting(
            id: "aiCustomDetection",
            section: .aiDetection,
            title: L("settings.search.aiCustomDetection.title", "Custom AI Detection"),
            keywords: localizedKeywords(
                "settings.search.aiCustomDetection.keywords",
                "custom,pattern,rules,detect"
            ),
            description: L("settings.search.aiCustomDetection.description", "Add custom AI CLI detection rules")
        ),
        SearchableSetting(
            id: "autoTabTheme",
            section: .aiDetection,
            title: L("settings.search.autoTabTheme.title", "Auto Tab Themes"),
            keywords: localizedKeywords(
                "settings.search.autoTabTheme.keywords",
                "color,tab,ai,theme"
            ),
            description: L("settings.search.autoTabTheme.description", "Color tabs by AI model")
        ),
        SearchableSetting(
            id: "rtkIntegration",
            section: .aiDetection,
            title: L("settings.search.aiRtk.title", "RTK Integration"),
            keywords: localizedKeywords(
                "settings.search.aiRtk.keywords",
                "rtk,prefix,tab,override,integration"
            ),
            description: L("settings.search.aiRtk.description", "Prepend RTK commands to terminal input")
        ),
        SearchableSetting(
            id: "llmProvider",
            section: .aiDetection,
            title: L("settings.search.llmProvider.title", "LLM Provider"),
            keywords: localizedKeywords(
                "settings.search.llmProvider.keywords",
                "openai,anthropic,api,key,llm,byoai"
            ),
            description: L("settings.search.llmProvider.description", "Configure LLM provider and API keys")
        ),

        // Remote Control
        SearchableSetting(
            id: "remote",
            section: .remoteControl,
            title: L("settings.search.remote.title", "Remote Control"),
            keywords: localizedKeywords(
                "settings.search.remote.keywords",
                "remote,ios,relay,pairing,qr"
            ),
            description: L("settings.search.remote.description", "Pair an iPhone and view terminal output remotely")
        ),
        SearchableSetting(
            id: "sshProfiles",
            section: .remoteControl,
            title: L("settings.search.sshProfiles.title", "SSH Profiles"),
            keywords: localizedKeywords(
                "settings.search.sshProfiles.keywords",
                "ssh,config,host,profile,connection"
            ),
            description: L("settings.search.sshProfiles.description", "Manage SSH config entries and connections")
        ),

        // API Proxy
        SearchableSetting(
            id: "apiAnalytics",
            section: .apiProxy,
            title: L("settings.search.apiAnalytics.title", "API Analytics"),
            keywords: localizedKeywords(
                "settings.search.apiAnalytics.keywords",
                "api,proxy,analytics,cost,token,tracking"
            ),
            description: L("settings.search.apiAnalytics.description", "Track API calls and token usage")
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

        // Logs & History
        SearchableSetting(
            id: "persistentHistory",
            section: .logsHistory,
            title: L("settings.search.persistentHistory.title", "Persistent History"),
            keywords: localizedKeywords(
                "settings.search.persistentHistory.keywords",
                "history,database,commands,persistent,storage"
            ),
            description: L("settings.search.persistentHistory.description", "Save command history across sessions")
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
}
