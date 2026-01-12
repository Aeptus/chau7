import SwiftUI

// MARK: - Tabs Settings

struct TabsSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Behavior
            SettingsSectionHeader("Behavior", icon: "rectangle.stack.badge.plus")

            SettingsPicker(
                label: "New Tab Position",
                help: "Where to insert newly created tabs",
                selection: $settings.newTabPosition,
                options: [
                    (value: "end", label: "At End"),
                    (value: "after", label: "After Current")
                ]
            )

            SettingsPicker(
                label: "Last Tab Close",
                help: "Choose what happens when closing the final tab",
                selection: $settings.lastTabCloseBehavior,
                options: LastTabCloseBehavior.allCases.map { (value: $0, label: $0.displayName) }
            )

            SettingsToggle(
                label: "Always Show Tab Bar",
                help: "Show the tab bar even when only one tab is open",
                isOn: $settings.alwaysShowTabBar
            )

            Divider()
                .padding(.vertical, 8)

            // Appearance
            SettingsSectionHeader("Appearance", icon: "paintpalette")

            SettingsToggle(
                label: "Last Command Badge",
                help: "Show the most recent command in the tab status area",
                isOn: $settings.isLastCommandBadgeEnabled
            )

            SettingsToggle(
                label: "AI Product Icons",
                help: "Display SF Symbol icons for detected AI CLIs in tabs",
                isOn: $settings.isAutoTabThemeEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Keyboard
            SettingsSectionHeader("Keyboard Navigation", icon: "keyboard")

            VStack(alignment: .leading, spacing: 4) {
                SettingsShortcutRow(label: "New Tab", shortcut: "⌘T")
                SettingsShortcutRow(label: "Close Tab", shortcut: "⌘W")
                SettingsShortcutRow(label: "Next Tab", shortcut: "⌘⇧] or ⌃Tab")
                SettingsShortcutRow(label: "Previous Tab", shortcut: "⌘⇧[ or ⌃⇧Tab")
                SettingsShortcutRow(label: "Switch to Tab 1-9", shortcut: "⌘1-9")
                SettingsShortcutRow(label: "Rename Tab", shortcut: "⌘⇧R")
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)
        }
    }
}
