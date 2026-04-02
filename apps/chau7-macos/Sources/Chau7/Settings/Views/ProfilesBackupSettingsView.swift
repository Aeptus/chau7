import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Sync & Backup Settings

struct ProfilesBackupSettingsView: View {
    @Bindable private var settings = FeatureSettings.shared
    @State private var switcher = ProfileAutoSwitcher()
    @State private var showImportSheet = false
    @State private var importError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Profile Auto-Switch
            ProfileAutoSwitchSettingsView(switcher: switcher, settings: settings)

            Divider()
                .padding(.vertical, 8)

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
                        settings.syncToiCloud()
                    },
                    .init(title: L("settings.general.icloud.restore", "Restore from iCloud"), icon: "icloud.and.arrow.down") {
                        settings.syncFromiCloud()
                    }
                ])
            }

            Divider()
                .padding(.vertical, 8)

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

            if let error = importError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }
        }
        .localized()
        .fileImporter(
            isPresented: $showImportSheet,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false
        ) { result in
            importSettings(result: result)
        }
    }

    private func exportSettings() {
        guard let data = settings.exportSettings() else { return }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "chau7-settings.json"
        panel.title = "Export Chau7 Settings"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try data.write(to: url)
            } catch {
                Log.error("Failed to export settings: \(error)")
            }
        }
    }

    private func importSettings(result: Result<[URL], Error>) {
        importError = nil
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                let data = try Data(contentsOf: url)
                if settings.importSettings(from: data) {
                    Log.info("Settings imported successfully")
                } else {
                    importError = "Invalid settings file format"
                }
            } catch {
                importError = "Failed to read file: \(error.localizedDescription)"
            }
        case .failure(let error):
            importError = "Import failed: \(error.localizedDescription)"
        }
    }
}
