import SwiftUI
import AppKit

// MARK: - Windows Settings

struct WindowsSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Overlay
            SettingsSectionHeader(L("settings.windows.overlayWindow", "Overlay Window"), icon: "macwindow")

            SettingsButtonRow(buttons: [
                .init(title: L("settings.windows.showOverlay", "Show Overlay"), icon: "rectangle.inset.filled") {
                    (NSApp.delegate as? AppDelegate)?.showOverlay()
                },
                .init(title: L("settings.windows.resetPosition", "Reset Position"), icon: "arrow.counterclockwise") {
                    FeatureSettings.shared.resetOverlayOffsets()
                }
            ])

            SettingsDescription(text: L("settings.windows.overlayDescription", "The overlay window remembers its position per workspace and restores it automatically."))

            Divider()
                .padding(.vertical, 8)

            // Split Panes
            SettingsSectionHeader(L("settings.windows.splitPanes", "Split Panes"), icon: "rectangle.split.2x1")

            SettingsToggle(
                label: L("settings.windows.enableSplitPanes", "Enable Split Panes"),
                help: L("settings.windows.enableSplitPanes.help", "Allow splitting terminal into multiple panes within a single tab"),
                isOn: $settings.isSplitPanesEnabled
            )

            if settings.isSplitPanesEnabled {
                SettingsShortcutRow(label: L("settings.windows.splitHorizontal", "Split Horizontal"), shortcut: "⌘⌥H")
                SettingsShortcutRow(label: L("settings.windows.splitVertical", "Split Vertical"), shortcut: "⌘⌥V")
                SettingsShortcutRow(label: L("settings.windows.navigatePanes", "Navigate Panes"), shortcut: "⌘⌥Arrow")
            }
        }
    }
}
