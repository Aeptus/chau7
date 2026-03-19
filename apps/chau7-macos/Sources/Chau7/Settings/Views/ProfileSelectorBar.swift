import SwiftUI

// MARK: - Profile Selector Bar

/// Persistent bar at the top of the settings window showing the active profile
/// and providing quick access to profile switching and creation.
struct ProfileSelectorBar: View {
    @ObservedObject var settings = FeatureSettings.shared
    let overlayModel: OverlayTabsModel?

    @State private var showCreateProfile = false

    private var activeProfile: SettingsProfile? {
        settings.activeProfile
    }

    private var titleText: String {
        if let name = activeProfile?.name {
            return L("settings.profileBar.titleFor", "Chau7 Settings for \(name)")
        }
        return L("settings.profileBar.title", "Chau7 Settings")
    }

    private var iconName: String {
        activeProfile?.icon ?? "gearshape"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)

            Text(titleText)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)

            profileMenu

            Spacer()

            if activeProfile != nil {
                Button(L("settings.profileBar.saveCurrent", "Save Current")) {
                    if let profile = activeProfile {
                        settings.saveCurrentToProfile(profile)
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color(NSColor.windowBackgroundColor))
        .overlay(alignment: .bottom) {
            Divider()
        }
        .sheet(isPresented: $showCreateProfile) {
            CreateProfileSheet(
                settings: settings,
                defaultName: suggestedProfileName
            ) {
                showCreateProfile = false
            }
        }
    }

    // MARK: - Profile Menu

    private var profileMenu: some View {
        Menu {
            ForEach(settings.savedProfiles) { profile in
                Button(action: { settings.loadProfile(profile) }) {
                    HStack {
                        Image(systemName: profile.icon)
                        Text(profile.name)
                    }
                    if profile.id == settings.activeProfileId {
                        Image(systemName: "checkmark")
                    }
                }
            }

            Divider()

            Button(L("settings.profileBar.createNew", "Create New Profile...")) {
                showCreateProfile = true
            }

            if activeProfile != nil {
                Button(L("settings.profileBar.deactivate", "Deactivate Profile")) {
                    settings.activeProfileId = nil
                }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: - Smart Default Name

    private var suggestedProfileName: String {
        guard let tab = overlayModel?.selectedTab else { return "" }
        let title = tab.displayTitle
        let skip = ["Shell", "Editor", "zsh", "bash", "fish"]
        if skip.contains(where: { title.caseInsensitiveCompare($0) == .orderedSame }) {
            // Fall back to directory basename
            if let dir = overlayModel?.selectedTab?.session?.currentDirectory {
                let basename = URL(fileURLWithPath: dir).lastPathComponent
                if !basename.isEmpty, basename != "/" {
                    return basename
                }
            }
            return ""
        }
        return title
    }
}

// MARK: - Create Profile Sheet

struct CreateProfileSheet: View {
    @ObservedObject var settings: FeatureSettings
    var defaultName = ""
    let onDismiss: () -> Void

    @State private var profileName = ""
    @State private var selectedIcon = "person.fill"

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(L("settings.general.profiles.createTitle", "Create New Profile"))
                .font(.headline)

            Text(L("settings.profileBar.createExplanation", "All current settings will be saved to this profile. Switch between profiles to customize Chau7 for different workflows."))
                .font(.caption)
                .foregroundStyle(.secondary)

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
        .onAppear {
            if !defaultName.isEmpty {
                profileName = defaultName
            }
        }
    }
}
