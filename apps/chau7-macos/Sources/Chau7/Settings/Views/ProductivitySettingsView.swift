import SwiftUI
import AppKit

// MARK: - Productivity Settings

struct ProductivitySettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

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
            .onChange(of: settings.isSnippetsEnabled) { _ in
                SnippetManager.shared.refreshConfiguration()
            }

            SettingsToggle(
                label: L("settings.productivity.repositorySnippets", "Repository Snippets"),
                help: L("settings.productivity.repositorySnippets.help", "Load snippets from the current git repository (.chau7/snippets.json)"),
                isOn: $settings.isRepoSnippetsEnabled,
                disabled: !settings.isSnippetsEnabled
            )
            .onChange(of: settings.isRepoSnippetsEnabled) { _ in
                SnippetManager.shared.refreshConfiguration()
            }

            SettingsToggle(
                label: L("settings.productivity.protectedFolders", "Allow Protected Folders"),
                help: L(
                    "settings.productivity.protectedFolders.help",
                    "Allow background repo detection in Downloads, Desktop, and Documents (may prompt for permissions)"
                ),
                isOn: $settings.allowProtectedFolderAccess
            )
            .onChange(of: settings.allowProtectedFolderAccess) { _ in
                if settings.allowProtectedFolderAccess {
                    ProtectedPathPolicy.resetAccessChecks()
                }
                SnippetManager.shared.refreshConfiguration()
                SnippetManager.shared.refreshContextForCurrentPath()
            }
            .padding(.bottom, 4)

            HStack(spacing: 8) {
                Button(L("settings.productivity.protectedFolders.grant", "Grant Access")) {
                    ProtectedPathPolicy.resetAccessChecks()
                    ProtectedPathPolicy.requestAccessToProtectedFolders()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                Button(L("settings.productivity.protectedFolders.openSettings", "Open System Settings")) {
                    openFilesAndFoldersSettings()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

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
                }
            ], alignment: .trailing)
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
