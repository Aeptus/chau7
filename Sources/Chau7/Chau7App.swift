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
        appDelegate.model = model
        appDelegate.overlayModel = overlayModel
    }

    var body: some Scene {
        // Status bar is handled by StatusBarController for multi-monitor support
        Settings {
            EmptyView()
        }
        .commands {
            // MARK: - App Menu
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",")
            }

            // MARK: - File Menu
            CommandGroup(replacing: .newItem) {
                Button("New Window") {
                    appDelegate.newOverlayWindow()
                }
                .keyboardShortcut("n")

                Button("New Tab") {
                    appDelegate.newTab()
                }
                .keyboardShortcut("t")

                Button("SSH Connections...") {
                    appDelegate.showSSHManager()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("Close Tab") {
                    appDelegate.closeTab()
                }
                .keyboardShortcut("w")

                Button("Close Window") {
                    appDelegate.closeWindow()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Button("Close Other Tabs") {
                    appDelegate.closeOtherTabs()
                }
                .keyboardShortcut("w", modifiers: [.command, .option])

                Divider()

                Button("Export Text...") {
                    appDelegate.exportText()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .saveItem) { }
            CommandGroup(replacing: .importExport) { }

            CommandGroup(replacing: .printItem) {
                Button("Print...") {
                    appDelegate.printTerminal()
                }
                .keyboardShortcut("p")
            }

            // MARK: - Edit Menu
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {
                    appDelegate.cut()
                }
                .keyboardShortcut("x")

                Button("Copy") {
                    appDelegate.copyOrInterrupt()
                }
                .keyboardShortcut("c")

                Button("Paste") {
                    appDelegate.paste()
                }
                .keyboardShortcut("v")

                Button("Paste Escaped") {
                    appDelegate.pasteEscaped()
                }
                .keyboardShortcut("v", modifiers: [.command, .option])

                Button("Select All") {
                    appDelegate.selectAll()
                }
                .keyboardShortcut("a")
            }

            CommandGroup(replacing: .textEditing) {
                Menu("Find") {
                    Button("Find...") {
                        appDelegate.toggleSearch()
                    }
                    .keyboardShortcut("f")

                    Button("Find Next") {
                        appDelegate.nextSearchMatch()
                    }
                    .keyboardShortcut("g")

                    Button("Find Previous") {
                        appDelegate.previousSearchMatch()
                    }
                    .keyboardShortcut("g", modifiers: [.command, .shift])

                    Divider()

                    Button("Use Selection for Find") {
                        appDelegate.useSelectionForFind()
                    }
                    .keyboardShortcut("e")
                }

                Divider()

                Button("Snippets...") {
                    appDelegate.toggleSnippets()
                }
                .keyboardShortcut(";", modifiers: [.command])

                Button("Command Palette...") {
                    appDelegate.toggleCommandPalette()
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
            }

            // MARK: - View Menu
            CommandGroup(after: .toolbar) {
                Button("Enter Full Screen") {
                    appDelegate.toggleFullScreen()
                }
                .keyboardShortcut("f", modifiers: [.command, .control])

                Divider()

                Button("Zoom In") {
                    appDelegate.zoomIn()
                }
                .keyboardShortcut("=")

                Button("Zoom Out") {
                    appDelegate.zoomOut()
                }
                .keyboardShortcut("-")

                Button("Actual Size") {
                    appDelegate.zoomReset()
                }
                .keyboardShortcut("0")

                Divider()

                Button("Clear Screen") {
                    appDelegate.clearScreen()
                }
                .keyboardShortcut("k")

                Button("Clear Scrollback") {
                    appDelegate.clearScrollback()
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])

                Divider()

                // MARK: - Panes
                Menu("Panes") {
                    Button("Split Horizontally") {
                        appDelegate.splitHorizontally()
                    }
                    .keyboardShortcut("d")

                    Button("Split Vertically") {
                        appDelegate.splitVertically()
                    }
                    .keyboardShortcut("d", modifiers: [.command, .shift])

                    Divider()

                    Button("Open Text Editor") {
                        appDelegate.openTextEditorPane()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .option])

                    Button("Append Selection to Editor") {
                        appDelegate.appendSelectionToEditor()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .shift])

                    Divider()

                    Button("Close Pane") {
                        appDelegate.closeCurrentPane()
                    }
                    .keyboardShortcut("w", modifiers: [.command, .control])

                    Divider()

                    Button("Focus Next Pane") {
                        appDelegate.focusNextPane()
                    }
                    .keyboardShortcut("]", modifiers: [.command, .option])

                    Button("Focus Previous Pane") {
                        appDelegate.focusPreviousPane()
                    }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                }
            }

            // MARK: - Window Menu
            CommandGroup(after: .windowSize) {
                Divider()

                Button("Rename Tab...") {
                    appDelegate.beginRenameTab()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Divider()

                Button("Show Next Tab") {
                    appDelegate.nextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Show Previous Tab") {
                    appDelegate.previousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Button("Move Tab Right") {
                    appDelegate.moveTabRight()
                }
                .keyboardShortcut("]", modifiers: [.command, .option, .shift])

                Button("Move Tab Left") {
                    appDelegate.moveTabLeft()
                }
                .keyboardShortcut("[", modifiers: [.command, .option, .shift])

                Divider()

                Group {
                    Button("Select Tab 1") { appDelegate.selectTab(number: 1) }
                        .keyboardShortcut("1")
                    Button("Select Tab 2") { appDelegate.selectTab(number: 2) }
                        .keyboardShortcut("2")
                    Button("Select Tab 3") { appDelegate.selectTab(number: 3) }
                        .keyboardShortcut("3")
                    Button("Select Tab 4") { appDelegate.selectTab(number: 4) }
                        .keyboardShortcut("4")
                    Button("Select Tab 5") { appDelegate.selectTab(number: 5) }
                        .keyboardShortcut("5")
                }

                Group {
                    Button("Select Tab 6") { appDelegate.selectTab(number: 6) }
                        .keyboardShortcut("6")
                    Button("Select Tab 7") { appDelegate.selectTab(number: 7) }
                        .keyboardShortcut("7")
                    Button("Select Tab 8") { appDelegate.selectTab(number: 8) }
                        .keyboardShortcut("8")
                    Button("Select Tab 9") { appDelegate.selectTab(number: 9) }
                        .keyboardShortcut("9")
                }

                Divider()

                Button("Debug Console") {
                    DebugConsoleController.shared.toggle()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])

                Divider()

                Button("Refresh Tab Bar") {
                    appDelegate.refreshTabBar()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
            }

            CommandGroup(after: .help) {
                Button("Keyboard Shortcuts...") {
                    appDelegate.showKeyboardShortcuts()
                }
                .keyboardShortcut("/", modifiers: [.command])
            }
        }
    }
}
