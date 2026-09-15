import SwiftUI
import AppKit
import Darwin
import Chau7Core

@main
struct Chau7App: App {
    @State private var model: AppModel
    @State private var overlayModel: OverlayTabsModel
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    private static var initCount = 0

    init() {
        if Self.handleCLIIfNeeded() {
            Darwin.exit(0)
        }

        Self.initCount += 1
        if Self.initCount > 1 {
            Log.warn("Chau7App.init() called \(Self.initCount) times — SwiftUI is recreating the App struct (pid=\(ProcessInfo.processInfo.processIdentifier))")
        }

        // Pre-initialize shell integration BEFORE creating any tabs
        TerminalSessionModel.preInitialize()

        // Composition root: construct the notification services and
        // inject into AppModel, then populate the service-locator slot
        // for view-layer callsites that can't easily thread an explicit
        // reference.
        let notifications = NotificationServices()
        NotificationServices.current = notifications
        let model = AppModel(notifications: notifications)
        _model = State(wrappedValue: model)
        let overlayModel = OverlayTabsModel(appModel: model)
        // Inject one host for tab titles, repo names, active-tab checks,
        // and tab routing. All five previously-separate closures used to
        // route to TerminalControlService anyway; the explicit protocol
        // injection collapses them into a single line.
        notifications.manager.setHost(TerminalControlService.shared)
        model.tabIDResolver = { target in
            TerminalControlService.shared.resolveTabID(for: target)
        }
        model.historySessionAdopter = { request in
            TerminalControlService.shared.adoptHistorySession(request)
        }

        // Wire notification system — single delegate replaces 5 separate closures
        notifications.executor.delegate = NotificationActionAdapter(
            overlayModel: overlayModel,
            statusBar: StatusBarController.shared
        )

        _overlayModel = State(wrappedValue: overlayModel)
        _ = SnippetManager.shared
        AppIcon.apply()
        let policy: NSApplication.ActivationPolicy = FeatureSettings.shared.menuBarOnlyMode ? .accessory : .regular
        NSApplication.shared.setActivationPolicy(policy)
        appDelegate.configureModels(model: model, overlayModel: overlayModel)
        RemoteControlManager.shared.configure(overlayModel: overlayModel)
        // Break the Remote↔MCP singleton cycle at the composition root: each
        // side reaches the other through an injected seam instead of
        // dereferencing the other's singleton.
        RemoteControlManager.shared.tabDirectory = TerminalControlService.shared
        TerminalControlService.shared.approvalForwarder = RemoteControlManager.shared
    }

    private static func handleCLIIfNeeded() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--hang-watchdog") {
            guard let command = MainThreadHangWatchdogCommand.parse(arguments: arguments) else {
                let message = "Invalid --hang-watchdog invocation; refusing GUI startup.\n"
                try? FileHandle.standardError.write(contentsOf: Data(message.utf8))
                return true
            }
            MainThreadHangWatchdogRunner.run(command: command)
            return true
        }

        if arguments.contains("--telemetry-backfill-latency") {
            let report = TelemetryStore.shared.backfillCompletedRunLatencySamples()
            let stdout = FileHandle.standardOutput
            let lines = [
                "telemetry_latency_backfill inspected=\(report.inspectedRuns)",
                "inserted=\(report.insertedSamples)",
                "skipped=\(report.skippedRuns)"
            ]
            if let data = lines.joined(separator: "\n").appending("\n").data(using: .utf8) {
                try? stdout.write(contentsOf: data)
            }
            return true
        }

        guard arguments.contains("--telemetry-repair") else { return false }

        let report = TelemetryRepairService.shared.rebuildTranscriptDerivedRuns(limit: 100_000)
        let stdout = FileHandle.standardOutput
        let lines = [
            "telemetry_repair inspected=\(report.inspectedRuns)",
            "rebuilt=\(report.rebuiltRuns)",
            "invalidated=\(report.invalidatedRuns)",
            "skipped=\(report.skippedRuns)"
        ]
        if let data = lines.joined(separator: "\n").appending("\n").data(using: .utf8) {
            try? stdout.write(contentsOf: data)
        }
        return true
    }

    var body: some Scene {
        // Status bar is handled by StatusBarController for multi-monitor support
        Settings {
            EmptyView()
        }
        .commands {

            // MARK: - App Menu

            CommandGroup(replacing: .appInfo) {
                Button(L("About Chau7", "About Chau7")) {
                    appDelegate.showAbout()
                }
            }

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

                Button(L("Open Location...", "Open Location...")) {
                    appDelegate.openLocation()
                }

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
                .disabled(!appDelegate.hasMultipleTabsInActiveWindow)

                Button(L("Reopen Closed Tab", "Reopen Closed Tab")) {
                    appDelegate.reopenClosedTab()
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!appDelegate.canReopenClosedTabInActiveWindow)

                Divider()

                Button(L("Export Text...", "Export Text...")) {
                    appDelegate.exportText()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!appDelegate.hasActiveTerminalInKeyWindow)
            }

            CommandGroup(replacing: .saveItem) {}

            CommandGroup(replacing: .printItem) {
                Button(L("Print...", "Print...")) {
                    appDelegate.printTerminal()
                }
                .keyboardShortcut("p")
                .disabled(!appDelegate.hasActiveTerminalInKeyWindow)
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

                Button(L("Toggle Full Screen", "Toggle Full Screen")) {
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
                .keyboardShortcut("0")

                Divider()

                Button(L("Clear Screen", "Clear Screen")) {
                    appDelegate.clearScreen()
                }
                .keyboardShortcut("k")
                .disabled(!appDelegate.hasActiveTerminalInKeyWindow)

                Button(L("Clear Scrollback", "Clear Scrollback")) {
                    appDelegate.clearScrollback()
                }
                .keyboardShortcut("k", modifiers: [.command, .option])
                .disabled(!appDelegate.hasActiveTerminalInKeyWindow)

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
                    .disabled(!appDelegate.hasActiveOverlayWindow)

                    Button(L("Split Vertically", "Split Vertically")) {
                        appDelegate.splitVertically()
                    }
                    .keyboardShortcut("d", modifiers: [.command, .option])
                    .disabled(!appDelegate.hasActiveOverlayWindow)

                    Divider()

                    Button(L("Open Text Editor", "Open Text Editor")) {
                        appDelegate.openTextEditorPane()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .option])
                    .disabled(!appDelegate.hasActiveOverlayWindow)

                    Button(L("Open File Preview", "Open File Preview")) {
                        appDelegate.openFilePreviewPane()
                    }
                    .keyboardShortcut("o", modifiers: [.command, .option])
                    .disabled(!appDelegate.hasActiveOverlayWindow)

                    Button(L("Open Diff Viewer", "Open Diff Viewer")) {
                        appDelegate.openDiffViewerPane()
                    }
                    .keyboardShortcut("d", modifiers: [.command, .option, .shift])
                    .disabled(!appDelegate.canOpenDiffViewerInActiveWindow)

                    Button(L("Repository Pane", "Repository Pane")) {
                        appDelegate.openRepositoryPane()
                    }
                    .keyboardShortcut("b", modifiers: [.command, .option])
                    .disabled(!appDelegate.canOpenRepositoryPaneInActiveWindow)

                    Button(L("Append Selection to Editor", "Append Selection to Editor")) {
                        appDelegate.appendSelectionToEditor()
                    }
                    .keyboardShortcut("e", modifiers: [.command, .option, .shift])
                    .disabled(!appDelegate.canAppendSelectionToEditorInActiveWindow)

                    Button(L("Agent Dashboard", "Agent Dashboard")) {
                        appDelegate.toggleDashboard()
                    }
                    .keyboardShortcut("g", modifiers: [.command, .control])
                    .disabled(!appDelegate.canOpenDashboardInActiveWindow)

                    Divider()

                    Button(L("Close Pane", "Close Pane")) {
                        appDelegate.closeCurrentPane()
                    }
                    .keyboardShortcut("w", modifiers: [.command, .control])
                    .disabled(!appDelegate.hasMultiplePanesInActiveTab)

                    Divider()

                    Button(L("Focus Next Pane", "Focus Next Pane")) {
                        appDelegate.focusNextPane()
                    }
                    .keyboardShortcut("]", modifiers: [.command, .option])
                    .disabled(!appDelegate.hasMultiplePanesInActiveTab)

                    Button(L("Focus Previous Pane", "Focus Previous Pane")) {
                        appDelegate.focusPreviousPane()
                    }
                    .keyboardShortcut("[", modifiers: [.command, .option])
                    .disabled(!appDelegate.hasMultiplePanesInActiveTab)
                }

                Divider()

                Button(L("menu.showChangedFiles", "Show Changed Files")) {
                    appDelegate.showChangedFiles()
                }
                .keyboardShortcut("g", modifiers: [.command, .option])
                .disabled(!appDelegate.canShowChangedFilesInActiveWindow)
            }

            // MARK: - Window Menu

            CommandGroup(after: .windowSize) {
                Divider()

                Button(L("Rename Tab...", "Rename Tab...")) {
                    appDelegate.beginRenameTab()
                }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!appDelegate.hasActiveOverlayWindow)

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
                .disabled(!appDelegate.hasMultipleTabsInActiveWindow)

                Button(L("Move Tab Left", "Move Tab Left")) {
                    appDelegate.moveTabLeft()
                }
                .keyboardShortcut("[", modifiers: [.command, .option, .shift])
                .disabled(!appDelegate.hasMultipleTabsInActiveWindow)

                Divider()

                Menu(L("menu.selectTab", "Select Tab")) {
                    let tabItems = appDelegate.menuTabItems(fallback: overlayModel)
                    // Tabs 1-9 with keyboard shortcuts
                    ForEach(Array(tabItems.prefix(9))) { item in
                        Button(item.title) { appDelegate.selectTab(number: item.number) }
                            .keyboardShortcut(KeyEquivalent(Character("\(item.number)")))
                    }
                    // Tabs 10+ without shortcuts
                    if tabItems.count > 9 {
                        Divider()
                        ForEach(Array(tabItems.dropFirst(9))) { item in
                            Button(item.title) { appDelegate.selectTab(number: item.number) }
                        }
                    }
                }
                .disabled(appDelegate.menuTabItems(fallback: overlayModel).isEmpty)

                Divider()

                Button(L("Refresh Tab Bar", "Refresh Tab Bar")) {
                    appDelegate.refreshTabBar()
                }
                .keyboardShortcut("r", modifiers: [.command, .option, .shift])
                .disabled(!appDelegate.hasActiveOverlayWindow)

                Divider()

                Menu(L("debug.menu.diagnostics", "Diagnostics")) {
                    Button(L("debug.surface.diagnostics.title", "Diagnostics")) {
                        DebugConsoleController.shared.show(surface: .diagnostics)
                    }

                    Button(L("debug.surface.usage.title", "Usage Monitor")) {
                        DebugConsoleController.shared.show(surface: .usageMonitor)
                    }

                    Button(L("debug.surface.runtime.title", "Runtime Inspector")) {
                        DebugConsoleController.shared.show(surface: .runtimeInspector)
                    }

                    Button(L("Debug Console", "Debug Console")) {
                        DebugConsoleController.shared.toggle(surface: .all)
                    }
                    .keyboardShortcut("l", modifiers: [.command, .option])
                }
            }

            CommandGroup(replacing: .help) {
                Button(L("Welcome to Chau7", "Welcome to Chau7")) {
                    appDelegate.showWelcomeFromMenu()
                }

                Divider()

                Button(L("Chau7 Help", "Chau7 Help")) {
                    appDelegate.showHelp()
                }

                Button(L("Release Notes...", "Release Notes...")) {
                    appDelegate.showReleaseNotes()
                }

                Button(L("Technology, Licenses & Acknowledgments", "Technology, Licenses & Acknowledgments")) {
                    appDelegate.showTechnologyLicenses()
                }

                Button(L("Keyboard Shortcuts...", "Keyboard Shortcuts...")) {
                    appDelegate.showKeyboardShortcuts()
                }
                .keyboardShortcut("/", modifiers: [.command])

                Button(L("Report Issue...", "Report Issue...")) {
                    appDelegate.reportIssue()
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
            }
        }
    }
}
