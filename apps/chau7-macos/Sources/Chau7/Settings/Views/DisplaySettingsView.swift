import SwiftUI
import AppKit

// MARK: - Display Settings

struct DisplaySettingsView: View {
    @Bindable private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Settings.pageSectionSpacing) {
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

            SettingsDivider()

            // Reset Button
            SettingsButtonRow(buttons: [
                .init(title: L("settings.display.resetToDefaults", "Reset Display to Defaults"), style: .plain) {
                    settings.resetDisplayToDefaults()
                }
            ], alignment: .trailing)
        }
    }
}
