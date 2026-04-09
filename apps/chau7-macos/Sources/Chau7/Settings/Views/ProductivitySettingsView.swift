import SwiftUI
import AppKit
import Chau7Core

// MARK: - Productivity Settings

struct ProductivitySettingsView: View {
    @Bindable private var settings = FeatureSettings.shared
    @State private var permissionCenter = PermissionCenterModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Snippets
            SettingsSectionHeader(L("settings.productivity.snippets", "Snippets"), icon: "text.badge.plus")

            // Quick summary and manage button
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("settings.productivity.snippetsDescription", "Reusable text snippets with placeholders"))
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        Label("\(SnippetManager.shared.entries.filter { $0.source == .global }.count) \(L("settings.productivity.user", "User"))", systemImage: "person.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        if SnippetManager.shared.activeRepoRoot != nil {
                            Label("\(SnippetManager.shared.entries.filter { $0.source == .repo }.count) \(L("settings.productivity.repo", "Repo"))", systemImage: "folder.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                Button {
                    SnippetsSettingsWindowController.shared.show()
                } label: {
                    Label(L("settings.productivity.manageSnippets", "Manage Snippets"), systemImage: "text.badge.plus")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
            .padding(12)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)

            // Shortcut hint
            HStack(spacing: 4) {
                Image(systemName: "keyboard")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                Text(L("settings.productivity.snippetShortcutHint", "Press ⌘⌥S to open snippet picker in terminal"))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            SettingsToggle(
                label: L("settings.productivity.enableSnippets", "Enable Snippets"),
                help: L("settings.productivity.enableSnippets.help", "Use reusable text snippets with placeholders"),
                isOn: $settings.isSnippetsEnabled
            )
            .onChange(of: settings.isSnippetsEnabled) {
                SnippetManager.shared.refreshConfiguration()
            }

            SettingsToggle(
                label: L("settings.productivity.repositorySnippets", "Repository Snippets"),
                help: L("settings.productivity.repositorySnippets.help", "Load snippets from the current git repository (.chau7/snippets.json)"),
                isOn: $settings.isRepoSnippetsEnabled,
                disabled: !settings.isSnippetsEnabled
            )
            .onChange(of: settings.isRepoSnippetsEnabled) {
                SnippetManager.shared.refreshConfiguration()
            }

            SettingsTextField(
                label: L("settings.productivity.repoSnippetPath", "Snippets Path"),
                help: L("settings.productivity.repoSnippetPath.help", "Relative path within the git repository where snippets are stored"),
                placeholder: ".chau7/snippets",
                text: $settings.repoSnippetPath,
                width: 250,
                monospaced: true,
                disabled: !settings.isSnippetsEnabled || !settings.isRepoSnippetsEnabled
            )

            SettingsToggle(
                label: L("settings.productivity.protectedFolders", "Allow Protected Folders"),
                help: L(
                    "settings.productivity.protectedFolders.help",
                    "Allow background repo detection in Downloads, Desktop, and Documents (may prompt for permissions)"
                ),
                isOn: $settings.allowProtectedFolderAccess
            )
            .onChange(of: settings.allowProtectedFolderAccess) {
                if settings.allowProtectedFolderAccess {
                    ProtectedPathPolicy.resetAccessChecks()
                }
                SnippetManager.shared.refreshConfiguration()
                SnippetManager.shared.refreshContextForCurrentPath()
                permissionCenter.refresh()
            }
            .padding(.bottom, 4)

            HStack(spacing: 8) {
                Button(L("settings.productivity.protectedFolders.grant", "Grant Access")) {
                    ProtectedPathPolicy.resetAccessChecks()
                    ProtectedPathPolicy.requestAccessToProtectedFolders()
                    permissionCenter.refresh()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(L("settings.productivity.protectedFolders.openSettings", "Open System Settings")) {
                    openFilesAndFoldersSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(L("settings.productivity.permissions.refresh", "Refresh Status")) {
                    permissionCenter.refresh()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            PermissionsStatusSection(permissionCenter: permissionCenter)

            SettingsPicker(
                label: L("settings.productivity.insertMode", "Insert Mode"),
                help: L("settings.productivity.insertMode.help", "How snippets are inserted into the terminal"),
                selection: $settings.snippetInsertMode,
                options: [
                    (value: "expand", label: L("settings.productivity.expandType", "Expand (type)")),
                    (value: "paste", label: L("settings.productivity.paste", "Paste"))
                ],
                disabled: !settings.isSnippetsEnabled
            )

            SettingsToggle(
                label: L("settings.productivity.placeholderNavigation", "Placeholder Navigation"),
                help: L("settings.productivity.placeholderNavigation.help", "Enable Tab key navigation between snippet placeholders"),
                isOn: $settings.snippetPlaceholdersEnabled,
                disabled: !settings.isSnippetsEnabled || settings.snippetInsertMode == "paste"
            )

            Divider()
                .padding(.vertical, 8)

            // Clipboard History
            SettingsSectionHeader(L("settings.productivity.clipboardHistory", "Clipboard History"), icon: "doc.on.clipboard")

            SettingsToggle(
                label: L("settings.productivity.enableClipboardHistory", "Enable Clipboard History"),
                help: L("settings.productivity.enableClipboardHistory.help", "Keep a history of copied text for quick access"),
                isOn: $settings.isClipboardHistoryEnabled
            )

            SettingsNumberField(
                label: L("settings.productivity.maximumItems", "Maximum Items"),
                help: L("settings.productivity.maximumItems.help", "Number of clipboard entries to remember (1-500)"),
                value: $settings.clipboardHistoryMaxItems,
                width: 80,
                disabled: !settings.isClipboardHistoryEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Bookmarks
            SettingsSectionHeader(L("settings.productivity.bookmarks", "Bookmarks"), icon: "bookmark")

            SettingsToggle(
                label: L("settings.productivity.enableBookmarks", "Enable Bookmarks"),
                help: L("settings.productivity.enableBookmarks.help", "Save and recall positions in terminal scrollback"),
                isOn: $settings.isBookmarksEnabled
            )

            SettingsNumberField(
                label: L("settings.productivity.maximumPerTab", "Maximum Per Tab"),
                help: L("settings.productivity.maximumPerTab.help", "Number of bookmarks allowed per tab (1-200)"),
                value: $settings.maxBookmarksPerTab,
                width: 80,
                disabled: !settings.isBookmarksEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Search
            SettingsSectionHeader(L("settings.productivity.search", "Search"), icon: "magnifyingglass")

            SettingsToggle(
                label: L("settings.productivity.semanticSearch", "Semantic Search"),
                help: L("settings.productivity.semanticSearch.help", "Enable command-aware search through terminal history (requires shell integration)"),
                isOn: $settings.isSemanticSearchEnabled
            )

            SettingsToggle(
                label: L("settings.productivity.defaultCaseSensitive", "Default Case Sensitive"),
                help: L("settings.productivity.defaultCaseSensitive.help", "Start new find sessions with case-sensitive matching"),
                isOn: $settings.findCaseSensitiveDefault
            )

            SettingsToggle(
                label: L("settings.productivity.defaultRegex", "Default Regex"),
                help: L("settings.productivity.defaultRegex.help", "Start new find sessions with regex matching enabled"),
                isOn: $settings.findRegexDefault
            )

            SettingsShortcutRow(label: L("settings.productivity.find", "Find"), shortcut: "⌘F")
            SettingsShortcutRow(label: L("settings.productivity.findNext", "Find Next"), shortcut: "⌘G")
            SettingsShortcutRow(label: L("settings.productivity.findPrevious", "Find Previous"), shortcut: "⌘⌥G")

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            SettingsButtonRow(buttons: [
                .init(title: L("settings.productivity.resetToDefaults", "Reset Productivity to Defaults"), style: .plain) {
                    settings.resetProductivityToDefaults()
                    permissionCenter.refresh()
                }
            ], alignment: .trailing)
        }
        .task {
            permissionCenter.refresh()
        }
    }

    private func openFilesAndFoldersSettings() {
        let urls = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity"
        ]
        for value in urls {
            if let url = URL(string: value) {
                NSWorkspace.shared.open(url)
                return
            }
        }
    }
}

private struct PermissionsStatusSection: View {
    let permissionCenter: PermissionCenterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsSectionHeader(L("settings.productivity.permissions", "Permissions"), icon: "lock.shield")

            Text(L("settings.productivity.permissions.help", "Review notification status and protected-folder access without guessing what is blocked."))
                .font(.system(size: 12))
                .foregroundColor(.secondary)

            permissionRow(
                title: L("settings.productivity.permissions.notifications", "Notifications"),
                status: permissionCenter.notificationPermissionState.localizedLabel,
                detail: notificationDetail
            )

            ForEach(permissionCenter.protectedSnapshots, id: \.root) { snapshot in
                permissionRow(
                    title: displayName(for: snapshot.root),
                    status: protectedStatusLabel(for: snapshot),
                    detail: protectedDetail(for: snapshot)
                )
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var notificationDetail: String {
        switch permissionCenter.notificationPermissionState {
        case .authorized, .provisional, .ephemeral:
            return L("settings.productivity.permissions.notifications.ok", "System notifications are available.")
        case .notDetermined:
            return L("settings.productivity.permissions.notifications.notDetermined", "Notification permission has not been requested yet.")
        case .denied:
            return L("settings.productivity.permissions.notifications.denied", "Notifications are denied in System Settings.")
        case .unavailableNotBundled:
            return L("settings.productivity.permissions.notifications.unavailable", "Notifications require the bundled app.")
        case .unknown:
            return L("settings.productivity.permissions.notifications.unknown", "Notification status could not be determined.")
        }
    }

    private func protectedStatusLabel(for snapshot: ProtectedPathAccessSnapshot) -> String {
        switch snapshot.state {
        case .unprotected:
            return L("settings.productivity.permissions.protected.state.unprotected", "Not Protected")
        case .availableActiveScope:
            return L("settings.productivity.permissions.protected.state.active", "Granted")
        case .availableBookmarkedScope:
            return L("settings.productivity.permissions.protected.state.bookmark", "Granted by Bookmark")
        case .blockedFeatureDisabled:
            return L("settings.productivity.permissions.protected.state.disabled", "Disabled")
        case .blockedNeedsExplicitGrant:
            return L("settings.productivity.permissions.protected.state.needsGrant", "Needs Access")
        case .blockedCooldown:
            return L("settings.productivity.permissions.protected.state.cooldown", "Retry Later")
        case .blockedStaleBookmark:
            return L("settings.productivity.permissions.protected.state.stale", "Needs Re-Grant")
        }
    }

    private func protectedDetail(for snapshot: ProtectedPathAccessSnapshot) -> String {
        if snapshot.canUseKnownIdentity, !snapshot.canProbeLive {
            return L("settings.productivity.permissions.protected.detail.cachedIdentity", "Known repo identity is preserved, but live refresh is blocked.")
        }

        switch snapshot.recommendedAction {
        case .none:
            return L("settings.productivity.permissions.protected.detail.ok", "Live repo detection is available for this root.")
        case .enableFeature:
            return L("settings.productivity.permissions.protected.detail.enableFeature", "Enable protected folder access in Chau7 to allow live repo refresh.")
        case .grantAccess:
            return L("settings.productivity.permissions.protected.detail.grantAccess", "Grant folder access to allow live repo refresh in this location.")
        case .waitForCooldown:
            return L("settings.productivity.permissions.protected.detail.cooldown", "Chau7 is waiting before retrying access after a recent denial.")
        case .regrantAccess:
            return L("settings.productivity.permissions.protected.detail.regrant", "The saved permission is stale. Grant access again to restore live refresh.")
        }
    }

    private func displayName(for root: String?) -> String {
        guard let root else {
            return L("settings.productivity.permissions.protected.unknownRoot", "Protected Root")
        }
        let normalized = URL(fileURLWithPath: root).standardized.path
        let home = RuntimeIsolation.homePath()
        if normalized.hasPrefix(home + "/") {
            return URL(fileURLWithPath: normalized).lastPathComponent
        }
        return normalized
    }

    private func permissionRow(title: String, status: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(status)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            Text(detail)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}
