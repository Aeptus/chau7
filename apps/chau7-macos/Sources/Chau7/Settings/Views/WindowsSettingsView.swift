import SwiftUI
import AppKit

// MARK: - Windows Settings

struct WindowsSettingsView: View {
    @Bindable private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Settings.pageSectionSpacing) {
            // Interface
            SettingsSectionHeader(L("settings.windows.interface", "Interface"), icon: "circle.lefthalf.filled")

            SettingsPicker(
                label: L("settings.appearance.appearance", "Appearance"),
                help: L("settings.appearance.appearance.help", "Choose light, dark, or match system appearance"),
                selection: $settings.appTheme,
                options: AppTheme.allCases.map { (value: $0, label: $0.displayName) },
                anchorID: "appTheme"
            )

            SettingsToggle(
                label: L("settings.windows.menuBarOnlyMode", "Menu Bar Only Mode"),
                help: L("settings.windows.menuBarOnlyMode.help", "Run Chau7 from the menu bar without a Dock icon. Takes effect after restarting Chau7."),
                isOn: $settings.menuBarOnlyMode
            )

            SettingsToggle(
                label: L("settings.windows.alwaysShowToolbar", "Always Show Toolbar in Fullscreen"),
                help: L("settings.windows.alwaysShowToolbar.help", "Keep the toolbar visible when the window is in fullscreen mode"),
                isOn: $settings.alwaysShowToolbarInFullscreen,
                anchorID: "fullscreenToolbar"
            )

            SettingsDivider()

            // Window Behavior
            SettingsSectionHeader(L("settings.windows.windowBehavior", "Window Behavior"), icon: "macwindow")

            SettingsSlider(
                label: L("settings.appearance.windowOpacity", "Window Opacity"),
                help: L("settings.appearance.windowOpacity.help", "Transparency level for terminal window (30-100%)"),
                value: Binding(
                    get: { settings.windowOpacity * 100 },
                    set: { settings.windowOpacity = $0 / 100 }
                ),
                range: 30 ... 100,
                step: 5,
                format: "%.0f",
                suffix: "%",
                anchorID: "opacity"
            )

            SettingsToggle(
                label: L("settings.windows.floatingWindow", "Keep Windows Above Other Apps"),
                help: L("settings.windows.floatingWindow.help", "Keep Chau7 terminal windows above normal app windows."),
                isOn: $settings.windowFloating,
                anchorID: "windowFloating"
            )

            SettingsDivider()

            // Overlay
            SettingsSectionHeader(L("settings.windows.overlayWindow", "Overlay Window"), icon: "rectangle.inset.filled")

            SettingsButtonRow(buttons: [
                .init(title: L("settings.windows.showOverlay", "Show Overlay"), icon: "rectangle.inset.filled") {
                    (NSApp.delegate as? AppDelegate)?.showOverlay()
                },
                .init(title: L("settings.windows.resetPosition", "Reset Position"), icon: "arrow.counterclockwise") {
                    FeatureSettings.shared.resetOverlayOffsets()
                }
            ])

            SettingsDescription(text: L("settings.windows.overlayDescription", "The overlay window remembers its position per workspace and restores it automatically."))

            SettingsDivider()

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

            SettingsDivider()

            SettingsButtonRow(buttons: [
                .init(title: L("settings.windows.resetToDefaults", "Reset Windows to Defaults"), style: .plain) {
                    settings.resetWindowsToDefaults()
                }
            ], alignment: .trailing)
        }
    }
}
