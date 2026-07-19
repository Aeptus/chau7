import SwiftUI
import Chau7Core

func settingsPageSummaryMinimumItemCount(for section: SettingsSection) -> Int {
    switch section {
    case .startHere, .general, .profilesBackup, .about,
         .fontColors, .display, .windows, .tabs, .hoverCard,
         .repositories, .shell, .scrollbackPerf, .dangerousCommands,
         .graphics, .keyboardMouse, .snippetsTools, .editor,
         .minimalMode, .aiDetection, .tokenOptimization, .mcpControl,
         .remoteControl, .sshProfiles, .apiProxy, .promptInjection,
         .notifications, .history, .logsHistory:
        return 4
    }
}

struct SettingsPageSummaryView: View {
    let section: SettingsSection
    var model: AppModel

    @Bindable private var settings = FeatureSettings.shared
    @Bindable private var graphics = SixelKittyBridge.shared
    @Bindable private var minimalMode = MinimalMode.shared
    @Bindable private var remote = RemoteControlManager.shared
    @Bindable private var proxy = ProxyManager.shared
    @Bindable private var sshProfiles = SharedSSHProfileManager.shared
    @Bindable private var sshConnections = SSHConnectionManager.shared
    @Bindable private var injectionStore = InjectionRuleStore.shared
    @Bindable private var configWatcher = ConfigFileWatcher.shared
    @State private var profileSwitcher = ProfileAutoSwitcher.shared

    var body: some View {
        SettingsStatusGrid(items: summaryItems, minimumColumnWidth: 150)
            .settingsSearchAnchor("pageSummary")
            .accessibilityLabel(
                String(
                    format: L("settings.summary.accessibility", "%@ summary"),
                    section.title
                )
            )
    }

    private var summaryItems: [SettingsStatusItem] {
        switch section {
        case .startHere:
            return [
                statusItem(
                    "profile",
                    L("settings.startHere.activeProfile", "Active Profile"),
                    activeProfileName,
                    icon: settings.activeProfile?.icon ?? "person.crop.circle",
                    tone: .neutral
                ),
                statusItem(
                    "agentControl",
                    L("settings.mcpControl", "Agent Control"),
                    enabledDisabled(settings.mcpEnabled),
                    detail: settings.mcpEnabled ? String(format: L("settings.startHere.mcp.detail", "Max tabs: %d"), settings.mcpMaxTabs) : nil,
                    icon: "face.dashed",
                    tone: enabledTone(settings.mcpEnabled)
                ),
                remoteSummaryItem(id: "remote"),
                statusItem(
                    "alerts",
                    L("settings.notifications", "Alerts"),
                    model.notificationStatus,
                    detail: model.notificationWarning,
                    icon: "bell.badge",
                    tone: model.notificationWarning == nil ? .enabled : .warning
                )
            ]
        case .general:
            return [
                statusItem(
                    "startup",
                    L("settings.general.launchAtLogin", "Launch at Login"),
                    enabledDisabled(settings.launchAtLogin),
                    icon: "power",
                    tone: enabledTone(settings.launchAtLogin)
                ),
                statusItem(
                    "language",
                    L("settings.general.language", "Language"),
                    settings.appLanguage.displayName,
                    icon: "globe",
                    tone: .neutral
                ),
                statusItem(
                    "configFile",
                    L("settings.configFile.title", "Config File"),
                    enabledDisabled(configWatcher.isEnabled),
                    icon: "doc.text",
                    tone: enabledTone(configWatcher.isEnabled)
                ),
                statusItem(
                    "defaultDirectory",
                    L("settings.general.defaultDirectory", "Default Directory"),
                    compactPath(settings.defaultStartDirectory.isEmpty ? "~" : settings.defaultStartDirectory),
                    icon: "folder",
                    tone: .neutral
                )
            ]
        case .profilesBackup:
            return [
                statusItem(
                    "profile",
                    L("settings.startHere.activeProfile", "Active Profile"),
                    activeProfileName,
                    icon: settings.activeProfile?.icon ?? "person.crop.circle",
                    tone: .neutral
                ),
                countItem(
                    "profiles",
                    L("settings.profileBar.profiles", "Profiles"),
                    settings.savedProfiles.count,
                    icon: "person.2"
                ),
                statusItem(
                    "icloud",
                    L("settings.general.icloudSync", "iCloud Sync"),
                    enabledDisabled(settings.iCloudSyncEnabled),
                    icon: "icloud",
                    tone: enabledTone(settings.iCloudSyncEnabled)
                ),
                statusItem(
                    "profileAutoSwitch",
                    L("Profile Auto-Switching", "Profile Auto-Switching"),
                    enabledDisabled(profileSwitcher.isEnabled),
                    detail: String(
                        format: L("settings.profileAutoSwitch.rules.count", "%d rules"),
                        profileSwitcher.rules.count
                    ),
                    icon: "arrow.triangle.swap",
                    tone: enabledTone(profileSwitcher.isEnabled)
                )
            ]
        case .about:
            return [
                statusItem(
                    "version",
                    L("settings.about.version", "Version"),
                    appVersion,
                    icon: "info.circle",
                    tone: .neutral
                ),
                statusItem(
                    "support",
                    L("settings.about.support", "Support"),
                    L("status.available", "Available"),
                    detail: L("settings.about.support.detail", "GitHub, issues, documentation"),
                    icon: "questionmark.circle",
                    tone: .neutral
                ),
                statusItem(
                    "logs",
                    L("settings.about.logPath", "Log Path"),
                    compactPath(model.logFilePath),
                    icon: "doc.text.magnifyingglass",
                    tone: .neutral
                ),
                statusItem(
                    "diagnostics",
                    L("settings.logsHistory", "Diagnostics"),
                    L("status.available", "Available"),
                    icon: "stethoscope",
                    tone: .neutral
                )
            ]
        case .fontColors:
            return [
                statusItem("font", L("settings.appearance.fontFamily", "Font Family"), settings.fontFamily, icon: "textformat", tone: .neutral),
                statusItem("size", L("settings.appearance.fontSize", "Font Size"), "\(settings.fontSize) pt", icon: "textformat.size", tone: .neutral),
                statusItem("scheme", L("settings.appearance.scheme", "Scheme"), settings.colorSchemeName, icon: "paintpalette", tone: .neutral),
                statusItem("zoom", L("settings.appearance.defaultZoom", "Default Zoom"), "\(settings.defaultZoomPercent)%", icon: "plus.magnifyingglass", tone: .neutral)
            ]
        case .display:
            return [
                statusItem(
                    "syntax",
                    L("settings.appearance.syntaxHighlighting", "Syntax Highlighting"),
                    enabledDisabled(settings.isSyntaxHighlightEnabled),
                    icon: "curlybraces",
                    tone: enabledTone(settings.isSyntaxHighlightEnabled)
                ),
                statusItem(
                    "urls",
                    L("settings.appearance.clickableURLs", "Clickable URLs"),
                    enabledDisabled(settings.isClickableURLsEnabled),
                    icon: "link",
                    tone: enabledTone(settings.isClickableURLsEnabled)
                ),
                statusItem(
                    "images",
                    L("settings.appearance.inlineImages", "Inline Images"),
                    enabledDisabled(settings.isInlineImagesEnabled),
                    icon: "photo",
                    tone: enabledTone(settings.isInlineImagesEnabled)
                ),
                statusItem(
                    "json",
                    L("settings.appearance.prettyPrintJSON", "Pretty Print JSON"),
                    enabledDisabled(settings.isJSONPrettyPrintEnabled),
                    icon: "curlybraces.square",
                    tone: enabledTone(settings.isJSONPrettyPrintEnabled)
                )
            ]
        case .windows:
            return [
                statusItem("theme", L("settings.appearance.appearance", "Appearance"), settings.appTheme.displayName, icon: "circle.lefthalf.filled", tone: .neutral),
                statusItem("opacity", L("settings.appearance.windowOpacity", "Window Opacity"), "\(Int(settings.windowOpacity * 100))%", icon: "circle.dashed", tone: .neutral),
                statusItem(
                    "floating",
                    L("settings.windows.floatingWindow", "Keep Windows Above Other Apps"),
                    enabledDisabled(settings.windowFloating),
                    icon: "macwindow.badge.plus",
                    tone: enabledTone(settings.windowFloating)
                ),
                statusItem(
                    "splitPanes",
                    L("settings.windows.splitPanes", "Split Panes"),
                    enabledDisabled(settings.isSplitPanesEnabled),
                    icon: "rectangle.split.2x1",
                    tone: enabledTone(settings.isSplitPanesEnabled)
                )
            ]
        case .tabs:
            return [
                statusItem("newTabPosition", L("settings.tabs.newTabPosition", "New Tab Position"), newTabPositionLabel, icon: "rectangle.stack.badge.plus", tone: .neutral),
                statusItem(
                    "idleGrouping",
                    L("settings.tabs.groupIdleTabs", "Group Idle Tabs in Dropdown"),
                    enabledDisabled(settings.groupIdleTabs),
                    detail: settings.groupIdleTabs ? "\(settings.idleTabThresholdMinutes) min" : nil,
                    icon: "tray.2",
                    tone: enabledTone(settings.groupIdleTabs)
                ),
                statusItem("indicators", L("settings.tabs.display", "Tab Display"), tabIndicatorSummary, icon: "eye", tone: .neutral),
                statusItem(
                    "closeWarnings",
                    L("settings.tabs.warnOnCloseWithProcess", "Warn When Closing Tab with Running Process"),
                    enabledDisabled(settings.warnOnCloseWithRunningProcess || settings.alwaysWarnOnTabClose),
                    icon: "exclamationmark.triangle",
                    tone: enabledTone(settings.warnOnCloseWithRunningProcess || settings.alwaysWarnOnTabClose)
                )
            ]
        case .hoverCard:
            return [
                statusItem("visible", L("settings.hoverCard.sections", "Visible Sections"), "\(visibleHoverCardSectionCount)/13", icon: "text.bubble", tone: .neutral),
                statusItem(
                    "aiSession",
                    L("settings.hover.aiSession", "AI Session"),
                    enabledDisabled(settings.hoverCardShowAISession),
                    icon: "sparkles",
                    tone: enabledTone(settings.hoverCardShowAISession)
                ),
                statusItem(
                    "processes",
                    L("settings.hover.processes", "Processes"),
                    enabledDisabled(settings.hoverCardShowProcesses),
                    icon: "terminal",
                    tone: enabledTone(settings.hoverCardShowProcesses)
                ),
                statusItem(
                    "footer",
                    L("settings.hover.footer", "Footer"),
                    enabledDisabled(settings.hoverCardShowFooter),
                    icon: "rectangle.bottomthird.inset.filled",
                    tone: enabledTone(settings.hoverCardShowFooter)
                )
            ]
        case .repositories:
            return [
                statusItem(
                    "grouping",
                    L("settings.tabs.repoGrouping", "Repo Grouping"),
                    settings.repoGroupingMode.displayName,
                    icon: "rectangle.3.group",
                    tone: settings.repoGroupingMode == .off ? .disabled : .enabled
                ),
                statusItem(
                    "search",
                    L("settings.repositories.semanticSearch", "Semantic Search"),
                    enabledDisabled(settings.isSemanticSearchEnabled),
                    icon: "magnifyingglass",
                    tone: enabledTone(settings.isSemanticSearchEnabled)
                ),
                countItem("recent", L("settings.repositories.recent", "Recent Repos"), settings.recentRepoRoots.count, icon: "clock.arrow.circlepath"),
                statusItem(
                    "defaultDirectory",
                    L("settings.general.defaultDirectory", "Default Directory"),
                    compactPath(settings.defaultStartDirectory.isEmpty ? "~" : settings.defaultStartDirectory),
                    icon: "folder",
                    tone: .neutral
                )
            ]
        case .shell:
            return [
                statusItem("shell", L("settings.terminal.shell", "Shell"), shellDisplayName, icon: "terminal", tone: .neutral),
                statusItem(
                    "startup",
                    L("settings.terminal.startupCommand", "Startup Command"),
                    configuredUnconfigured(!settings.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty),
                    icon: "play",
                    tone: configuredTone(!settings.startupCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                ),
                statusItem("lsColors", L("settings.terminal.lsColors", "ls Colors"), enabledDisabled(settings.isLsColorsEnabled), icon: "paintbrush", tone: enabledTone(settings.isLsColorsEnabled)),
                statusItem(
                    "bell",
                    L("settings.terminal.bell", "Bell"),
                    enabledDisabled(settings.bellEnabled),
                    detail: settings.bellEnabled ? settings.bellSound : nil,
                    icon: "bell",
                    tone: enabledTone(settings.bellEnabled)
                )
            ]
        case .scrollbackPerf:
            return [
                countItem("scrollback", L("settings.terminal.scrollback", "Scrollback"), settings.scrollbackLines, icon: "scroll"),
                countItem("restored", L("settings.performance.restoredScrollback", "Restored Lines"), settings.restoredScrollbackLines, icon: "clock.arrow.circlepath"),
                statusItem(
                    "renderer",
                    L("settings.performance.renderer", "Renderer"),
                    settings.useMetalRenderer ? "Metal" : "CoreGraphics",
                    icon: "speedometer",
                    tone: settings.useMetalRenderer ? .enabled : .neutral
                ),
                statusItem("refresh", L("settings.performance.activeRefresh", "Active Refresh"), settings.activePollingRateCap.displayName, icon: "gauge.with.dots.needle.67percent", tone: .neutral)
            ]
        case .dangerousCommands:
            return [
                statusItem(
                    "protectChau7",
                    L("settings.dangerous.protectChau7", "Protect Chau7"),
                    enabledDisabled(settings.dangerousCommandProtectChau7Enabled),
                    detail: protectionLevelLabel,
                    icon: "shield",
                    tone: enabledTone(settings.dangerousCommandProtectChau7Enabled)
                ),
                statusItem("scope", L("settings.dangerous.highlightScope", "Highlight Scope"), highlightScopeLabel, icon: "highlighter", tone: .neutral),
                countItem("patterns", L("settings.dangerous.patterns", "Patterns"), settings.dangerousCommandPatterns.count, icon: "list.bullet.rectangle"),
                statusItem(
                    "lowPower",
                    L("settings.dangerous.lowPower", "Low Power"),
                    enabledDisabled(settings.dangerousOutputHighlightLowPowerEnabled),
                    icon: "battery.25",
                    tone: enabledTone(settings.dangerousOutputHighlightLowPowerEnabled)
                )
            ]
        case .graphics:
            return [
                statusItem("sixel", L("settings.graphics.sixel", "Sixel"), enabledDisabled(graphics.isSixelEnabled), icon: "photo", tone: enabledTone(graphics.isSixelEnabled)),
                statusItem(
                    "kitty",
                    L("settings.graphics.kitty", "Kitty Graphics"),
                    enabledDisabled(graphics.isKittyGraphicsEnabled),
                    icon: "photo.stack",
                    tone: enabledTone(graphics.isKittyGraphicsEnabled)
                ),
                statusItem(
                    "inlineImages",
                    L("settings.appearance.inlineImages", "Inline Images"),
                    enabledDisabled(settings.isInlineImagesEnabled),
                    icon: "rectangle.on.rectangle",
                    tone: enabledTone(settings.isInlineImagesEnabled)
                ),
                statusItem("cache", L("settings.graphics.cache", "Cache"), "\(graphics.kittyCacheLimitMB) MB", icon: "externaldrive", tone: .neutral)
            ]
        case .keyboardMouse:
            return [
                statusItem(
                    "shortcutHelper",
                    L("settings.shortcuts.helper", "Shortcut Helper"),
                    enabledDisabled(settings.isShortcutHelperHintEnabled),
                    icon: "keyboard",
                    tone: enabledTone(settings.isShortcutHelperHintEnabled)
                ),
                statusItem(
                    "copyOnSelect",
                    L("settings.input.copyOnSelect", "Copy on Select"),
                    enabledDisabled(settings.isCopyOnSelectEnabled),
                    icon: "doc.on.doc",
                    tone: enabledTone(settings.isCopyOnSelectEnabled)
                ),
                statusItem(
                    "cmdClick",
                    L("settings.input.cmdClickPaths", "Cmd-Click Paths"),
                    enabledDisabled(settings.isCmdClickPathsEnabled),
                    icon: "cursorarrow.click",
                    tone: enabledTone(settings.isCmdClickPathsEnabled)
                ),
                statusItem(
                    "mouseReporting",
                    L("settings.input.mouseReporting", "Mouse Reporting"),
                    enabledDisabled(settings.isMouseReportingEnabled),
                    icon: "computermouse",
                    tone: enabledTone(settings.isMouseReportingEnabled)
                )
            ]
        case .snippetsTools:
            return [
                statusItem(
                    "snippets",
                    L("settings.snippetsTools.snippets", "Snippets"),
                    enabledDisabled(settings.isSnippetsEnabled),
                    icon: "text.badge.plus",
                    tone: enabledTone(settings.isSnippetsEnabled)
                ),
                statusItem(
                    "repoSnippets",
                    L("settings.snippetsTools.repoSnippets", "Repo Snippets"),
                    enabledDisabled(settings.isRepoSnippetsEnabled),
                    icon: "folder.badge.plus",
                    tone: enabledTone(settings.isRepoSnippetsEnabled)
                ),
                statusItem(
                    "clipboard",
                    L("settings.snippetsTools.clipboardHistory", "Clipboard History"),
                    enabledDisabled(settings.isClipboardHistoryEnabled),
                    detail: settings.isClipboardHistoryEnabled ? String(format: L("settings.summary.items", "%d items"), settings.clipboardHistoryMaxItems) : nil,
                    icon: "clipboard",
                    tone: enabledTone(settings.isClipboardHistoryEnabled)
                ),
                statusItem(
                    "bookmarks",
                    L("settings.snippetsTools.bookmarks", "Bookmarks"),
                    enabledDisabled(settings.isBookmarksEnabled),
                    icon: "bookmark",
                    tone: enabledTone(settings.isBookmarksEnabled)
                )
            ]
        case .editor:
            return [
                statusItem("editor", L("settings.editor.defaultEditor", "Default Editor"), settings.defaultEditor, icon: "doc.text", tone: .neutral),
                statusItem(
                    "internal",
                    L("settings.editor.internalEditor", "Internal Editor"),
                    enabledDisabled(settings.cmdClickOpensInternalEditor),
                    icon: "square.split.2x1",
                    tone: enabledTone(settings.cmdClickOpensInternalEditor)
                ),
                statusItem(
                    "splitPanes",
                    L("settings.windows.splitPanes", "Split Panes"),
                    enabledDisabled(settings.isSplitPanesEnabled),
                    icon: "rectangle.split.2x1",
                    tone: enabledTone(settings.isSplitPanesEnabled)
                ),
                statusItem(
                    "semanticSearch",
                    L("settings.repositories.semanticSearch", "Semantic Search"),
                    enabledDisabled(settings.isSemanticSearchEnabled),
                    icon: "magnifyingglass",
                    tone: enabledTone(settings.isSemanticSearchEnabled)
                )
            ]
        case .minimalMode:
            return [
                statusItem("minimal", L("settings.minimalMode", "Minimal Mode"), enabledDisabled(minimalMode.isEnabled), icon: "rectangle.compress.vertical", tone: enabledTone(minimalMode.isEnabled)),
                statusItem(
                    "tabBar",
                    L("settings.minimal.hideTabBar", "Hide Tab Bar"),
                    visibleHidden(minimalMode.hideTabBar),
                    icon: "rectangle.topthird.inset.filled",
                    tone: enabledTone(minimalMode.hideTabBar)
                ),
                statusItem("titleBar", L("settings.minimal.hideTitleBar", "Hide Title Bar"), visibleHidden(minimalMode.hideTitleBar), icon: "macwindow", tone: enabledTone(minimalMode.hideTitleBar)),
                statusItem(
                    "statusBar",
                    L("settings.minimal.hideStatusBar", "Hide Status Bar"),
                    visibleHidden(minimalMode.hideStatusBar),
                    icon: "rectangle.bottomthird.inset.filled",
                    tone: enabledTone(minimalMode.hideStatusBar)
                )
            ]
        case .aiDetection:
            return [
                statusItem(
                    "autoTheme",
                    L("settings.ai.autoTheme", "AI Tab Theme"),
                    enabledDisabled(settings.isAutoTabThemeEnabled),
                    icon: "sparkles",
                    tone: enabledTone(settings.isAutoTabThemeEnabled)
                ),
                countItem("customRules", L("settings.ai.customDetectionRules", "Custom Detection Rules"), settings.customAIDetectionRules.count, icon: "slider.horizontal.3"),
                statusItem(
                    "errorExplain",
                    L("settings.ai.errorExplain", "Error Explanation"),
                    enabledDisabled(settings.errorExplainEnabled),
                    icon: "questionmark.bubble",
                    tone: enabledTone(settings.errorExplainEnabled)
                ),
                statusItem(
                    "usage",
                    L("settings.ai.usageMonitoring", "Usage Monitoring"),
                    enabledDisabled(settings.isUsageMonitoringEnabled),
                    icon: "chart.bar",
                    tone: enabledTone(settings.isUsageMonitoringEnabled)
                ),
                statusItem(
                    "numberFormat",
                    L("settings.ai.numberFormat", "Number Format"),
                    settings.regionalNumberFormat.displayName,
                    detail: settings.regionalNumberFormat.example,
                    icon: "number",
                    tone: .neutral
                )
            ]
        case .tokenOptimization:
            return [
                statusItem(
                    "mode",
                    L("cto.settings.mode.label", "Mode"),
                    settings.tokenOptimizationMode.displayName,
                    icon: "bolt.horizontal.circle",
                    tone: settings.tokenOptimizationMode == .off ? .disabled : .enabled
                ),
                statusItem(
                    "prefix",
                    L("settings.ai.cto.enabled", "Enable Input Prefix"),
                    enabledDisabled(settings.isCTOEnabled),
                    detail: settings.isCTOEnabled ? settings.ctoPrefix : nil,
                    icon: "wand.and.stars",
                    tone: enabledTone(settings.isCTOEnabled)
                ),
                countItem("overrides", L("cto.settings.perTab", "Per-Tab Control"), settings.ctoTabOverrides.count, icon: "rectangle.stack"),
                statusItem(
                    "indicator",
                    L("settings.tabs.allowCTOToggle", "Allow Context Optimization Toggle in Hover Card"),
                    enabledDisabled(settings.allowTabCTOToggle),
                    icon: "switch.2",
                    tone: enabledTone(settings.allowTabCTOToggle)
                )
            ]
        case .mcpControl:
            return [
                statusItem("enabled", L("settings.mcp.enable", "Enable Agent Control"), enabledDisabled(settings.mcpEnabled), icon: "face.dashed", tone: enabledTone(settings.mcpEnabled)),
                statusItem(
                    "approval",
                    L("settings.mcp.approval", "Require Approval"),
                    enabledDisabled(settings.mcpRequiresApproval),
                    icon: "lock.shield",
                    tone: enabledTone(settings.mcpRequiresApproval)
                ),
                statusItem("mode", L("settings.mcp.permissionMode", "Permission Mode"), settings.mcpPermissionMode.displayName, icon: "checklist.checked", tone: .neutral),
                countItem("profiles", L("settings.mcp.profiles", "Agent Profiles"), settings.mcpProfiles.count, icon: "person.crop.rectangle.stack")
            ]
        case .remoteControl:
            return [
                statusItem(
                    "enabled",
                    L("settings.remote.enable", "Enable Remote Access"),
                    enabledDisabled(settings.isRemoteEnabled),
                    icon: "antenna.radiowaves.left.and.right",
                    tone: enabledTone(settings.isRemoteEnabled)
                ),
                statusItem(
                    "agent",
                    L("settings.remote.agent", "Remote Agent"),
                    remote.isAgentRunning ? L("status.running", "Running") : L("status.stopped", "Stopped"),
                    detail: remote.lastError,
                    icon: "dot.radiowaves.left.and.right",
                    tone: remoteStatusTone
                ),
                statusItem(
                    "relay",
                    L("settings.remote.relay", "Relay"),
                    compactPath(settings.remoteRelayURL),
                    icon: "network",
                    tone: settings.remoteRelayURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? .warning : .neutral
                ),
                countItem("devices", L("settings.remote.devices", "Paired Devices"), remote.pairedDevices.count, icon: "iphone")
            ]
        case .sshProfiles:
            return [
                statusItem("watch", L("settings.ssh.fileWatch", "File Watch"), activePaused(sshProfiles.isWatching), icon: "eye", tone: activeTone(sshProfiles.isWatching)),
                countItem("configEntries", L("settings.ssh.entries", "SSH Config Entries"), sshProfiles.configEntries.count, icon: "list.bullet"),
                countItem("connections", L("settings.ssh.connections", "Chau7 Connections"), sshConnections.connections.count, icon: "server.rack"),
                statusItem("lastSync", L("ssh.lastSync.short", "Last Sync"), lastSyncText, icon: "arrow.triangle.2.circlepath", tone: sshProfiles.lastSyncTime == nil ? .warning : .neutral)
            ]
        case .apiProxy:
            return [
                statusItem(
                    "enabled",
                    L("settings.proxy.enable", "Enable API Analytics"),
                    enabledDisabled(settings.isAPIAnalyticsEnabled),
                    icon: "chart.bar.xaxis",
                    tone: enabledTone(settings.isAPIAnalyticsEnabled)
                ),
                statusItem("status", L("settings.proxy.status", "Status"), proxyStatusText, detail: proxy.lastError, icon: "network", tone: proxyStatusTone),
                statusItem("port", L("settings.proxy.port", "Port"), "\(settings.apiAnalyticsPort)", icon: "number", tone: .neutral),
                statusItem(
                    "privacy",
                    L("settings.proxy.logPrompts", "Log Prompt Previews"),
                    enabledDisabled(settings.apiAnalyticsLogPrompts),
                    icon: "lock.open",
                    tone: settings.apiAnalyticsLogPrompts ? .warning : .enabled
                )
            ]
        case .promptInjection:
            return [
                statusItem(
                    "global",
                    L("settings.injection.global", "All Repositories"),
                    enabledDisabled(injectionStore.globalRule != nil),
                    icon: "globe",
                    tone: enabledTone(injectionStore.globalRule != nil)
                ),
                countItem("repoRules", L("settings.injection.perRepo", "Per Repository"), injectionStore.repoRules.count, icon: "folder.badge.gearshape"),
                countItem("localRules", L("settings.injection.localRules", "Repo-Local Rules"), injectionStore.localRules.count, icon: "doc.badge.gearshape"),
                statusItem(
                    "proxy",
                    L("settings.apiProxy", "API Tracking"),
                    enabledDisabled(settings.isAPIAnalyticsEnabled),
                    detail: L("settings.summary.proxyNeeded", "Proxy applies AI context rules."),
                    icon: "network",
                    tone: enabledTone(settings.isAPIAnalyticsEnabled)
                )
            ]
        case .notifications:
            return [
                statusItem(
                    "permission",
                    L("settings.productivity.permissions.notifications", "Notifications"),
                    model.notificationStatus,
                    detail: model.notificationWarning,
                    icon: "bell.badge",
                    tone: model.notificationWarning == nil ? .enabled : .warning
                ),
                countItem("actions", L("settings.notifications.actions", "Actions"), settings.triggerActionBindings.values.reduce(0) { $0 + $1.count }, icon: "bolt"),
                countItem("conditions", L("settings.notifications.conditions", "Conditions"), settings.triggerConditions.count, icon: "line.3.horizontal.decrease.circle"),
                statusItem("rateLimit", L("settings.notifications.rateLimit", "Rate Limit"), notificationRateLimitText, icon: "timer", tone: .neutral)
            ]
        case .history:
            return [
                statusItem(
                    "persistent",
                    L("settings.history.enable", "Enable Persistent History"),
                    enabledDisabled(persistentHistoryEnabled),
                    icon: "clock.arrow.circlepath",
                    tone: enabledTone(persistentHistoryEnabled)
                ),
                countItem("maxRecords", L("settings.history.maxRecords", "Maximum Records"), historyMaxRecords, icon: "externaldrive"),
                statusItem(
                    "telemetry",
                    L("settings.logs.telemetry", "AI Telemetry & Transcripts"),
                    telemetryRetentionText,
                    icon: "chart.bar.doc.horizontal",
                    tone: settings.telemetryRetentionDays == 0 ? .warning : .neutral
                ),
                statusItem("privacy", L("settings.history.importExport", "Import / Export"), L("status.available", "Available"), icon: "arrow.left.arrow.right", tone: .neutral)
            ]
        case .logsHistory:
            return [
                statusItem(
                    "historyLogs",
                    L("settings.logs.monitorHistoryLogs", "Monitor History Logs"),
                    enabledDisabled(model.isIdleMonitoring),
                    icon: "clock.arrow.circlepath",
                    tone: enabledTone(model.isIdleMonitoring)
                ),
                statusItem(
                    "terminalLogs",
                    L("settings.logs.monitorTerminalLogs", "Monitor Terminal Logs"),
                    enabledDisabled(model.isTerminalMonitoring),
                    icon: "terminal",
                    tone: enabledTone(model.isTerminalMonitoring)
                ),
                countItem("sessions", L("settings.logs.activeSessions", "Active Sessions"), model.sessionStatuses.count, icon: "person.2"),
                statusItem("logPath", L("settings.notifications.eventLogPath", "Event Log Path"), compactPath(model.logPath), icon: "doc.text.magnifyingglass", tone: .neutral)
            ]
        }
    }

    private func statusItem(
        _ id: String,
        _ label: String,
        _ value: String,
        detail: String? = nil,
        icon: String,
        tone: SettingsStatusTone
    ) -> SettingsStatusItem {
        SettingsStatusItem(
            id: id,
            label: label,
            value: value,
            detail: detail,
            systemImage: icon,
            tone: tone
        )
    }

    private func countItem(_ id: String, _ label: String, _ count: Int, icon: String) -> SettingsStatusItem {
        statusItem(
            id,
            label,
            count.formatted(),
            icon: icon,
            tone: count > 0 ? .neutral : .disabled
        )
    }

    private func remoteSummaryItem(id: String) -> SettingsStatusItem {
        statusItem(
            id,
            L("settings.remoteControl", "Remote Access"),
            remoteStatusValue,
            detail: remoteStatusDetail,
            icon: "antenna.radiowaves.left.and.right",
            tone: remoteStatusTone
        )
    }

    private var activeProfileName: String {
        guard let profile = settings.activeProfile else {
            return L("settings.profileBar.defaultSettings", "Default Settings")
        }
        if profile.name == "Default", profile.icon == "house.fill" {
            return L("settings.profileBar.defaultSettings", "Default Settings")
        }
        return profile.name
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? L("settings.about.developmentVersion", "Development")
    }

    private var shellDisplayName: String {
        switch settings.shellType {
        case .custom:
            let path = settings.customShellPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return path.isEmpty ? L("status.unconfigured", "Unconfigured") : compactPath(path)
        default:
            return settings.shellType.displayName
        }
    }

    private var newTabPositionLabel: String {
        settings.newTabPosition == "after"
            ? L("settings.tabs.afterCurrent", "After Current")
            : L("settings.tabs.atEnd", "At End")
    }

    private var tabIndicatorSummary: String {
        let visibleCount = [
            settings.showTabIcons,
            settings.showTabPath,
            settings.showTabGitIndicator,
            settings.allowTabCTOToggle,
            settings.showTabBroadcastIndicator,
            settings.isLastCommandBadgeEnabled
        ].filter { $0 }.count
        return String(format: L("settings.tabs.indicators.count", "%d visible"), visibleCount)
    }

    private var visibleHoverCardSectionCount: Int {
        [
            settings.hoverCardShowDirectory,
            settings.hoverCardShowGitBranch,
            settings.hoverCardShowLastCommand,
            settings.hoverCardShowDevServer,
            settings.hoverCardShowAISession,
            settings.hoverCardShowRepoStats,
            settings.hoverCardShowConflicts,
            settings.hoverCardShowNotificationState,
            settings.hoverCardShowProcesses,
            settings.hoverCardShowTokenOptimization,
            settings.hoverCardShowShellIntegration,
            settings.hoverCardShowBroadcast,
            settings.hoverCardShowFooter
        ].filter { $0 }.count
    }

    private var remoteStatusValue: String {
        guard settings.isRemoteEnabled else {
            return L("status.disabled", "Disabled")
        }
        return remote.isAgentRunning ? L("status.running", "Running") : L("status.stopped", "Stopped")
    }

    private var remoteStatusDetail: String? {
        if let error = remote.lastError, !error.isEmpty {
            return error
        }
        if let connectedDevice = remote.pairedDevices.first(where: \.isConnected) {
            return String(format: L("settings.remote.connectedDevice", "Connected device: %@"), connectedDevice.name)
        }
        if let sessionStatus = remote.sessionStatus, !sessionStatus.isEmpty {
            return String(format: L("remote.sessionStatus", "Session: %@"), sessionStatus)
        }
        return settings.isRemoteEnabled ? remote.activeRelayURL : nil
    }

    private var remoteStatusTone: SettingsStatusTone {
        guard settings.isRemoteEnabled else { return .disabled }
        if let error = remote.lastError, !error.isEmpty { return .warning }
        return remote.isAgentRunning ? .active : .warning
    }

    private var proxyStatusText: String {
        guard settings.isAPIAnalyticsEnabled else {
            return L("status.disabled", "Disabled")
        }
        if let error = proxy.lastError, !error.isEmpty {
            return L("status.error", "Error")
        }
        return proxy.isRunning ? L("status.running", "Running") : L("status.starting", "Starting...")
    }

    private var proxyStatusTone: SettingsStatusTone {
        guard settings.isAPIAnalyticsEnabled else { return .disabled }
        if let error = proxy.lastError, !error.isEmpty { return .warning }
        return proxy.isRunning ? .active : .warning
    }

    private var lastSyncText: String {
        guard let lastSyncTime = sshProfiles.lastSyncTime else {
            return L("status.never", "Never")
        }
        return lastSyncTime.formatted(date: .abbreviated, time: .shortened)
    }

    private var persistentHistoryEnabled: Bool {
        UserDefaults.standard.object(forKey: "feature.persistentHistory") as? Bool ?? true
    }

    private var historyMaxRecords: Int {
        let stored = UserDefaults.standard.integer(forKey: "history.maxRecords")
        return max(10000, min(stored > 0 ? stored : 50000, 100_000))
    }

    private var telemetryRetentionText: String {
        settings.telemetryRetentionDays == 0
            ? L("settings.logs.telemetryRetention.forever.short", "Forever")
            : String(format: L("settings.summary.days", "%d days"), settings.telemetryRetentionDays)
    }

    private var notificationRateLimitText: String {
        let config = settings.notificationRateLimitConfig
        return String(
            format: L("settings.summary.rateLimit", "%d/min, %ds cooldown"),
            config.maxPerMinute,
            Int(config.cooldownSeconds)
        )
    }

    private var highlightScopeLabel: String {
        switch settings.dangerousCommandHighlightScope {
        case .none:
            return L("settings.dangerousGuard.scope.none", "Disabled")
        case .aiOutputs:
            return L("settings.dangerousGuard.scope.aiOutputs", "AI Outputs Only")
        case .allOutputs:
            return L("settings.dangerousGuard.scope.allOutputs", "All Outputs")
        }
    }

    private var protectionLevelLabel: String {
        switch settings.dangerousCommandProtectChau7Level {
        case .verboseLogging:
            return L("settings.dangerousGuard.level.verboseLogging", "Verbose Logging")
        case .warning:
            return L("settings.dangerousGuard.level.warning", "Warning")
        case .blocking:
            return L("settings.dangerousGuard.level.blocking", "Blocking")
        }
    }

    private func enabledDisabled(_ enabled: Bool) -> String {
        enabled ? L("status.enabled", "Enabled") : L("status.disabled", "Disabled")
    }

    private func activePaused(_ active: Bool) -> String {
        active ? L("status.active", "Active") : L("status.paused", "Paused")
    }

    private func configuredUnconfigured(_ configured: Bool) -> String {
        configured ? L("status.configured", "Configured") : L("status.unconfigured", "Unconfigured")
    }

    private func visibleHidden(_ hidden: Bool) -> String {
        hidden ? L("status.hidden", "Hidden") : L("status.visible", "Visible")
    }

    private func enabledTone(_ enabled: Bool) -> SettingsStatusTone {
        enabled ? .enabled : .disabled
    }

    private func activeTone(_ active: Bool) -> SettingsStatusTone {
        active ? .active : .paused
    }

    private func configuredTone(_ configured: Bool) -> SettingsStatusTone {
        configured ? .enabled : .disabled
    }

    private func compactPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return L("status.unconfigured", "Unconfigured")
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let abbreviated = trimmed.replacingOccurrences(of: home, with: "~")
        guard abbreviated.count > 42 else { return abbreviated }
        let suffix = abbreviated.suffix(39)
        return "...\(suffix)"
    }
}
