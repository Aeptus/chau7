import SwiftUI
import AppKit

// MARK: - Productivity Settings

struct ProductivitySettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Snippets
            SettingsSectionHeader("Snippets", icon: "text.badge.plus")

            // Quick summary and manage button
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Reusable text snippets with placeholders")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    HStack(spacing: 12) {
                        Label("\(SnippetManager.shared.entries.filter { $0.source == .global }.count) User", systemImage: "person.fill")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        if SnippetManager.shared.repoRoot != nil {
                            Label("\(SnippetManager.shared.entries.filter { $0.source == .repo }.count) Repo", systemImage: "folder.fill")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Spacer()

                Button {
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.showSnippetsSettings()
                    }
                } label: {
                    Label("Manage Snippets", systemImage: "text.badge.plus")
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
                Text("Press ⌘; to open snippet picker in terminal")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            SettingsToggle(
                label: "Enable Snippets",
                help: "Use reusable text snippets with placeholders",
                isOn: $settings.isSnippetsEnabled
            )
            .onChange(of: settings.isSnippetsEnabled) { _ in
                SnippetManager.shared.refreshConfiguration()
            }

            SettingsToggle(
                label: "Repository Snippets",
                help: "Load snippets from the current git repository (.chau7/snippets.json)",
                isOn: $settings.isRepoSnippetsEnabled,
                disabled: !settings.isSnippetsEnabled
            )
            .onChange(of: settings.isRepoSnippetsEnabled) { _ in
                SnippetManager.shared.refreshConfiguration()
            }

            SettingsPicker(
                label: "Insert Mode",
                help: "How snippets are inserted into the terminal",
                selection: $settings.snippetInsertMode,
                options: [
                    (value: "expand", label: "Expand (type)"),
                    (value: "paste", label: "Paste")
                ],
                disabled: !settings.isSnippetsEnabled
            )

            SettingsToggle(
                label: "Placeholder Navigation",
                help: "Enable Tab key navigation between snippet placeholders",
                isOn: $settings.snippetPlaceholdersEnabled,
                disabled: !settings.isSnippetsEnabled || settings.snippetInsertMode == "paste"
            )

            Divider()
                .padding(.vertical, 8)

            // Clipboard History
            SettingsSectionHeader("Clipboard History", icon: "doc.on.clipboard")

            SettingsToggle(
                label: "Enable Clipboard History",
                help: "Keep a history of copied text for quick access",
                isOn: $settings.isClipboardHistoryEnabled
            )

            SettingsNumberField(
                label: "Maximum Items",
                help: "Number of clipboard entries to remember (1-500)",
                value: $settings.clipboardHistoryMaxItems,
                width: 80,
                disabled: !settings.isClipboardHistoryEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Bookmarks
            SettingsSectionHeader("Bookmarks", icon: "bookmark")

            SettingsToggle(
                label: "Enable Bookmarks",
                help: "Save and recall positions in terminal scrollback",
                isOn: $settings.isBookmarksEnabled
            )

            SettingsNumberField(
                label: "Maximum Per Tab",
                help: "Number of bookmarks allowed per tab (1-200)",
                value: $settings.maxBookmarksPerTab,
                width: 80,
                disabled: !settings.isBookmarksEnabled
            )

            Divider()
                .padding(.vertical, 8)

            // Search
            SettingsSectionHeader("Search", icon: "magnifyingglass")

            SettingsToggle(
                label: "Semantic Search",
                help: "Enable command-aware search through terminal history (requires shell integration)",
                isOn: $settings.isSemanticSearchEnabled
            )

            VStack(alignment: .leading, spacing: 6) {
                SettingsToggle(
                    label: "Default Case Sensitive",
                    help: "Start new find sessions with case-sensitive matching",
                    isOn: $settings.findCaseSensitiveDefault
                )

                SettingsToggle(
                    label: "Default Regex",
                    help: "Start new find sessions with regex matching enabled",
                    isOn: $settings.findRegexDefault
                )
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            VStack(alignment: .leading, spacing: 4) {
                SettingsShortcutRow(label: "Find", shortcut: "⌘F")
                SettingsShortcutRow(label: "Find Next", shortcut: "⌘G")
                SettingsShortcutRow(label: "Find Previous", shortcut: "⌘⇧G")
            }
            .padding(8)
            .background(Color.secondary.opacity(0.05))
            .cornerRadius(8)

            Divider()
                .padding(.vertical, 8)

            // Reset Button
            SettingsButtonRow(buttons: [
                .init(title: "Reset Productivity to Defaults", style: .plain) {
                    settings.resetProductivityToDefaults()
                }
            ], alignment: .trailing)
        }
    }
}
