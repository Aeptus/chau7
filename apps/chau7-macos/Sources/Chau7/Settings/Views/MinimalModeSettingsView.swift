import SwiftUI

// MARK: - Minimal Mode Settings

struct MinimalModeSettingsView: View {
    @ObservedObject private var minimalMode = MinimalMode.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
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

            Divider()
                .padding(.vertical, 8)

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

            Divider()
                .padding(.vertical, 8)

            // Status Summary
            SettingsSectionHeader(L("Status"), icon: "info.circle")

            VStack(alignment: .leading, spacing: 6) {
                statusRow(label: "Minimal Mode", active: minimalMode.isEnabled)
                if minimalMode.isEnabled {
                    statusRow(label: "Tab Bar", active: minimalMode.hideTabBar)
                    statusRow(label: "Title Bar", active: minimalMode.hideTitleBar)
                    statusRow(label: "Status Bar", active: minimalMode.hideStatusBar)
                    statusRow(label: "Sidebar", active: minimalMode.hideSidebar)
                }
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
    }

    // MARK: - Status Row

    @ViewBuilder
    private func statusRow(label: String, active: Bool) -> some View {
        HStack {
            Circle()
                .fill(active ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
            Text(label)
                .font(.system(size: 12))
            Spacer()
            Text(active ? "Hidden" : "Visible")
                .font(.system(size: 11))
                .foregroundStyle(active ? .green : .secondary)
        }
    }
}
