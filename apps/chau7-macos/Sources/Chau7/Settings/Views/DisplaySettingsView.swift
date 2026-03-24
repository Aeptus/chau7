import SwiftUI
import AppKit

// MARK: - Display Settings

struct DisplaySettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Display Enhancements
            SettingsSectionHeader(L("settings.appearance.displayEnhancements", "Display Enhancements"), icon: "eye")

            SettingsToggle(
                label: L("settings.appearance.syntaxHighlighting", "Syntax Highlighting"),
                help: L("settings.appearance.syntaxHighlighting.help", "Highlight code syntax in terminal output for better readability"),
                isOn: $settings.isSyntaxHighlightEnabled
            )

            SettingsToggle(
                label: L("settings.appearance.clickableURLs", "Clickable URLs"),
                help: L("settings.appearance.clickableURLs.help", "Make URLs in terminal output clickable to open in browser"),
                isOn: $settings.isClickableURLsEnabled
            )

            SettingsToggle(
                label: L("settings.appearance.inlineImages", "Inline Images"),
                help: L("settings.appearance.inlineImages.help", "Display images inline using iTerm2's imgcat protocol (use imgcat command)"),
                isOn: $settings.isInlineImagesEnabled
            )

            SettingsToggle(
                label: L("settings.appearance.prettyPrintJSON", "Pretty Print JSON"),
                help: L("settings.appearance.prettyPrintJSON.help", "Automatically format JSON output with indentation and colors"),
                isOn: $settings.isJSONPrettyPrintEnabled
            )

            SettingsToggle(
                label: L("settings.appearance.lineTimestamps", "Line Timestamps"),
                help: L("settings.appearance.lineTimestamps.help", "Show timestamps next to each terminal line"),
                isOn: $settings.isLineTimestampsEnabled
            )

            if settings.isLineTimestampsEnabled {
                SettingsTextField(
                    label: L("settings.appearance.timestampFormat", "Timestamp Format"),
                    help: L("settings.appearance.timestampFormat.help", "Date format string (e.g., HH:mm:ss, yyyy-MM-dd HH:mm)"),
                    placeholder: "HH:mm:ss",
                    text: $settings.timestampFormat,
                    width: 150,
                    monospaced: true
                )
            }

            Divider()
                .padding(.vertical, 8)

            // Window & Layout
            SettingsSectionHeader(L("settings.display.windowLayout", "Window & Layout"), icon: "macwindow")

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

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            SettingsButtonRow(buttons: [
                .init(title: L("settings.display.resetToDefaults", "Reset Display to Defaults"), style: .plain) {
                    settings.resetDisplayToDefaults()
                }
            ], alignment: .trailing)
        }
    }
}
