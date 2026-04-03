import SwiftUI
import AppKit

@main
struct Chau7App: App {
    @State private var model: AppModel
    @State private var overlayModel: OverlayTabsModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private static var initCount = 0

    init() {
        Self.initCount += 1
        if Self.initCount > 1 {
            Log.warn("Chau7App.init() called \(Self.initCount) times — SwiftUI is recreating the App struct (pid=\(ProcessInfo.processInfo.processIdentifier))")
        }

        // Pre-initialize shell integration BEFORE creating any tabs
        TerminalSessionModel.preInitialize()

        let model = AppModel()
        _model = State(wrappedValue: model)
        let overlayModel = OverlayTabsModel(appModel: model)
        // All resolvers search ALL windows via TerminalControlService.allTabs,
        // not just window 0's overlayModel. Without this, notifications for tabs
        // in window 1+ never get titles, repo names, or tab IDs resolved.
        NotificationManager.shared.tabTitleProvider = { target in
            let tabs = TerminalControlService.shared.allTabs
            return TabResolver.resolve(target, in: tabs)?.displayTitle
        }
        NotificationManager.shared.repoNameProvider = { target in
            let tabs = TerminalControlService.shared.allTabs
            guard let tab = TabResolver.resolve(target, in: tabs),
                  let session = tab.displaySession ?? tab.session,
                  let rootPath = session.gitRootPath else { return nil }
            return URL(fileURLWithPath: rootPath).lastPathComponent
        }
        model.tabIDResolver = { target in
            let tabs = TerminalControlService.shared.allTabs
            return TabResolver.resolve(target, in: tabs)?.id
        }

        // Wire notification system — single delegate replaces 5 separate closures
        NotificationActionExecutor.shared.delegate = NotificationActionAdapter(
            overlayModel: overlayModel,
            statusBar: StatusBarController.shared
        )

        // Wire activeTabChecker so onlyWhenTabInactive condition works
        NotificationManager.shared.activeTabChecker = { target in
            let tabs = TerminalControlService.shared.allTabs
            guard let tab = TabResolver.resolve(target, in: tabs) else { return false }
            // Check if this tab is the selected tab in ANY window
            return TerminalControlService.shared.allModels
                .contains { $0.model.selectedTabID == tab.id }
        }

        // Wire tabResolver so external events get tabID filled in
        NotificationManager.shared.tabResolver = { target in
            let tabs = TerminalControlService.shared.allTabs
            return TabResolver.resolve(target, in: tabs)?.id
        }

        _overlayModel = State(wrappedValue: overlayModel)
        _ = SnippetManager.shared
        AppIcon.apply()
        let policy: NSApplication.ActivationPolicy = FeatureSettings.shared.menuBarOnlyMode ? .accessory : .regular
        NSApplication.shared.setActivationPolicy(policy)
        appDelegate.configureModels(model: model, overlayModel: overlayModel)
        RemoteControlManager.shared.configure(overlayModel: overlayModel)
    }

    var body: some Scene {
        // Status bar is handled by StatusBarController for multi-monitor support
        Settings {
            EmptyView()
        }
        .commands {

            // MARK: - App Menu

            CommandGroup(replacing: .appSettings) {
                Button(L("Settings...", "Settings...")) {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",")
            }

            // MARK: - File Menu

            CommandGroup(replacing: .newItem) {
                Button(L("New Window", "New Window")) {
                    appDelegate.newOverlayWindow()
                }
                .keyboardShortcut("n")

                Button(L("New Tab", "New Tab")) {
                    appDelegate.newTab()
                }
                .keyboardShortcut("t")

                Button(L("SSH Connections...", "SSH Connections...")) {
                    appDelegate.showSSHManager()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button(L("Close Tab", "Close Tab")) {
                    appDelegate.closeTab()
                }
                .keyboardShortcut("w")

                Button(L("Close Window", "Close Window")) {
                    appDelegate.closeWindow()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Button(L("Close Other Tabs", "Close Other Tabs")) {
                    appDelegate.closeOtherTabs()
                }
                .keyboardShortcut("w", modifiers: [.command, .option])

                Button(L("Reopen Closed Tab", "Reopen Closed Tab")) {
                    appDelegate.reopenClosedTab()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Divider()

                Button(L("Export Text...", "Export Text...")) {
                    appDelegate.exportText()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .saveItem) {}
            CommandGroup(replacing: .importExport) {}

            CommandGroup(replacing: .printItem) {
                Button(L("Print...", "Print...")) {
                    appDelegate.printTerminal()
                }
                .keyboardShortcut("p")
            }

            // MARK: - Edit Menu

            CommandGroup(replacing: .pasteboard) {
                Button(L("Cut", "Cut")) {
                    appDelegate.cut()
                }
                .keyboardShortcut("x")

                Button(L("Copy", "Copy")) {
                    appDelegate.copyOrInterrupt()
                }
                .keyboardShortcut("c")

                Button(L("Paste", "Paste")) {
                    appDelegate.paste()
                }
                .keyboardShortcut("v")

                Button(L("AutoFill from Passwords...", "AutoFill from Passwords...")) {
                    appDelegate.autofillFromPasswords()
                }

                Button(L("Paste Escaped", "Paste Escaped")) {
                    appDelegate.pasteEscaped()
                }
                .keyboardShortcut("v", modifiers: [.command, .option])

                Button(L("Select All", "Select All")) {
                    appDelegate.selectAll()
                }
                .keyboardShortcut("a")
            }

            CommandGroup(replacing: .textEditing) {
                Menu(L("menu.find", "Find")) {
                    Button(L("Find...", "Find...")) {
                        appDelegate.toggleSearch()
                    }
                    .keyboardShortcut("f")

                    Button(L("Find Next", "Find Next")) {
                        appDelegate.nextSearchMatch()
                    }
                    .keyboardShortcut("g")

                    Button(L("Find Previous", "Find Previous")) {
                        appDelegate.previousSearchMatch()
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])

                    Divider()

                    Button(L("Use Selection for Find", "Use Selection for Find")) {
                        appDelegate.useSelectionForFind()
                    }
                    .keyboardShortcut("e")
                }

                Divider()

                // Shortcut ⌘; is handled by the AppDelegate local event monitor.
                // Do NOT add .keyboardShortcut here — SwiftUI menu shortcuts and
                // local monitors are separate dispatch paths; both fire, causing
                // toggleSnippets to be called twice (on→off) and triggering
                // fullscreen exit on macOS autoHideMenuBar windows.
                Button(L("Snippets...\t⌘;", "Snippets...\t⌘;")) {
                    appDelegate.toggleSnippets()
                }

                Button(L("Command Palette...", "Command Palette...")) {
                    appDelegate.toggleCommandPalette()
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
            }

            // MARK: - View Menu

            CommandGroup(after: .toolbar) {
                Button(L("Data Explorer", "Data Explorer")) {
                    DataExplorerWindow.shared.show()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button(L("Enter Full Screen", "Enter Full Screen")) {
                    appDelegate.toggleFullScreen()
                }
                .keyboardShortcut("f", modifiers: [.command, .control])

                Divider()

                Button(L("Zoom In", "Zoom In")) {
                    appDelegate.zoomIn()
                }
                .keyboardShortcut("=")

                Button(L("Zoom Out", "Zoom Out")) {
                    appDelegate.zoomOut()
                }
                .keyboardShortcut("-")

                Button(L("Actual Size", "Actual Size")) {
                    appDelegate.zoomReset()
                }
                .keyboardShortcut("à")

                Divider()

                Button(L("Clear Screen", "Clear Screen")) {
                    appDelegate.clearScreen()
                }
                .keyboardShortcut("k")

                Button(L("Clear Scrollback", "Clear Scrollback")) {
                    appDelegate.clearScrollback()
                }
                .keyboardShortcut("k", modifiers: [.command, .option])

                Divider()

                Button(L("Previous Input Line", "Previous Input Line")) {
                    appDelegate.scrollToPreviousInputLine()
                }
                .keyboardShortcut(.upArrow, modifiers: .command)

                Button(L("Next Input Line", "Next Input Line")) {
                    appDelegate.scrollToNextInputLine()
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Divider()

                // MARK: - Panes

                Menu(L("menu.panes", "Panes")) {
                    Button(L("Split Horizontally", "Split Horizontally")) {
                        appDelegate.splitHorizontally()
                    }
                    .keyboardShortcut("d")

                    Button(L("Split Vertically", "Split Vertically")) {
                        appDelegate.splitVertically()
                    }
                    .keyboardShortcut("d", modifiers: [.command, .option])

                    Divider()

                    Button(L("Open Text Editor", "Open Text Editor")) {
                        appDelegate.openTextEditorPane()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .option])

                    Button(L("Open File Preview", "Open File Preview")) {
                        appDelegate.openFilePreviewPane()
                    }
                    .keyboardShortcut("o", modifiers: [.command, .option])

                    Button(L("Open Diff Viewer", "Open Diff Viewer")) {
                        appDelegate.openDiffViewerPane()
                    }
                    .keyboardShortcut("d", modifiers: [.command, .option, .shift])

                    Button(L("Repository", "Repository")) {
                        appDelegate.openRepositoryPane()
                    }
                    .keyboardShortcut("b", modifiers: [.command, .option])

                    Button(L("Append Selection to Editor", "Append Selection to Editor")) {
                        appDelegate.appendSelectionToEditor()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .option, .shift])

                    Button(L("Agent Dashboard", "Agent Dashboard")) {
                        appDelegate.toggleDashboard()
                    }
                    .keyboardShortcut("g", modifiers: [.command, .control])

                    Divider()

                    Button(L("Close Pane", "Close Pane")) {
                        appDelegate.closeCurrentPane()
                    }
                    .keyboardShortcut("w", modifiers: [.command, .control])

                    Divider()

                    Button(L("Focus Next Pane", "Focus Next Pane")) {
                        appDelegate.focusNextPane()
                    }
                    .keyboardShortcut("]", modifiers: [.command, .option])

                    Button(L("Focus Previous Pane", "Focus Previous Pane")) {
                        appDelegate.focusPreviousPane()
                    }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                }

                Divider()

                Button(L("menu.showChangedFiles", "Show Changed Files")) {
                    appDelegate.showChangedFiles()
                }
                .keyboardShortcut("g", modifiers: [.command, .option])
            }

            // MARK: - Window Menu

            CommandGroup(after: .windowSize) {
                Divider()

                Button(L("Rename Tab...", "Rename Tab...")) {
                    appDelegate.beginRenameTab()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])

                Divider()

                Button(L("Show Next Tab", "Show Next Tab")) {
                    appDelegate.nextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button(L("Show Previous Tab", "Show Previous Tab")) {
                    appDelegate.previousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button(L("Move Tab Right", "Move Tab Right")) {
                    appDelegate.moveTabRight()
                }
                .keyboardShortcut("]", modifiers: [.command, .option, .shift])

                Button(L("Move Tab Left", "Move Tab Left")) {
                    appDelegate.moveTabLeft()
                }
                .keyboardShortcut("[", modifiers: [.command, .option, .shift])

                Divider()

                Menu(L("menu.selectTab", "Select Tab")) {
                    // Tabs 1-9 with keyboard shortcuts
                    ForEach(Array(overlayModel.tabs.prefix(9).enumerated()), id: \.element.id) { index, tab in
                        let name = tab.customTitle ?? tab.displaySession?.activeAppName ?? "Tab \(index + 1)"
                        Button(name) { appDelegate.selectTab(number: index + 1) }
                            .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")))
                    }
                    // Tabs 10+ without shortcuts
                    if overlayModel.tabs.count > 9 {
                        Divider()
                        ForEach(Array(overlayModel.tabs.dropFirst(9).enumerated()), id: \.element.id) { index, tab in
                            let name = tab.customTitle ?? tab.displaySession?.activeAppName ?? "Tab \(index + 10)"
                            Button(name) { appDelegate.selectTab(number: index + 10) }
                        }
                    }
                }

                Divider()

                Button(L("Refresh Tab Bar", "Refresh Tab Bar")) {
                    appDelegate.refreshTabBar()
                }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
            }

            CommandGroup(replacing: .help) {
                Button(L("Welcome to Chau7", "Welcome to Chau7")) {
                    appDelegate.showWelcomeFromMenu()
                }

                Divider()

                Button(L("Chau7 Help", "Chau7 Help")) {
                    appDelegate.showHelp()
                }

                Button(L("Technology, Licenses & Acknowledgments", "Technology, Licenses & Acknowledgments")) {
                    appDelegate.showTechnologyLicenses()
                }

                Button(L("Keyboard Shortcuts...", "Keyboard Shortcuts...")) {
                    appDelegate.showKeyboardShortcuts()
                }
                .keyboardShortcut("/", modifiers: [.command])

                Button(L("Report Issue", "Report Issue")) {
                    appDelegate.reportIssue()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])

                Divider()

                Button(L("Debug Console", "Debug Console")) {
                    DebugConsoleController.shared.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .option])
            }
        }
    }
}
