import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Sync & Backup Settings

struct ProfilesBackupSettingsView: View {
    @Bindable private var settings = FeatureSettings.shared
    @State private var switcher = ProfileAutoSwitcher()
    @State private var showImportSheet = false
    @State private var showResetConfirmation = false
    @State private var operationMessage: SettingsBackupOperationMessage?

    var body: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Settings.pageSectionSpacing) {
            // Profile Auto-Switch
            ProfileAutoSwitchSettingsView(switcher: switcher, settings: settings)

            SettingsDivider()

            // iCloud Sync
            SettingsSectionHeader(L("settings.general.icloud", "iCloud Sync"), icon: "icloud")

            SettingsToggle(
                label: L("settings.general.icloud.sync", "Sync Settings via iCloud"),
                help: L("settings.general.icloud.sync.help", "Keep your Chau7 settings synchronized across all your Macs"),
                isOn: $settings.iCloudSyncEnabled
            )

            if settings.iCloudSyncEnabled {
                SettingsButtonRow(buttons: [
                    .init(title: L("settings.general.icloud.syncNow", "Sync Now"), icon: "arrow.triangle.2.circlepath") {
                        operationMessage = SettingsBackupOperationMessage(syncResult: settings.forceSyncToiCloud())
                    },
                    .init(title: L("settings.general.icloud.restore", "Restore from iCloud"), icon: "icloud.and.arrow.down") {
                        operationMessage = SettingsBackupOperationMessage(restoreResult: settings.syncFromiCloud())
                    }
                ])
            }

            SettingsDivider()

            // Import/Export
            SettingsSectionHeader(L("settings.general.backup", "Settings Backup"), icon: "square.and.arrow.up.on.square")

            Text(L("settings.general.backup.description", "Export your settings to a JSON file or import from a backup."))
                .font(.caption)
                .foregroundStyle(.secondary)

            SettingsButtonRow(buttons: [
                .init(title: L("settings.general.backup.export", "Export Settings..."), icon: "square.and.arrow.up") {
                    exportSettings()
                },
                .init(title: L("settings.general.backup.import", "Import Settings..."), icon: "square.and.arrow.down") {
                    showImportSheet = true
                }
            ])
            .settingsSearchAnchor("export")

            if let operationMessage {
                SettingsBackupOperationMessageView(message: operationMessage)
            }

            SettingsDivider()

            // Reset
            SettingsSectionHeader(L("settings.general.reset", "Reset"), icon: "arrow.counterclockwise")

            SettingsButtonRow(buttons: [
                .init(
                    title: L("settings.general.reset.all", "Reset All Settings to Defaults"),
                    style: .plain,
                    role: .destructive
                ) {
                    showResetConfirmation = true
                }
            ], alignment: .trailing)
        }
        .fileImporter(
            isPresented: $showImportSheet,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            importSettings(result: result)
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

    private func exportSettings() {
        guard let data = settings.exportSettings() else {
            operationMessage = .error(L("settings.backup.export.prepareFailed", "Could not prepare settings for export."))
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "chau7-settings.json"
        panel.title = L("dialog.exportSettings.title", "Export Chau7 Settings")

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
                operationMessage = .success(
                    String(
                        format: L("settings.backup.export.success", "Exported settings to %@."),
                        url.lastPathComponent
                    )
                )
            } catch {
                Log.error("Failed to export settings: \(error)")
                operationMessage = .error(
                    String(
                        format: L("settings.backup.export.failed", "Export failed: %@"),
                        error.localizedDescription
                    )
                )
            }
        }
    }

    private func importSettings(result: Result<[URL], Error>) {
        operationMessage = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let data = try Data(contentsOf: url)
                if settings.importSettings(from: data) {
                    Log.info("Settings imported successfully")
                    operationMessage = .success(
                        String(
                            format: L("settings.backup.import.success", "Imported settings from %@."),
                            url.lastPathComponent
                        )
                    )
                } else {
                    operationMessage = .error(L("settings.backup.import.invalid", "Invalid settings file format."))
                }
            } catch {
                operationMessage = .error(
                    String(
                        format: L("settings.backup.import.readFailed", "Failed to read file: %@"),
                        error.localizedDescription
                    )
                )
            }
        case .failure(let error):
            operationMessage = .error(
                String(
                    format: L("settings.backup.import.failed", "Import failed: %@"),
                    error.localizedDescription
                )
            )
        }
    }
}

private struct SettingsBackupOperationMessage: Equatable {
    enum Tone {
        case success
        case warning
        case error

        var color: Color {
            switch self {
            case .success: .green
            case .warning: .orange
            case .error: .red
            }
        }

        var icon: String {
            switch self {
            case .success: "checkmark.circle"
            case .warning: "exclamationmark.triangle"
            case .error: "xmark.octagon"
            }
        }
    }

    let text: String
    let tone: Tone

    init(text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    static func success(_ text: String) -> SettingsBackupOperationMessage {
        SettingsBackupOperationMessage(text: text, tone: .success)
    }

    static func warning(_ text: String) -> SettingsBackupOperationMessage {
        SettingsBackupOperationMessage(text: text, tone: .warning)
    }

    static func error(_ text: String) -> SettingsBackupOperationMessage {
        SettingsBackupOperationMessage(text: text, tone: .error)
    }

    init(syncResult: FeatureSettings.SettingsCloudSyncResult) {
        switch syncResult {
        case .synced:
            self = .success(L("settings.icloud.sync.success", "Settings synced to iCloud."))
        case .syncFailed:
            self = .error(L("settings.icloud.sync.failed", "iCloud did not accept the sync request."))
        case .exportFailed:
            self = .error(L("settings.icloud.sync.exportFailed", "Could not prepare settings for iCloud sync."))
        case .disabled:
            self = .warning(L("settings.icloud.sync.disabled", "Turn on iCloud Sync before syncing."))
        case .skippedInTests:
            self = .warning(L("settings.icloud.sync.unavailable", "iCloud sync is unavailable in this environment."))
        }
    }

    init(restoreResult: FeatureSettings.SettingsCloudRestoreResult) {
        switch restoreResult {
        case .restored:
            self = .success(L("settings.icloud.restore.success", "Restored newer settings from iCloud."))
        case .restoredLegacy:
            self = .success(L("settings.icloud.restore.legacySuccess", "Restored settings from iCloud."))
        case .notNewer:
            self = .warning(L("settings.icloud.restore.notNewer", "iCloud settings are not newer than this Mac's settings."))
        case .missing:
            self = .warning(L("settings.icloud.restore.missing", "No iCloud settings backup was found."))
        case .invalid:
            self = .error(L("settings.icloud.restore.invalid", "Could not restore settings from iCloud."))
        case .disabled:
            self = .warning(L("settings.icloud.restore.disabled", "Turn on iCloud Sync before restoring."))
        case .skippedInTests:
            self = .warning(L("settings.icloud.restore.unavailable", "iCloud restore is unavailable in this environment."))
        }
    }
}

private struct SettingsBackupOperationMessageView: View {
    let message: SettingsBackupOperationMessage

    var body: some View {
        HStack(alignment: .top, spacing: Chau7Style.Spacing.xSmall) {
            Image(systemName: message.tone.icon)
                .foregroundStyle(message.tone.color)
                .frame(width: 14)
                .accessibilityHidden(true)
            Text(message.text)
                .font(.caption2)
                .foregroundStyle(message.tone.color)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Chau7Style.Settings.rowVerticalPadding)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message.text)
    }
}
