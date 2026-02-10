import SwiftUI
import AppKit

// MARK: - Command Definition

struct PaletteCommand: Identifiable {
    let id = UUID()
    let title: String
    let shortcut: String?
    let category: CommandCategory
    let icon: String
    let action: () -> Void

    enum CommandCategory: String, CaseIterable {
        case file = "File"
        case edit = "Edit"
        case view = "View"
        case terminal = "Terminal"
        case tabs = "Tabs"
        case window = "Window"
        case help = "Help"

        var localizedTitle: String {
            switch self {
            case .file:
                return L("command.category.file", "File")
            case .edit:
                return L("command.category.edit", "Edit")
            case .view:
                return L("command.category.view", "View")
            case .terminal:
                return L("command.category.terminal", "Terminal")
            case .tabs:
                return L("command.category.tabs", "Tabs")
            case .window:
                return L("command.category.window", "Window")
            case .help:
                return L("command.category.help", "Help")
            }
        }
    }
}

// MARK: - Command Palette View

struct CommandPaletteView: View {
    @Binding var isVisible: Bool
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @State private var shouldFocusSearch = false

    let commands: [PaletteCommand]
    let onDismiss: () -> Void

    private var filteredCommands: [PaletteCommand] {
        if searchText.isEmpty {
            return commands
        }
        let query = searchText.lowercased()
        return commands.filter { command in
            command.title.lowercased().contains(query) ||
            command.category.localizedTitle.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))

                CommandPaletteSearchField(
                    text: $searchText,
                    shouldFocus: shouldFocusSearch,
                    onReturn: { executeSelected() },
                    onUpArrow: {
                        if selectedIndex > 0 { selectedIndex -= 1 }
                    },
                    onDownArrow: {
                        if selectedIndex < filteredCommands.count - 1 { selectedIndex += 1 }
                    },
                    onEscape: { dismiss() }
                )
                .frame(maxWidth: .infinity)
                .accessibilityLabel(L("Search commands", "Search commands"))
                .accessibilityHint(L("Type to filter commands, press Return to execute selected command", "Type to filter commands, press Return to execute selected command"))

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(L("Clear search", "Clear search"))
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(NSColor.controlBackgroundColor))

            Divider()

            // Command list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                            CommandRow(
                                command: command,
                                isSelected: index == selectedIndex
                            )
                            .id(index)
                            .onTapGesture {
                                selectedIndex = index
                                executeSelected()
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 350)
                .onChange(of: selectedIndex) { newValue in
                    withAnimation(.easeInOut(duration: 0.1)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }

            // Footer
            HStack {
                Text(String(format: L("command.count", "%d commands"), filteredCommands.count))
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .accessibilityLabel(
                        String(format: L("command.count.available", "%d commands available"), filteredCommands.count)
                    )

                Spacer()

                HStack(spacing: 12) {
                    KeyHint(keys: ["↑", "↓"], label: L("command.hint.navigate", "navigate"))
                    KeyHint(keys: ["↵"], label: L("command.hint.select", "select"))
                    KeyHint(keys: ["esc"], label: L("command.hint.close", "close"))
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(L("Use arrow keys to navigate, Return to select, Escape to close", "Use arrow keys to navigate, Return to select, Escape to close"))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))
        }
        .frame(width: 500)
        .background(Color(NSColor.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.3), radius: 20, y: 5)
        .onAppear {
            selectedIndex = 0
            searchText = ""
            shouldFocusSearch = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                shouldFocusSearch = false
            }
        }
        .onChange(of: searchText) { _ in
            selectedIndex = 0
        }
    }

    private func executeSelected() {
        guard selectedIndex < filteredCommands.count else { return }
        let command = filteredCommands[selectedIndex]
        dismiss()
        // Small delay to let the palette close before executing
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            command.action()
        }
    }

    private func dismiss() {
        isVisible = false
        onDismiss()
    }
}

// MARK: - Command Row

private struct CommandRow: View {
    let command: PaletteCommand
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.icon)
                .font(.system(size: 13))
                .foregroundColor(isSelected ? .white : .secondary)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .font(.system(size: 13))
                    .foregroundColor(isSelected ? .white : .primary)

                Text(command.category.localizedTitle)
                    .font(.system(size: 10))
                    .foregroundColor(isSelected ? .white.opacity(0.7) : .secondary)
            }

            Spacer()

            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(isSelected ? Color.white.opacity(0.2) : Color(NSColor.separatorColor).opacity(0.5))
                    )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(format: L("command.accessibility.label", "%@, %@"), command.title, command.category.localizedTitle)
        )
        .accessibilityHint(
            command.shortcut.map { String(format: L("command.accessibility.shortcut", "Shortcut: %@"), $0) }
                ?? L("command.accessibility.noShortcut", "No keyboard shortcut")
        )
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Key Hint

private struct KeyHint: View {
    let keys: [String]
    let label: String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(keys, id: \.self) { key in
                Text(key)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(Color(NSColor.separatorColor).opacity(0.5))
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }
}

// MARK: - Search Field (Arrow/Escape Handling)

private struct CommandPaletteSearchField: NSViewRepresentable {
    @Binding var text: String
    var shouldFocus: Bool
    var onReturn: () -> Void
    var onUpArrow: () -> Void
    var onDownArrow: () -> Void
    var onEscape: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> KeyHandlingTextField {
        let field = KeyHandlingTextField()
        field.placeholderString = L("command.search.placeholder", "Type a command...")
        field.font = NSFont.systemFont(ofSize: 14)
        field.isEditable = true
        field.isSelectable = true
        field.usesSingleLineMode = true
        field.lineBreakMode = .byTruncatingTail
        field.textColor = NSColor.labelColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = context.coordinator
        field.onReturn = onReturn
        field.onUpArrow = onUpArrow
        field.onDownArrow = onDownArrow
        field.onEscape = onEscape
        return field
    }

    func updateNSView(_ nsView: KeyHandlingTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.shouldFocus = shouldFocus
        nsView.onReturn = onReturn
        nsView.onUpArrow = onUpArrow
        nsView.onDownArrow = onDownArrow
        nsView.onEscape = onEscape
        if shouldFocus {
            nsView.focusIfNeeded()
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: CommandPaletteSearchField

        init(_ parent: CommandPaletteSearchField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            parent.text = field.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                parent.onUpArrow()
                return true
            case #selector(NSResponder.moveDown(_:)):
                parent.onDownArrow()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)):
                parent.onReturn()
                return true
            default:
                return false
            }
        }
    }

    final class KeyHandlingTextField: NSTextField {
        var onReturn: (() -> Void)?
        var onUpArrow: (() -> Void)?
        var onDownArrow: (() -> Void)?
        var onEscape: (() -> Void)?
        var shouldFocus = false

        func focusIfNeeded() {
            guard let window else { return }
            if window.firstResponder === self {
                return
            }
            if let editor = window.firstResponder as? NSTextView, editor.delegate as? NSTextField === self {
                return
            }
            DispatchQueue.main.async {
                window.makeFirstResponder(self)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if shouldFocus {
                focusIfNeeded()
            }
        }

        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 126: // Up arrow
                onUpArrow?()
            case 125: // Down arrow
                onDownArrow?()
            case 53: // Escape
                onEscape?()
            case 36: // Return
                onReturn?()
            default:
                super.keyDown(with: event)
            }
        }
    }
}

// MARK: - Command Provider

final class CommandPaletteProvider {
    weak var appDelegate: AppDelegate?

    func buildCommands() -> [PaletteCommand] {
        guard let delegate = appDelegate else { return [] }

        return [
            // File commands
            PaletteCommand(title: L("commandPalette.command.newWindow", "New Window"), shortcut: "⌘N", category: .file, icon: "macwindow.badge.plus") {
                delegate.newOverlayWindow()
            },
            PaletteCommand(title: L("commandPalette.command.newTab", "New Tab"), shortcut: "⌘T", category: .file, icon: "plus.square") {
                delegate.newTab()
            },
            PaletteCommand(title: L("commandPalette.command.closeTab", "Close Tab"), shortcut: "⌘W", category: .file, icon: "xmark.square") {
                delegate.closeTab()
            },
            PaletteCommand(title: L("commandPalette.command.closeWindow", "Close Window"), shortcut: "⇧⌘W", category: .file, icon: "xmark.rectangle") {
                delegate.closeWindow()
            },
            PaletteCommand(title: L("commandPalette.command.closeOtherTabs", "Close Other Tabs"), shortcut: "⌥⌘W", category: .file, icon: "xmark.square.fill") {
                delegate.closeOtherTabs()
            },
            PaletteCommand(title: L("commandPalette.command.exportText", "Export Text..."), shortcut: "⇧⌘S", category: .file, icon: "square.and.arrow.up") {
                delegate.exportText()
            },
            PaletteCommand(title: L("commandPalette.command.print", "Print..."), shortcut: "⌘P", category: .file, icon: "printer") {
                delegate.printTerminal()
            },

            // Edit commands
            PaletteCommand(title: L("commandPalette.command.cut", "Cut"), shortcut: "⌘X", category: .edit, icon: "scissors") {
                delegate.cut()
            },
            PaletteCommand(title: L("commandPalette.command.copy", "Copy"), shortcut: "⌘C", category: .edit, icon: "doc.on.doc") {
                delegate.copyOrInterrupt()
            },
            PaletteCommand(title: L("commandPalette.command.paste", "Paste"), shortcut: "⌘V", category: .edit, icon: "doc.on.clipboard") {
                delegate.paste()
            },
            PaletteCommand(title: L("commandPalette.command.pasteEscaped", "Paste Escaped"), shortcut: "⌥⌘V", category: .edit, icon: "doc.on.clipboard.fill") {
                delegate.pasteEscaped()
            },
            PaletteCommand(title: L("commandPalette.command.selectAll", "Select All"), shortcut: "⌘A", category: .edit, icon: "selection.pin.in.out") {
                delegate.selectAll()
            },
            PaletteCommand(title: L("commandPalette.command.find", "Find..."), shortcut: "⌘F", category: .edit, icon: "magnifyingglass") {
                delegate.toggleSearch()
            },
            PaletteCommand(title: L("commandPalette.command.findNext", "Find Next"), shortcut: "⌘G", category: .edit, icon: "arrow.down.circle") {
                delegate.nextSearchMatch()
            },
            PaletteCommand(title: L("commandPalette.command.findPrevious", "Find Previous"), shortcut: "⇧⌘G", category: .edit, icon: "arrow.up.circle") {
                delegate.previousSearchMatch()
            },
            PaletteCommand(title: L("commandPalette.command.useSelectionForFind", "Use Selection for Find"), shortcut: "⌘E", category: .edit, icon: "text.magnifyingglass") {
                delegate.useSelectionForFind()
            },
            PaletteCommand(title: L("commandPalette.command.snippets", "Snippets..."), shortcut: "⌘;", category: .edit, icon: "text.badge.plus") {
                delegate.toggleSnippets()
            },
            PaletteCommand(title: L("commandPalette.command.manageSnippets", "Manage Snippets..."), shortcut: nil, category: .edit, icon: "text.badge.checkmark") {
                delegate.showSnippetsSettings()
            },
            PaletteCommand(title: L("commandPalette.command.migrateSnippets", "Migrate Snippets to Clean JSON"), shortcut: nil, category: .edit, icon: "arrow.triangle.2.circlepath") {
                SnippetManager.shared.migrateToCleanJSON()
            },

            // View commands
            PaletteCommand(title: L("commandPalette.command.toggleFullScreen", "Toggle Full Screen"), shortcut: "⌃⌘F", category: .view, icon: "arrow.up.left.and.arrow.down.right") {
                delegate.toggleFullScreen()
            },
            PaletteCommand(title: L("commandPalette.command.zoomIn", "Zoom In"), shortcut: "⌘=", category: .view, icon: "plus.magnifyingglass") {
                delegate.zoomIn()
            },
            PaletteCommand(title: L("commandPalette.command.zoomOut", "Zoom Out"), shortcut: "⌘-", category: .view, icon: "minus.magnifyingglass") {
                delegate.zoomOut()
            },
            PaletteCommand(title: L("commandPalette.command.actualSize", "Actual Size"), shortcut: "⌘0", category: .view, icon: "1.magnifyingglass") {
                delegate.zoomReset()
            },

            // Terminal commands
            PaletteCommand(title: L("commandPalette.command.openTextEditor", "Open Text Editor"), shortcut: "⌥⌘E", category: .terminal, icon: "doc.text") {
                delegate.openTextEditorPane()
            },
            PaletteCommand(title: L("commandPalette.command.appendSelectionToEditor", "Append Selection to Editor"), shortcut: "⇧⌘E", category: .terminal, icon: "text.append") {
                delegate.appendSelectionToEditor()
            },
            PaletteCommand(title: L("commandPalette.command.splitHorizontal", "Split Horizontal"), shortcut: "⌘D", category: .terminal, icon: "rectangle.split.1x2") {
                delegate.splitHorizontally()
            },
            PaletteCommand(title: L("commandPalette.command.splitVertical", "Split Vertical"), shortcut: "⇧⌘D", category: .terminal, icon: "rectangle.split.2x1") {
                delegate.splitVertically()
            },
            PaletteCommand(title: L("commandPalette.command.closePane", "Close Pane"), shortcut: "⌃⌘W", category: .terminal, icon: "xmark.rectangle") {
                delegate.closeCurrentPane()
            },
            PaletteCommand(title: L("commandPalette.command.focusNextPane", "Focus Next Pane"), shortcut: "⌥⌘]", category: .terminal, icon: "arrow.right.square") {
                delegate.focusNextPane()
            },
            PaletteCommand(title: L("commandPalette.command.focusPreviousPane", "Focus Previous Pane"), shortcut: "⌥⌘[", category: .terminal, icon: "arrow.left.square") {
                delegate.focusPreviousPane()
            },
            PaletteCommand(title: L("commandPalette.command.clearScreen", "Clear Screen"), shortcut: "⌘K", category: .terminal, icon: "clear") {
                delegate.clearScreen()
            },
            PaletteCommand(title: L("commandPalette.command.clearScrollback", "Clear Scrollback"), shortcut: "⇧⌘K", category: .terminal, icon: "clear.fill") {
                delegate.clearScrollback()
            },
            PaletteCommand(title: L("commandPalette.command.scrollToTop", "Scroll to Top"), shortcut: nil, category: .terminal, icon: "arrow.up.to.line") {
                delegate.scrollToTop()
            },
            PaletteCommand(title: L("commandPalette.command.scrollToBottom", "Scroll to Bottom"), shortcut: nil, category: .terminal, icon: "arrow.down.to.line") {
                delegate.scrollToBottom()
            },
            PaletteCommand(title: L("commandPalette.command.previousInputLine", "Previous Input Line"), shortcut: "⌘↑", category: .terminal, icon: "arrow.up.to.line") {
                delegate.scrollToPreviousInputLine()
            },
            PaletteCommand(title: L("commandPalette.command.nextInputLine", "Next Input Line"), shortcut: "⌘↓", category: .terminal, icon: "arrow.down.to.line") {
                delegate.scrollToNextInputLine()
            },

            // Tab commands
            PaletteCommand(title: L("commandPalette.command.showNextTab", "Show Next Tab"), shortcut: "⇧⌘]", category: .tabs, icon: "arrow.right.square") {
                delegate.nextTab()
            },
            PaletteCommand(title: L("commandPalette.command.showPreviousTab", "Show Previous Tab"), shortcut: "⇧⌘[", category: .tabs, icon: "arrow.left.square") {
                delegate.previousTab()
            },
            PaletteCommand(title: L("commandPalette.command.moveTabRight", "Move Tab Right"), shortcut: "⇧⌥⌘]", category: .tabs, icon: "arrow.right.to.line") {
                delegate.moveTabRight()
            },
            PaletteCommand(title: L("commandPalette.command.moveTabLeft", "Move Tab Left"), shortcut: "⇧⌥⌘[", category: .tabs, icon: "arrow.left.to.line") {
                delegate.moveTabLeft()
            },
            PaletteCommand(title: L("commandPalette.command.renameTab", "Rename Tab..."), shortcut: "⇧⌘R", category: .tabs, icon: "pencil") {
                delegate.beginRenameTab()
            },
            PaletteCommand(title: L("commandPalette.command.forceRefreshTab", "Force Refresh Tab"), shortcut: nil, category: .tabs, icon: "arrow.clockwise") {
                delegate.forceRefreshTab()
            },
            PaletteCommand(title: L("commandPalette.command.selectTab1", "Select Tab 1"), shortcut: "⌘1", category: .tabs, icon: "1.circle") {
                delegate.selectTab(number: 1)
            },
            PaletteCommand(title: L("commandPalette.command.selectTab2", "Select Tab 2"), shortcut: "⌘2", category: .tabs, icon: "2.circle") {
                delegate.selectTab(number: 2)
            },
            PaletteCommand(title: L("commandPalette.command.selectTab3", "Select Tab 3"), shortcut: "⌘3", category: .tabs, icon: "3.circle") {
                delegate.selectTab(number: 3)
            },
            PaletteCommand(title: L("commandPalette.command.selectTab4", "Select Tab 4"), shortcut: "⌘4", category: .tabs, icon: "4.circle") {
                delegate.selectTab(number: 4)
            },
            PaletteCommand(title: L("commandPalette.command.selectTab5", "Select Tab 5"), shortcut: "⌘5", category: .tabs, icon: "5.circle") {
                delegate.selectTab(number: 5)
            },
            PaletteCommand(title: L("commandPalette.command.selectTab6", "Select Tab 6"), shortcut: "⌘6", category: .tabs, icon: "6.circle") {
                delegate.selectTab(number: 6)
            },
            PaletteCommand(title: L("commandPalette.command.selectTab7", "Select Tab 7"), shortcut: "⌘7", category: .tabs, icon: "7.circle") {
                delegate.selectTab(number: 7)
            },
            PaletteCommand(title: L("commandPalette.command.selectTab8", "Select Tab 8"), shortcut: "⌘8", category: .tabs, icon: "8.circle") {
                delegate.selectTab(number: 8)
            },
            PaletteCommand(title: L("commandPalette.command.selectTab9", "Select Tab 9"), shortcut: "⌘9", category: .tabs, icon: "9.circle") {
                delegate.selectTab(number: 9)
            },

            // Window commands
            PaletteCommand(title: L("commandPalette.command.settings", "Settings..."), shortcut: "⌘,", category: .window, icon: "gear") {
                delegate.showSettings()
            },
            PaletteCommand(title: L("commandPalette.command.debugConsole", "Debug Console"), shortcut: "⇧⌘L", category: .window, icon: "terminal") {
                DebugConsoleController.shared.toggle()
            },
            PaletteCommand(title: L("commandPalette.command.sshConnections", "SSH Connections..."), shortcut: "⇧⌘O", category: .window, icon: "server.rack") {
                delegate.showSSHManager()
            },
            PaletteCommand(title: L("commandPalette.command.keyboardShortcuts", "Keyboard Shortcuts..."), shortcut: "⌘/", category: .window, icon: "keyboard") {
                delegate.showKeyboardShortcuts()
            },

            // Help commands
            PaletteCommand(title: L("commandPalette.command.about", "About Chau7"), shortcut: nil, category: .help, icon: "info.circle") {
                delegate.showAbout()
            },
            PaletteCommand(title: L("commandPalette.command.documentation", "Documentation"), shortcut: nil, category: .help, icon: "book") {
                delegate.showHelp()
            },
            PaletteCommand(title: L("commandPalette.command.reportIssue", "Report Issue"), shortcut: nil, category: .help, icon: "exclamationmark.bubble") {
                delegate.reportIssue()
            },
        ]
    }
}

// MARK: - Command Palette Controller

final class CommandPaletteController: ObservableObject {
    static let shared = CommandPaletteController()

    @Published var isVisible = false

    private var window: NSWindow?
    private var hostingView: NSHostingView<AnyView>?
    private let provider = CommandPaletteProvider()

    private init() {}

    private final class CommandPalettePanel: NSPanel {
        override var canBecomeKey: Bool { true }
        override var canBecomeMain: Bool { true }
    }

    func setup(appDelegate: AppDelegate) {
        provider.appDelegate = appDelegate
    }

    func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard !isVisible else { return }
        isVisible = true

        let commands = provider.buildCommands()
        let view = CommandPaletteView(
            isVisible: Binding(
                get: { self.isVisible },
                set: { self.isVisible = $0 }
            ),
            commands: commands,
            onDismiss: { [weak self] in
                self?.hide()
            }
        )

        let hostingView = NSHostingView(rootView: AnyView(view))
        self.hostingView = hostingView

        // Calculate size
        let size = hostingView.fittingSize
        let width = max(500, size.width)
        let height = min(450, max(200, size.height))

        // Position at top center of screen
        guard let screen = NSScreen.main else { return }
        let screenFrame = screen.visibleFrame
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - height - 100

        let window = CommandPalettePanel(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.isMovableByWindowBackground = true
        window.hidesOnDeactivate = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = window
    }

    func hide() {
        isVisible = false
        window?.orderOut(nil)
        window = nil
        hostingView = nil
    }
}
