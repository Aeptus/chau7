import SwiftUI
import AppKit

// MARK: - Snippets Settings View

struct SnippetsSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    private var snippetManager = SnippetManager.shared
    @State private var selectedSource: SnippetSource? = .global
    @State private var searchText = ""
    @State private var selectedSnippet: SnippetEntry?
    @State private var isEditorPresented = false
    @State private var editorDraft = SnippetDraft()
    @State private var isNewSnippet = false
    @State private var showDeleteConfirmation = false
    @State private var snippetToDelete: SnippetEntry?
    @State private var showRepoCopyError = false
    @State private var repoCopyErrorMessage = ""
    @State private var showImportExportSheet = false
    @State private var importExportMode: ImportExportMode = .export

    enum ImportExportMode {
        case `import`, export
    }

    private var filteredSnippets: [SnippetEntry] {
        var entries = snippetManager.entries

        // Filter by source
        if let source = selectedSource {
            entries = entries.filter { $0.source == source }
        }

        // Filter by search
        if !searchText.isEmpty {
            let query = searchText.lowercased()
            entries = entries.filter { entry in
                entry.snippet.title.lowercased().contains(query) ||
                    entry.snippet.body.lowercased().contains(query) ||
                    entry.snippet.tags.contains { $0.lowercased().contains(query) }
            }
        }

        return entries
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header with title and quick actions
            headerSection

            Divider()

            // Main content
            HStack(spacing: 0) {
                // Left sidebar - source filter and snippet list
                snippetListSidebar
                    .frame(width: 280)

                Divider()

                // Right panel - snippet details/editor or placeholder
                snippetDetailPanel
            }

            Divider()

            // Footer with settings and info
            footerSection
        }
        .frame(minWidth: 700, minHeight: 500)
        .alert(L("snippets.alert.delete.title", "Delete Snippet"), isPresented: $showDeleteConfirmation) {
            Button(L("Cancel", "Cancel"), role: .cancel) {}
            Button(L("Delete", "Delete"), role: .destructive) {
                if let entry = snippetToDelete {
                    snippetManager.deleteSnippet(entry)
                    selectedSnippet = nil
                }
            }
        } message: {
            Text(L(
                "snippets.alert.delete.message",
                "Are you sure you want to delete \"%@\"? This cannot be undone.",
                snippetToDelete?.snippet.title ?? ""
            ))
        }
        .alert(L("snippets.repo.choose.invalid.title", "Invalid Repository"), isPresented: $showRepoCopyError) {
            Button(L("OK", "OK"), role: .cancel) {}
        } message: {
            Text(repoCopyErrorMessage)
        }
        .sheet(isPresented: $showImportExportSheet) {
            ImportExportSheet(mode: importExportMode)
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Snippets", "Snippets"))
                    .font(.headline)
                Text(L("Manage reusable text snippets • Press ⌘; to open snippet picker", "Manage reusable text snippets • Press ⌘; to open snippet picker"))
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Quick actions
            HStack(spacing: 8) {
                Button {
                    importExportMode = .import
                    showImportExportSheet = true
                } label: {
                    Label(L("Import", "Import"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    importExportMode = .export
                    showImportExportSheet = true
                } label: {
                    Label(L("Export", "Export"), systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Button {
                    createNewSnippet()
                } label: {
                    Label(L("New Snippet", "New Snippet"), systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }

    // MARK: - Snippet List Sidebar

    private var snippetListSidebar: some View {
        VStack(spacing: 0) {
            // Source filter tabs
            sourceFilterTabs
                .padding(.horizontal, 12)
                .padding(.vertical, 8)

            // Search field
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField(L("Search snippets...", "Search snippets..."), text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            .padding(.horizontal, 12)
            .padding(.bottom, 8)

            Divider()

            // Snippet list
            if filteredSnippets.isEmpty {
                emptyStateView
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(filteredSnippets) { entry in
                            SnippetListRow(
                                entry: entry,
                                isSelected: selectedSnippet?.id == entry.id
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedSnippet = entry
                                isEditorPresented = false
                            }
                        }
                    }
                    .padding(8)
                }
            }
        }
        .background(Color(NSColor.controlBackgroundColor).opacity(0.3))
    }

    private var sourceFilterTabs: some View {
        HStack(spacing: 4) {
            SourceFilterButton(
                source: nil,
                label: L("snippets.filter.all", "All"),
                icon: "tray.full",
                count: snippetManager.entries.count,
                isSelected: selectedSource == nil
            ) {
                selectedSource = nil
            }

            SourceFilterButton(
                source: .global,
                label: L("snippets.filter.user", "User"),
                icon: SnippetSource.global.icon,
                count: snippetManager.entries.filter { $0.source == .global }.count,
                isSelected: selectedSource == .global
            ) {
                selectedSource = .global
            }

            if snippetManager.activeRepoRoot != nil {
                SourceFilterButton(
                    source: .repo,
                    label: L("snippets.filter.repo", "Repo"),
                    icon: SnippetSource.repo.icon,
                    count: snippetManager.entries.filter { $0.source == .repo }.count,
                    isSelected: selectedSource == .repo
                ) {
                    selectedSource = .repo
                }
            }
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "text.badge.plus")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(searchText.isEmpty
                ? L("snippets.empty.none", "No snippets yet")
                : L("snippets.empty.noMatches", "No matching snippets"))
                .font(.headline)
                .foregroundColor(.secondary)
            Text(searchText.isEmpty
                ? L("snippets.empty.cta", "Click \"New Snippet\" to create one")
                : L("snippets.empty.tryDifferent", "Try a different search term"))
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Snippet Detail Panel

    private var snippetDetailPanel: some View {
        Group {
            if isEditorPresented {
                SnippetEditorPanel(
                    draft: $editorDraft,
                    isNew: isNewSnippet,
                    repoSnippetsEnabled: settings.isRepoSnippetsEnabled,
                    currentRepoRoot: snippetManager.activeRepoRoot,
                    recentRepoRoots: settings.recentRepoRoots,
                    onCancel: {
                        isEditorPresented = false
                    },
                    onSave: {
                        saveSnippet()
                    }
                )
            } else if let entry = selectedSnippet {
                SnippetDetailView(
                    entry: entry,
                    currentRepoRoot: snippetManager.activeRepoRoot,
                    onEdit: {
                        startEditing(entry)
                    },
                    onDelete: {
                        snippetToDelete = entry
                        showDeleteConfirmation = true
                    },
                    onInsert: {
                        // Insert into terminal if available
                        NSApp.sendAction(#selector(AppDelegate.insertSnippetByID(_:)), to: nil, from: entry.snippet.id)
                    },
                    canCopyToCurrentRepo: settings.isRepoSnippetsEnabled && snippetManager.activeRepoRoot != nil,
                    repoCopyEnabled: settings.isRepoSnippetsEnabled,
                    onCopyToGlobal: {
                        copySnippet(entry, to: .global, repoRoot: nil)
                    },
                    onCopyToCurrentRepo: {
                        guard let repoRoot = snippetManager.activeRepoRoot else { return }
                        copySnippet(entry, to: .repo, repoRoot: repoRoot)
                    },
                    onCopyToRepoPicker: {
                        guard settings.isRepoSnippetsEnabled else { return }
                        guard let repoRoot = pickRepoRoot() else { return }
                        copySnippet(entry, to: .repo, repoRoot: repoRoot)
                    }
                )
            } else {
                noSelectionView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noSelectionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.badge.plus")
                .font(.system(size: 50))
                .foregroundColor(.secondary.opacity(0.5))
            Text(L("Select a snippet to view details", "Select a snippet to view details"))
                .font(.headline)
                .foregroundColor(.secondary)
            Text(L("or create a new one", "or create a new one"))
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                createNewSnippet()
            } label: {
                Label(L("New Snippet", "New Snippet"), systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    // MARK: - Footer Section

    private var footerSection: some View {
        HStack {
            // Settings toggles
            HStack(spacing: 16) {
                Toggle(L("Enable Snippets", "Enable Snippets"), isOn: $settings.isSnippetsEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: settings.isSnippetsEnabled) {
                        snippetManager.refreshConfiguration()
                    }

                Toggle(L("Repo Snippets", "Repo Snippets"), isOn: $settings.isRepoSnippetsEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!settings.isSnippetsEnabled)
                    .onChange(of: settings.isRepoSnippetsEnabled) {
                        snippetManager.refreshConfiguration()
                    }

                Toggle(L("Placeholders", "Placeholders"), isOn: $settings.snippetPlaceholdersEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!settings.isSnippetsEnabled)
            }

            Spacer()

            // Info
            HStack(spacing: 4) {
                Text(L("snippets.count", "%@ snippets", snippetManager.entries.count.formatted()))
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let repoRoot = snippetManager.activeRepoRoot {
                    Text(L("•", "•"))
                        .foregroundColor(.secondary)
                    Text(URL(fileURLWithPath: repoRoot).lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: - Actions

    private func defaultRepoRoot() -> String {
        if let current = snippetManager.activeRepoRoot {
            return current
        }
        return settings.recentRepoRoots.first ?? ""
    }

    private func createNewSnippet() {
        let source = selectedSource ?? .global
        let repoPath = source == .repo ? defaultRepoRoot() : ""
        editorDraft = SnippetDraft(source: source, repoPath: repoPath)
        isNewSnippet = true
        isEditorPresented = true
    }

    private func startEditing(_ entry: SnippetEntry) {
        let repoPath = entry.source == .repo ? (entry.repoRoot ?? defaultRepoRoot()) : ""
        editorDraft = SnippetDraft(
            id: entry.snippet.id,
            title: entry.snippet.title,
            body: entry.snippet.body,
            tagsText: entry.snippet.tags.joined(separator: ", "),
            folder: entry.snippet.folder ?? "",
            shellsText: entry.snippet.shells?.joined(separator: ", ") ?? "",
            key: entry.snippet.key ?? "",
            source: entry.source,
            repoPath: repoPath
        )
        isNewSnippet = false
        isEditorPresented = true
    }

    private func copySnippet(_ entry: SnippetEntry, to target: SnippetSource, repoRoot: String?) {
        if let repoRoot, !repoRoot.isEmpty {
            settings.recordRecentRepo(repoRoot)
        }
        snippetManager.duplicateSnippet(entry, to: target, repoRootOverride: repoRoot)
    }

    private func pickRepoRoot() -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L("snippets.repo.choose.message", "Choose a git repository")

        if panel.runModal() == .OK, let url = panel.url {
            if let root = SnippetManager.resolveRepoRoot(at: url.path) {
                settings.recordRecentRepo(root)
                return root
            } else {
                repoCopyErrorMessage = L("snippets.repo.choose.invalid", "That folder is not a git repository.")
                showRepoCopyError = true
            }
        }
        return nil
    }

    private func saveSnippet() {
        if isNewSnippet {
            snippetManager.createSnippet(from: editorDraft)
        } else if let entry = selectedSnippet {
            snippetManager.updateSnippet(entry: entry, with: editorDraft)
        }
        isEditorPresented = false
        // Refresh selection after save
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            if let id = editorDraft.id.isEmpty ? nil : editorDraft.id {
                selectedSnippet = snippetManager.entries.first { $0.snippet.id == id }
            }
        }
    }
}

// MARK: - Source Filter Button

private struct SourceFilterButton: View {
    let source: SnippetSource?
    let label: String
    let icon: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                Text(label)
                    .font(.system(size: 11))
                Text(count.formatted())
                    .font(.system(size: 10))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(isSelected ? Color.white.opacity(0.2) : Color.secondary.opacity(0.2))
                    .cornerRadius(4)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor : Color.clear)
            .foregroundColor(isSelected ? .white : .primary)
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Snippet List Row

private struct SnippetListRow: View {
    let entry: SnippetEntry
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: entry.source.icon)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.snippet.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(isSelected ? .white : .primary)
                    .lineLimit(1)

                Text(entry.snippet.body.replacingOccurrences(of: "\n", with: " "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
                    .lineLimit(1)
            }

            Spacer()

            if entry.isOverridden {
                Text(L("OVERRIDDEN", "OVERRIDDEN"))
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.orange)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.2))
                    .cornerRadius(3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor : Color.clear)
        .cornerRadius(6)
    }
}

// MARK: - Snippet Detail View

private struct SnippetDetailView: View {
    let entry: SnippetEntry
    let currentRepoRoot: String?
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onInsert: () -> Void
    let canCopyToCurrentRepo: Bool
    let repoCopyEnabled: Bool
    let onCopyToGlobal: () -> Void
    let onCopyToCurrentRepo: () -> Void
    let onCopyToRepoPicker: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.snippet.title)
                            .font(.title2.weight(.semibold))
                            .textSelection(.enabled)

                        HStack(spacing: 8) {
                            Label(entry.source.displayName, systemImage: entry.source.icon)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if let key = entry.snippet.validatedKey {
                                Text(L("snippets.key.label", "Key: %@", String(key)))
                                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                                    .foregroundColor(.accentColor)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15))
                                    .cornerRadius(3)
                                    .textSelection(.enabled)
                            }

                            if entry.isOverridden {
                                Text(L("OVERRIDDEN", "OVERRIDDEN"))
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundColor(.orange)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2))
                                    .cornerRadius(3)
                            }
                        }
                    }

                    Spacer()

                    HStack(spacing: 8) {
                        Button(action: onInsert) {
                            Label(L("Insert", "Insert"), systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(.bordered)

                        Menu {
                            if entry.source != .global {
                                Button(L("snippets.copy.global", "Copy to Global"), action: onCopyToGlobal)
                            }
                            if repoCopyEnabled {
                                if canCopyToCurrentRepo, currentRepoRoot != nil {
                                    Button(L("snippets.copy.repo.current", "Copy to Current Repo"), action: onCopyToCurrentRepo)
                                }
                                Button(L("snippets.copy.repo.choose", "Copy to Repo..."), action: onCopyToRepoPicker)
                            }
                        } label: {
                            Label(L("Copy", "Copy"), systemImage: "doc.on.doc")
                        }
                        .buttonStyle(.bordered)

                        Button(action: onEdit) {
                            Label(L("Edit", "Edit"), systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)

                        Button(action: onDelete) {
                            Label(L("Delete", "Delete"), systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
                }

                Divider()

                // Body
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Content", "Content"))
                        .font(.headline)

                    Text(entry.snippet.body)
                        .font(.system(size: 12, design: .monospaced))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                        .textSelection(.enabled)
                }

                // Metadata
                if !entry.snippet.tags.isEmpty || entry.snippet.folder != nil || entry.snippet.shells != nil {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("Metadata", "Metadata"))
                            .font(.headline)

                        HStack(spacing: 16) {
                            if !entry.snippet.tags.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L("Tags", "Tags"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    HStack(spacing: 4) {
                                        ForEach(entry.snippet.tags, id: \.self) { tag in
                                            Text(tag)
                                                .font(.system(size: 11))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Color.accentColor.opacity(0.2))
                                                .cornerRadius(4)
                                                .textSelection(.enabled)
                                        }
                                    }
                                }
                            }

                            if let folder = entry.snippet.folder {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L("Folder", "Folder"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(folder)
                                        .font(.system(size: 11))
                                        .textSelection(.enabled)
                                }
                            }

                            if let shells = entry.snippet.shells, !shells.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(L("Shells", "Shells"))
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(shells.joined(separator: ", "))
                                        .font(.system(size: 11))
                                        .textSelection(.enabled)
                                }
                            }
                        }
                    }
                }

                // Tokens help
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Available Tokens", "Available Tokens"))
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        TokenHelpRow(token: "${cwd}", description: L("snippets.token.cwd", "Current working directory"))
                        TokenHelpRow(token: "${home}", description: L("snippets.token.home", "User home directory"))
                        TokenHelpRow(token: "${date}", description: L("snippets.token.date", "Current date (yyyy-MM-dd)"))
                        TokenHelpRow(token: "${time}", description: L("snippets.token.time", "Current time (HH:mm:ss)"))
                        TokenHelpRow(token: "${clip}", description: L("snippets.token.clip", "Clipboard content"))
                        TokenHelpRow(token: "${env:VAR}", description: L("snippets.token.env", "Environment variable"))
                        TokenHelpRow(token: "${1:default}", description: L("snippets.token.placeholder", "Placeholder with Tab navigation"))
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }

                // Input variables help
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("Input Variables", "Input Variables"))
                        .font(.headline)

                    Text(L("Prompt for values when inserting a snippet", "Prompt for values when inserting a snippet"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)

                    VStack(alignment: .leading, spacing: 12) {
                        // Text input
                        InputVariableHelpSection(
                            title: L("snippets.input.text.title", "Text Input"),
                            icon: "character.cursor.ibeam",
                            color: .blue,
                            examples: [
                                ("${input:name}", L("snippets.input.text.example.basic", "Text field, no default")),
                                ("${input:port:8080}", L("snippets.input.text.example.default", "Text field with default value"))
                            ],
                            description: L("snippets.input.text.description", "Shows a text field. Use colon to set a default value.")
                        )

                        Divider()

                        // Single select
                        InputVariableHelpSection(
                            title: L("snippets.input.single.title", "Single Select"),
                            icon: "list.bullet",
                            color: .green,
                            examples: [
                                ("${input:env:dev|staging|prod}", L("snippets.input.single.example", "Dropdown picker"))
                            ],
                            description: L("snippets.input.single.description", "Options separated by | create a dropdown picker. User selects one option.")
                        )

                        Divider()

                        // Multi select
                        InputVariableHelpSection(
                            title: L("snippets.input.multi.title", "Multi Select"),
                            icon: "checklist",
                            color: .orange,
                            examples: [
                                ("${multiselect:flags:--verbose|--dry-run|--force}", L("snippets.input.multi.example", "Checkbox list"))
                            ],
                            description: L("snippets.input.multi.description", "Checkboxes for each option. Selected values joined with spaces.")
                        )
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }

                // Source path
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Source", "Source"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(entry.sourcePath)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }

                Spacer()
            }
            .padding()
        }
    }
}

private struct TokenHelpRow: View {
    let token: String
    let description: String

    var body: some View {
        HStack {
            Text(token)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.accentColor)
                .frame(width: 100, alignment: .leading)
                .textSelection(.enabled)
            Text(description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .textSelection(.enabled)
        }
    }
}

private struct InputVariableHelpSection: View {
    let title: String
    let icon: String
    let color: Color
    let examples: [(syntax: String, description: String)]
    let description: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
            }

            ForEach(examples, id: \.syntax) { example in
                HStack(spacing: 8) {
                    Text(example.syntax)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.1))
                        .cornerRadius(4)
                        .textSelection(.enabled)

                    Text(example.description)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }

            Text(description)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
                .italic()
                .textSelection(.enabled)
        }
    }
}

// MARK: - Snippet Editor Panel

private struct SnippetEditorPanel: View {
    @Binding var draft: SnippetDraft
    let isNew: Bool
    let repoSnippetsEnabled: Bool
    let currentRepoRoot: String?
    let recentRepoRoots: [String]
    let onCancel: () -> Void
    let onSave: () -> Void
    @State private var repoSelectionError = ""

    private var repoOptions: [String] {
        var options: [String] = []
        if let currentRepoRoot {
            options.append(currentRepoRoot)
        }
        for path in recentRepoRoots where path != currentRepoRoot {
            options.append(path)
        }
        if !draft.repoPath.isEmpty, !options.contains(draft.repoPath) {
            options.insert(draft.repoPath, at: 0)
        }
        return options
    }

    private func pickRepoRoot() {
        repoSelectionError = ""
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = L("snippets.repo.choose.message", "Choose a git repository")

        if panel.runModal() == .OK, let url = panel.url {
            if let root = SnippetManager.resolveRepoRoot(at: url.path) {
                draft.repoPath = root
                FeatureSettings.shared.recordRecentRepo(root)
            } else {
                repoSelectionError = L("snippets.repo.choose.invalid", "That folder is not a git repository.")
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Text(isNew ? L("snippets.editor.newTitle", "New Snippet") : L("snippets.editor.editTitle", "Edit Snippet"))
                        .font(.title2.weight(.semibold))

                    Spacer()

                    HStack(spacing: 8) {
                        Button(L("Cancel", "Cancel"), action: onCancel)
                            .buttonStyle(.bordered)

                        Button(L("Save", "Save"), action: onSave)
                            .buttonStyle(.borderedProminent)
                            .disabled(draft.title.isEmpty || draft.body.isEmpty || (draft.source == .repo && draft.repoPath.isEmpty))
                    }
                }

                Divider()

                // Title, ID, and Key
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Title", "Title"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField(L("Snippet title", "Snippet title"), text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("ID (auto-generated if empty)", "ID (auto-generated if empty)"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField(L("snippet-id", "snippet-id"), text: $draft.id)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .frame(width: 180)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Key (a-z)", "Key (a-z)"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("", text: $draft.key)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .help(L("Quick-select key for snippet picker (single letter a-z)", "Quick-select key for snippet picker (single letter a-z)"))
                    }
                    .frame(width: 60)
                }

                // Body
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Content", "Content"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextEditor(text: $draft.body)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 150)
                        .padding(4)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(8)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )

                    HStack(spacing: 16) {
                        Label(L("Text: ${input:name}", "Text: ${input:name}"), systemImage: "character.cursor.ibeam")
                        Label(L("Picker: ${input:name:a|b|c}", "Picker: ${input:name:a|b|c}"), systemImage: "list.bullet")
                        Label(L("Multi: ${multiselect:name:a|b|c}", "Multi: ${multiselect:name:a|b|c}"), systemImage: "checklist")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                }

                // Location picker
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Location", "Location"))
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("", selection: $draft.source) {
                        Label(SnippetSource.global.displayName, systemImage: SnippetSource.global.icon)
                            .tag(SnippetSource.global)
                        Label(SnippetSource.profile.displayName, systemImage: SnippetSource.profile.icon)
                            .tag(SnippetSource.profile)
                        if repoSnippetsEnabled {
                            Label(SnippetSource.repo.displayName, systemImage: SnippetSource.repo.icon)
                                .tag(SnippetSource.repo)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(draft.source.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                if draft.source == .repo, repoSnippetsEnabled {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("Repository", "Repository"))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        HStack(spacing: 8) {
                            Picker("", selection: $draft.repoPath) {
                                if repoOptions.isEmpty {
                                    Text(L("snippets.repo.none", "No recent repos")).tag("")
                                } else {
                                    ForEach(repoOptions, id: \.self) { path in
                                        Text(URL(fileURLWithPath: path).lastPathComponent).tag(path)
                                    }
                                }
                            }
                            .frame(maxWidth: 240)

                            Button(L("snippets.repo.choose", "Choose...")) {
                                pickRepoRoot()
                            }
                            .buttonStyle(.bordered)
                        }

                        if !draft.repoPath.isEmpty {
                            Text(draft.repoPath)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }

                        Text(L("snippets.repo.visibility", "Repo snippets appear only when that repo is active."))
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if !repoSelectionError.isEmpty {
                            Text(repoSelectionError)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                    }
                    .onChange(of: draft.source) {
                        if draft.source == .repo, draft.repoPath.isEmpty, let first = repoOptions.first {
                            draft.repoPath = first
                        }
                    }
                    .onChange(of: draft.repoPath) {
                        if !draft.repoPath.isEmpty {
                            FeatureSettings.shared.recordRecentRepo(draft.repoPath)
                        }
                    }
                    .onAppear {
                        if draft.repoPath.isEmpty, let first = repoOptions.first {
                            draft.repoPath = first
                        }
                    }
                }

                // Tags and Folder
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Tags (comma separated)", "Tags (comma separated)"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField(L("git, docker, aws", "git, docker, aws"), text: $draft.tagsText)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("Folder", "Folder"))
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField(L("Optional folder", "Optional folder"), text: $draft.folder)
                            .textFieldStyle(.roundedBorder)
                    }
                    .frame(width: 150)
                }

                // Shells
                VStack(alignment: .leading, spacing: 4) {
                    Text(L("Shells (leave empty for all)", "Shells (leave empty for all)"))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField(L("zsh, bash, fish", "zsh, bash, fish"), text: $draft.shellsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                Spacer()
            }
            .padding()
        }
        .onChange(of: repoSnippetsEnabled) {
            if !repoSnippetsEnabled, draft.source == .repo {
                draft.source = .global
                draft.repoPath = ""
            }
        }
    }
}

// MARK: - Import/Export Sheet

private struct ImportExportSheet: View {
    let mode: SnippetsSettingsView.ImportExportMode
    @Environment(\.dismiss) private var dismiss
    @State private var selectedSource: SnippetSource = .global
    @State private var importText = ""
    @State private var exportText = ""
    @State private var statusMessage = ""
    @State private var statusIsError = false
    @State private var isProcessing = false

    var body: some View {
        VStack(spacing: 16) {
            Text(mode == .import
                ? L("snippets.import.title", "Import Snippets")
                : L("snippets.export.title", "Export Snippets"))
                .font(.headline)

            if mode == .export {
                Picker(L("Source", "Source"), selection: $selectedSource) {
                    Text(SnippetSource.global.displayName).tag(SnippetSource.global)
                    Text(SnippetSource.profile.displayName).tag(SnippetSource.profile)
                    Text(SnippetSource.repo.displayName).tag(SnippetSource.repo)
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedSource) {
                    generateExport()
                }

                TextEditor(text: .constant(exportText))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 300)
                    .border(Color.secondary.opacity(0.3))

                HStack {
                    Button(L("Copy to Clipboard", "Copy to Clipboard")) {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(exportText, forType: .string)
                        statusMessage = L("snippets.export.copied", "Copied to clipboard!")
                        statusIsError = false
                    }
                    .disabled(exportText.isEmpty)

                    Button(L("Save to File...", "Save to File...")) {
                        saveToFile()
                    }
                    .disabled(exportText.isEmpty)

                    Spacer()

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(statusIsError ? .red : .green)
                    }
                }
            } else {
                Text(L("Paste JSON snippet data below:", "Paste JSON snippet data below:"))
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: $importText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 300)
                    .border(Color.secondary.opacity(0.3))

                Picker(L("Import to", "Import to"), selection: $selectedSource) {
                    Text(SnippetSource.global.displayName).tag(SnippetSource.global)
                    Text(SnippetSource.profile.displayName).tag(SnippetSource.profile)
                }
                .pickerStyle(.segmented)

                HStack {
                    Button(L("Load from File...", "Load from File...")) {
                        loadFromFile()
                    }

                    Button(L("Import", "Import")) {
                        performImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importText.isEmpty || isProcessing)

                    Spacer()

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(statusIsError ? .red : .green)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button(L("Done", "Done")) {
                    dismiss()
                }
                .keyboardShortcut(.escape)
            }
        }
        .padding()
        .frame(width: 500, height: 450)
        .onAppear {
            if mode == .export {
                generateExport()
            }
        }
    }

    private func generateExport() {
        let entries = SnippetManager.shared.entries.filter { $0.source == selectedSource }
        let snippets = entries.map { $0.snippet }
        let file = SnippetExportFile(version: 1, snippets: snippets)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        if let data = JSONOperations.encode(file, encoder: encoder, context: "snippet export"),
           let json = String(data: data, encoding: .utf8) {
            exportText = json
        } else {
            exportText = L("snippets.export.error.generate", "Error generating export")
        }
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = L(
            "snippets.export.filename",
            "%@-snippets.json",
            selectedSource.displayName.lowercased()
        )

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try exportText.write(to: url, atomically: true, encoding: .utf8)
                statusMessage = L("snippets.export.saved", "Saved!")
                statusIsError = false
            } catch {
                statusMessage = L("snippets.status.error", "Error: %@", error.localizedDescription)
                statusIsError = true
            }
        }
    }

    private func loadFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]

        if panel.runModal() == .OK, let url = panel.url {
            do {
                importText = try String(contentsOf: url, encoding: .utf8)
                statusMessage = L("snippets.import.fileLoaded", "File loaded")
                statusIsError = false
            } catch {
                statusMessage = L("snippets.status.error", "Error: %@", error.localizedDescription)
                statusIsError = true
            }
        }
    }

    private func performImport() {
        isProcessing = true
        statusMessage = ""
        statusIsError = false

        guard let data = importText.data(using: .utf8) else {
            statusMessage = L("snippets.import.invalidText", "Error: Invalid text")
            statusIsError = true
            isProcessing = false
            return
        }

        do {
            let file = try SnippetManager.snippetDecoder().decode(SnippetExportFile.self, from: data)

            for snippet in file.snippets {
                let draft = SnippetDraft(
                    id: snippet.id,
                    title: snippet.title,
                    body: snippet.body,
                    tagsText: snippet.tags.joined(separator: ", "),
                    folder: snippet.folder ?? "",
                    shellsText: snippet.shells?.joined(separator: ", ") ?? "",
                    key: snippet.key ?? "",
                    source: selectedSource
                )
                SnippetManager.shared.createSnippet(from: draft)
            }

            statusMessage = L(
                "snippets.import.success",
                "Imported %@ snippets!",
                file.snippets.count.formatted()
            )
            statusIsError = false
            importText = ""
        } catch {
            statusMessage = L("snippets.status.error", "Error: %@", error.localizedDescription)
            statusIsError = true
        }

        isProcessing = false
    }
}

private struct SnippetExportFile: Codable {
    let version: Int
    let snippets: [Snippet]
}

// MARK: - Window Controller

final class SnippetsSettingsWindowController: NSObject {
    static let shared = SnippetsSettingsWindowController()

    private var window: NSWindow?
    private var hostingView: NSHostingView<SnippetsSettingsView>?

    override private init() {
        super.init()
    }

    func show() {
        // If window exists and is visible, just bring it to front
        if let existing = window, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        // Create the view and hosting view
        let view = SnippetsSettingsView()
        let hosting = NSHostingView(rootView: view)
        hostingView = hosting

        // Create window
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = L("snippets.window.title", "Snippets")
        newWindow.contentView = hosting
        newWindow.contentMinSize = NSSize(width: 700, height: 500)
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)

        window = newWindow
        NSApp.activate(ignoringOtherApps: true)
    }
}
