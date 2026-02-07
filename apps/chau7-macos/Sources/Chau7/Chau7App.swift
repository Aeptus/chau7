import SwiftUI
import AppKit

@main
struct Chau7App: App {
    @StateObject private var model: AppModel
    @StateObject private var overlayModel: OverlayTabsModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // Pre-initialize shell integration BEFORE creating any tabs
        TerminalSessionModel.preInitialize()

        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        let overlayModel = OverlayTabsModel(appModel: model)
        NotificationManager.shared.tabTitleProvider = { [weak overlayModel] tool in
            overlayModel?.notificationTabTitle(forTool: tool)
        }

        // Wire up tab style handler for notification actions
        NotificationActionExecutor.shared.tabStyleHandler = { [weak overlayModel] tool, stylePreset, config in
            guard let model = overlayModel else { return }
            model.applyNotificationStyle(forTool: tool, stylePreset: stylePreset, config: config)
        }

        _overlayModel = StateObject(wrappedValue: overlayModel)
        _ = SnippetManager.shared
        AppIcon.apply()
        NSApplication.shared.setActivationPolicy(.regular)
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

                Divider()

                Button(L("Export Text...", "Export Text...")) {
                    appDelegate.exportText()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .saveItem) { }
            CommandGroup(replacing: .importExport) { }

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
                Menu("Find") {
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

                Button(L("Snippets...", "Snippets...")) {
                    appDelegate.toggleSnippets()
                }
                .keyboardShortcut(";", modifiers: [.command])

                Button(L("Command Palette...", "Command Palette...")) {
                    appDelegate.toggleCommandPalette()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            // MARK: - View Menu
            CommandGroup(after: .toolbar) {
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
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Divider()

                // MARK: - Panes
                Menu("Panes") {
                    Button(L("Split Horizontally", "Split Horizontally")) {
                        appDelegate.splitHorizontally()
                    }
                    .keyboardShortcut("d")

                    Button(L("Split Vertically", "Split Vertically")) {
                        appDelegate.splitVertically()
                    }
                    .keyboardShortcut("d", modifiers: [.command, .shift])

                    Divider()

                    Button(L("Open Text Editor", "Open Text Editor")) {
                        appDelegate.openTextEditorPane()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .option])

                    Button(L("Append Selection to Editor", "Append Selection to Editor")) {
                        appDelegate.appendSelectionToEditor()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])

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
            }

            // MARK: - Window Menu
            CommandGroup(after: .windowSize) {
                Divider()

                Button(L("Rename Tab...", "Rename Tab...")) {
                    appDelegate.beginRenameTab()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

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

                Group {
                    Button(L("Select Tab 1", "Select Tab 1")) { appDelegate.selectTab(number: 1) }
                        .keyboardShortcut("&")
                    Button(L("Select Tab 2", "Select Tab 2")) { appDelegate.selectTab(number: 2) }
                        .keyboardShortcut("é")
                    Button(L("Select Tab 3", "Select Tab 3")) { appDelegate.selectTab(number: 3) }
                        .keyboardShortcut("\"")
                    Button(L("Select Tab 4", "Select Tab 4")) { appDelegate.selectTab(number: 4) }
                        .keyboardShortcut("'")
                    Button(L("Select Tab 5", "Select Tab 5")) { appDelegate.selectTab(number: 5) }
                        .keyboardShortcut("(")
                }

                Group {
                    Button(L("Select Tab 6", "Select Tab 6")) { appDelegate.selectTab(number: 6) }
                        .keyboardShortcut("§")
                    Button(L("Select Tab 7", "Select Tab 7")) { appDelegate.selectTab(number: 7) }
                        .keyboardShortcut("è")
                    Button(L("Select Tab 8", "Select Tab 8")) { appDelegate.selectTab(number: 8) }
                        .keyboardShortcut("!")
                    Button(L("Select Tab 9", "Select Tab 9")) { appDelegate.selectTab(number: 9) }
                        .keyboardShortcut("ç")
                }

                Divider()

                Button(L("Debug Console", "Debug Console")) {
                    DebugConsoleController.shared.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                Button(L("Refresh Tab Bar", "Refresh Tab Bar")) {
                    appDelegate.refreshTabBar()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }

            CommandGroup(after: .help) {
                Button(L("Keyboard Shortcuts...", "Keyboard Shortcuts...")) {
                    appDelegate.showKeyboardShortcuts()
                }
                .keyboardShortcut("/", modifiers: [.command])
            }
        }
    }
}
