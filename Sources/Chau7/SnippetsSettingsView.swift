import SwiftUI
import AppKit

// MARK: - Snippets Settings View

struct SnippetsSettingsView: View {
    @ObservedObject private var settings = FeatureSettings.shared
    @ObservedObject private var snippetManager = SnippetManager.shared
    @State private var selectedSource: SnippetSource? = .global
    @State private var searchText = ""
    @State private var selectedSnippet: SnippetEntry?
    @State private var isEditorPresented = false
    @State private var editorDraft = SnippetDraft()
    @State private var isNewSnippet = false
    @State private var showDeleteConfirmation = false
    @State private var snippetToDelete: SnippetEntry?
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
        .alert("Delete Snippet", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let entry = snippetToDelete {
                    snippetManager.deleteSnippet(entry)
                    selectedSnippet = nil
                }
            }
        } message: {
            Text("Are you sure you want to delete \"\(snippetToDelete?.snippet.title ?? "")\"? This cannot be undone.")
        }
        .sheet(isPresented: $showImportExportSheet) {
            ImportExportSheet(mode: importExportMode)
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Snippets")
                    .font(.headline)
                Text("Manage reusable text snippets • Press ⌘; to open snippet picker")
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
                    Label("Import", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.bordered)

                Button {
                    importExportMode = .export
                    showImportExportSheet = true
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)

                Button {
                    createNewSnippet()
                } label: {
                    Label("New Snippet", systemImage: "plus")
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
                TextField("Search snippets...", text: $searchText)
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
                label: "All",
                icon: "tray.full",
                count: snippetManager.entries.count,
                isSelected: selectedSource == nil
            ) {
                selectedSource = nil
            }

            SourceFilterButton(
                source: .global,
                label: "User",
                icon: SnippetSource.global.icon,
                count: snippetManager.entries.filter { $0.source == .global }.count,
                isSelected: selectedSource == .global
            ) {
                selectedSource = .global
            }

            if snippetManager.repoRoot != nil {
                SourceFilterButton(
                    source: .repo,
                    label: "Repo",
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
            Text(searchText.isEmpty ? "No snippets yet" : "No matching snippets")
                .font(.headline)
                .foregroundColor(.secondary)
            Text(searchText.isEmpty ? "Click \"New Snippet\" to create one" : "Try a different search term")
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
                    repoAvailable: snippetManager.repoRoot != nil,
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
            Text("Select a snippet to view details")
                .font(.headline)
                .foregroundColor(.secondary)
            Text("or create a new one")
                .font(.caption)
                .foregroundColor(.secondary)

            Button {
                createNewSnippet()
            } label: {
                Label("New Snippet", systemImage: "plus")
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
                Toggle("Enable Snippets", isOn: $settings.isSnippetsEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .onChange(of: settings.isSnippetsEnabled) { _ in
                        snippetManager.refreshConfiguration()
                    }

                Toggle("Repo Snippets", isOn: $settings.isRepoSnippetsEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!settings.isSnippetsEnabled)
                    .onChange(of: settings.isRepoSnippetsEnabled) { _ in
                        snippetManager.refreshConfiguration()
                    }

                Toggle("Placeholders", isOn: $settings.snippetPlaceholdersEnabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .disabled(!settings.isSnippetsEnabled)
            }

            Spacer()

            // Info
            HStack(spacing: 4) {
                Text("\(snippetManager.entries.count) snippets")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if let repoRoot = snippetManager.repoRoot {
                    Text("•")
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

    private func createNewSnippet() {
        editorDraft = SnippetDraft(source: selectedSource ?? .global)
        isNewSnippet = true
        isEditorPresented = true
    }

    private func startEditing(_ entry: SnippetEntry) {
        editorDraft = SnippetDraft(
            id: entry.snippet.id,
            title: entry.snippet.title,
            body: entry.snippet.body,
            tagsText: entry.snippet.tags.joined(separator: ", "),
            folder: entry.snippet.folder ?? "",
            shellsText: entry.snippet.shells?.joined(separator: ", ") ?? "",
            source: entry.source
        )
        isNewSnippet = false
        isEditorPresented = true
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
                Text("\(count)")
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
                Text("OVERRIDDEN")
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
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onInsert: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.snippet.title)
                            .font(.title2.weight(.semibold))

                        HStack(spacing: 8) {
                            Label(entry.source.displayName, systemImage: entry.source.icon)
                                .font(.caption)
                                .foregroundColor(.secondary)

                            if entry.isOverridden {
                                Text("OVERRIDDEN")
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
                            Label("Insert", systemImage: "arrow.down.doc")
                        }
                        .buttonStyle(.bordered)

                        Button(action: onEdit) {
                            Label("Edit", systemImage: "pencil")
                        }
                        .buttonStyle(.bordered)

                        Button(action: onDelete) {
                            Label("Delete", systemImage: "trash")
                        }
                        .buttonStyle(.bordered)
                        .foregroundColor(.red)
                    }
                }

                Divider()

                // Body
                VStack(alignment: .leading, spacing: 8) {
                    Text("Content")
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
                        Text("Metadata")
                            .font(.headline)

                        HStack(spacing: 16) {
                            if !entry.snippet.tags.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Tags")
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
                                        }
                                    }
                                }
                            }

                            if let folder = entry.snippet.folder {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Folder")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(folder)
                                        .font(.system(size: 11))
                                }
                            }

                            if let shells = entry.snippet.shells, !shells.isEmpty {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Shells")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(shells.joined(separator: ", "))
                                        .font(.system(size: 11))
                                }
                            }
                        }
                    }
                }

                // Tokens help
                VStack(alignment: .leading, spacing: 8) {
                    Text("Available Tokens")
                        .font(.headline)

                    VStack(alignment: .leading, spacing: 4) {
                        TokenHelpRow(token: "${cwd}", description: "Current working directory")
                        TokenHelpRow(token: "${home}", description: "User home directory")
                        TokenHelpRow(token: "${date}", description: "Current date (yyyy-MM-dd)")
                        TokenHelpRow(token: "${time}", description: "Current time (HH:mm:ss)")
                        TokenHelpRow(token: "${clip}", description: "Clipboard content")
                        TokenHelpRow(token: "${env:VAR}", description: "Environment variable")
                        TokenHelpRow(token: "${1:default}", description: "Placeholder with Tab navigation")
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(8)
                }

                // Source path
                VStack(alignment: .leading, spacing: 4) {
                    Text("Source")
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
            Text(description)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Snippet Editor Panel

private struct SnippetEditorPanel: View {
    @Binding var draft: SnippetDraft
    let isNew: Bool
    let repoAvailable: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Header
                HStack {
                    Text(isNew ? "New Snippet" : "Edit Snippet")
                        .font(.title2.weight(.semibold))

                    Spacer()

                    HStack(spacing: 8) {
                        Button("Cancel", action: onCancel)
                            .buttonStyle(.bordered)

                        Button("Save", action: onSave)
                            .buttonStyle(.borderedProminent)
                            .disabled(draft.title.isEmpty || draft.body.isEmpty)
                    }
                }

                Divider()

                // Title and ID
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Title")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Snippet title", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("ID (auto-generated if empty)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("snippet-id", text: $draft.id)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                    }
                    .frame(width: 180)
                }

                // Body
                VStack(alignment: .leading, spacing: 4) {
                    Text("Content")
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
                }

                // Location picker
                VStack(alignment: .leading, spacing: 4) {
                    Text("Location")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Picker("", selection: $draft.source) {
                        Label(SnippetSource.global.displayName, systemImage: SnippetSource.global.icon)
                            .tag(SnippetSource.global)
                        Label(SnippetSource.profile.displayName, systemImage: SnippetSource.profile.icon)
                            .tag(SnippetSource.profile)
                        if repoAvailable {
                            Label(SnippetSource.repo.displayName, systemImage: SnippetSource.repo.icon)
                                .tag(SnippetSource.repo)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text(draft.source.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                // Tags and Folder
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Tags (comma separated)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("git, docker, aws", text: $draft.tagsText)
                            .textFieldStyle(.roundedBorder)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Folder")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        TextField("Optional folder", text: $draft.folder)
                            .textFieldStyle(.roundedBorder)
                    }
                    .frame(width: 150)
                }

                // Shells
                VStack(alignment: .leading, spacing: 4) {
                    Text("Shells (leave empty for all)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("zsh, bash, fish", text: $draft.shellsText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }

                Spacer()
            }
            .padding()
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
    @State private var isProcessing = false

    var body: some View {
        VStack(spacing: 16) {
            Text(mode == .import ? "Import Snippets" : "Export Snippets")
                .font(.headline)

            if mode == .export {
                Picker("Source", selection: $selectedSource) {
                    Text(SnippetSource.global.displayName).tag(SnippetSource.global)
                    Text(SnippetSource.profile.displayName).tag(SnippetSource.profile)
                    Text(SnippetSource.repo.displayName).tag(SnippetSource.repo)
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedSource) { _ in
                    generateExport()
                }

                TextEditor(text: .constant(exportText))
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 300)
                    .border(Color.secondary.opacity(0.3))

                HStack {
                    Button("Copy to Clipboard") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(exportText, forType: .string)
                        statusMessage = "Copied to clipboard!"
                    }
                    .disabled(exportText.isEmpty)

                    Button("Save to File...") {
                        saveToFile()
                    }
                    .disabled(exportText.isEmpty)

                    Spacer()

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
            } else {
                Text("Paste JSON snippet data below:")
                    .font(.caption)
                    .foregroundColor(.secondary)

                TextEditor(text: $importText)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 300)
                    .border(Color.secondary.opacity(0.3))

                Picker("Import to", selection: $selectedSource) {
                    Text(SnippetSource.global.displayName).tag(SnippetSource.global)
                    Text(SnippetSource.profile.displayName).tag(SnippetSource.profile)
                }
                .pickerStyle(.segmented)

                HStack {
                    Button("Load from File...") {
                        loadFromFile()
                    }

                    Button("Import") {
                        performImport()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(importText.isEmpty || isProcessing)

                    Spacer()

                    if !statusMessage.isEmpty {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundColor(statusMessage.contains("Error") ? .red : .green)
                    }
                }
            }

            Divider()

            HStack {
                Spacer()
                Button("Done") {
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

        if let data = try? encoder.encode(file),
           let json = String(data: data, encoding: .utf8) {
            exportText = json
        } else {
            exportText = "Error generating export"
        }
    }

    private func saveToFile() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(selectedSource.displayName.lowercased())-snippets.json"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try exportText.write(to: url, atomically: true, encoding: .utf8)
                statusMessage = "Saved!"
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func loadFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]

        if panel.runModal() == .OK, let url = panel.url {
            do {
                importText = try String(contentsOf: url, encoding: .utf8)
                statusMessage = "File loaded"
            } catch {
                statusMessage = "Error: \(error.localizedDescription)"
            }
        }
    }

    private func performImport() {
        isProcessing = true
        statusMessage = ""

        guard let data = importText.data(using: .utf8) else {
            statusMessage = "Error: Invalid text"
            isProcessing = false
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let file = try decoder.decode(SnippetExportFile.self, from: data)

            for snippet in file.snippets {
                let draft = SnippetDraft(
                    id: snippet.id,
                    title: snippet.title,
                    body: snippet.body,
                    tagsText: snippet.tags.joined(separator: ", "),
                    folder: snippet.folder ?? "",
                    shellsText: snippet.shells?.joined(separator: ", ") ?? "",
                    source: selectedSource
                )
                SnippetManager.shared.createSnippet(from: draft)
            }

            statusMessage = "Imported \(file.snippets.count) snippets!"
            importText = ""
        } catch {
            statusMessage = "Error: \(error.localizedDescription)"
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

    private override init() {
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
        self.hostingView = hosting

        // Create window
        let newWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        newWindow.title = "Snippets"
        newWindow.contentView = hosting
        newWindow.contentMinSize = NSSize(width: 700, height: 500)
        newWindow.isReleasedWhenClosed = false
        newWindow.center()
        newWindow.makeKeyAndOrderFront(nil)

        self.window = newWindow
        NSApp.activate(ignoringOtherApps: true)
    }
}
