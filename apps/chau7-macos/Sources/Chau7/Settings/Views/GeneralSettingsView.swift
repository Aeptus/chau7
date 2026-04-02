import SwiftUI
import AppKit

// MARK: - General Settings

struct GeneralSettingsView: View {
    var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Startup
            SettingsSectionHeader(L("settings.general.startup", "Startup"), icon: "power")

            SettingsToggle(
                label: L("settings.general.launchAtLogin", "Launch at Login"),
                help: L("settings.general.launchAtLogin.help", "Automatically start Chau7 when you log in to your Mac"),
                isOn: $settings.launchAtLogin
            )

            SettingsDirectoryField(
                label: L("settings.general.defaultDirectory", "Default Directory"),
                help: L("settings.general.defaultDirectory.help", "Starting directory for new terminal sessions"),
                placeholder: "~",
                text: $settings.defaultStartDirectory,
                width: 280,
                monospaced: true,
                buttonTitle: L("settings.general.defaultDirectory.choose", "Choose...")
            )

            Divider()
                .padding(.vertical, 8)

            // Language
            SettingsSectionHeader(L("settings.general.language", "Language"), icon: "globe")

            SettingsPicker(
                label: L("settings.general.language.label", "App Language"),
                help: L("settings.general.language.help", "Choose the language for the Chau7 interface"),
                selection: $settings.appLanguage,
                options: AppLanguage.allCases.map { (value: $0, label: $0.displayName) }
            )

            SettingsDescription(text: L("settings.general.language.note", "Some changes may require restarting the app"))

            Divider()
                .padding(.vertical, 8)

            // Config File
            ConfigFileSettingsView()

            Divider()
                .padding(.vertical, 8)

            // Status
            SettingsSectionHeader(L("settings.general.status", "Status"), icon: "info.circle")

            SettingsInfoRow(label: L("settings.general.status.notifications", "Notifications"), value: model.notificationStatus, monospaced: true)
            SettingsInfoRow(
                label: L("settings.general.status.eventMonitoring", "Event Monitoring"),
                value: model.isMonitoring ? L("status.active", "Active") : L("status.paused", "Paused"),
                valueColor: model.isMonitoring ? .green : .secondary,
                monospaced: true
            )
            SettingsInfoRow(
                label: L("settings.general.status.historyMonitoring", "History Monitoring"),
                value: model.isIdleMonitoring ? L("status.active", "Active") : L("status.paused", "Paused"),
                valueColor: model.isIdleMonitoring ? .green : .secondary,
                monospaced: true
            )
            SettingsInfoRow(
                label: L("settings.general.status.terminalMonitoring", "Terminal Monitoring"),
                value: model.isTerminalMonitoring ? L("status.active", "Active") : L("status.paused", "Paused"),
                valueColor: model.isTerminalMonitoring ? .green : .secondary,
                monospaced: true
            )

            Divider()
                .padding(.vertical, 8)

            // Actions
            SettingsSectionHeader(L("settings.general.actions", "Actions"), icon: "hand.tap")

            SettingsButtonRow(buttons: [
                .init(title: L("settings.general.actions.showOverlay", "Show Overlay"), icon: "rectangle.inset.filled") {
                    (NSApp.delegate as? AppDelegate)?.showOverlay()
                },
                .init(title: L("settings.general.actions.resetWindowPositions", "Reset Window Positions"), icon: "arrow.counterclockwise") {
                    FeatureSettings.shared.resetOverlayOffsets()
                },
                .init(title: L("settings.general.actions.debugConsole", "Debug Console"), icon: "terminal") {
                    DebugConsoleController.shared.show()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Reset
            SettingsSectionHeader(L("settings.general.reset", "Reset"), icon: "arrow.counterclockwise")

            SettingsButtonRow(buttons: [
                .init(title: L("settings.general.reset.all", "Reset All Settings to Defaults"), style: .plain) {
                    showResetConfirmation = true
                }
            ], alignment: .trailing)
        }
        .localized()
        .alert(L("settings.general.reset.confirm.title", "Reset All Settings?"), isPresented: $showResetConfirmation) {
            Button(L("button.cancel", "Cancel"), role: .cancel) {}
            Button(L("button.reset", "Reset"), role: .destructive) {
                settings.resetAllToDefaults()
            }
        } message: {
            Text(L("settings.general.reset.confirm.message", "This will reset all Chau7 settings to their default values. This action cannot be undone."))
        }
    }
}
