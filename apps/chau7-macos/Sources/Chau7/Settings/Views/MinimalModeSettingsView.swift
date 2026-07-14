import SwiftUI

// MARK: - Minimal Mode Settings

struct MinimalModeSettingsView: View {
    @Bindable private var minimalMode = MinimalMode.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Settings.pageSectionSpacing) {
            // Master Toggle
            SettingsSectionHeader(L("Minimal Mode"), icon: "rectangle.compress.vertical")

            SettingsDescription(
                text: L("Minimal mode hides non-essential UI chrome to maximize terminal real estate. Toggle it quickly with a keyboard shortcut.")
            )

            SettingsToggle(
                label: L("Enable Minimal Mode"),
                help: L("Hide non-essential UI elements to maximize the terminal area"),
                isOn: $minimalMode.isEnabled
            )

            // Keyboard shortcut hint
            SettingsShortcutRow(label: L("Toggle Minimal Mode"), shortcut: "Cmd+Shift+M")

            SettingsDivider()

            // Individual Element Toggles
            SettingsSectionHeader(L("Hidden Elements"), icon: "eye.slash")

            SettingsDescription(
                text: L("Choose which UI elements are hidden when minimal mode is active.")
            )

            SettingsToggle(
                label: L("Hide Tab Bar"),
                help: L("Hide the tab bar when only a single tab is open"),
                isOn: $minimalMode.hideTabBar,
                disabled: !minimalMode.isEnabled
            )

            SettingsToggle(
                label: L("Hide Title Bar"),
                help: L("Hide title bar accessories and window controls"),
                isOn: $minimalMode.hideTitleBar,
                disabled: !minimalMode.isEnabled
            )

            SettingsToggle(
                label: L("Hide Status Bar"),
                help: L("Hide the status bar and overlay widgets at the bottom"),
                isOn: $minimalMode.hideStatusBar,
                disabled: !minimalMode.isEnabled
            )

            SettingsToggle(
                label: L("Hide Sidebar"),
                help: L("Automatically close the sidebar when minimal mode is activated"),
                isOn: $minimalMode.hideSidebar,
                disabled: !minimalMode.isEnabled
            )

            SettingsDivider()

            // Status Summary
            SettingsSectionHeader(L("Status"), icon: "info.circle")

            SettingsStatusGrid(items: statusItems)
        }
    }

    private var statusItems: [SettingsStatusItem] {
        [
            SettingsStatusItem(
                id: "minimalMode",
                label: L("Minimal Mode"),
                value: enabledDisabled(minimalMode.isEnabled),
                systemImage: "rectangle.compress.vertical",
                tone: enabledTone(minimalMode.isEnabled)
            ),
            hiddenElementItem(
                id: "tabBar",
                label: L("Tab Bar"),
                isHidden: minimalMode.hideTabBar,
                systemImage: "rectangle.topthird.inset.filled"
            ),
            hiddenElementItem(
                id: "titleBar",
                label: L("Title Bar"),
                isHidden: minimalMode.hideTitleBar,
                systemImage: "macwindow"
            ),
            hiddenElementItem(
                id: "statusBar",
                label: L("Status Bar"),
                isHidden: minimalMode.hideStatusBar,
                systemImage: "rectangle.bottomthird.inset.filled"
            ),
            hiddenElementItem(
                id: "sidebar",
                label: L("Sidebar"),
                isHidden: minimalMode.hideSidebar,
                systemImage: "sidebar.left"
            )
        ]
    }

    private func hiddenElementItem(id: String, label: String, isHidden: Bool, systemImage: String) -> SettingsStatusItem {
        SettingsStatusItem(
            id: id,
            label: label,
            value: isHidden ? L("status.hidden", "Hidden") : L("status.visible", "Visible"),
            systemImage: systemImage,
            tone: isHidden ? .enabled : .disabled
        )
    }

    private func enabledDisabled(_ isEnabled: Bool) -> String {
        isEnabled ? L("status.enabled", "Enabled") : L("status.disabled", "Disabled")
    }

    private func enabledTone(_ isEnabled: Bool) -> SettingsStatusTone {
        isEnabled ? .enabled : .disabled
    }
}
