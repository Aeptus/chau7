import Foundation

// MARK: - Searchable Settings Metadata

struct SearchableSetting: Identifiable {
    let id: String
    let section: SettingsSection
    let title: String
    let keywords: [String]
    let description: String
    let anchorID: String

    init(
        id: String,
        section: SettingsSection,
        title: String,
        keywords: [String],
        description: String,
        anchorID: String? = nil
    ) {
        self.id = id
        self.section = section
        self.title = title
        self.keywords = keywords
        self.description = description
        self.anchorID = anchorID ?? id
    }

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

private func normalizedSearchTitle(_ title: String) -> String {
    title
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
}

// MARK: - Settings Section Groups

enum SettingsSectionGroup: String, CaseIterable, Identifiable {
    case general
    case appearance
    case terminal
    case aiWorkflows
    case automation
    case safetyPrivacy

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .general: return L("settings.group.general", "GENERAL")
        case .appearance: return L("settings.group.appearance", "APPEARANCE")
        case .terminal: return L("settings.group.terminal", "TERMINAL")
        case .aiWorkflows: return L("settings.group.aiWorkflows", "AI WORKFLOWS")
        case .automation: return L("settings.group.automation", "AUTOMATION")
        case .safetyPrivacy: return L("settings.group.safetyPrivacy", "SAFETY & PRIVACY")
        }
    }

    var sections: [SettingsSection] {
        switch self {
        case .general: return [.startHere, .general, .profilesBackup, .about]
        case .appearance: return [.windows, .tabs, .hoverCard, .fontColors, .display, .minimalMode]
        case .terminal: return [.shell, .scrollbackPerf, .graphics, .keyboardMouse]
        case .aiWorkflows: return [.aiDetection, .mcpControl, .promptInjection, .tokenOptimization]
        case .automation: return [.snippetsTools, .editor, .repositories, .apiProxy, .remoteControl, .sshProfiles]
        case .safetyPrivacy: return [.dangerousCommands, .notifications, .history, .logsHistory]
        }
    }
}

// MARK: - Settings Sections

enum SettingsSection: String, CaseIterable, Identifiable {
    case startHere
    // Essentials
    case general
    case profilesBackup
    case about
    // Appearance
    case fontColors
    case display
    case windows
    case tabs
    case hoverCard
    case repositories
    // Terminal
    case shell
    case scrollbackPerf
    case dangerousCommands
    case graphics
    // Input & Productivity
    case keyboardMouse
    case snippetsTools
    case editor
    /// Appearance (additional)
    case minimalMode
    // Integrations
    case aiDetection
    case tokenOptimization
    case mcpControl
    case remoteControl
    case sshProfiles
    case apiProxy
    case promptInjection
    // Monitoring
    case notifications
    case history
    case logsHistory

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .startHere: return L("settings.startHere", "Start Here")
        case .general: return L("settings.general", "General")
        case .profilesBackup: return L("settings.profilesBackup", "Sync & Backup")
        case .about: return L("settings.about", "About")
        case .fontColors: return L("settings.fontColors", "Font & Colors")
        case .display: return L("settings.display", "Display")
        case .windows: return L("settings.windows", "Windows")
        case .tabs: return L("settings.tabs", "Tabs")
        case .hoverCard: return L("settings.hoverCard", "Hover Card")
        case .repositories: return L("settings.repositories", "Repositories")
        case .shell: return L("settings.shell", "Shell")
        case .scrollbackPerf: return L("settings.scrollbackPerf", "Performance")
        case .dangerousCommands: return L("settings.dangerousCommands", "Command Safety")
        case .graphics: return L("settings.graphics", "Graphics")
        case .keyboardMouse: return L("settings.keyboardMouse", "Keyboard & Mouse")
        case .snippetsTools: return L("settings.snippetsTools", "Snippets & Tools")
        case .editor: return L("settings.editor", "Text Editor")
        case .minimalMode: return L("settings.minimalMode", "Minimal Mode")
        case .aiDetection: return L("settings.aiDetection", "AI Detection")
        case .tokenOptimization: return L("settings.tokenOptimization", "Context Optimization")
        case .mcpControl: return L("settings.mcpControl", "Agent Control")
        case .remoteControl: return L("settings.remoteControl", "Remote Access")
        case .sshProfiles: return L("settings.sshProfiles", "SSH Profiles")
        case .apiProxy: return L("settings.apiProxy", "API Tracking")
        case .promptInjection: return L("settings.promptInjection", "AI Context")
        case .notifications: return L("settings.notifications", "Alerts")
        case .history: return L("settings.history", "History")
        case .logsHistory: return L("settings.logsHistory", "Diagnostics")
        }
    }

    var systemImage: String {
        switch self {
        case .startHere: return "checklist"
        case .general: return "gearshape"
        case .profilesBackup: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        case .fontColors: return "paintbrush"
        case .display: return "eye"
        case .windows: return "macwindow"
        case .tabs: return "rectangle.stack"
        case .hoverCard: return "text.bubble"
        case .repositories: return "folder.badge.gearshape"
        case .shell: return "terminal"
        case .scrollbackPerf: return "gauge.with.dots.needle.33percent"
        case .dangerousCommands: return "exclamationmark.triangle"
        case .graphics: return "photo"
        case .keyboardMouse: return "keyboard"
        case .snippetsTools: return "bolt.fill"
        case .editor: return "doc.text"
        case .minimalMode: return "rectangle.compress.vertical"
        case .aiDetection: return "sparkles"
        case .tokenOptimization: return "bolt.horizontal.circle"
        case .mcpControl: return "face.dashed"
        case .remoteControl: return "antenna.radiowaves.left.and.right"
        case .sshProfiles: return "network"
        case .apiProxy: return "network"
        case .promptInjection: return "text.insert"
        case .notifications: return "bell.badge"
        case .history: return "clock.arrow.circlepath"
        case .logsHistory: return "doc.text.magnifyingglass"
        }
    }

    var description: String {
        switch self {
        case .startHere: return L("settings.startHere.description", "Current setup, permissions, and service status")
        case .general: return L("settings.general.description", "Startup, language, default directory, and advanced config files")
        case .profilesBackup: return L("settings.profilesBackup.description", "Profile auto-switch, iCloud sync, and settings backup")
        case .about: return L("settings.about.summaryDescription", "Version, support links, diagnostics, and acknowledgments")
        case .fontColors: return L("settings.fontColors.description", "Terminal font, color scheme, zoom, and ligatures")
        case .display: return L("settings.display.description", "Syntax highlighting, URLs, images, and output formatting")
        case .windows: return L("settings.windows.description", "App theme, opacity, window behavior, and layout")
        case .tabs: return L("settings.tabs.description", "Tab behavior and appearance")
        case .hoverCard: return L("settings.hoverCard.description", "Choose which sections appear in the tab hover card")
        case .repositories: return L("settings.repositories.description", "Manage repo descriptions, labels, and favorite files")
        case .shell: return L("settings.shell.description", "Shell, cursor, and bell")
        case .scrollbackPerf: return L("settings.scrollbackPerf.description", "Rendering, scrollback, and performance limits")
        case .dangerousCommands: return L("settings.dangerousCommands.description", "Highlight and guard risky commands")
        case .graphics: return L("settings.graphics.description", "Sixel and Kitty graphics protocols")
        case .keyboardMouse: return L("settings.keyboardMouse.description", "Keyboard shortcuts and mouse behavior")
        case .snippetsTools: return L("settings.snippetsTools.description", "Snippets, clipboard, bookmarks, and search")
        case .editor: return L("settings.editor.description", "Built-in text editor font, indentation, and display")
        case .minimalMode: return L("settings.minimalMode.description", "Hide tab bar, title bar, and status elements")
        case .aiDetection: return L("settings.aiDetection.description", "AI CLI detection, theming, and LLM provider")
        case .tokenOptimization: return L("settings.tokenOptimization.description", "Context optimization mode, per-tab control, and prefix")
        case .mcpControl: return L("settings.mcpControl.description", "Agent tab creation, limits, and approval")
        case .remoteControl: return L("settings.remoteControl.description", "Remote app access, relay, pairing, and devices")
        case .sshProfiles: return L("settings.sshProfiles.description", "Import, sync, and export SSH connection profiles")
        case .apiProxy: return L("settings.apiProxy.description", "API call tracking and analytics")
        case .promptInjection: return L("settings.promptInjection.description", "Add repository context to AI requests")
        case .notifications: return L("settings.notifications.description", "Alert preferences and event filters")
        case .history: return L("settings.history.description", "Command history and transcript retention")
        case .logsHistory: return L("settings.logsHistory.description", "Log monitors, diagnostic paths, and active sessions")
        }
    }

    var group: SettingsSectionGroup {
        switch self {
        case .startHere, .general, .profilesBackup, .about:
            return .general
        case .fontColors, .display, .windows, .tabs, .minimalMode, .hoverCard:
            return .appearance
        case .shell, .scrollbackPerf, .graphics, .keyboardMouse:
            return .terminal
        case .aiDetection, .mcpControl, .promptInjection, .tokenOptimization:
            return .aiWorkflows
        case .snippetsTools, .editor, .repositories, .apiProxy, .remoteControl, .sshProfiles:
            return .automation
        case .dangerousCommands, .notifications, .history, .logsHistory:
            return .safetyPrivacy
        }
    }
}

// MARK: - FeatureSettings Search Extension

extension FeatureSettings {
    static let searchableSettings: [SearchableSetting] = [
        // Start Here
        SearchableSetting(
            id: "startHereStatus",
            section: .startHere,
            title: L("settings.search.startHere.title", "Start Here Status"),
            keywords: localizedKeywords(
                "settings.search.startHere.keywords",
                "status,start here,overview,setup,health,permissions,profile,mcp,remote,logs"
            ),
            description: L("settings.search.startHere.description", "Review launch, profile, permissions, Agent Control, remote access, alerts, and log paths")
        ),

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

        // Sync & Backup
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
        SearchableSetting(
            id: "resetSettings",
            section: .profilesBackup,
            title: L("settings.general.reset.all", "Reset All Settings to Defaults"),
            keywords: localizedKeywords(
                "settings.search.resetSettings.keywords",
                "reset,defaults,recovery,restore,clear,settings"
            ),
            description: L("settings.search.resetSettings.description", "Reset Chau7 settings after exporting a backup if needed")
        ),
        SearchableSetting(
            id: "about",
            section: .about,
            title: L("settings.search.about.title", "About Chau7"),
            keywords: localizedKeywords(
                "settings.search.about.keywords",
                "about,version,license,logs,system,credits"
            ),
            description: L("settings.search.about.description", "View app version, system information, links, and application logs")
        ),
        SearchableSetting(
            id: "aboutSupportInfo",
            section: .about,
            title: L("settings.about.copySupportInfo", "Copy Support Info"),
            keywords: localizedKeywords(
                "settings.search.aboutSupportInfo.keywords",
                "support,copy,issue,bug,report,github,help"
            ),
            description: L("settings.search.aboutSupportInfo.description", "Copy build, system, and log details for support")
        ),
        SearchableSetting(
            id: "aboutDiagnostics",
            section: .about,
            title: L("settings.about.diagnostics", "Diagnostics"),
            keywords: localizedKeywords(
                "settings.search.aboutDiagnostics.keywords",
                "diagnostics,version,build,bundle,macos,architecture,log,debug"
            ),
            description: L("settings.search.aboutDiagnostics.description", "Review build, system, and log details")
        ),
        SearchableSetting(
            id: "aboutAcknowledgments",
            section: .about,
            title: L("settings.about.acknowledgments", "Acknowledgments"),
            keywords: localizedKeywords(
                "settings.search.aboutAcknowledgments.keywords",
                "license,licenses,acknowledgments,credits,agpl,open source"
            ),
            description: L("settings.search.aboutAcknowledgments.description", "Open licenses, credits, and acknowledgments")
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
            section: .windows,
            title: L("settings.search.opacity.title", "Window Opacity"),
            keywords: localizedKeywords(
                "settings.search.opacity.keywords",
                "transparency,translucent,see-through,alpha"
            ),
            description: L("settings.search.opacity.description", "Terminal window transparency")
        ),
        SearchableSetting(
            id: "appTheme",
            section: .windows,
            title: L("settings.search.appTheme.title", "App Theme"),
            keywords: localizedKeywords(
                "settings.search.appTheme.keywords",
                "theme,system,light,dark,appearance"
            ),
            description: L("settings.search.appTheme.description", "Choose the Chau7 interface theme")
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
            id: "clickableURLs",
            section: .display,
            title: L("settings.search.clickableURLs.title", "Clickable URLs"),
            keywords: localizedKeywords(
                "settings.search.clickableURLs.keywords",
                "url,link,browser,open,click"
            ),
            description: L("settings.search.clickableURLs.description", "Make terminal URLs clickable")
        ),
        SearchableSetting(
            id: "inlineImages",
            section: .display,
            title: L("settings.search.inlineImages.title", "Inline Images"),
            keywords: localizedKeywords(
                "settings.search.inlineImages.keywords",
                "image,imgcat,preview,inline"
            ),
            description: L("settings.search.inlineImages.description", "Display inline terminal images")
        ),
        SearchableSetting(
            id: "prettyPrintJSON",
            section: .display,
            title: L("settings.search.prettyPrintJSON.title", "Pretty Print JSON"),
            keywords: localizedKeywords(
                "settings.search.prettyPrintJSON.keywords",
                "json,format,pretty,indent"
            ),
            description: L("settings.search.prettyPrintJSON.description", "Format JSON output for readability")
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

        // Windows
        SearchableSetting(
            id: "menuBarOnlyMode",
            section: .windows,
            title: L("settings.search.menuBarOnlyMode.title", "Menu Bar Only Mode"),
            keywords: localizedKeywords(
                "settings.search.menuBarOnlyMode.keywords",
                "menu bar,dock,accessory,hide app,launcher"
            ),
            description: L("settings.search.menuBarOnlyMode.description", "Run Chau7 from the menu bar without a Dock icon")
        ),
        SearchableSetting(
            id: "windowBlur",
            section: .windows,
            title: L("settings.search.windowBlur.title", "Window Blur"),
            keywords: localizedKeywords(
                "settings.search.windowBlur.keywords",
                "blur,transparency,performance,memory,graphics,background"
            ),
            description: L("settings.search.windowBlur.description", "Blur the desktop behind terminal windows")
        ),
        SearchableSetting(
            id: "windowFloating",
            section: .windows,
            title: L("settings.search.windowFloating.title", "Floating Window"),
            keywords: localizedKeywords(
                "settings.search.windowFloating.keywords",
                "float,always on top,above,window"
            ),
            description: L("settings.search.windowFloating.description", "Keep terminal windows above other apps")
        ),
        SearchableSetting(
            id: "overlayWindow",
            section: .windows,
            title: L("settings.search.overlayWindow.title", "Overlay Window"),
            keywords: localizedKeywords(
                "settings.search.overlayWindow.keywords",
                "overlay,show,position,workspace,reset"
            ),
            description: L("settings.search.overlayWindow.description", "Show or reset the remembered overlay window position")
        ),
        SearchableSetting(
            id: "fullscreenToolbar",
            section: .windows,
            title: L("settings.search.fullscreenToolbar.title", "Fullscreen Toolbar"),
            keywords: localizedKeywords(
                "settings.search.fullscreenToolbar.keywords",
                "fullscreen,toolbar,titlebar,window"
            ),
            description: L("settings.search.fullscreenToolbar.description", "Keep the toolbar visible in fullscreen")
        ),
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

        // Tabs
        SearchableSetting(
            id: "newTabPosition",
            section: .tabs,
            title: L("settings.search.newTabPosition.title", "New Tab Position"),
            keywords: localizedKeywords(
                "settings.search.newTabPosition.keywords",
                "new,tab,position,after,current,end"
            ),
            description: L("settings.search.newTabPosition.description", "Choose where new tabs are inserted")
        ),
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
            id: "tabCloseWarnings",
            section: .tabs,
            title: L("settings.search.tabCloseWarnings.title", "Tab Close Warnings"),
            keywords: localizedKeywords(
                "settings.search.tabCloseWarnings.keywords",
                "warn,warning,close,running process,confirm"
            ),
            description: L("settings.search.tabCloseWarnings.description", "Confirm before closing tabs or running processes")
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
        SearchableSetting(
            id: "tabDisplay",
            section: .tabs,
            title: L("settings.search.tabDisplay.title", "Tab Display"),
            keywords: localizedKeywords(
                "settings.search.tabDisplay.keywords",
                "tab,icons,path,git,cto,broadcast,custom title,indicator"
            ),
            description: L("settings.search.tabDisplay.description", "Choose which tab indicators are visible")
        ),
        SearchableSetting(
            id: "repoGrouping",
            section: .tabs,
            title: L("settings.search.repoGrouping.title", "Repo Grouping"),
            keywords: localizedKeywords(
                "settings.search.repoGrouping.keywords",
                "repo,repository,group,git,tabs"
            ),
            description: L("settings.search.repoGrouping.description", "Group tabs by repository")
        ),
        SearchableSetting(
            id: "tabSwitchShortcut",
            section: .tabs,
            title: L("settings.search.tabSwitchShortcut.title", "Switch-to-Tab Keys"),
            keywords: localizedKeywords(
                "settings.search.tabSwitchShortcut.keywords",
                "switch,tab,command number,function key,f1,f12,shortcut"
            ),
            description: L("settings.search.tabSwitchShortcut.description", "Choose keyboard shortcuts for jumping to tabs")
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

        // Performance
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
            id: "smartScroll",
            section: .scrollbackPerf,
            title: L("settings.search.smartScroll.title", "Smart Scroll"),
            keywords: localizedKeywords(
                "settings.search.smartScroll.keywords",
                "smart,scroll,autoscroll,position,preserve"
            ),
            description: L("settings.search.smartScroll.description", "Preserve scroll position while output continues")
        ),
        SearchableSetting(
            id: "restoredScrollback",
            section: .scrollbackPerf,
            title: L("settings.search.restoredScrollback.title", "Restored Scrollback"),
            keywords: localizedKeywords(
                "settings.search.restoredScrollback.keywords",
                "restore,recover,scrollback,lines,tabs"
            ),
            description: L("settings.search.restoredScrollback.description", "Limit how much scrollback is restored for recovered tabs")
        ),
        SearchableSetting(
            id: "refreshCaps",
            section: .scrollbackPerf,
            title: L("settings.search.refreshCaps.title", "Refresh Caps"),
            keywords: localizedKeywords(
                "settings.search.refreshCaps.keywords",
                "refresh,fps,rate,cap,battery,performance"
            ),
            description: L("settings.search.refreshCaps.description", "Limit active and background terminal refresh rates")
        ),

        // Command Safety
        SearchableSetting(
            id: "dangerousCommands",
            section: .dangerousCommands,
            title: L("settings.search.dangerousCommands.title", "Command Safety"),
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
        SearchableSetting(
            id: "keybindingPreset",
            section: .keyboardMouse,
            title: L("settings.search.keybindingPreset.title", "Keybinding Preset"),
            keywords: localizedKeywords(
                "settings.search.keybindingPreset.keywords",
                "preset,vim,emacs,default,keybinding,shortcut"
            ),
            description: L("settings.search.keybindingPreset.description", "Choose a built-in keyboard shortcut preset")
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
            id: "llmProvider",
            section: .aiDetection,
            title: L("settings.search.llmProvider.title", "LLM Provider"),
            keywords: localizedKeywords(
                "settings.search.llmProvider.keywords",
                "openai,anthropic,api,key,llm,byoai"
            ),
            description: L("settings.search.llmProvider.description", "Configure LLM provider and API keys")
        ),
        SearchableSetting(
            id: "errorExplanation",
            section: .aiDetection,
            title: L("settings.search.errorExplanation.title", "Error Explanation"),
            keywords: localizedKeywords(
                "settings.search.errorExplanation.keywords",
                "error,explain,llm,ai,diagnose"
            ),
            description: L("settings.search.errorExplanation.description", "Use an LLM to explain terminal errors")
        ),

        // Context Optimization
        SearchableSetting(
            id: "ctoMode",
            section: .tokenOptimization,
            title: L("settings.search.ctoMode.title", "Context Mode"),
            keywords: localizedKeywords(
                "settings.search.ctoMode.keywords",
                "cto,token,optimization,mode,wrapper,all,ai,manual"
            ),
            description: L("settings.search.ctoMode.description", "Controls when context optimization is active")
        ),
        SearchableSetting(
            id: "ctoPrefix",
            section: .tokenOptimization,
            title: L("settings.search.ctoPrefix.title", "Context Prefix"),
            keywords: localizedKeywords(
                "settings.search.ctoPrefix.keywords",
                "cto,prefix,prepend,tab,override,integration"
            ),
            description: L("settings.search.ctoPrefix.description", "Prefix text prepended to terminal commands")
        ),
        SearchableSetting(
            id: "ctoPerTab",
            section: .tokenOptimization,
            title: L("settings.search.ctoPerTab.title", "Per-Tab Context Optimization"),
            keywords: localizedKeywords(
                "settings.search.ctoPerTab.keywords",
                "tab,override,force,enable,disable,bolt"
            ),
            description: L("settings.search.ctoPerTab.description", "Override context optimization per tab")
        ),

        // Agent Control
        SearchableSetting(
            id: "mcpServer",
            section: .mcpControl,
            title: L("settings.search.mcpServer.title", "Agent Server"),
            keywords: localizedKeywords(
                "settings.search.mcpServer.keywords",
                "mcp,server,remote,agent,tabs,automation"
            ),
            description: L("settings.search.mcpServer.description", "Enable agent control and tab creation")
        ),
        SearchableSetting(
            id: "mcpPermissions",
            section: .mcpControl,
            title: L("settings.search.mcpPermissions.title", "Agent Permissions"),
            keywords: localizedKeywords(
                "settings.search.mcpPermissions.keywords",
                "permission,approval,allow,block,command,profile"
            ),
            description: L("settings.search.mcpPermissions.description", "Configure agent command approval and allow/block lists")
        ),
        SearchableSetting(
            id: "mcpProfiles",
            section: .mcpControl,
            title: L("settings.search.mcpProfiles.title", "Agent Profiles"),
            keywords: localizedKeywords(
                "settings.search.mcpProfiles.keywords",
                "profile,project,permissions,mcp"
            ),
            description: L("settings.search.mcpProfiles.description", "Manage agent permission profiles")
        ),

        // Remote Access
        SearchableSetting(
            id: "remote",
            section: .remoteControl,
            title: L("settings.search.remote.title", "Remote Access"),
            keywords: localizedKeywords(
                "settings.search.remote.keywords",
                "remote,ios,relay,pairing,qr"
            ),
            description: L("settings.search.remote.description", "Pair an iPhone and view terminal output remotely")
        ),

        // SSH Profiles
        SearchableSetting(
            id: "sshProfiles",
            section: .sshProfiles,
            title: L("settings.search.sshProfiles.title", "SSH Profiles"),
            keywords: localizedKeywords(
                "settings.search.sshProfiles.keywords",
                "ssh,config,host,profile,connection"
            ),
            description: L("settings.search.sshProfiles.description", "Manage SSH config entries and connections")
        ),

        // API Tracking
        SearchableSetting(
            id: "apiAnalytics",
            section: .apiProxy,
            title: L("settings.search.apiAnalytics.title", "API Tracking"),
            keywords: localizedKeywords(
                "settings.search.apiAnalytics.keywords",
                "api,proxy,analytics,cost,token,tracking"
            ),
            description: L("settings.search.apiAnalytics.description", "Track API calls and token usage")
        ),

        // AI Context
        SearchableSetting(
            id: "promptInjection",
            section: .promptInjection,
            title: L("settings.search.promptInjection.title", "AI Context"),
            keywords: localizedKeywords(
                "settings.search.promptInjection.keywords",
                "inject,prompt,context,prefix,prepend,append,system,repository,repo,rules"
            ),
            description: L("settings.search.promptInjection.description", "Add custom context to AI requests per repository")
        ),

        // Alerts
        SearchableSetting(
            id: "notificationStatus",
            section: .notifications,
            title: L("settings.search.notificationStatus.title", "Alert Status"),
            keywords: localizedKeywords(
                "settings.search.notificationStatus.keywords",
                "permission,alert,system,status"
            ),
            description: L("settings.search.notificationStatus.description", "System alert permission status")
        ),
        SearchableSetting(
            id: "notificationTriggers",
            section: .notifications,
            title: L("settings.search.notificationTriggers.title", "Notification Triggers"),
            keywords: localizedKeywords(
                "settings.search.notificationTriggers.keywords",
                "filter,event,type,toggle,task,complete,failed,trigger,enable,disable"
            ),
            description: L("settings.search.notificationTriggers.description", "Enable triggers and configure alert actions")
        ),
        SearchableSetting(
            id: "triggerActions",
            section: .notifications,
            title: L("settings.search.triggerActions.title", "Trigger Actions"),
            keywords: localizedKeywords(
                "settings.search.triggerActions.keywords",
                "action,webhook,slack,discord,script,sound,docker,notification,play,run"
            ),
            description: L("settings.search.triggerActions.description", "Configure what happens when alert triggers fire"),
            anchorID: "notificationTriggers"
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
            description: L("settings.search.aiToolNotifications.description", "Alerts from AI coding tools")
        ),
        SearchableSetting(
            id: "eventMonitoring",
            section: .notifications,
            title: L("settings.search.eventMonitoring.title", "Event Monitoring"),
            keywords: localizedKeywords(
                "settings.search.eventMonitoring.keywords",
                "monitor,watch,ai,events,log,tailer,restart"
            ),
            description: L("settings.search.eventMonitoring.description", "Monitor AI CLI events for alerts")
        ),

        // History
        SearchableSetting(
            id: "persistentHistory",
            section: .history,
            title: L("settings.search.persistentHistory.title", "Persistent History"),
            keywords: localizedKeywords(
                "settings.search.persistentHistory.keywords",
                "history,database,commands,persistent,storage"
            ),
            description: L("settings.search.persistentHistory.description", "Save command history across sessions")
        ),
        SearchableSetting(
            id: "telemetryRetention",
            section: .history,
            title: L("settings.search.telemetryRetention.title", "Telemetry Retention"),
            keywords: localizedKeywords(
                "settings.search.telemetryRetention.keywords",
                "telemetry,transcripts,history,retention,days,storage"
            ),
            description: L("settings.search.telemetryRetention.description", "Control how long AI transcripts are kept")
        ),

        // Diagnostics
        SearchableSetting(
            id: "historyLogs",
            section: .logsHistory,
            title: L("settings.search.historyLogs.title", "History Logs"),
            keywords: localizedKeywords(
                "settings.search.historyLogs.keywords",
                "codex,claude,history,path,idle,stale,monitor"
            ),
            description: L("settings.search.historyLogs.description", "Configure AI history log monitoring")
        ),
        SearchableSetting(
            id: "terminalLogs",
            section: .logsHistory,
            title: L("settings.search.terminalLogs.title", "Terminal Logs"),
            keywords: localizedKeywords(
                "settings.search.terminalLogs.keywords",
                "terminal,log,path,ansi,normalize,prefill,monitor"
            ),
            description: L("settings.search.terminalLogs.description", "Configure PTY terminal log monitoring")
        ),
        SearchableSetting(
            id: "debugConsole",
            section: .logsHistory,
            title: L("debug.surface.diagnostics.title", "Diagnostics"),
            keywords: localizedKeywords(
                "settings.search.debugConsole.keywords",
                "debug,console,diagnostics,logs,troubleshooting,state,events,runtime,usage,cost,quota"
            ),
            description: L("settings.search.debugConsole.description", "Open Chau7 diagnostics, runtime inspection, and usage monitor surfaces")
        ),

        // Additional searchable controls
        SearchableSetting(
            id: "ligatures",
            section: .fontColors,
            title: L("settings.search.ligatures.title", "Font Ligatures"),
            keywords: localizedKeywords("settings.search.ligatures.keywords", "ligature,fira code,jetbrains,cascadia,coding font"),
            description: L("settings.search.ligatures.description", "Multi-character ligature rendering for coding fonts")
        ),
        SearchableSetting(
            id: "suspendRendering",
            section: .scrollbackPerf,
            title: L("settings.search.suspendRendering.title", "Suspend Background Rendering"),
            keywords: localizedKeywords("settings.search.suspendRendering.keywords", "suspend,background,render,gpu,cpu,performance"),
            description: L("settings.search.suspendRendering.description", "Pause rendering for inactive tabs")
        ),
        SearchableSetting(
            id: "metalRenderer",
            section: .scrollbackPerf,
            title: L("settings.search.metalRenderer.title", "Metal Renderer"),
            keywords: localizedKeywords("settings.search.metalRenderer.keywords", "metal,gpu,renderer,hardware,acceleration"),
            description: L("settings.search.metalRenderer.description", "GPU-accelerated terminal rendering")
        ),
        SearchableSetting(
            id: "groupIdleTabs",
            section: .tabs,
            title: L("settings.search.groupIdleTabs.title", "Group Idle Tabs"),
            keywords: localizedKeywords("settings.search.groupIdleTabs.keywords", "idle,tabs,group,dropdown,declutter,threshold,minutes"),
            description: L("settings.search.groupIdleTabs.description", "Collect idle tabs in a dropdown chip (configurable threshold)")
        ),
        SearchableSetting(
            id: "hoverCardSections",
            section: .hoverCard,
            title: L("settings.search.hoverCardSections.title", "Hover Card Sections"),
            keywords: localizedKeywords(
                "settings.search.hoverCardSections.keywords",
                "hover,card,preview,sections,directory,git,processes,notifications"
            ),
            description: L("settings.search.hoverCardSections.description", "Choose which information appears in tab hover cards")
        ),
        SearchableSetting(
            id: "repositoryMetadata",
            section: .repositories,
            title: L("settings.search.repositoryMetadata.title", "Repository Metadata"),
            keywords: localizedKeywords(
                "settings.search.repositoryMetadata.keywords",
                "repository,repo,metadata,description,labels,favorite files"
            ),
            description: L("settings.search.repositoryMetadata.description", "Manage repository descriptions, labels, and favorite files")
        ),
        SearchableSetting(
            id: "clickToPosition",
            section: .keyboardMouse,
            title: L("settings.search.clickToPosition.title", "Click to Position Cursor"),
            keywords: localizedKeywords("settings.search.clickToPosition.keywords", "click,cursor,position,input"),
            description: L("settings.search.clickToPosition.description", "Click on input line to move cursor")
        ),
        SearchableSetting(
            id: "mouseReporting",
            section: .keyboardMouse,
            title: L("settings.search.mouseReporting.title", "Mouse Reporting"),
            keywords: localizedKeywords("settings.search.mouseReporting.keywords", "mouse,reporting,vim,tmux,click"),
            description: L("settings.search.mouseReporting.description", "Forward mouse events to terminal apps")
        ),
        SearchableSetting(
            id: "textEditor",
            section: .editor,
            title: L("settings.search.textEditor.title", "Text Editor"),
            keywords: localizedKeywords("settings.search.textEditor.keywords", "editor,text,font,indentation,line numbers,word wrap"),
            description: L("settings.search.textEditor.description", "Built-in text editor settings")
        ),
        SearchableSetting(
            id: "minimalMode",
            section: .minimalMode,
            title: L("settings.search.minimalMode.title", "Minimal Mode"),
            keywords: localizedKeywords("settings.search.minimalMode.keywords", "minimal,hide,tab bar,title bar,distraction free"),
            description: L("settings.search.minimalMode.description", "Hide UI elements for distraction-free mode")
        )
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

    static func searchAnchorID(forTitle title: String, in section: SettingsSection?) -> String? {
        let normalizedTitle = normalizedSearchTitle(title)
        return searchableSettings.first { setting in
            (section == nil || setting.section == section) &&
                normalizedSearchTitle(setting.title) == normalizedTitle
        }?.anchorID
    }
}

// MARK: - Notification Names

// Notification.Name constants live in App/AppSignals.swift (central registry).
