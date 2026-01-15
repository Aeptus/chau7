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
                label: L("settings.tabs.alwaysShowTabBar", "Always Show Tab Bar"),
                help: L("settings.tabs.alwaysShowTabBar.help", "Show the tab bar even when only one tab is open"),
                isOn: $settings.alwaysShowTabBar
            )

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
            SettingsShortcutRow(label: L("settings.tabs.nextTab", "Next Tab"), shortcut: "⌘⌥]")
            SettingsShortcutRow(label: L("settings.tabs.previousTab", "Previous Tab"), shortcut: "⌘⌥[")
            SettingsShortcutRow(label: L("settings.tabs.switchToTab", "Switch to Tab 1-9"), shortcut: "⌘1-9")
            SettingsShortcutRow(label: L("settings.tabs.renameTab", "Rename Tab"), shortcut: "⌘⌥R")
        }
    }
}
