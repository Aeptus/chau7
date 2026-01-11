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
        _overlayModel = StateObject(wrappedValue: overlayModel)
        _ = SnippetManager.shared
        AppIcon.apply()
        NSApplication.shared.setActivationPolicy(.regular)
        appDelegate.model = model
        appDelegate.overlayModel = overlayModel
    }

    var body: some Scene {
        // Status bar is handled by StatusBarController for multi-monitor support
        // This empty Settings scene is required to attach commands
        Settings {
            EmptyView()
        }
        .commands {
            // Settings in app menu with Cmd+,
            CommandGroup(replacing: .appSettings) {
                Button("Settings...") {
                    appDelegate.showSettings()
                }
                .keyboardShortcut(",")
            }

            // Hide the default File menu by replacing all its groups with empty content
            CommandGroup(replacing: .newItem) { }
            CommandGroup(replacing: .saveItem) { }
            CommandGroup(replacing: .importExport) { }
            CommandGroup(replacing: .printItem) { }

            // Custom "Shell" menu (like Terminal.app)
            CommandMenu("Shell") {
                Button("Settings...") {
                    appDelegate.showSettings()
                }

                Divider()

                Button("New Window") {
                    appDelegate.newOverlayWindow()
                }
                .keyboardShortcut("n")

                Button("New Tab") {
                    appDelegate.newTab()
                }
                .keyboardShortcut("t")

                Divider()

                Button("Close Tab") {
                    appDelegate.closeTab()
                }
                .keyboardShortcut("w")

                Button("Close Window") {
                    appDelegate.closeWindow()
                }
                .keyboardShortcut("w", modifiers: [.command, .shift])

                Divider()

                Button("Print...") {
                    appDelegate.printTerminal()
                }
                .keyboardShortcut("p")
            }


            CommandGroup(after: .pasteboard) {
                Button("Copy") {
                    appDelegate.copyOrInterrupt()
                }
                .keyboardShortcut("c")

                Button("Paste") {
                    appDelegate.paste()
                }
                .keyboardShortcut("v")
            }

            CommandGroup(after: .textEditing) {
                Button("Find") {
                    appDelegate.toggleSearch()
                }
                .keyboardShortcut("f")

                Button("Snippets...") {
                    appDelegate.toggleSnippets()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Button("Rename Tab") {
                    appDelegate.beginRenameTab()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("Find Next") {
                    appDelegate.nextSearchMatch()
                }
                .keyboardShortcut("g")

                Button("Find Previous") {
                    appDelegate.previousSearchMatch()
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }

            CommandGroup(after: .toolbar) {
                Button("Zoom In") {
                    appDelegate.zoomIn()
                }
                .keyboardShortcut("=")

                // Alternative zoom in shortcut (Cmd+Shift+= which is Cmd++) - Issue #22 fix
                Button("Zoom In (+)") {
                    appDelegate.zoomIn()
                }
                .keyboardShortcut("+", modifiers: [.command, .shift])

                Button("Zoom Out") {
                    appDelegate.zoomOut()
                }
                .keyboardShortcut("-")

                Button("Actual Size") {
                    appDelegate.zoomReset()
                }
                .keyboardShortcut("0")

                Divider()

                Button("Clear Scrollback") {
                    appDelegate.clearScrollback()
                }
                .keyboardShortcut("k")
            }

            CommandGroup(after: .windowSize) {
                Button("Next Tab") {
                    appDelegate.nextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])

                Button("Previous Tab") {
                    appDelegate.previousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])

                Divider()

                Group {
                    Button("Tab 1") { appDelegate.selectTab(number: 1) }.keyboardShortcut("1")
                    Button("Tab 2") { appDelegate.selectTab(number: 2) }.keyboardShortcut("2")
                    Button("Tab 3") { appDelegate.selectTab(number: 3) }.keyboardShortcut("3")
                    Button("Tab 4") { appDelegate.selectTab(number: 4) }.keyboardShortcut("4")
                    Button("Tab 5") { appDelegate.selectTab(number: 5) }.keyboardShortcut("5")
                    Button("Tab 6") { appDelegate.selectTab(number: 6) }.keyboardShortcut("6")
                    Button("Tab 7") { appDelegate.selectTab(number: 7) }.keyboardShortcut("7")
                    Button("Tab 8") { appDelegate.selectTab(number: 8) }.keyboardShortcut("8")
                    Button("Tab 9") { appDelegate.selectTab(number: 9) }.keyboardShortcut("9")
                }
            }
        }
    }
}
