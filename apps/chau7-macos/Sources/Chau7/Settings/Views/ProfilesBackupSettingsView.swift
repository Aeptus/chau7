import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Profiles & Backup Settings

struct ProfilesBackupSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @StateObject private var switcher = ProfileAutoSwitcher()
    @State private var showExportSheet = false
    @State private var showImportSheet = false
    @State private var importError: String? = nil
    @State private var showCreateProfile = false
    @State private var showDeleteConfirmation = false
    @State private var profileToDelete: SettingsProfile? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Settings Profiles
            SettingsSectionHeader(L("settings.general.profiles", "Settings Profiles"), icon: "person.2.fill")

            Text(L("settings.general.profiles.description", "Create named profiles for different workflows (Work, Personal, Presentation Mode)"))
                .font(.caption)
                .foregroundStyle(.secondary)

            // Active profile indicator
            if let activeProfile = settings.activeProfile {
                SettingsRow(L("settings.general.profiles.active", "Active Profile")) {
                    HStack(spacing: 8) {
                        Image(systemName: activeProfile.icon)
                            .foregroundColor(.accentColor)
                        Text(activeProfile.name)
                            .fontWeight(.medium)
                        Button(L("settings.general.profiles.save", "Save Current")) {
                            settings.saveCurrentToProfile(activeProfile)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }

            // Profile list
            ForEach(settings.savedProfiles) { profile in
                ProfileRow(
                    profile: profile,
                    isActive: profile.id == settings.activeProfileId,
                    onLoad: { settings.loadProfile(profile) },
                    onDelete: {
                        profileToDelete = profile
                        showDeleteConfirmation = true
                    }
                )
            }

            Button(action: { showCreateProfile = true }) {
                Label(L("settings.general.profiles.create", "Create New Profile..."), systemImage: "plus.circle")
            }

            Divider()
                .padding(.vertical, 8)

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
        .sheet(isPresented: $showCreateProfile) {
            CreateProfileSheet(settings: settings) { showCreateProfile = false }
        }
        .alert(L("settings.general.profiles.delete.title", "Delete Profile?"), isPresented: $showDeleteConfirmation) {
            Button(L("button.cancel", "Cancel"), role: .cancel) { profileToDelete = nil }
            Button(L("button.delete", "Delete"), role: .destructive) {
                if let profile = profileToDelete {
                    settings.deleteProfile(id: profile.id)
                }
                profileToDelete = nil
            }
        } message: {
            if let profile = profileToDelete {
                Text(L("settings.general.profiles.delete.message", "Are you sure you want to delete the profile \"\(profile.name)\"? This action cannot be undone."))
            }
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

// MARK: - Profile Row

struct ProfileRow: View {
    let profile: SettingsProfile
    let isActive: Bool
    let onLoad: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: SettingsLayout.controlSpacing) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: profile.icon)
                        .foregroundColor(isActive ? .accentColor : .secondary)
                    Text(profile.name)
                        .fontWeight(isActive ? .semibold : .regular)
                    if isActive {
                        Text(L("settings.general.profiles.activeLabel", "(Active)"))
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
                Text(L("settings.general.profiles.created", "Created") + " \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(width: SettingsLayout.labelWidth, alignment: .leading)

            HStack(spacing: 8) {
                if !isActive {
                    Button(L("button.load", "Load")) { onLoad() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundStyle(.red.opacity(0.7))
                }
                .buttonStyle(.borderless)
                .disabled(isActive)
                .opacity(isActive ? 0.3 : 1)
                .help(L("settings.general.profiles.delete", "Delete profile"))
            }

            Spacer()
        }
        .padding(.vertical, 4)
        .localized()
    }
}

// MARK: - Create Profile Sheet

struct CreateProfileSheet: View {
    @ObservedObject var settings: FeatureSettings
    let onDismiss: () -> Void

    @State private var profileName: String = ""
    @State private var selectedIcon: String = "person.fill"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("settings.general.profiles.createTitle", "Create New Profile"))
                .font(.headline)

            Divider()

            TextField(L("settings.general.profiles.namePlaceholder", "Profile Name"), text: $profileName)
                .textFieldStyle(.roundedBorder)

            Text(L("settings.general.profiles.chooseIcon", "Choose Icon"))
                .font(.subheadline)
                .foregroundStyle(.secondary)

            LazyVGrid(columns: Array(repeating: GridItem(.fixed(44)), count: 8), spacing: 8) {
                ForEach(SettingsProfile.availableIcons, id: \.self) { icon in
                    Button(action: { selectedIcon = icon }) {
                        Image(systemName: icon)
                            .font(.system(size: 18))
                            .frame(width: 36, height: 36)
                            .background(selectedIcon == icon ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(selectedIcon == icon ? Color.accentColor : Color.clear, lineWidth: 2)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            Divider()

            HStack {
                Button(L("button.cancel", "Cancel")) { onDismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button(L("settings.general.profiles.createButton", "Create Profile")) {
                    let profile = settings.createProfile(name: profileName, icon: selectedIcon)
                    settings.activeProfileId = profile.id
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 400)
        .localized()
    }
}
