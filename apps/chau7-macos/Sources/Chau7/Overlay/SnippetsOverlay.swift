import SwiftUI
import AppKit
import Chau7Core

// MARK: - F21: Snippets Overlay

struct SnippetManagerOverlayView: View {
    var model: OverlayTabsModel
    var manager = SnippetManager.shared
    var settings = FeatureSettings.shared
    @State private var query = ""
    @State private var draft = SnippetDraft()
    @State private var editingEntry: SnippetEntry?
    @State private var isEditorVisible = false
    @State private var deleteTarget: SnippetEntry?
    // Variable input dialog state
    @State private var pendingVariableEntry: SnippetEntry?
    @State private var pendingVariables: [SnippetInputVariable] = []
    @State private var isVariableDialogVisible = false

    /// All available letters for quick selection (a-z)
    private static let allLetters = Set("abcdefghijklmnopqrstuvwxyz")

    private let panelMaxWidth: CGFloat = 560
    private let listMaxHeight: CGFloat = 400

    private var repoAvailable: Bool {
        FeatureSettings.shared.isRepoSnippetsEnabled && manager.activeRepoRoot != nil
    }

    private var preferredSource: SnippetSource {
        repoAvailable ? .repo : .global
    }

    /// Result of building the key map for snippets
    struct KeyMapResult {
        /// Maps snippet ID to its assigned key (nil if conflict or no key available)
        let snippetKeys: [String: Character]
        /// Maps key to snippet entry for quick lookup
        let keyToSnippet: [Character: SnippetEntry]
        /// Keys that have conflicts (multiple snippets claim the same custom key)
        let conflictingKeys: Set<Character>
    }

    /// Builds a key map for the given snippets:
    /// 1. Custom keys (from snippet.key) take priority
    /// 2. Conflicting custom keys are marked (neither gets the key)
    /// 3. Remaining snippets get auto-assigned from available letters
    private func buildKeyMap(for entries: [SnippetEntry]) -> KeyMapResult {
        var snippetKeys: [String: Character] = [:]
        var keyToSnippet: [Character: SnippetEntry] = [:]
        var usedKeys = Set<Character>()
        var conflictingKeys = Set<Character>()

        // First pass: assign custom keys and detect conflicts
        var customKeyEntries: [(entry: SnippetEntry, key: Character)] = []
        for entry in entries {
            if let customKey = entry.snippet.validatedKey {
                customKeyEntries.append((entry, customKey))
            }
        }

        // Group by key to detect conflicts
        let grouped = Dictionary(grouping: customKeyEntries) { $0.key }
        for (key, group) in grouped {
            if group.count > 1 {
                // Conflict: multiple snippets have the same custom key
                conflictingKeys.insert(key)
            } else if let first = group.first {
                // No conflict: assign the key
                snippetKeys[first.entry.id] = key
                keyToSnippet[key] = first.entry
                usedKeys.insert(key)
            }
        }

        // Second pass: auto-assign remaining letters to snippets without custom keys
        var availableLetters = Self.allLetters.subtracting(usedKeys).subtracting(conflictingKeys).sorted()
        for entry in entries {
            // Skip if already has a key assigned
            if snippetKeys[entry.id] != nil { continue }
            // Skip if has a conflicting custom key
            if let customKey = entry.snippet.validatedKey, conflictingKeys.contains(customKey) { continue }

            // Auto-assign next available letter
            if let nextLetter = availableLetters.first {
                snippetKeys[entry.id] = nextLetter
                keyToSnippet[nextLetter] = entry
                availableLetters.removeFirst()
            }
        }

        return KeyMapResult(
            snippetKeys: snippetKeys,
            keyToSnippet: keyToSnippet,
            conflictingKeys: conflictingKeys
        )
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Main snippet selector panel
            DraggableOverlay(id: "snippets", workspace: model.overlayWorkspaceIdentifier, maxWidth: panelMaxWidth) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        OverlayCloseButton(action: { model.toggleSnippetManager() })
                        Text(L("Snippets", "Snippets"))
                            .font(.custom("Avenir Next", size: 12).weight(.semibold))
                        Spacer()
                        Button(L("New", "New")) {
                            startCreate()
                        }
                        .controlSize(.small)
                        .disabled(!settings.isSnippetsEnabled)
                    }

                    if !settings.isSnippetsEnabled {
                        Text(L("Snippets are disabled in Settings.", "Snippets are disabled in Settings."))
                            .font(.custom("Avenir Next", size: 11))
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        let filtered = manager.filteredEntries(query: query)
                        let keyMap = buildKeyMap(for: filtered)

                        SnippetSearchField(
                            text: $query,
                            onEscape: { model.toggleSnippetManager() },
                            onLetterKey: { letter in
                                if query.isEmpty, !isEditorVisible, !isVariableDialogVisible {
                                    if let entry = keyMap.keyToSnippet[letter] {
                                        attemptInsert(entry)
                                    }
                                }
                            }
                        )

                        if isEditorVisible, !isVariableDialogVisible {
                            SnippetEditorView(
                                draft: $draft,
                                isNew: editingEntry == nil,
                                repoAvailable: repoAvailable,
                                onCancel: cancelEdit,
                                onSave: saveEdit
                            )
                        } else {
                            if filtered.isEmpty {
                                Text(L("No snippets found.", "No snippets found."))
                                    .font(.custom("Avenir Next", size: 11))
                                    .foregroundStyle(.secondary)
                                    .padding(.vertical, 8)
                            } else {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 6) {
                                        ForEach(filtered) { entry in
                                            let assignedKey = query.isEmpty ? keyMap.snippetKeys[entry.id] : nil
                                            let hasConflict = entry.snippet.validatedKey.map { keyMap.conflictingKeys.contains($0) } ?? false
                                            SnippetRowView(
                                                entry: entry,
                                                quickSelectLetter: assignedKey,
                                                hasKeyConflict: hasConflict,
                                                onInsert: { attemptInsert(entry) },
                                                onEdit: { startEdit(entry) },
                                                onDelete: { deleteTarget = entry },
                                                onTogglePin: { manager.togglePin(entry) }
                                            )
                                        }
                                    }
                                }
                                .frame(maxHeight: listMaxHeight)

                                if query.isEmpty {
                                    Text(L("Press a letter to quick-insert", "Press a letter to quick-insert"))
                                        .font(.custom("Avenir Next", size: 10))
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }

                    if let root = manager.activeRepoRoot, settings.isRepoSnippetsEnabled {
                        Text(String(format: L("snippet.repo", "Repo: %@"), root))
                            .font(.custom("Avenir Next", size: 9))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
                .onAppear {
                    query = ""
                }
                .alert(item: $deleteTarget) { entry in
                    Alert(
                        title: Text(L("Delete snippet?", "Delete snippet?")),
                        message: Text(entry.snippet.title),
                        primaryButton: .destructive(Text(L("Delete", "Delete"))) {
                            manager.deleteSnippet(entry)
                        },
                        secondaryButton: .cancel()
                    )
                }
            }

            // Variable input dialog — separate floating panel on top
            if isVariableDialogVisible, let entry = pendingVariableEntry {
                DraggableOverlay(id: "snippet-variables", workspace: model.overlayWorkspaceIdentifier, maxWidth: 420) {
                    SnippetVariableDialog(
                        snippetTitle: entry.snippet.title,
                        variables: $pendingVariables,
                        onCancel: cancelVariableInput,
                        onInsert: insertWithVariables
                    )
                }
                .padding(.top, 50)
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(1)
            }
        }
    }

    private func startCreate() {
        let repoPath = preferredSource == .repo ? (manager.activeRepoRoot ?? "") : ""
        draft = SnippetDraft(source: preferredSource, repoPath: repoPath)
        editingEntry = nil
        isEditorVisible = true
    }

    private func startEdit(_ entry: SnippetEntry) {
        draft = SnippetDraft(
            id: entry.snippet.id,
            title: entry.snippet.title,
            body: entry.snippet.body,
            tagsText: entry.snippet.tags.joined(separator: ", "),
            folder: entry.snippet.folder ?? "",
            shellsText: entry.snippet.shells?.joined(separator: ", ") ?? "",
            key: entry.snippet.key ?? "",
            source: entry.source,
            repoPath: entry.repoRoot ?? ""
        )
        editingEntry = entry
        isEditorVisible = true
    }

    private func cancelEdit() {
        isEditorVisible = false
        editingEntry = nil
    }

    private func saveEdit() {
        let cleaned = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        var finalDraft = draft
        finalDraft.title = cleaned
        if let entry = editingEntry {
            manager.updateSnippet(entry: entry, with: finalDraft)
        } else {
            manager.createSnippet(from: finalDraft)
        }
        isEditorVisible = false
        editingEntry = nil
    }

    /// Attempts to insert a snippet, showing variable dialog if needed
    private func attemptInsert(_ entry: SnippetEntry) {
        let variables = SnippetManager.parseInputVariables(from: entry.snippet.body)
        if variables.isEmpty {
            // No variables - insert directly
            model.insertSnippet(entry)
        } else {
            // Has variables - show dialog
            pendingVariableEntry = entry
            pendingVariables = variables
            isVariableDialogVisible = true
        }
    }

    /// Cancels variable input and returns to snippet list
    private func cancelVariableInput() {
        isVariableDialogVisible = false
        pendingVariableEntry = nil
        pendingVariables = []
    }

    /// Inserts snippet with filled-in variables
    private func insertWithVariables() {
        guard let entry = pendingVariableEntry else { return }
        model.insertSnippetWithVariables(entry, variables: pendingVariables)
        cancelVariableInput()
    }
}

struct SnippetRowView: View {
    let entry: SnippetEntry
    let quickSelectLetter: Character?
    let hasKeyConflict: Bool
    let onInsert: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onTogglePin: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Quick select letter badge
            if let letter = quickSelectLetter {
                Text(String(letter))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.accentColor.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            } else if hasKeyConflict, let conflictKey = entry.snippet.validatedKey {
                // Show conflicting key with warning style
                Text(String(conflictKey))
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Color.orange.opacity(0.8))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .help(
                        Text(
                            String(
                                format: L("snippets.conflictKey", "Key '%@' is used by multiple snippets"),
                                String(conflictKey)
                            )
                        )
                    )
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if entry.snippet.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.accentColor)
                    }

                    Text(entry.snippet.title)
                        .font(.custom("Avenir Next", size: 11).weight(.semibold))

                    Text(entry.source.displayName.uppercased())
                        .font(.system(size: 8, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(overlayChipBackground)
                        .clipShape(Capsule())

                    if entry.isOverridden {
                        Text(L("OVERRIDDEN", "OVERRIDDEN"))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }

                    if hasKeyConflict {
                        Text(L("KEY CONFLICT", "KEY CONFLICT"))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                }

                Text(entry.snippet.body)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)

                if !entry.snippet.tags.isEmpty {
                    Text(entry.snippet.tags.joined(separator: ", "))
                        .font(.custom("Avenir Next", size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Button(action: onTogglePin) {
                    Image(systemName: entry.snippet.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 10))
                        .foregroundStyle(entry.snippet.isPinned ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(entry.snippet.isPinned ? L("Unpin", "Unpin") : L("Pin to top", "Pin to top"))

                Button(action: onInsert) {
                    Image(systemName: "arrow.down.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(L("Insert", "Insert"))

                Button(action: onEdit) {
                    Image(systemName: "pencil")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(L("Edit", "Edit"))

                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                }
                .buttonStyle(.plain)
                .help(L("Delete", "Delete"))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(overlayRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: L("accessibility.snippet", "Snippet: %@"), entry.snippet.title))
        .accessibilityHint(L("Tap to insert into terminal", "Tap to insert into terminal"))
        .onTapGesture {
            onInsert()
        }
    }
}

struct SnippetEditorView: View {
    @Binding var draft: SnippetDraft
    let isNew: Bool
    let repoAvailable: Bool
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(isNew ? "New Snippet" : "Edit Snippet")
                .font(.custom("Avenir Next", size: 11).weight(.semibold))

            HStack(spacing: 8) {
                TextField(L("Title", "Title"), text: $draft.title)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                TextField(L("ID (optional)", "ID (optional)"), text: $draft.id)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(maxWidth: 120)
                TextField(L("Key", "Key"), text: $draft.key)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 40)
                    .help(L("Quick-select key (single letter a-z)", "Quick-select key (single letter a-z)"))
            }

            TextEditor(text: $draft.body)
                .font(.system(size: 11, design: .monospaced))
                .frame(height: OverlayLayout.colorPreviewHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.1), lineWidth: 1)
                )

            Text(L("Variables: ${input:Name} or ${input:Name:default}", "Variables: ${input:Name} or ${input:Name:default}"))
                .font(.custom("Avenir Next", size: 9))
                .foregroundStyle(.tertiary)

            HStack(spacing: 8) {
                TextField(L("Tags (comma separated)", "Tags (comma separated)"), text: $draft.tagsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
                TextField(L("Folder", "Folder"), text: $draft.folder)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))
            }

            HStack(spacing: 8) {
                TextField(L("Shells (zsh, bash, fish)", "Shells (zsh, bash, fish)"), text: $draft.shellsText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 10))

                Picker(L("Location", "Location"), selection: $draft.source) {
                    Text(SnippetSource.global.displayName).tag(SnippetSource.global)
                    Text(SnippetSource.profile.displayName).tag(SnippetSource.profile)
                    if repoAvailable {
                        Text(SnippetSource.repo.displayName).tag(SnippetSource.repo)
                    }
                }
                .frame(maxWidth: OverlayLayout.colorPickerMaxWidth)
            }

            HStack {
                Spacer()
                Button(L("Cancel", "Cancel")) { onCancel() }
                    .controlSize(.small)
                Button(L("Save", "Save")) { onSave() }
                    .controlSize(.small)
            }
        }
        .padding(8)
        .background(overlayRowBackground)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Snippet Variable Input Dialog

struct SnippetVariableDialog: View {
    let snippetTitle: String
    @Binding var variables: [SnippetInputVariable]
    let onCancel: () -> Void
    let onInsert: () -> Void
    @FocusState private var focusedField: String?

    /// Creates a safe binding to a variable's value that won't crash if index becomes invalid
    /// This prevents crashes when the array is cleared while text field callbacks are pending
    private func safeValueBinding(for variable: SnippetInputVariable) -> Binding<String> {
        Binding<String>(
            get: {
                // Find by id instead of index for safety
                variables.first(where: { $0.id == variable.id })?.value ?? variable.value
            },
            set: { newValue in
                // Find and update by id instead of index
                if let idx = variables.firstIndex(where: { $0.id == variable.id }) {
                    variables[idx].value = newValue
                }
            }
        )
    }

    /// Creates a safe binding to a variable's selectedOptions for multi-select
    private func safeSelectedOptionsBinding(for variable: SnippetInputVariable) -> Binding<Set<String>> {
        Binding<Set<String>>(
            get: {
                variables.first(where: { $0.id == variable.id })?.selectedOptions ?? variable.selectedOptions
            },
            set: { newValue in
                if let idx = variables.firstIndex(where: { $0.id == variable.id }) {
                    variables[idx].selectedOptions = newValue
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                OverlayCloseButton(action: onCancel)
                Image(systemName: "doc.text.fill")
                    .foregroundStyle(.secondary)
                Text(L("Fill in variables", "Fill in variables"))
                    .font(.custom("Avenir Next", size: 12).weight(.semibold))
                Spacer()
                Text(snippetTitle)
                    .font(.custom("Avenir Next", size: 11))
                    .foregroundStyle(.secondary)
            }

            // Use ForEach with identifiable items instead of indices to avoid binding crashes
            // when the array is modified while text field callbacks are pending
            ForEach(variables) { variable in
                SnippetVariableRow(
                    variable: variable,
                    valueBinding: safeValueBinding(for: variable),
                    selectedOptionsBinding: safeSelectedOptionsBinding(for: variable),
                    focusedField: $focusedField,
                    onSubmit: {
                        // Move to next field or submit
                        if let currentIndex = variables.firstIndex(where: { $0.id == variable.id }),
                           currentIndex < variables.count - 1 {
                            focusedField = variables[currentIndex + 1].id
                        } else {
                            onInsert()
                        }
                    }
                )
            }

            HStack {
                Spacer()
                Button(L("Cancel", "Cancel")) { onCancel() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
                Button(L("Insert", "Insert")) { onInsert() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }

            Text(L("Tab to next field • Enter to insert", "Tab to next field • Enter to insert"))
                .font(.custom("Avenir Next", size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .onAppear {
            // Focus first text field (pickers don't need focus)
            if let first = variables.first(where: { $0.inputType == .text }) {
                focusedField = first.id
            }
        }
    }
}

/// Helper view for each variable row - renders appropriate control based on input type
private struct SnippetVariableRow: View {
    let variable: SnippetInputVariable
    @Binding var valueBinding: String
    @Binding var selectedOptionsBinding: Set<String>
    var focusedField: FocusState<String?>.Binding
    let onSubmit: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(variable.name)
                .font(.custom("Avenir Next", size: 10).weight(.medium))
                .foregroundStyle(.secondary)

            switch variable.inputType {
            case .text:
                TextField(
                    variable.defaultValue.isEmpty ? "Enter value..." : variable.defaultValue,
                    text: $valueBinding
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11))
                .focused(focusedField, equals: variable.id)
                .onSubmit(onSubmit)

            case .singleSelect:
                if variable.options.isEmpty {
                    // Fallback to text field if options array is empty (defensive)
                    TextField(L("Enter value...", "Enter value..."), text: $valueBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                } else {
                    Picker("", selection: $valueBinding) {
                        ForEach(variable.options, id: \.self) { option in
                            Text(option).tag(option)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .font(.system(size: 11))
                }

            case .multiSelect:
                if variable.options.isEmpty {
                    // Fallback to text field if options array is empty (defensive)
                    TextField(L("Enter values (space-separated)...", "Enter values (space-separated)..."), text: $valueBinding)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11))
                } else {
                    MultiSelectOptionsView(
                        options: variable.options,
                        selectedOptions: $selectedOptionsBinding
                    )
                }
            }
        }
    }
}

/// Multi-select options displayed as toggle buttons
private struct MultiSelectOptionsView: View {
    let options: [String]
    @Binding var selectedOptions: Set<String>

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.self) { option in
                MultiSelectOptionButton(
                    option: option,
                    isSelected: selectedOptions.contains(option),
                    onToggle: {
                        if selectedOptions.contains(option) {
                            selectedOptions.remove(option)
                        } else {
                            selectedOptions.insert(option)
                        }
                    }
                )
            }
        }
    }
}

/// Individual toggle button for multi-select option
private struct MultiSelectOptionButton: View {
    let option: String
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white : .secondary)
                Text(option)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .white : .primary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(isSelected ? Color.accentColor : Color.secondary.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// Simple flow layout for multi-select options
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = computeLayout(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y), proposal: .unspecified)
        }
    }

    private func computeLayout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, positions: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            totalWidth = max(totalWidth, currentX - spacing)
        }

        return (CGSize(width: totalWidth, height: currentY + lineHeight), positions)
    }
}

// MARK: - Snippet Search Field (with quick-select letter handling)

private struct SnippetSearchField: NSViewRepresentable {
    @Binding var text: String
    var onEscape: () -> Void
    var onLetterKey: (Character) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> SnippetKeyHandlingTextField {
        let field = SnippetKeyHandlingTextField()
        field.placeholderString = "Search snippets (or press a-z to quick-select)"
        field.font = NSFont.systemFont(ofSize: 11)
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.textColor = NSColor.labelColor
        field.isBordered = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .default
        field.delegate = context.coordinator
        field.onEscape = onEscape
        field.onLetterKey = onLetterKey
        field.textBinding = $text

        // Request focus with retry logic to handle view hierarchy timing
        field.focusWithRetry()
        return field
    }

    func updateNSView(_ nsView: SnippetKeyHandlingTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.onEscape = onEscape
        nsView.onLetterKey = onLetterKey
        nsView.textBinding = $text
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: SnippetSearchField

        init(_ parent: SnippetSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
                parent.onEscape()
                return true
            }
            return false
        }
    }

    final class SnippetKeyHandlingTextField: NSTextField {
        var onEscape: (() -> Void)?
        var onLetterKey: ((Character) -> Void)?
        var textBinding: Binding<String>?

        /// Generation counter to cancel stale focus retries
        private var focusGeneration = 0

        func focusIfNeeded() {
            guard let window else { return }
            if window.firstResponder === self {
                return
            }
            if let editor = window.firstResponder as? NSTextView, editor.delegate as? NSTextField === self {
                return
            }
            window.makeFirstResponder(self)
        }

        /// Focuses the field with retry logic for when view hierarchy isn't ready
        func focusWithRetry(attempts: Int = 3, delay: TimeInterval = 0.05) {
            // Increment generation to cancel any pending retries from previous calls
            focusGeneration += 1
            let currentGeneration = focusGeneration
            focusWithRetryInternal(attempts: attempts, delay: delay, generation: currentGeneration)
        }

        private func focusWithRetryInternal(attempts: Int, delay: TimeInterval, generation: Int) {
            // Cancel if generation has changed (panel was closed/reopened)
            guard generation == focusGeneration else { return }
            guard attempts > 0 else { return }

            // Check if still in view hierarchy
            guard let window, superview != nil else {
                // Not in hierarchy yet, retry
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.focusWithRetryInternal(attempts: attempts - 1, delay: delay * 2, generation: generation)
                }
                return
            }

            // Already focused
            if window.firstResponder === self { return }
            if let editor = window.firstResponder as? NSTextView, editor.delegate as? NSTextField === self { return }

            // Try to focus
            let success = window.makeFirstResponder(self)
            if !success {
                // Focus failed, retry with longer delay
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.focusWithRetryInternal(attempts: attempts - 1, delay: delay * 2, generation: generation)
                }
            }
        }

        /// Cancel pending focus retries (call when view is being removed)
        func cancelFocusRetries() {
            focusGeneration += 1
        }

        override func keyDown(with event: NSEvent) {
            // Escape key
            if event.keyCode == 53 {
                onEscape?()
                return
            }

            // Check for letter keys (a-z) when field is empty
            if let chars = event.charactersIgnoringModifiers,
               chars.count == 1,
               let char = chars.lowercased().first,
               char >= "a", char <= "z",
               event.modifierFlags.isDisjoint(with: [.command, .control, .option]) {
                // Only trigger quick-select if the field is empty
                if stringValue.isEmpty {
                    onLetterKey?(char)
                    return
                }
            }

            super.keyDown(with: event)
        }
    }
}
