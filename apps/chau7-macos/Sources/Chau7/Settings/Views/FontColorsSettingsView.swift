import SwiftUI
import AppKit

// MARK: - Font & Colors Settings

struct FontColorsSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Live Preview Panel
            SettingsSectionHeader(L("settings.appearance.livePreview", "Live Preview"), icon: "rectangle.inset.filled.and.cursorarrow")

            LiveTerminalPreview(settings: settings)
                .padding(.bottom, 8)

            Divider()
                .padding(.vertical, 8)

            // Font Settings
            SettingsSectionHeader(L("settings.appearance.font", "Font"), icon: "textformat")

            SettingsPicker(
                label: L("settings.appearance.fontFamily", "Font Family"),
                help: L("settings.appearance.fontFamily.help", "Choose a monospace font for the terminal"),
                selection: $settings.fontFamily,
                options: FeatureSettings.availableFonts.map { (value: $0, label: $0) }
            )

            SettingsStepper(
                label: L("settings.appearance.fontSize", "Font Size"),
                help: L("settings.appearance.fontSize.help", "Terminal font size in points (8-72)"),
                value: $settings.fontSize,
                range: 8...72,
                suffix: " pt"
            )

            SettingsSlider(
                label: L("settings.appearance.defaultZoom", "Default Zoom"),
                help: L("settings.appearance.defaultZoom.help", "Scale new terminal sessions (50-200%)"),
                value: Binding(
                    get: { Double(settings.defaultZoomPercent) },
                    set: { settings.defaultZoomPercent = Int($0) }
                ),
                range: 50...200,
                step: 5,
                format: "%.0f",
                suffix: "%"
            )

            // Font Preview
            Text(L("settings.appearance.fontPreview", "The quick brown fox jumps over the lazy dog"))
                .font(.custom(settings.fontFamily, size: CGFloat(settings.fontSize)))
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
                .padding(.vertical, 8)

            // Color Scheme
            SettingsSectionHeader(L("settings.appearance.colorScheme", "Color Scheme"), icon: "paintpalette")

            SettingsPicker(
                label: L("settings.appearance.scheme", "Scheme"),
                help: L("settings.appearance.scheme.help", "Choose a terminal color scheme preset"),
                selection: $settings.colorSchemeName,
                options: TerminalColorScheme.allPresets.map { (value: $0.name, label: $0.name) }
            )

            // Color Preview
            ColorSchemePreview(scheme: settings.currentColorScheme)
                .padding(.vertical, 8)

            Divider()
                .padding(.vertical, 8)

            // Window Transparency
            SettingsSectionHeader(L("settings.appearance.window", "Window"), icon: "square.on.square.dashed")

            SettingsSlider(
                label: L("settings.appearance.windowOpacity", "Window Opacity"),
                help: L("settings.appearance.windowOpacity.help", "Transparency level for terminal window (30-100%)"),
                value: Binding(
                    get: { settings.windowOpacity * 100 },
                    set: { settings.windowOpacity = $0 / 100 }
                ),
                range: 30...100,
                step: 5,
                format: "%.0f",
                suffix: "%"
            )

            Divider()
                .padding(.vertical, 8)

            // Theme
            SettingsSectionHeader(L("settings.appearance.systemTheme", "System Theme"), icon: "circle.lefthalf.filled")

            SettingsPicker(
                label: L("settings.appearance.appearance", "Appearance"),
                help: L("settings.appearance.appearance.help", "Choose light, dark, or match system appearance"),
                selection: $settings.appTheme,
                options: AppTheme.allCases.map { (value: $0, label: $0.displayName) }
            )

            Divider()
                .padding(.vertical, 8)

            // AI Theming
            SettingsSectionHeader(L("settings.appearance.aiTabTheming", "AI Tab Theming"), icon: "sparkles")

            SettingsToggle(
                label: L("settings.appearance.autoTabThemes", "Auto Tab Themes"),
                help: L("settings.appearance.autoTabThemes.help", "Automatically color tabs based on the detected AI CLI (Claude = purple, Codex = green, etc.)"),
                isOn: $settings.isAutoTabThemeEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            SettingsButtonRow(buttons: [
                .init(title: L("settings.appearance.resetToDefaults", "Reset Appearance to Defaults"), style: .plain) {
                    settings.resetAppearanceToDefaults()
                }
            ], alignment: .trailing)
        }
    }
}
