import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Sync & Backup Settings

struct ProfilesBackupSettingsView: View {
    @Bindable private var settings = FeatureSettings.shared
    @State private var switcher = ProfileAutoSwitcher.shared
    @State private var showImportSheet = false
    @State private var showImportConfirmation = false
    @State private var showRestoreConfirmation = false
    @State private var showResetConfirmation = false
    @State private var pendingImport: PendingSettingsImport?
    @State private var operationMessage: SettingsBackupOperationMessage?

    var body: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Settings.pageSectionSpacing) {
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
                        showRestoreConfirmation = true
                    }
                ])
            }

            SettingsDivider()

            // Recovery
            SettingsSectionHeader(L("settings.backup.recovery", "Recovery"), icon: "arrow.counterclockwise", anchorID: "resetSettings")

            SettingsButtonRow(buttons: [
                .init(
                    title: L("settings.general.reset.all", "Reset All Settings to Defaults"),
                    style: .plain,
                    role: .destructive
                ) {
                    showResetConfirmation = true
                }
            ], alignment: .trailing)

            SettingsDivider()

            SettingsAdvancedDisclosure(
                L("settings.profileAutomation", "Profile Automation"),
                icon: "arrow.triangle.swap",
                searchAnchorIDs: ["profileAutoSwitch"]
            ) {
                ProfileAutoSwitchSettingsView(switcher: switcher, settings: settings)
            }
        }
        .fileImporter(
            isPresented: $showImportSheet,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            prepareImport(result: result)
        }
        .alert(L("settings.icloud.restore.confirm.title", "Restore Settings from iCloud?"), isPresented: $showRestoreConfirmation) {
            Button(L("button.cancel", "Cancel"), role: .cancel) {}
            Button(L("settings.general.icloud.restore", "Restore from iCloud"), role: .destructive) {
                operationMessage = SettingsBackupOperationMessage(restoreResult: settings.syncFromiCloud())
            }
        } message: {
            Text(L(
                "settings.icloud.restore.confirm.message",
                "This will replace local settings with the newest eligible iCloud settings backup. Export a local backup first if you may want to undo it."
            ))
        }
        .alert(L("settings.backup.import.confirm.title", "Import Settings Backup?"), isPresented: $showImportConfirmation) {
            Button(L("button.cancel", "Cancel"), role: .cancel) {
                pendingImport = nil
            }
            Button(L("settings.general.backup.import", "Import Settings..."), role: .destructive) {
                confirmImport()
            }
        } message: {
            Text(importConfirmationMessage)
        }
        .alert(L("settings.general.reset.confirm.title", "Reset All Settings?"), isPresented: $showResetConfirmation) {
            Button(L("settings.general.backup.export", "Export Settings...")) {
                exportSettings()
            }
            Button(L("button.cancel", "Cancel"), role: .cancel) {}
            Button(L("button.reset", "Reset"), role: .destructive) {
                settings.resetAllToDefaults()
                operationMessage = .success(L("settings.reset.success", "Settings were reset to defaults."))
            }
        } message: {
            Text(L(
                "settings.general.reset.confirm.message",
                "This will reset all Chau7 settings to their default values. This action cannot be undone. Export a backup first if you may want to restore your current setup."
            ))
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

    private func prepareImport(result: Result<[URL], Error>) {
        operationMessage = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let data = try Data(contentsOf: url)
                guard let preview = JSONOperations.decode(FeatureSettings.ExportableSettings.self, from: data, context: "settings import preview") else {
                    operationMessage = .error(L("settings.backup.import.invalid", "Invalid settings file format."))
                    return
                }
                pendingImport = PendingSettingsImport(
                    fileName: url.lastPathComponent,
                    data: data,
                    exportedAt: preview.exportedAt,
                    exportVersion: preview.exportVersion
                )
                showImportConfirmation = true
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

    private func confirmImport() {
        guard let importCandidate = pendingImport else { return }
        pendingImport = nil

        if settings.importSettings(from: importCandidate.data) {
            Log.info("Settings imported successfully")
            operationMessage = .success(
                String(
                    format: L("settings.backup.import.success", "Imported settings from %@."),
                    importCandidate.fileName
                )
            )
        } else {
            operationMessage = .error(L("settings.backup.import.invalid", "Invalid settings file format."))
        }
    }

    private var importConfirmationMessage: String {
        guard let pendingImport else {
            return L("settings.backup.import.confirm.message", "This will replace current Chau7 settings with the selected backup.")
        }

        var details = String(
            format: L("settings.backup.import.confirm.file", "This will replace current Chau7 settings with %@."),
            pendingImport.fileName
        )
        if let exportedAt = pendingImport.exportedAt {
            details += "\n" + String(
                format: L("settings.backup.import.confirm.exportedAt", "Backup exported: %@"),
                pendingImportDateFormatter.string(from: exportedAt)
            )
        }
        if let exportVersion = pendingImport.exportVersion {
            details += "\n" + String(
                format: L("settings.backup.import.confirm.version", "Format version: %d"),
                exportVersion
            )
        }
        details += "\n" + L("settings.backup.import.confirm.backupFirst", "Export a local backup first if you may want to undo it.")
        return details
    }

    private var pendingImportDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }
}

private struct PendingSettingsImport {
    let fileName: String
    let data: Data
    let exportedAt: Date?
    let exportVersion: Int?
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
