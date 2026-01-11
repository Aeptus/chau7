import SwiftUI
import AppKit

// MARK: - Windows Settings

struct WindowsSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Overlay
            SettingsSectionHeader("Overlay Window", icon: "macwindow")

            SettingsButtonRow(buttons: [
                .init(title: "Show Overlay", icon: "rectangle.inset.filled") {
                    (NSApp.delegate as? AppDelegate)?.showOverlay()
                },
                .init(title: "Reset Position", icon: "arrow.counterclockwise") {
                    FeatureSettings.shared.resetOverlayOffsets()
                }
            ])

            SettingsDescription(text: "The overlay window remembers its position per workspace and restores it automatically.")

            Divider()
                .padding(.vertical, 8)

            // Dropdown Terminal
            SettingsSectionHeader("Dropdown Terminal", icon: "rectangle.topthird.inset.filled")

            SettingsToggle(
                label: "Enable Dropdown",
                help: "Show a Quake-style dropdown terminal with a global hotkey",
                isOn: $settings.isDropdownEnabled
            )

            if settings.isDropdownEnabled {
                SettingsTextField(
                    label: "Hotkey",
                    help: "Global keyboard shortcut to toggle dropdown (e.g., ⌃`, ⌘Space)",
                    placeholder: "ctrl+`",
                    text: $settings.dropdownHotkey,
                    width: 120,
                    monospaced: true
                )

                SettingsRow("Height", help: "Dropdown height as percentage of screen (10-100%)") {
                    HStack(spacing: 8) {
                        Slider(value: $settings.dropdownHeight, in: 0.1...1.0, step: 0.05)
                            .frame(width: 150)
                        Text("\(Int(settings.dropdownHeight * 100))%")
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 50, alignment: .trailing)
                    }
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Split Panes
            SettingsSectionHeader("Split Panes", icon: "rectangle.split.2x1")

            SettingsToggle(
                label: "Enable Split Panes",
                help: "Allow splitting terminal into multiple panes within a single tab",
                isOn: $settings.isSplitPanesEnabled
            )

            if settings.isSplitPanesEnabled {
                VStack(alignment: .leading, spacing: 4) {
                    SettingsShortcutRow(label: "Split Horizontal", shortcut: "⌘D")
                    SettingsShortcutRow(label: "Split Vertical", shortcut: "⌘⇧D")
                    SettingsShortcutRow(label: "Navigate Panes", shortcut: "⌘⌥Arrow")
                }
                .padding(8)
                .background(Color.secondary.opacity(0.05))
                .cornerRadius(8)
            }
        }
    }
}
