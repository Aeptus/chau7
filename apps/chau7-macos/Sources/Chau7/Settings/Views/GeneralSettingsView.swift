import SwiftUI
import AppKit

// MARK: - General Settings

struct GeneralSettingsView: View {
    var model: AppModel
    @Bindable private var settings = FeatureSettings.shared
    @State private var showResetConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Settings.pageSectionSpacing) {
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

            SettingsDivider()

            // Language
            SettingsSectionHeader(L("settings.general.language", "Language"), icon: "globe")

            SettingsPicker(
                label: L("settings.general.language.label", "App Language"),
                help: L("settings.general.language.help", "Choose the language for the Chau7 interface"),
                selection: $settings.appLanguage,
                options: AppLanguage.allCases.map { (value: $0, label: $0.displayName) }
            )

            SettingsDescription(text: L("settings.general.language.note", "Some changes may require restarting the app"))

            SettingsDivider()

            // Config File
            ConfigFileSettingsView()

            SettingsDivider()

            // Status
            SettingsSectionHeader(L("settings.general.status", "Status"), icon: "info.circle")

            SettingsStatusGrid(items: statusItems)

            SettingsDivider()

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

            SettingsDivider()

            // Reset
            SettingsSectionHeader(L("settings.general.reset", "Reset"), icon: "arrow.counterclockwise")

            SettingsButtonRow(buttons: [
                .init(title: L("settings.general.reset.all", "Reset All Settings to Defaults"), style: .plain) {
                    showResetConfirmation = true
                }
            ], alignment: .trailing)
        }
        .alert(L("settings.general.reset.confirm.title", "Reset All Settings?"), isPresented: $showResetConfirmation) {
            Button(L("button.cancel", "Cancel"), role: .cancel) {}
            Button(L("button.reset", "Reset"), role: .destructive) {
                settings.resetAllToDefaults()
            }
        } message: {
            Text(L("settings.general.reset.confirm.message", "This will reset all Chau7 settings to their default values. This action cannot be undone."))
        }
    }

    private var statusItems: [SettingsStatusItem] {
        [
            SettingsStatusItem(
                id: "notifications",
                label: L("settings.general.status.notifications", "Alerts"),
                value: model.notificationStatus,
                systemImage: "bell.badge",
                tone: .neutral
            ),
            SettingsStatusItem(
                id: "eventMonitoring",
                label: L("settings.general.status.eventMonitoring", "Event Monitoring"),
                value: activePaused(model.isMonitoring),
                systemImage: "waveform.path.ecg",
                tone: activeTone(model.isMonitoring)
            ),
            SettingsStatusItem(
                id: "historyMonitoring",
                label: L("settings.general.status.historyMonitoring", "History Monitoring"),
                value: activePaused(model.isIdleMonitoring),
                systemImage: "clock.arrow.circlepath",
                tone: activeTone(model.isIdleMonitoring)
            ),
            SettingsStatusItem(
                id: "terminalMonitoring",
                label: L("settings.general.status.terminalMonitoring", "Terminal Monitoring"),
                value: activePaused(model.isTerminalMonitoring),
                systemImage: "terminal",
                tone: activeTone(model.isTerminalMonitoring)
            ),
            SettingsStatusItem(
                id: "launchAtLogin",
                label: L("settings.general.launchAtLogin", "Launch at Login"),
                value: enabledDisabled(settings.launchAtLogin),
                systemImage: "power",
                tone: enabledTone(settings.launchAtLogin)
            ),
            SettingsStatusItem(
                id: "menuBarOnly",
                label: L("settings.windows.menuBarOnlyMode", "Menu Bar Only Mode"),
                value: enabledDisabled(settings.menuBarOnlyMode),
                systemImage: "menubar.rectangle",
                tone: enabledTone(settings.menuBarOnlyMode)
            ),
            SettingsStatusItem(
                id: "mcp",
                label: L("settings.mcpControl", "Agent Control"),
                value: enabledDisabled(settings.mcpEnabled),
                systemImage: "face.dashed",
                tone: enabledTone(settings.mcpEnabled)
            ),
            SettingsStatusItem(
                id: "defaultDirectory",
                label: L("settings.general.defaultDirectory", "Default Directory"),
                value: settings.defaultStartDirectory.isEmpty ? "~" : settings.defaultStartDirectory,
                systemImage: "folder",
                tone: .neutral
            )
        ]
    }

    private func activePaused(_ isActive: Bool) -> String {
        isActive ? L("status.active", "Active") : L("status.paused", "Paused")
    }

    private func enabledDisabled(_ isEnabled: Bool) -> String {
        isEnabled ? L("status.enabled", "Enabled") : L("status.disabled", "Disabled")
    }

    private func activeTone(_ isActive: Bool) -> SettingsStatusTone {
        isActive ? .active : .paused
    }

    private func enabledTone(_ isEnabled: Bool) -> SettingsStatusTone {
        isEnabled ? .enabled : .disabled
    }
}
