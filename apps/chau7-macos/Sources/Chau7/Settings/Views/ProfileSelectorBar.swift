import SwiftUI

// MARK: - Profile Selector

/// Compact titlebar control showing the active settings profile and profile actions.
struct ProfileSelectorBar: View {
    var settings = FeatureSettings.shared
    let overlayModel: OverlayTabsModel?

    @State private var showCreateProfile = false

    private var activeProfile: SettingsProfile? {
        settings.activeProfile
    }

    private var displayName: String {
        guard let activeProfile else {
            return L("settings.profileBar.defaultSettings", "Default Settings")
        }
        return displayName(for: activeProfile)
    }

    private var iconName: String {
        activeProfile?.icon ?? "house.fill"
    }

    var body: some View {
        profileMenu
            .fixedSize()
            .accessibilityLabel(
                String(
                    format: L("settings.profileBar.accessibilityLabel", "Settings profile: %@"),
                    displayName
                )
            )
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
            Section(L("settings.profileBar.loadSection", "Load Profile")) {
                ForEach(settings.savedProfiles) { profile in
                    Button(action: { settings.loadProfile(profile) }) {
                        HStack {
                            Image(systemName: profile.icon)
                            Text(displayName(for: profile))
                        }
                        if isCurrentProfile(profile) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }

            Divider()

            Section(L("settings.profileBar.saveSection", "Save")) {
                if let activeProfile {
                    Button(action: { settings.saveCurrentToProfile(activeProfile) }) {
                        Label(
                            String(
                                format: L("settings.profileBar.saveCurrentTo", "Save Current to %@"),
                                displayName(for: activeProfile)
                            ),
                            systemImage: "square.and.arrow.down"
                        )
                    }
                }

                Button(action: { showCreateProfile = true }) {
                    Label(
                        L("settings.profileBar.saveAsNew", "Save Current as New Profile..."),
                        systemImage: "plus"
                    )
                }
            }

            if activeProfile != nil {
                Divider()
                Button(action: {
                    settings.activeProfileId = nil
                }) {
                    Label(
                        L("settings.profileBar.stopUsingProfile", "Stop Using Profile (Keep Current Settings)"),
                        systemImage: "person.crop.circle.badge.xmark"
                    )
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: iconName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                Text(displayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .frame(height: 24)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .controlSize(.small)
    }

    private func displayName(for profile: SettingsProfile) -> String {
        if isDefaultProfile(profile) {
            return L("settings.profileBar.defaultSettings", "Default Settings")
        }
        return profile.name
    }

    private func isDefaultProfile(_ profile: SettingsProfile) -> Bool {
        profile.name == "Default" && profile.icon == "house.fill"
    }

    private func isCurrentProfile(_ profile: SettingsProfile) -> Bool {
        if let activeProfileId = settings.activeProfileId {
            return profile.id == activeProfileId
        }
        return isDefaultProfile(profile)
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
    var settings: FeatureSettings
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
        .onAppear {
            if !defaultName.isEmpty {
                profileName = defaultName
            }
        }
    }
}
