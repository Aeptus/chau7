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
    }
}

// MARK: - Command Palette View

struct CommandPaletteView: View {
    @Binding var isVisible: Bool
    @State private var searchText = ""
    @State private var selectedIndex = 0
    @FocusState private var isSearchFocused: Bool

    let commands: [PaletteCommand]
    let onDismiss: () -> Void

    private var filteredCommands: [PaletteCommand] {
        if searchText.isEmpty {
            return commands
        }
        let query = searchText.lowercased()
        return commands.filter { command in
            command.title.lowercased().contains(query) ||
            command.category.rawValue.lowercased().contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search field
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                    .font(.system(size: 14))

                TextField("Type a command...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($isSearchFocused)
                    .accessibilityLabel("Search commands")
                    .accessibilityHint("Type to filter commands, press Return to execute selected command")
                    .onSubmit {
                        executeSelected()
                    }

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear search")
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
                Text("\(filteredCommands.count) commands")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .accessibilityLabel("\(filteredCommands.count) commands available")

                Spacer()

                HStack(spacing: 12) {
                    KeyHint(keys: ["↑", "↓"], label: "navigate")
                    KeyHint(keys: ["↵"], label: "select")
                    KeyHint(keys: ["esc"], label: "close")
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Use arrow keys to navigate, Return to select, Escape to close")
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isSearchFocused = true
            }
        }
        .onChange(of: searchText) { _ in
            selectedIndex = 0
        }
        .background(
            CommandPaletteKeyHandler(
                onUpArrow: {
                    if selectedIndex > 0 { selectedIndex -= 1 }
                },
                onDownArrow: {
                    if selectedIndex < filteredCommands.count - 1 { selectedIndex += 1 }
                },
                onEscape: { dismiss() },
                onReturn: { executeSelected() }
            )
        )
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

                Text(command.category.rawValue)
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
        .accessibilityLabel("\(command.title), \(command.category.rawValue)")
        .accessibilityHint(command.shortcut.map { "Shortcut: \($0)" } ?? "No keyboard shortcut")
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

// MARK: - Command Provider

final class CommandPaletteProvider {
    weak var appDelegate: AppDelegate?

    func buildCommands() -> [PaletteCommand] {
        guard let delegate = appDelegate else { return [] }

        return [
            // File commands
            PaletteCommand(title: "New Window", shortcut: "⌘N", category: .file, icon: "macwindow.badge.plus") {
                delegate.newOverlayWindow()
            },
            PaletteCommand(title: "New Tab", shortcut: "⌘T", category: .file, icon: "plus.square") {
                delegate.newTab()
            },
            PaletteCommand(title: "Close Tab", shortcut: "⌘W", category: .file, icon: "xmark.square") {
                delegate.closeTab()
            },
            PaletteCommand(title: "Close Window", shortcut: "⇧⌘W", category: .file, icon: "xmark.rectangle") {
                delegate.closeWindow()
            },
            PaletteCommand(title: "Close Other Tabs", shortcut: "⌥⌘W", category: .file, icon: "xmark.square.fill") {
                delegate.closeOtherTabs()
            },
            PaletteCommand(title: "Export Text...", shortcut: "⇧⌘S", category: .file, icon: "square.and.arrow.up") {
                delegate.exportText()
            },
            PaletteCommand(title: "Print...", shortcut: "⌘P", category: .file, icon: "printer") {
                delegate.printTerminal()
            },

            // Edit commands
            PaletteCommand(title: "Cut", shortcut: "⌘X", category: .edit, icon: "scissors") {
                delegate.cut()
            },
            PaletteCommand(title: "Copy", shortcut: "⌘C", category: .edit, icon: "doc.on.doc") {
                delegate.copyOrInterrupt()
            },
            PaletteCommand(title: "Paste", shortcut: "⌘V", category: .edit, icon: "doc.on.clipboard") {
                delegate.paste()
            },
            PaletteCommand(title: "Paste Escaped", shortcut: "⌥⌘V", category: .edit, icon: "doc.on.clipboard.fill") {
                delegate.pasteEscaped()
            },
            PaletteCommand(title: "Select All", shortcut: "⌘A", category: .edit, icon: "selection.pin.in.out") {
                delegate.selectAll()
            },
            PaletteCommand(title: "Find...", shortcut: "⌘F", category: .edit, icon: "magnifyingglass") {
                delegate.toggleSearch()
            },
            PaletteCommand(title: "Find Next", shortcut: "⌘G", category: .edit, icon: "arrow.down.circle") {
                delegate.nextSearchMatch()
            },
            PaletteCommand(title: "Find Previous", shortcut: "⇧⌘G", category: .edit, icon: "arrow.up.circle") {
                delegate.previousSearchMatch()
            },
            PaletteCommand(title: "Snippets...", shortcut: "⌘;", category: .edit, icon: "text.badge.plus") {
                delegate.toggleSnippets()
            },
            PaletteCommand(title: "Manage Snippets...", shortcut: nil, category: .edit, icon: "text.badge.checkmark") {
                delegate.showSnippetsSettings()
            },

            // View commands
            PaletteCommand(title: "Toggle Full Screen", shortcut: "⌃⌘F", category: .view, icon: "arrow.up.left.and.arrow.down.right") {
                delegate.toggleFullScreen()
            },
            PaletteCommand(title: "Zoom In", shortcut: "⌘=", category: .view, icon: "plus.magnifyingglass") {
                delegate.zoomIn()
            },
            PaletteCommand(title: "Zoom Out", shortcut: "⌘-", category: .view, icon: "minus.magnifyingglass") {
                delegate.zoomOut()
            },
            PaletteCommand(title: "Actual Size", shortcut: "⌘0", category: .view, icon: "1.magnifyingglass") {
                delegate.zoomReset()
            },

            // Terminal commands
            PaletteCommand(title: "Open Text Editor", shortcut: "⌥⌘E", category: .terminal, icon: "doc.text") {
                delegate.openTextEditorPane()
            },
            PaletteCommand(title: "Split Horizontal", shortcut: "⌘D", category: .terminal, icon: "rectangle.split.1x2") {
                delegate.splitHorizontally()
            },
            PaletteCommand(title: "Split Vertical", shortcut: "⇧⌘D", category: .terminal, icon: "rectangle.split.2x1") {
                delegate.splitVertically()
            },
            PaletteCommand(title: "Close Pane", shortcut: "⌃⌘W", category: .terminal, icon: "xmark.rectangle") {
                delegate.closeCurrentPane()
            },
            PaletteCommand(title: "Focus Next Pane", shortcut: "⌥⌘]", category: .terminal, icon: "arrow.right.square") {
                delegate.focusNextPane()
            },
            PaletteCommand(title: "Focus Previous Pane", shortcut: "⌥⌘[", category: .terminal, icon: "arrow.left.square") {
                delegate.focusPreviousPane()
            },
            PaletteCommand(title: "Clear Screen", shortcut: "⌘K", category: .terminal, icon: "clear") {
                delegate.clearScreen()
            },
            PaletteCommand(title: "Clear Scrollback", shortcut: "⇧⌘K", category: .terminal, icon: "clear.fill") {
                delegate.clearScrollback()
            },
            PaletteCommand(title: "Scroll to Top", shortcut: nil, category: .terminal, icon: "arrow.up.to.line") {
                delegate.scrollToTop()
            },
            PaletteCommand(title: "Scroll to Bottom", shortcut: nil, category: .terminal, icon: "arrow.down.to.line") {
                delegate.scrollToBottom()
            },

            // Tab commands
            PaletteCommand(title: "Show Next Tab", shortcut: "⇧⌘]", category: .tabs, icon: "arrow.right.square") {
                delegate.nextTab()
            },
            PaletteCommand(title: "Show Previous Tab", shortcut: "⇧⌘[", category: .tabs, icon: "arrow.left.square") {
                delegate.previousTab()
            },
            PaletteCommand(title: "Move Tab Right", shortcut: "⇧⌥⌘]", category: .tabs, icon: "arrow.right.to.line") {
                delegate.moveTabRight()
            },
            PaletteCommand(title: "Move Tab Left", shortcut: "⇧⌥⌘[", category: .tabs, icon: "arrow.left.to.line") {
                delegate.moveTabLeft()
            },
            PaletteCommand(title: "Rename Tab...", shortcut: "⇧⌘R", category: .tabs, icon: "pencil") {
                delegate.beginRenameTab()
            },

            // Window commands
            PaletteCommand(title: "Settings...", shortcut: "⌘,", category: .window, icon: "gear") {
                delegate.showSettings()
            },
            PaletteCommand(title: "Debug Console", shortcut: "⇧⌘L", category: .window, icon: "terminal") {
                DebugConsoleController.shared.toggle()
            },
            PaletteCommand(title: "SSH Connections...", shortcut: "⇧⌘O", category: .window, icon: "server.rack") {
                delegate.showSSHManager()
            },
            PaletteCommand(title: "Keyboard Shortcuts...", shortcut: nil, category: .window, icon: "keyboard") {
                delegate.showKeyboardShortcuts()
            },

            // Help commands
            PaletteCommand(title: "About Chau7", shortcut: nil, category: .help, icon: "info.circle") {
                delegate.showAbout()
            },
            PaletteCommand(title: "Documentation", shortcut: nil, category: .help, icon: "book") {
                delegate.showHelp()
            },
            PaletteCommand(title: "Report Issue", shortcut: nil, category: .help, icon: "exclamationmark.bubble") {
                delegate.reportIssue()
            },
        ]
    }
}

// MARK: - Key Handler (macOS 13 compatible)

private struct CommandPaletteKeyHandler: NSViewRepresentable {
    let onUpArrow: () -> Void
    let onDownArrow: () -> Void
    let onEscape: () -> Void
    let onReturn: () -> Void

    func makeNSView(context: Context) -> KeyHandlerView {
        let view = KeyHandlerView()
        view.onUpArrow = onUpArrow
        view.onDownArrow = onDownArrow
        view.onEscape = onEscape
        view.onReturn = onReturn
        return view
    }

    func updateNSView(_ nsView: KeyHandlerView, context: Context) {
        nsView.onUpArrow = onUpArrow
        nsView.onDownArrow = onDownArrow
        nsView.onEscape = onEscape
        nsView.onReturn = onReturn
    }

    final class KeyHandlerView: NSView {
        var onUpArrow: (() -> Void)?
        var onDownArrow: (() -> Void)?
        var onEscape: (() -> Void)?
        var onReturn: (() -> Void)?

        override var acceptsFirstResponder: Bool { true }

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

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            switch event.keyCode {
            case 126: // Up arrow
                onUpArrow?()
                return true
            case 125: // Down arrow
                onDownArrow?()
                return true
            case 53: // Escape
                onEscape?()
                return true
            case 36: // Return
                onReturn?()
                return true
            default:
                return super.performKeyEquivalent(with: event)
            }
        }
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

        let window = NSWindow(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .floating
        window.contentView = hostingView
        window.makeKeyAndOrderFront(nil)

        // Force focus on the search field by making the hosting view first responder
        // This is needed because @FocusState doesn't work reliably in borderless windows
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            window.makeFirstResponder(hostingView)
        }

        self.window = window
    }

    func hide() {
        isVisible = false
        window?.orderOut(nil)
        window = nil
        hostingView = nil
    }
}
