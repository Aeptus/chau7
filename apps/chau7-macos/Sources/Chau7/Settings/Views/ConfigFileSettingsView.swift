import SwiftUI
import Chau7Core

/// Settings view for config file support (.chau7.toml).
/// Provides controls for enabling/disabling config file loading,
/// viewing the config path, creating defaults, and reloading.
struct ConfigFileSettingsView: View {
    var showsTitle = true
    @Bindable private var watcher = ConfigFileWatcher.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Chau7Style.Settings.pageSectionSpacing) {
            // Header
            if showsTitle {
                SettingsSectionHeader(L("settings.configFile.title", "Config File"), icon: "doc.text")
            }

            SettingsToggle(
                label: L("settings.configFile.enabled", "Load Config Files"),
                help: L("settings.configFile.enabled.help", "Load settings from ~/.chau7/config.toml and per-repo .chau7/config.toml"),
                isOn: $watcher.isEnabled,
                anchorID: "configFile"
            )

            SettingsDescription(
                text: L("settings.configFile.description", "Config files use a TOML-like format. Per-repo configs override global settings.")
            )

            SettingsDivider()

            // Global Config Path
            SettingsSectionHeader(L("settings.configFile.global", "Global Config"), icon: "folder")

            SettingsRow(L("settings.configFile.path", "Path")) {
                Text(L("~/.chau7/config.toml", "~/.chau7/config.toml"))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            // Last load time
            if let loadTime = watcher.lastLoadTime {
                SettingsRow(L("settings.configFile.lastLoaded", "Last Loaded")) {
                    Text(loadTime, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // Error display
            if let error = watcher.lastError {
                HStack(alignment: .top, spacing: Chau7Style.Settings.inlineControlSpacing) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.system(size: 12))
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                .padding(Chau7Style.Settings.inlineControlSpacing)
                .background(Color.red.opacity(0.1))
                .cornerRadius(6)
            }

            // Action buttons
            SettingsButtonRow(buttons: [
                .init(
                    title: L("settings.configFile.createDefault", "Create Default Config"),
                    icon: "doc.badge.plus"
                ) {
                    watcher.createDefaultConfig()
                    watcher.loadGlobalConfig()
                },
                .init(
                    title: L("settings.configFile.openInEditor", "Open in Editor"),
                    icon: "pencil",
                    isDisabled: watcher.globalConfig == nil
                ) {
                    openConfigInEditor()
                },
                .init(
                    title: L("settings.configFile.reload", "Reload Now"),
                    icon: "arrow.clockwise"
                ) {
                    watcher.loadGlobalConfig()
                    watcher.applyConfig()
                }
            ])

            SettingsDivider()

            // Repo Config Info
            SettingsSectionHeader(L("settings.configFile.repo", "Per-Repo Config"), icon: "folder.badge.gearshape")

            SettingsDescription(
                text: L("settings.configFile.repo.description", "Place a .chau7/config.toml in your repository root to override global settings for that project.")
            )

            if let repoPath = watcher.repoConfigPath {
                SettingsRow(L("settings.configFile.repo.path", "Path")) {
                    Text((repoPath as NSString).abbreviatingWithTildeInPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            if watcher.repoConfig != nil {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.green)
                        .font(.system(size: 12))
                    Text(L("settings.configFile.repo.active", "Repo config active"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            SettingsButtonRow(buttons: [
                .init(
                    title: L("settings.configFile.repo.create", "Create Per-Repo Config"),
                    icon: "doc.badge.plus",
                    isDisabled: watcher.repoConfigDirectory == nil
                ) {
                    if let dir = watcher.repoConfigDirectory {
                        watcher.createRepoConfig(directory: dir)
                        watcher.loadRepoConfig(directory: dir)
                    }
                },
                .init(
                    title: L("settings.configFile.openInEditor", "Open in Editor"),
                    icon: "pencil",
                    isDisabled: watcher.repoConfig == nil
                ) {
                    openRepoConfigInEditor()
                }
            ])
        }
    }

    // MARK: - Helpers

    private func openConfigInEditor() {
        let path = RuntimeIsolation.pathInHome(".chau7/config.toml")
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private func openRepoConfigInEditor() {
        guard let path = watcher.repoConfigPath else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
}
