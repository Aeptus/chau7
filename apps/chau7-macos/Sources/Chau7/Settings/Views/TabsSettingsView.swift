import SwiftUI

// MARK: - Tabs Settings

struct TabsSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Behavior
            SettingsSectionHeader(L("settings.tabs.behavior", "Behavior"), icon: "rectangle.stack.badge.plus")

            SettingsPicker(
                label: L("settings.tabs.newTabPosition", "New Tab Position"),
                help: L("settings.tabs.newTabPosition.help", "Where to insert newly created tabs"),
                selection: $settings.newTabPosition,
                options: [
                    (value: "end", label: L("settings.tabs.atEnd", "At End")),
                    (value: "after", label: L("settings.tabs.afterCurrent", "After Current"))
                ]
            )

            SettingsToggle(
                label: L("settings.tabs.newTabsUseCurrentDirectory", "New Tabs Use Current Directory"),
                help: L("settings.tabs.newTabsUseCurrentDirectory.help", "Open new tabs in the active tab's folder (the first tab still uses Default Directory)"),
                isOn: $settings.newTabsUseCurrentDirectory
            )

            SettingsPicker(
                label: L("settings.tabs.lastTabClose", "Last Tab Close"),
                help: L("settings.tabs.lastTabClose.help", "Choose what happens when closing the final tab"),
                selection: $settings.lastTabCloseBehavior,
                options: LastTabCloseBehavior.allCases.map { (value: $0, label: $0.displayName) }
            )

            SettingsToggle(
                label: L("settings.tabs.warnOnCloseWithProcess", "Warn When Closing Tab with Running Process"),
                help: L("settings.tabs.warnOnCloseWithProcess.help", "Show a confirmation dialog before closing a tab that has a running process"),
                isOn: $settings.warnOnCloseWithRunningProcess
            )

            SettingsToggle(
                label: L("settings.tabs.alwaysWarnOnClose", "Always Warn Before Closing Tab"),
                help: L("settings.tabs.alwaysWarnOnClose.help", "Show a confirmation dialog before closing any tab"),
                isOn: $settings.alwaysWarnOnTabClose
            )

            SettingsToggle(
                label: L("settings.tabs.alwaysShowTabBar", "Always Show Tab Bar"),
                help: L("settings.tabs.alwaysShowTabBar.help", "Show the tab bar even when only one tab is open"),
                isOn: $settings.alwaysShowTabBar
            )

            Divider()
                .padding(.vertical, 8)

            // Tab Display
            SettingsSectionHeader(L("settings.tabs.display", "Tab Display"), icon: "eye")

            SettingsToggle(
                label: L("settings.tabs.customTitleOnly", "Custom Title Only"),
                help: L("settings.tabs.customTitleOnly.help", "When a tab has a custom title, hide all other elements (icons, path, indicators). Tabs without a custom title are unaffected."),
                isOn: $settings.customTitleOnly
            )

            SettingsToggle(
                label: L("settings.tabs.showIcons", "Tab Icons"),
                help: L("settings.tabs.showIcons.help", "Show AI product logos and dev server icons in tabs"),
                isOn: $settings.showTabIcons
            )
            .disabled(settings.customTitleOnly)

            SettingsToggle(
                label: L("settings.tabs.showPath", "Working Directory"),
                help: L("settings.tabs.showPath.help", "Show the current working directory path next to the tab title"),
                isOn: $settings.showTabPath
            )
            .disabled(settings.customTitleOnly)

            SettingsToggle(
                label: L("settings.tabs.showGitIndicator", "Git Indicator"),
                help: L("settings.tabs.showGitIndicator.help", "Show a branch icon when the tab is in a git repository"),
                isOn: $settings.showTabGitIndicator
            )
            .disabled(settings.customTitleOnly)

            SettingsToggle(
                label: L("settings.tabs.allowCTOToggle", "Allow CTO Toggle in Hover Card"),
                help: L(
                    "settings.tabs.allowCTOToggle.help",
                    "Show a toggle button in the tab hover card to control per-tab token optimization override."
                ),
                isOn: $settings.allowTabCTOToggle
            )
            .disabled(settings.customTitleOnly)

            SettingsToggle(
                label: L("settings.tabs.showBroadcastIndicator", "Broadcast Indicator"),
                help: L("settings.tabs.showBroadcastIndicator.help", "Show the broadcast icon when a tab is included in broadcast mode"),
                isOn: $settings.showTabBroadcastIndicator
            )
            .disabled(settings.customTitleOnly)

            Divider()
                .padding(.vertical, 8)

            // Appearance
            SettingsSectionHeader(L("settings.tabs.appearance", "Appearance"), icon: "paintpalette")

            SettingsToggle(
                label: L("settings.tabs.lastCommandBadge", "Last Command Badge"),
                help: L("settings.tabs.lastCommandBadge.help", "Show the most recent command in the tab status area"),
                isOn: $settings.isLastCommandBadgeEnabled
            )

            SettingsToggle(
                label: L("settings.tabs.aiProductIcons", "AI Product Logos"),
                help: L("settings.tabs.aiProductIcons.help", "Display AI product logos for detected AI CLIs in tabs"),
                isOn: $settings.isAutoTabThemeEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Keyboard
            SettingsSectionHeader(L("settings.tabs.keyboardNavigation", "Keyboard Navigation"), icon: "keyboard")

            SettingsShortcutRow(label: L("settings.tabs.newTab", "New Tab"), shortcut: "⌘T")
            SettingsShortcutRow(label: L("settings.tabs.closeTab", "Close Tab"), shortcut: "⌘W")
            SettingsShortcutRow(label: L("settings.tabs.nextTab", "Next Tab"), shortcut: "⇧⌘] or ⌃Tab or ⌥⌘→")
            SettingsShortcutRow(label: L("settings.tabs.previousTab", "Previous Tab"), shortcut: "⇧⌘[ or ⌃⇧Tab or ⌥⌘←")
            SettingsShortcutRow(label: L("settings.tabs.switchToTab", "Switch to Tab 1-9"), shortcut: "⌘1-9")
            SettingsShortcutRow(label: L("settings.tabs.renameTab", "Rename Tab"), shortcut: "⌘⌥R")
        }
    }
}
