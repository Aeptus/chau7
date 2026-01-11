import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - General Settings

struct GeneralSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var settings = FeatureSettings.shared
    @State private var launchAtLogin = false
    @State private var showExportSheet = false
    @State private var showImportSheet = false
    @State private var showResetConfirmation = false
    @State private var importError: String? = nil
    @State private var showCreateProfile = false
    @State private var showDeleteConfirmation = false
    @State private var profileToDelete: SettingsProfile? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Startup
            SettingsSectionHeader("Startup", icon: "power")

            SettingsToggle(
                label: "Launch at Login",
                help: "Automatically start Chau7 when you log in to your Mac",
                isOn: $launchAtLogin
            )

            SettingsTextField(
                label: L("settings.general.defaultDirectory"),
                help: L("settings.general.defaultDirectory.help"),
                placeholder: "~",
                text: $settings.defaultStartDirectory,
                width: 280,
                monospaced: true
            )

            Divider()
                .padding(.vertical, 8)

            // Language
            SettingsSectionHeader(L("settings.general.language"), icon: "globe")

            SettingsPicker(
                label: L("settings.general.language.label"),
                help: L("settings.general.language.help"),
                selection: $settings.appLanguage,
                options: AppLanguage.allCases.map { (value: $0, label: $0.displayName) }
            )

            SettingsDescription(text: L("settings.general.language.note"))

            Divider()
                .padding(.vertical, 8)

            // Settings Profiles (NEW)
            SettingsSectionHeader("Settings Profiles", icon: "person.2.fill")

            Text("Create named profiles for different workflows (Work, Personal, Presentation Mode)")
                .font(.caption)
                .foregroundStyle(.secondary)

            // Active profile indicator
            if let activeProfile = settings.activeProfile {
                HStack {
                    Image(systemName: activeProfile.icon)
                        .foregroundColor(.accentColor)
                    Text("Active: \(activeProfile.name)")
                        .fontWeight(.medium)
                    Spacer()
                    Button("Save Current Settings") {
                        settings.saveCurrentToProfile(activeProfile)
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
                }
                .padding(10)
                .background(Color.accentColor.opacity(0.1))
                .cornerRadius(8)
            }

            // Profile list
            VStack(spacing: 4) {
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
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            Button(action: { showCreateProfile = true }) {
                Label("Create New Profile...", systemImage: "plus.circle")
            }

            Divider()
                .padding(.vertical, 8)

            // iCloud Sync (NEW)
            SettingsSectionHeader("iCloud Sync", icon: "icloud")

            SettingsToggle(
                label: "Sync Settings via iCloud",
                help: "Keep your Chau7 settings synchronized across all your Macs",
                isOn: $settings.iCloudSyncEnabled
            )

            if settings.iCloudSyncEnabled {
                HStack(spacing: 12) {
                    Button("Sync Now") {
                        settings.syncToiCloud()
                    }

                    Button("Restore from iCloud") {
                        settings.syncFromiCloud()
                    }
                }
            }

            Divider()
                .padding(.vertical, 8)

            // Import/Export (NEW)
            SettingsSectionHeader("Settings Backup", icon: "square.and.arrow.up.on.square")

            Text("Export your settings to a JSON file or import from a backup.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button("Export Settings...") {
                    exportSettings()
                }

                Button("Import Settings...") {
                    showImportSheet = true
                }
            }

            if let error = importError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.top, 4)
            }

            Divider()
                .padding(.vertical, 8)

            // Status
            SettingsSectionHeader("Status", icon: "info.circle")

            SettingsInfoRow(label: "Notifications", value: model.notificationStatus, monospaced: true)
            SettingsInfoRow(
                label: "Event Monitoring",
                value: model.isMonitoring ? "Active" : "Paused",
                valueColor: model.isMonitoring ? .green : .secondary,
                monospaced: true
            )
            SettingsInfoRow(
                label: "History Monitoring",
                value: model.isIdleMonitoring ? "Active" : "Paused",
                valueColor: model.isIdleMonitoring ? .green : .secondary,
                monospaced: true
            )
            SettingsInfoRow(
                label: "Terminal Monitoring",
                value: model.isTerminalMonitoring ? "Active" : "Paused",
                valueColor: model.isTerminalMonitoring ? .green : .secondary,
                monospaced: true
            )

            Divider()
                .padding(.vertical, 8)

            // Actions
            SettingsSectionHeader("Actions", icon: "hand.tap")

            SettingsButtonRow(buttons: [
                .init(title: "Show Overlay", icon: "rectangle.inset.filled") {
                    (NSApp.delegate as? AppDelegate)?.showOverlay()
                },
                .init(title: "Reset Window Positions", icon: "arrow.counterclockwise") {
                    FeatureSettings.shared.resetOverlayOffsets()
                },
                .init(title: "Debug Console", icon: "terminal") {
                    DebugConsoleController.shared.show()
                }
            ])

            Divider()
                .padding(.vertical, 8)

            // Reset
            SettingsSectionHeader("Reset", icon: "arrow.counterclockwise")

            SettingsButtonRow(buttons: [
                .init(title: "Reset All Settings to Defaults", style: .plain) {
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
        .alert("Reset All Settings?", isPresented: $showResetConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Reset", role: .destructive) {
                settings.resetAllToDefaults()
            }
        } message: {
            Text("This will reset all Chau7 settings to their default values. This action cannot be undone.")
        }
        .sheet(isPresented: $showCreateProfile) {
            CreateProfileSheet(settings: settings) { showCreateProfile = false }
        }
        .alert("Delete Profile?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) { profileToDelete = nil }
            Button("Delete", role: .destructive) {
                if let profile = profileToDelete {
                    settings.deleteProfile(id: profile.id)
                }
                profileToDelete = nil
            }
        } message: {
            if let profile = profileToDelete {
                Text("Are you sure you want to delete the profile \"\(profile.name)\"? This action cannot be undone.")
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
        HStack(spacing: 12) {
            Image(systemName: profile.icon)
                .foregroundColor(isActive ? .accentColor : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(profile.name)
                        .fontWeight(isActive ? .semibold : .regular)
                    if isActive {
                        Text("(Active)")
                            .font(.caption)
                            .foregroundColor(.accentColor)
                    }
                }
                Text("Created \(profile.createdAt.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !isActive {
                Button("Load") { onLoad() }
                    .buttonStyle(.plain)
                    .foregroundColor(.accentColor)
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(.red.opacity(0.7))
            }
            .buttonStyle(.plain)
            .disabled(isActive)
            .opacity(isActive ? 0.3 : 1)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isActive ? Color.accentColor.opacity(0.08) : Color.clear)
        .cornerRadius(6)
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
            Text("Create New Profile")
                .font(.headline)

            Divider()

            TextField("Profile Name", text: $profileName)
                .textFieldStyle(.roundedBorder)

            Text("Choose Icon")
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
                Button("Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Create Profile") {
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
    }
}
