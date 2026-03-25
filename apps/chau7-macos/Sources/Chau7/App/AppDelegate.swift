import AppKit
import Carbon.HIToolbox
import SwiftUI
import Chau7Core

private final class OverlayBlurView: NSVisualEffectView {
    weak var hostedView: NSView?

    override func layout() {
        super.layout()
        guard let hostedView else { return }
        hostedView.frame = window?.contentLayoutRect ?? bounds
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private static let passwordAutofillSelector = NSSelectorFromString("_handleInsertFromPasswordsCommand:")
    var model: AppModel?
    var overlayModel: OverlayTabsModel?
    private struct OverlayHost {
        let window: NSWindow
        let model: OverlayTabsModel
    }

    private var overlayHosts: [OverlayHost] = []
    private(set) weak var activeOverlayModel: OverlayTabsModel?
    private var lastOverlayDiagLogAt: CFAbsoluteTime = 0
    private var lastOverlayDiagReason = ""
    private var keyMonitor: Any?
    private var opacityObserver: Any?
    private var appThemeObserver: Any?
    private var splashController: SplashWindowController?
    private var settingsWindow: NSWindow?
    private var isClosingTab = false // Flag to prevent windowShouldClose from hiding window during tab close
    private var nextOverlayWindowNumber = 1
    /// Tracks windows that were hidden via orderOut - used to trigger tab bar refresh only when needed
    private var hiddenWindowNumbers: Set<Int> = []
    /// Tracks windows that have been shown at least once
    private var shownWindowNumbers: Set<Int> = []
    private var didFinishLaunching = false
    private var didPerformInitialSetup = false
    private var lastOverlayLifecycleLogAt: CFAbsoluteTime = 0
    private var lastOverlayLifecycleReason = ""
    /// Centralized autosave timer — saves all windows atomically every 30s
    private var multiWindowAutoSaveTimer: DispatchSourceTimer?

    // MARK: - App Nap Prevention

    /// Activity token to prevent App Nap from throttling the terminal
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("AppDelegate did finish launching.")
        didFinishLaunching = true

        // Ignore SIGPIPE process-wide: broken socket/pipe writes return EPIPE error
        // instead of killing the app. Per-socket SO_NOSIGPIPE is also set where possible,
        // but this catches any unprotected write paths (proxies, IPC, MCP bridges).
        signal(SIGPIPE, SIG_IGN)

        // Purge oversized PTY logs on startup to prevent disk bloat
        purgeLargePTYLogs()

        // Strip env vars from parent process that would confuse nested CLI tools.
        // When Chau7 is launched from within a Claude Code session (e.g. via
        // build-and-run.sh), CLAUDECODE=1 leaks into every terminal child process,
        // causing Claude Code inside Chau7 to refuse to start.
        unsetenv("CLAUDECODE")

        // CRITICAL: Prevent App Nap from throttling the terminal
        // This eliminates the "first keystroke lag" issue
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Terminal requires low-latency input processing"
        )
        Log.info("App Nap prevention enabled with latency-critical activity")

        // Start API analytics proxy if enabled
        Task { @MainActor in
            ProxyIPCServer.shared.start()
            ProxyManager.shared.startIfEnabled()
            Log.info("API proxy subsystem initialized")
        }

        // CTO: setup wrapper scripts if token optimization is enabled
        if FeatureSettings.shared.tokenOptimizationMode != .off {
            CTOManager.shared.setup()
            Log.info("CTO wrapper scripts installed")
        }

        NSApp.activate(ignoringOtherApps: true)

        opacityObserver = NotificationCenter.default.addObserver(
            forName: .terminalOpacityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyWindowOpacity()
            }
        }

        appThemeObserver = NotificationCenter.default.addObserver(
            forName: .appThemeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.applyAppTheme()
            }
        }

        // Show splash screen while initializing
        splashController = SplashWindowController()
        splashController?.show()

        applyAppTheme()
        installKeyMonitor()

        // Initialize command palette controller
        CommandPaletteController.shared.setup(appDelegate: self)

        // Initialize SSH connection manager
        SSHConnectionWindowController.shared.appDelegate = self

        attemptInitialSetupIfReady()
    }

    func configureModels(model: AppModel, overlayModel: OverlayTabsModel) {
        self.model = model
        self.overlayModel = overlayModel
        attemptInitialSetupIfReady()
    }

    @MainActor private func attemptInitialSetupIfReady() {
        guard didFinishLaunching else { return }
        guard !didPerformInitialSetup else { return }
        guard let model, let overlayModel else {
            Log.warn("Launch deferred: models not ready yet.")
            return
        }
        didPerformInitialSetup = true

        model.bootstrap()

        // Activate persisted security-scoped bookmarks before tabs are restored,
        // so git detection in ~/Downloads etc. works on the first check.
        if FeatureSettings.shared.allowProtectedFolderAccess {
            ProtectedPathPolicy.activatePersistedBookmarks()
        }

        // Start MCP telemetry server and register terminal control
        MCPServerManager.shared.start()
        TerminalControlService.shared.register(overlayModel)

        // Initialize status bar controller (replaces MenuBarExtra for multi-monitor support)
        StatusBarController.shared.setup(model: model)

        // Create overlay window (initially hidden behind splash) - this starts the shell
        setupOverlayWindow()

        // Restore additional windows from multi-window save state
        restoreAdditionalWindows()

        // Start centralized autosave timer (replaces per-window timers)
        startMultiWindowAutoSaveTimer()

        // Initialize debug console controller
        DebugConsoleController.shared.configure(appModel: model, overlayModel: overlayModel)

        // Ensure theme is applied after windows exist
        applyAppTheme()

        // Keep overlay hidden initially
        for host in overlayHosts {
            hiddenWindowNumbers.insert(host.window.windowNumber)
            host.model.noteTabBarVisibilityChanged(isVisible: false)
            host.window.orderOut(nil)
        }

        // Wait for shell to initialize and run integration, then show
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.finishLaunching()
        }
    }

    private func finishLaunching() {
        // Dismiss splash and show overlay (terminal only, no settings window)
        splashController?.dismiss { [weak self] in
            self?.splashController = nil
            // Show all restored overlay windows
            if let hosts = self?.overlayHosts {
                for host in hosts {
                    self?.showOverlayWindow(host, reason: "finishLaunching")
                }
            }
            // Ensure menu bar is anchored after splash dismissal.
            // During the splash phase no window is key/main, so macOS may
            // drop the menu bar for this app. Re-activating here forces it back.
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Collect running process names across all tabs
        var runningProcessNames: [String] = []
        for host in overlayHosts {
            for tab in host.model.tabs {
                guard let session = tab.session else { continue }
                if let children = session.processGroup?.children {
                    for proc in children where !proc.name.isEmpty {
                        runningProcessNames.append(proc.name)
                    }
                }
            }
        }

        guard !runningProcessNames.isEmpty else { return .terminateNow }

        let unique = Array(Set(runningProcessNames)).sorted()
        let processList = unique.joined(separator: ", ")
        let alert = NSAlert()
        alert.messageText = "Quit Chau7?"
        alert.informativeText = "\(unique.count) running process\(unique.count == 1 ? "" : "es") will be terminated: \(processList)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        multiWindowAutoSaveTimer?.cancel()
        multiWindowAutoSaveTimer = nil
        saveAllWindowStates(reason: .termination)
        for host in overlayHosts {
            host.model.closeAllSessionsForTermination()
        }

        // Stop MCP telemetry server
        MCPServerManager.shared.stop()

        // CTO: clean up all flag files and wrappers (no-op if mode was .off)
        CTOManager.shared.teardown()

        MainActor.assumeIsolated {
            ProxyManager.shared.stop()
            ProxyIPCServer.shared.stop()
            RemoteControlManager.shared.stopAgent()
            Log.info("API proxy subsystem stopped")
        }

        // End App Nap prevention activity
        if let activityToken {
            ProcessInfo.processInfo.endActivity(activityToken)
            self.activityToken = nil
        }

        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let opacityObserver {
            NotificationCenter.default.removeObserver(opacityObserver)
            self.opacityObserver = nil
        }
        if let appThemeObserver {
            NotificationCenter.default.removeObserver(appThemeObserver)
            self.appThemeObserver = nil
        }
        // Cleanup status bar controller
        StatusBarController.shared.cleanup()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            showOverlay()
        }
        return true
    }

    func showOverlay() {
        if let active = activeOverlayModel,
           let host = overlayHosts.first(where: { $0.model === active }) {
            showOverlayWindow(host, reason: "showOverlay")
        } else if let host = overlayHosts.first {
            showOverlayWindow(host, reason: "showOverlay")
        } else {
            newOverlayWindow()
        }
    }

    func showSettings() {
        // If settings window already exists, bring it to front
        if let existing = settingsWindow, existing.isVisible {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            Log.info("Settings window brought to front.")
            return
        }

        guard let model else {
            Log.error("Cannot show settings: AppModel not available.")
            return
        }

        // Create the settings view with its own state
        let settingsView = SettingsWindowView(model: model, overlayModel: overlayModel)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 820, height: 650)

        window.title = L("window.settings.title", "Chau7 Settings")
        window.center()
        window.contentView = hostingView
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        settingsWindow = window
        Log.info("Settings window created and shown.")
    }

    func newOverlayWindow() {
        guard let model else { return }
        let tabsModel = OverlayTabsModel(appModel: model, restoreState: false)
        TerminalControlService.shared.register(tabsModel)
        let windowNumber = allocateOverlayWindowNumber()
        let window = createOverlayWindow(tabsModel: tabsModel, windowNumber: windowNumber)
        overlayHosts.append(OverlayHost(window: window, model: tabsModel))
        activeOverlayModel = tabsModel
        wireTabMoveCallbacks()
        showOverlayWindow(overlayHosts.last!, reason: "newWindow")
    }

    func newTab() {
        ensureActiveOverlayModel()?.newTab()
    }

    func showSSHManager() {
        SSHConnectionWindowController.shared.showConnectionManager()
    }

    func closeTab() {
        ensureActiveOverlayModel()?.closeCurrentTab()
    }

    func closeTabFromShortcut() {
        Log.info("Close tab via shortcut.")
        isClosingTab = true
        closeTab()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.isClosingTab = false
        }
    }

    func closeWindow() {
        guard let window = NSApp.keyWindow else {
            Log.trace("Close window: no key window.")
            return
        }
        // If it's an overlay window, hide it instead of closing
        if overlayHosts.contains(where: { $0.window == window }) {
            if let host = overlayHosts.first(where: { $0.window == window }) {
                host.model.noteTabBarVisibilityChanged(isVisible: false)
            }
            hiddenWindowNumbers.insert(window.windowNumber)
            logOverlayWindowLifecycle(reason: "closeWindow-orderOut", window: window)
            window.orderOut(nil)
            Log.info("Overlay window hidden via Close Window.")
        } else {
            window.close()
            Log.info("Window closed.")
        }
    }

    func printTerminal() {
        guard let terminalView = activeTerminalView(in: NSApp.keyWindow) else {
            Log.trace("Print: no active terminal found.")
            return
        }

        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = false

        // TerminalViewLike conforms to NSView, so we can use it directly
        let printOp = NSPrintOperation(view: terminalView, printInfo: printInfo)
        printOp.showsPrintPanel = true
        printOp.showsProgressPanel = true
        printOp.run()
        Log.info("Print dialog opened for terminal.")
    }

    func selectTab(number: Int) {
        ensureActiveOverlayModel()?.selectTab(number: number)
    }

    func nextTab() {
        ensureActiveOverlayModel()?.selectNextTab()
    }

    func previousTab() {
        ensureActiveOverlayModel()?.selectPreviousTab()
    }

    func copyOrInterrupt() {
        Log.info("copyOrInterrupt called - first responder: \(String(describing: NSApp.keyWindow?.firstResponder))")

        if let window = NSApp.keyWindow,
           overlayHosts.contains(where: { $0.window == window }),
           !isTextInputFocused(in: window) {
            if let terminal = activeTerminalView(in: window) {
                terminal.window?.makeFirstResponder(terminal)
                if let rustView = terminal as? RustTerminalView {
                    rustView.copy(nil)
                }
                return
            }
            ensureActiveOverlayModel()?.copyOrInterrupt()
            return
        }

        if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) {
            Log.info("Copy action sent via responder chain.")
            return
        }
        Log.info("Responder chain failed, using overlay model fallback.")
        ensureActiveOverlayModel()?.copyOrInterrupt()
    }

    func paste() {
        if let window = NSApp.keyWindow,
           overlayHosts.contains(where: { $0.window == window }),
           !isTextInputFocused(in: window) {
            if let terminal = activeTerminalView(in: window) {
                terminal.window?.makeFirstResponder(terminal)
                if let rustView = terminal as? RustTerminalView {
                    rustView.paste(nil)
                }
                return
            }
            ensureActiveOverlayModel()?.paste()
            return
        }

        if NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) {
            Log.trace("Paste handled by responder chain.")
            return
        }
        Log.trace("Paste handled by overlay model fallback.")
        ensureActiveOverlayModel()?.paste()
    }

    func zoomIn() {
        ensureActiveOverlayModel()?.zoomIn()
    }

    func zoomOut() {
        ensureActiveOverlayModel()?.zoomOut()
    }

    func zoomReset() {
        ensureActiveOverlayModel()?.zoomReset()
    }

    func toggleSearch() {
        ensureActiveOverlayModel()?.toggleSearch()
    }

    func toggleCommandPalette() {
        CommandPaletteController.shared.toggle()
    }

    func toggleSnippets() {
        ensureActiveOverlayModel()?.toggleSnippetManager()
    }

    func beginRenameTab() {
        ensureActiveOverlayModel()?.beginRenameSelected()
    }

    func nextSearchMatch() {
        ensureActiveOverlayModel()?.nextMatch()
    }

    func previousSearchMatch() {
        ensureActiveOverlayModel()?.previousMatch()
    }

    func clearScrollback() {
        guard let terminalView = activeTerminalView(in: NSApp.keyWindow) else {
            Log.trace("Clear scrollback: no active terminal found.")
            return
        }
        terminalView.clearScrollbackBuffer()
        Log.info("Scrollback cleared.")
    }

    func clearScreen() {
        guard let terminalView = activeTerminalView(in: NSApp.keyWindow) else {
            Log.trace("Clear screen: no active terminal found.")
            return
        }
        // Send Ctrl+L to the shell - it will clear screen and redraw prompt
        terminalView.send(data: [0x0C])
        terminalView.clearSelection()
        Log.info("Sent Ctrl+L to shell for clear screen.")
    }

    // MARK: - App Menu Actions

    func showAbout() {
        let credits = L("about.credits", """
        A modern terminal emulator designed for AI-assisted development.

        Features:
        - AI CLI Detection (Claude, Codex, Gemini)
        - Command Palette
        - SSH Connection Manager
        - Inline Images
        - Split Panes
        - Snippets & More

        Built with SwiftUI and Rust.

        Copyright \u{00a9} 2024-2025
        """)

        let attributedCredits = NSMutableAttributedString(string: credits)
        attributedCredits.addAttributes(
            [.font: NSFont.systemFont(ofSize: 11)],
            range: NSRange(location: 0, length: credits.count)
        )

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: L("app.name", "Chau7"),
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
            .credits: attributedCredits
        ])
    }

    // MARK: - File Menu Actions

    func openLocation() {
        let alert = NSAlert()
        alert.messageText = L("alert.openLocation.title", "Open Location")
        alert.informativeText = L("alert.openLocation.message", "Enter a directory path to open in a new tab:")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("button.open", "Open"))
        alert.addButton(withTitle: L("button.cancel", "Cancel"))

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = RuntimeIsolation.homePath()
        alert.accessoryView = textField

        if alert.runModal() == .alertFirstButtonReturn {
            let path = textField.stringValue
            if FileManager.default.fileExists(atPath: path) {
                if let tabsModel = ensureActiveOverlayModel() {
                    tabsModel.newTab(at: path)
                }
            }
        }
    }

    func exportText() {
        guard let terminalView = activeTerminalView(in: NSApp.keyWindow) else {
            Log.trace("Export text: no active terminal found.")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = L("export.terminalText.filename", "terminal-output.txt")
        savePanel.title = L("export.terminalText.title", "Export Terminal Text")

        if savePanel.runModal() == .OK, let url = savePanel.url {
            // Get all text from terminal buffer
            guard let data = terminalView.getBufferAsData(),
                  let text = String(data: data, encoding: .utf8) else {
                Log.warn("Export text: failed to read terminal buffer.")
                return
            }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                Log.info("Terminal text exported to \(url.path)")
            } catch {
                Log.error("Failed to export terminal text: \(error)")
            }
        }
    }

    func closeOtherTabs() {
        ensureActiveOverlayModel()?.closeOtherTabs()
    }

    func reopenClosedTab() {
        ensureActiveOverlayModel()?.reopenClosedTab()
    }

    // MARK: - Edit Menu Actions

    func cut() {
        // In terminal, cut = copy (we can't cut from terminal output)
        copyOrInterrupt()
    }

    func pasteEscaped() {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        let escaped = PasteEscaper.escape(string)

        guard let terminalView = activeTerminalView(in: NSApp.keyWindow) else { return }

        terminalView.send(txt: escaped)
        Log.info("Pasted escaped text.")
    }

    func autofillFromPasswords() {
        guard let window = NSApp.keyWindow else { return }
        if let terminalView = activeTerminalView(in: window) {
            window.makeFirstResponder(terminalView)
        }

        if NSApp.sendAction(Self.passwordAutofillSelector, to: nil, from: nil) {
            Log.info("Invoked Password AutoFill from Edit menu.")
        } else {
            Log.warn("Password AutoFill command unavailable in responder chain.")
        }
    }

    // MARK: - Smart Select All (Cmd+A / Cmd+A Cmd+A)

    private var lastSelectAllTime: Date?
    private let doubleTapThreshold: TimeInterval = 0.4 // 400ms for double-tap

    func selectAll() {
        guard let window = NSApp.keyWindow else { return }
        if let terminalView = activeTerminalView(in: window) {
            let now = Date()

            // Check if this is a double-tap (Cmd+A Cmd+A)
            if let lastTime = lastSelectAllTime,
               now.timeIntervalSince(lastTime) < doubleTapThreshold {
                // Double-tap: Select entire terminal buffer
                if let rustView = terminalView as? RustTerminalView {
                    rustView.selectAll(nil)
                }
                terminalView.clearCommandSelectionState()
                Log.info("Cmd+A Cmd+A: Selected all terminal buffer.")
                lastSelectAllTime = nil // Reset for next sequence
            } else {
                // Single tap: Select current command (including wrapped rows)
                terminalView.selectCurrentCommand()
                Log.info("Cmd+A: Selected current command.")
                lastSelectAllTime = now
            }
            return
        }

        lastSelectAllTime = nil
        if !NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) {
            window.firstResponder?.perform(#selector(NSText.selectAll(_:)), with: nil)
        }
    }

    func clearToPreviousMark() {
        // This is like Cmd+L in iTerm - clears screen but keeps scrollback
        clearScreen()
    }

    func useSelectionForFind() {
        guard let terminalView = activeTerminalView(in: NSApp.keyWindow) else { return }

        if let selection = terminalView.getSelectedText() {
            if let tabsModel = activeOverlayModel {
                tabsModel.searchQuery = selection
                if !tabsModel.isSearchVisible {
                    tabsModel.toggleSearch()
                }
            }
        }
    }

    func showCharacterPalette() {
        NSApp.orderFrontCharacterPalette(nil)
    }

    // MARK: - View Menu Actions

    func toggleTabBar() {
        // Tab bar is always shown in Chau7, but this could toggle compact mode
        Log.info("Toggle tab bar - not implemented (always visible)")
    }

    func toggleFullScreen() {
        guard let window = NSApp.keyWindow else { return }
        window.toggleFullScreen(nil)
    }

    func scrollToTop() {
        guard let terminalView = activeTerminalView(in: NSApp.keyWindow) else { return }
        terminalView.scrollToTop()
        Log.info("Scrolled to top.")
    }

    func scrollToBottom() {
        guard let terminalView = activeTerminalView(in: NSApp.keyWindow) else { return }
        terminalView.scrollToBottom()
        Log.info("Scrolled to bottom.")
    }

    func scrollToPreviousInputLine() {
        guard let terminalView = activeTerminalView(in: NSApp.keyWindow) else { return }
        terminalView.scrollToPreviousInputLine()
    }

    func scrollToNextInputLine() {
        guard let terminalView = activeTerminalView(in: NSApp.keyWindow) else { return }
        terminalView.scrollToNextInputLine()
    }

    // MARK: - Window Menu Actions

    func showTabColorPicker() {
        ensureActiveOverlayModel()?.showTabColorPicker()
    }

    func moveTabRight() {
        ensureActiveOverlayModel()?.moveCurrentTabRight()
    }

    func moveTabLeft() {
        ensureActiveOverlayModel()?.moveCurrentTabLeft()
    }

    func refreshTabBar() {
        ensureActiveOverlayModel()?.refreshTabBar()
    }

    func forceRefreshTab() {
        ensureActiveOverlayModel()?.forceRefreshSelectedTab()
    }

    // MARK: - Pane Actions

    func splitHorizontally() {
        ensureActiveOverlayModel()?.splitCurrentTabHorizontally()
    }

    func splitVertically() {
        ensureActiveOverlayModel()?.splitCurrentTabVertically()
    }

    func openTextEditorPane() {
        ensureActiveOverlayModel()?.openTextEditorInCurrentTab()
    }

    func openFilePreviewPane() {
        ensureActiveOverlayModel()?.openFilePreviewInCurrentTab()
    }

    func openDiffViewerPane() {
        guard let model = ensureActiveOverlayModel(),
              let tab = model.tabs.first(where: { $0.id == model.selectedTabID }),
              let session = tab.session else { return }

        let dir = session.currentDirectory

        // Try changed files from last AI command first
        let tabID = session.ownerTabID?.uuidString ?? model.selectedTabID.uuidString
        let aiFiles = CommandBlockManager.shared.lastChangedFiles(tabID: tabID)
        if let firstFile = aiFiles.first {
            model.openDiffViewerInCurrentTab(filePath: firstFile, directory: dir)
            return
        }

        // Fallback: first dirty file in working tree
        let porcelain = GitDiffTracker.runGit(args: ["status", "--porcelain"], in: dir)
        if let firstLine = porcelain.components(separatedBy: "\n").first(where: { !$0.isEmpty }),
           firstLine.count > 3 {
            let file = String(firstLine.dropFirst(3))
            model.openDiffViewerInCurrentTab(filePath: file, directory: dir)
        }
    }

    func showChangedFiles() {
        guard let model = ensureActiveOverlayModel(),
              let tab = model.tabs.first(where: { $0.id == model.selectedTabID }),
              let session = tab.session else { return }
        let tabID = session.ownerTabID?.uuidString ?? model.selectedTabID.uuidString
        let files = CommandBlockManager.shared.lastChangedFiles(tabID: tabID)
        if files.isEmpty {
            Log.info("AppDelegate: showChangedFiles — no changed files for tab \(tabID.prefix(8))")
            return
        }
        ChangedFilesPanel.show(files: files, directory: session.currentDirectory)
    }

    // MARK: - Multi-Window Autosave

    /// Start a centralized 30-second autosave timer that atomically saves ALL windows.
    /// Replaces the per-window autosave that caused race conditions on the same UserDefaults key.
    private func startMultiWindowAutoSaveTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self] in
            self?.saveAllWindowStates(reason: .autosave)
        }
        timer.resume()
        multiWindowAutoSaveTimer = timer
    }

    /// Save all visible windows' tab states atomically to UserDefaults.
    /// Window 0 → legacy key, windows 1..N → multi-window key.
    /// Also triggers per-window disk backups.
    private func saveAllWindowStates(reason: TabStateSaveReason) {
        var allWindows: [[SavedTabState]] = []
        for host in overlayHosts {
            let isHidden = hiddenWindowNumbers.contains(host.window.windowNumber)
            guard !isHidden, host.window.isVisible else { continue }
            let states = host.model.exportTabStates()
            if !states.isEmpty { allWindows.append(states) }
        }
        guard !allWindows.isEmpty else { return }

        // Write window 0 to legacy key
        if let firstWindowStates = allWindows.first,
           let data = try? JSONEncoder().encode(firstWindowStates) {
            UserDefaults.standard.set(data, forKey: SavedTabState.userDefaultsKey)
        }
        // Write all windows to multi-window key
        if allWindows.count > 1 {
            let multiState = SavedMultiWindowState(windows: allWindows)
            if let data = try? JSONEncoder().encode(multiState) {
                UserDefaults.standard.set(data, forKey: SavedMultiWindowState.userDefaultsKey)
            }
        } else {
            UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        }
        Log.trace("Saved \(allWindows.count) window(s) tab state [\(reason.rawValue)]")

        // Trigger per-window disk backups
        for host in overlayHosts {
            let isHidden = hiddenWindowNumbers.contains(host.window.windowNumber)
            guard !isHidden, host.window.isVisible else { continue }
            host.model.saveTabState(reason: reason)
        }
    }

    // MARK: - Tab Move Between Windows

    /// Wire tab-move callbacks on all overlay models and update their window lists.
    /// Called after window creation, tab moves, and window activation.
    private func wireTabMoveCallbacks() {
        for (i, host) in overlayHosts.enumerated() {
            // Use weak self + resolve index at call time to handle array mutations
            let model = host.model
            model.onMoveTabToWindow = { [weak self, weak model] tabID, targetWindowIndex in
                guard let self, let model,
                      let currentIndex = self.overlayHosts.firstIndex(where: { $0.model === model }) else { return }
                self.moveTab(tabID, fromWindowIndex: currentIndex, toWindowIndex: targetWindowIndex)
            }
            model.onMoveGroupToWindow = { [weak self, weak model] groupID, targetWindowIndex in
                guard let self, let model,
                      let currentIndex = self.overlayHosts.firstIndex(where: { $0.model === model }) else { return }
                self.moveGroup(groupID, fromWindowIndex: currentIndex, toWindowIndex: targetWindowIndex)
            }
            // Wire the lazy refresh callback for context menu
            model.onRefreshWindowTitles = { [weak self] in
                self?.wireTabMoveCallbacks()
            }
            // Build window titles: "Window N (M tabs)" for each OTHER window
            model.otherWindowTitles = overlayHosts.enumerated().compactMap { j, other in
                guard j != i else { return nil }
                let tabCount = other.model.tabs.count
                let title = other.window.title.isEmpty
                    ? "Window \(j + 1) (\(tabCount) tab\(tabCount == 1 ? "" : "s"))"
                    : "\(other.window.title) (\(tabCount) tab\(tabCount == 1 ? "" : "s"))"
                return OverlayTabsModel.WindowMenuItem(id: j, title: title)
            }
        }
    }

    /// Move a tab from one window to another. Pass toWindowIndex = -1 to create a new window.
    private func moveTab(_ tabID: UUID, fromWindowIndex: Int, toWindowIndex: Int) {
        guard fromWindowIndex < overlayHosts.count else { return }
        let source = overlayHosts[fromWindowIndex].model
        guard let tab = source.detachTab(id: tabID) else { return }

        if toWindowIndex == -1 {
            // Create a new window and move the tab into it
            guard let model else { return }
            let tabsModel = OverlayTabsModel(appModel: model, restoreState: false)
            // Replace the default fresh tab with the moved tab
            var movedTab = tab
            tabsModel.tabs = [movedTab]
            tabsModel.selectedTabID = movedTab.id
            movedTab.stampOwnerTabID()
            tabsModel.tabs[0] = movedTab
            TerminalControlService.shared.register(tabsModel)
            let windowNumber = allocateOverlayWindowNumber()
            let window = createOverlayWindow(tabsModel: tabsModel, windowNumber: windowNumber)
            overlayHosts.append(OverlayHost(window: window, model: tabsModel))
            wireTabMoveCallbacks()
            showOverlayWindow(overlayHosts.last!, reason: "moveToNewWindow")
            Log.info("Moved tab \(tabID) to new window \(windowNumber)")
        } else {
            guard toWindowIndex < overlayHosts.count else { return }
            let target = overlayHosts[toWindowIndex].model
            target.tabs.append(tab)
            target.selectTab(id: tab.id)
            wireTabMoveCallbacks()
            Log.info("Moved tab \(tabID) from window \(fromWindowIndex) to \(toWindowIndex)")
        }
    }

    /// Move all tabs in a repo group from one window to another.
    private func moveGroup(_ repoGroupID: String, fromWindowIndex: Int, toWindowIndex: Int) {
        guard fromWindowIndex < overlayHosts.count else { return }
        let source = overlayHosts[fromWindowIndex].model
        let groupTabs = source.detachGroup(repoGroupID: repoGroupID)
        guard !groupTabs.isEmpty else { return }

        if toWindowIndex == -1 {
            guard let model else { return }
            let tabsModel = OverlayTabsModel(appModel: model, restoreState: false)
            tabsModel.tabs = groupTabs.map { var t = $0; t.stampOwnerTabID(); return t }
            tabsModel.selectedTabID = groupTabs[0].id
            TerminalControlService.shared.register(tabsModel)
            let windowNumber = allocateOverlayWindowNumber()
            let window = createOverlayWindow(tabsModel: tabsModel, windowNumber: windowNumber)
            overlayHosts.append(OverlayHost(window: window, model: tabsModel))
            wireTabMoveCallbacks()
            showOverlayWindow(overlayHosts.last!, reason: "moveGroupToNewWindow")
            Log.info("Moved group \(repoGroupID) (\(groupTabs.count) tabs) to new window \(windowNumber)")
        } else {
            guard toWindowIndex < overlayHosts.count else { return }
            let target = overlayHosts[toWindowIndex].model
            target.tabs.append(contentsOf: groupTabs)
            target.selectTab(id: groupTabs[0].id)
            wireTabMoveCallbacks()
            Log.info("Moved group \(repoGroupID) (\(groupTabs.count) tabs) from window \(fromWindowIndex) to \(toWindowIndex)")
        }
    }

    // MARK: - Multi-Window Restoration

    /// Restore additional windows saved in the multi-window state.
    /// Window 0 is already restored by the primary OverlayTabsModel init.
    /// Windows 1..N are created here with their saved tab states.
    private func restoreAdditionalWindows() {
        guard let model else { return }
        guard let data = UserDefaults.standard.data(forKey: SavedMultiWindowState.userDefaultsKey),
              let multiState = try? JSONDecoder().decode(SavedMultiWindowState.self, from: data),
              multiState.windows.count > 1 else { return }

        // Clear the key so we don't restore stale windows on crash recovery
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)

        // Skip window 0 (already restored by the primary overlayModel)
        for windowIndex in 1 ..< multiState.windows.count {
            let windowStates = multiState.windows[windowIndex]
            guard !windowStates.isEmpty else { continue }

            // Pass pre-decoded states directly — no UserDefaults round-trip
            let tabsModel = OverlayTabsModel(appModel: model, restoringStates: windowStates)
            TerminalControlService.shared.register(tabsModel)
            let windowNumber = allocateOverlayWindowNumber()
            let window = createOverlayWindow(tabsModel: tabsModel, windowNumber: windowNumber)
            overlayHosts.append(OverlayHost(window: window, model: tabsModel))

            Log.info("Restored additional window \(windowIndex) with \(windowStates.count) tab(s)")
        }
    }

    // MARK: - PTY Log Maintenance

    /// Truncate PTY logs over 10MB on startup to prevent disk bloat.
    private func purgeLargePTYLogs() {
        let logDir = RuntimeIsolation.expandTilde(in: "~/Library/Logs/Chau7")
        let maxBytes: UInt64 = 10 * 1024 * 1024
        DispatchQueue.global(qos: .utility).async {
            guard let files = try? FileManager.default.contentsOfDirectory(atPath: logDir) else { return }
            for file in files where file.hasSuffix("-pty.log") {
                let path = (logDir as NSString).appendingPathComponent(file)
                guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
                      let size = attrs[.size] as? UInt64, size > maxBytes else { continue }
                // Keep the last 5MB — seek to tail instead of reading entire file
                let keepBytes: UInt64 = 5 * 1024 * 1024
                do {
                    let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
                    handle.seek(toFileOffset: size - keepBytes)
                    let tail = handle.readDataToEndOfFile()
                    handle.closeFile()
                    try tail.write(to: URL(fileURLWithPath: path), options: .atomic)
                    Log.info("Purged PTY log \(file): \(size / 1024 / 1024)MB → \(keepBytes / 1024 / 1024)MB")
                } catch {
                    Log.warn("Failed to purge PTY log \(file): \(error)")
                }
            }
        }
    }

    // MARK: - URL Scheme Handler (chau7://)

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            handleChau7URL(url)
        }
    }

    private func handleChau7URL(_ url: URL) {
        guard url.scheme == "chau7" else { return }
        let host = url.host ?? ""
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        Log.info("AppDelegate: URL handler: \(url)")

        switch host {
        case "run":
            // chau7://run/<base64-encoded-command>
            guard !path.isEmpty,
                  let data = Data(base64Encoded: path),
                  let command = String(data: data, encoding: .utf8) else {
                Log.warn("AppDelegate: chau7://run — invalid base64 command")
                return
            }
            confirmAndRun(command: command, source: url.absoluteString)

        case "ssh":
            // chau7://ssh/user@host or chau7://ssh/user@host:port
            guard !path.isEmpty else { return }
            let sanitized = path.replacingOccurrences(of: "'", with: "'\\''")
            openNewTabWithCommand("ssh '\(sanitized)'")

        case "cd":
            // chau7://cd/path/to/directory
            let dir = "/" + path // URL path is already absolute minus leading /
            openNewTabWithCommand("cd '\(dir.replacingOccurrences(of: "'", with: "'\\''"))' && clear")

        case "open":
            // chau7://open/path/to/file.md — open file in editor pane
            let filePath = "/" + path
            ensureActiveOverlayModel()?.openTextEditorInCurrentTab(filePath: filePath)

        default:
            Log.warn("AppDelegate: unknown chau7:// host: \(host)")
        }
    }

    private func confirmAndRun(command: String, source: String) {
        let alert = NSAlert()
        alert.messageText = "Run command from URL?"
        alert.informativeText = "A URL is requesting to run:\n\n\(command.prefix(500))\n\nSource: \(source)"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Run")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        openNewTabWithCommand(command)
    }

    private func openNewTabWithCommand(_ command: String) {
        guard let model = ensureActiveOverlayModel() else { return }
        model.newTab()
        // Delay slightly to let the terminal initialize
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            model.selectedTab?.session?.sendInput(command + "\n")
        }
    }

    func closeCurrentPane() {
        ensureActiveOverlayModel()?.closeFocusedPaneInCurrentTab()
    }

    func focusNextPane() {
        ensureActiveOverlayModel()?.focusNextPaneInCurrentTab()
    }

    func focusPreviousPane() {
        ensureActiveOverlayModel()?.focusPreviousPaneInCurrentTab()
    }

    func appendSelectionToEditor() {
        ensureActiveOverlayModel()?.appendSelectionToEditorInCurrentTab()
    }

    // MARK: - Help Menu Actions

    func showHelp() {
        HelpWindowController.shared.show()
    }

    func showKeyboardShortcuts() {
        KeyboardShortcutsWindowController.shared.show()
    }

    func showSnippetsSettings() {
        SnippetsSettingsWindowController.shared.show()
    }

    @objc func insertSnippetByID(_ sender: Any?) {
        guard let snippetID = sender as? String else { return }
        guard let entry = SnippetManager.shared.entries.first(where: { $0.snippet.id == snippetID }) else { return }
        ensureActiveOverlayModel()?.insertSnippet(entry)
    }

    func showReleaseNotes() {
        let alert = NSAlert()
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        alert.messageText = L("alert.whatsNew.title", "What's New in Chau7")
        alert.informativeText = String(
            format: L("alert.whatsNew.message", """
            Version %@

            Recent Updates:
            - Command Palette (⇧⌘P)
            - SSH Connection Manager
            - Inline Image Support (imgcat)
            - Keyboard Shortcuts Editor
            - Built-in Help Documentation
            - Option+Click cursor positioning
            - Auto-focus on new tabs
            - Improved menu bar organization
            """),
            version
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("button.ok", "OK"))
        alert.runModal()
    }

    func reportIssue() {
        if let issueURL = BugReporter.shared.prefilledIssueURL() {
            NSWorkspace.shared.open(issueURL)
        } else {
            let alert = NSAlert()
            alert.messageText = L("alert.reportIssue.title", "Report an Issue")
            alert.informativeText = L("alert.reportIssue.message", "Unable to build a prefilled GitHub issue link.")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("button.ok", "OK"))
            alert.runModal()
        }
    }

    private func setupOverlayWindow() {
        guard let overlayModel else {
            Log.error("Overlay window missing models.")
            return
        }
        guard overlayHosts.isEmpty else { return }

        let windowNumber = allocateOverlayWindowNumber()
        let window = createOverlayWindow(tabsModel: overlayModel, windowNumber: windowNumber)
        overlayHosts.append(OverlayHost(window: window, model: overlayModel))
        activeOverlayModel = overlayModel
        wireTabMoveCallbacks()
        logOverlayDiagnostics(reason: "setup", window: window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        Log.info("windowShouldClose called for window: \(sender.title), isClosingTab=\(isClosingTab)")
        if overlayHosts.contains(where: { $0.window == sender }) {
            if isClosingTab {
                // Don't hide window - we're just closing a tab, not the window
                Log.info("windowShouldClose: ignoring - tab close in progress")
                return false
            }
            Log.info("windowShouldClose: hiding overlay window instead of closing")
            hiddenWindowNumbers.insert(sender.windowNumber)
            if let host = overlayHosts.first(where: { $0.window == sender }) {
                host.model.noteTabBarVisibilityChanged(isVisible: false)
            }
            logOverlayWindowLifecycle(reason: "windowShouldClose-orderOut", window: sender)
            sender.orderOut(nil)
            return false
        }
        Log.info("windowShouldClose: allowing window to close")
        return true
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard overlayHosts.contains(where: { $0.window == window }) else { return }
        logOverlayWindowLifecycle(reason: "windowWillClose", window: window)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let host = overlayHosts.first(where: { $0.window == window }) {
            activeOverlayModel = host.model
            host.model.focusSelected()

            // Only refresh the tab bar if this window was previously hidden.
            // This prevents unnecessary refreshes on every focus change (e.g., Command-Tab).
            // The NSHostingView in the toolbar can become "stale" after hide/show cycles.
            let wasHidden = hiddenWindowNumbers.remove(window.windowNumber) != nil
            let wasShownBefore = shownWindowNumbers.contains(window.windowNumber)
            if !wasShownBefore {
                shownWindowNumbers.insert(window.windowNumber)
            }
            if wasHidden, wasShownBefore {
                host.model.noteTabBarVisibilityChanged(isVisible: true)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    Log.info("Proactive tab bar refresh after window show")
                    TabBarToolbarDelegate.shared.recreateToolbar(for: window)
                    TabBarToolbarDelegate.shared.updateToolbarItemSizing(for: window)
                }
            }
        }
        logOverlayWindowLifecycle(reason: "didBecomeKey", window: window)
        logOverlayDiagnostics(reason: "didBecomeKey", window: window)
    }

    func windowDidResignKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        logOverlayWindowLifecycle(reason: "didResignKey", window: window)
        logOverlayDiagnostics(reason: "didResignKey", window: window)
    }

    func windowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        logOverlayWindowLifecycle(reason: "didBecomeMain", window: window)
        logOverlayDiagnostics(reason: "didBecomeMain", window: window)
    }

    func windowDidResignMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        logOverlayWindowLifecycle(reason: "didResignMain", window: window)
        logOverlayDiagnostics(reason: "didResignMain", window: window)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        // Occlusion fires many times per second during space switches — trace-only
        guard Log.isTraceEnabled else { return }
        guard let window = notification.object as? NSWindow else { return }
        logOverlayDiagnostics(reason: "didChangeOcclusion", window: window)
    }

    func windowDidMiniaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        logOverlayWindowLifecycle(reason: "didMiniaturize", window: window)
        logOverlayDiagnostics(reason: "didMiniaturize", window: window)
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        logOverlayWindowLifecycle(reason: "didDeminiaturize", window: window)
        logOverlayDiagnostics(reason: "didDeminiaturize", window: window)
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard overlayHosts.contains(where: { $0.window == window }) else { return }
        logOverlayWindowLifecycle(reason: "didResize", window: window)
        let titlebarHeight = window.frame.height - window.contentLayoutRect.height
        if window.contentLayoutRect.width <= 0 || window.contentLayoutRect.height <= 0 || titlebarHeight <= 0 || !titlebarHeight.isFinite {
            Log
                .warn(
                    "windowDidResize: invalid resize geometry for overlay window. frame=\(window.frame) content=\(window.contentLayoutRect) titlebarHeight=\(titlebarHeight). Forcing toolbar recreation"
                )
            TabBarToolbarDelegate.shared.recreateToolbar(for: window)
        }
        TabBarToolbarDelegate.shared.updateToolbarItemSizing(for: window)

        // Post-resize recovery: check if the hosting view collapsed after layout settles.
        // NSHostingView inside NSToolbar can lose its render layer during resize transitions
        // even though SwiftUI reports valid metrics. Detect and force recreation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard self != nil else { return }
            TabBarToolbarDelegate.shared.validateHostingViewFrame(for: window) {
                Log.warn("windowDidResize: hosting view frame collapsed after resize, forcing toolbar recreation")
                TabBarToolbarDelegate.shared.recreateToolbar(for: window)
            }
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard overlayHosts.contains(where: { $0.window == window }) else { return }
        // Keep the toolbar visible during fullscreen to avoid slide-down layout shifts.
        logOverlayWindowLifecycle(reason: "willEnterFullScreen", window: window)
        window.toolbar?.isVisible = true
        TitlebarBackgroundInstaller.install(for: window)
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard overlayHosts.contains(where: { $0.window == window }) else { return }
        logOverlayWindowLifecycle(reason: "didEnterFullScreen", window: window)
        window.toolbar?.isVisible = true
        TabBarToolbarDelegate.shared.updateToolbarItemSizing(for: window)
        TitlebarBackgroundInstaller.install(for: window)

        // macOS moves the toolbar into an NSToolbarFullScreenWindow during fullscreen.
        // The NSHostingView's CALayer can become stale after this re-parenting, leaving
        // SwiftUI reporting valid layout but nothing composited on screen.
        // Force a toolbar recreation to get a fresh hosting view in the new window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Log.info("windowDidEnterFullScreen: recreating toolbar for fullscreen compositing fix")
            TabBarToolbarDelegate.shared.recreateToolbar(for: window)
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        guard overlayHosts.contains(where: { $0.window == window }) else { return }
        logOverlayWindowLifecycle(reason: "didExitFullScreen", window: window)
        window.toolbar?.isVisible = true
        TabBarToolbarDelegate.shared.updateToolbarItemSizing(for: window)
        TitlebarBackgroundInstaller.install(for: window)

        // Same compositing fix as didEnterFullScreen — toolbar moves back from
        // NSToolbarFullScreenWindow to the regular window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            Log.info("windowDidExitFullScreen: recreating toolbar for compositing fix")
            TabBarToolbarDelegate.shared.recreateToolbar(for: window)
        }
    }

    /// Fullscreen with auto-hiding menu bar (appears on hover at top edge)
    func window(_ window: NSWindow, willUseFullScreenPresentationOptions proposedOptions: NSApplication.PresentationOptions = []) -> NSApplication.PresentationOptions {
        // Only apply to overlay windows
        guard overlayHosts.contains(where: { $0.window == window }) else {
            return proposedOptions
        }
        // .autoHideMenuBar: menu bar hides but appears on top-edge hover
        // .fullScreen: standard fullscreen mode
        // Note: We don't use .autoHideToolbar since we have no system toolbar
        return [.autoHideMenuBar, .fullScreen]
    }

    /// Returns the active overlay model, creating a new overlay window if none exists.
    /// This ensures shortcuts like Cmd+T always work, even when no overlay is open.
    @discardableResult
    private func ensureActiveOverlayModel() -> OverlayTabsModel? {
        if let activeOverlayModel {
            return activeOverlayModel
        }
        if let host = overlayHosts.first {
            activeOverlayModel = host.model
            return host.model
        }
        // No overlay exists - create one automatically
        guard model != nil else {
            Log.warn("Cannot create overlay: AppModel not available.")
            return nil
        }
        Log.info("Auto-creating overlay window for shortcut.")
        newOverlayWindow()
        return activeOverlayModel
    }

    private func createOverlayWindow(tabsModel: OverlayTabsModel, windowNumber: Int) -> NSWindow {
        guard let model else {
            fatalError("AppModel must be set before creating overlay windows")
        }
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1200, height: 800)
        let width = min(1100, screenFrame.width - 120)
        let height = min(640, screenFrame.height - 120)
        let origin = NSPoint(
            x: screenFrame.minX + (screenFrame.width - width) / 2,
            y: screenFrame.maxY - height - 60
        )

        let window = OverlayWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        let overlay = Chau7OverlayView(overlayModel: tabsModel, appModel: model)
        let hostingView = NSHostingView(rootView: overlay)

        let blur = OverlayBlurView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        window.contentView = blur
        blur.hostedView = hostingView
        blur.addSubview(hostingView)
        hostingView.frame = window.contentLayoutRect

        window.title = String(format: L("window.overlay.title", "Chau7 - Window %d"), windowNumber)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true

        // Safari-style unified toolbar - traffic lights integrate naturally
        let toolbarIdentifier = NSToolbar.Identifier("Chau7Toolbar-\(windowNumber)")
        // Register tabsModel BEFORE creating toolbar (toolbar populates items immediately)
        TabBarToolbarDelegate.shared.registerTabsModel(tabsModel, for: toolbarIdentifier)

        let toolbar = NSToolbar(identifier: toolbarIdentifier)
        toolbar.displayMode = .iconOnly
        toolbar.delegate = TabBarToolbarDelegate.shared
        window.toolbar = toolbar
        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
            window.titlebarSeparatorStyle = .none
        }
        TitlebarBackgroundInstaller.install(for: window)

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.alphaValue = FeatureSettings.shared.windowOpacity
        window.level = FeatureSettings.shared.windowFloating ? .floating : .normal
        // collectionBehavior is set by OverlayWindow.setupFullscreenBehavior()
        // to [.fullScreenPrimary, .managed] — don't overwrite it here.
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.isRestorable = false // Chau7 manages its own window restoration
        window.delegate = self
        window.contentView = blur

        tabsModel.overlayWindow = window
        tabsModel.onCloseLastTab = { [weak self, weak window] in
            guard let window else { return }
            self?.hiddenWindowNumbers.insert(window.windowNumber)
            tabsModel.noteTabBarVisibilityChanged(isVisible: false)
            self?.logOverlayWindowLifecycle(reason: "onCloseLastTab-orderOut", window: window)
            window.orderOut(nil)
        }
        Log.info("Overlay window created.")
        return window
    }

    private func showOverlayWindow(_ host: OverlayHost, reason: String) {
        host.model.noteTabBarVisibilityChanged(isVisible: true)
        host.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        host.model.focusSelected()
        logOverlayWindowLifecycle(reason: "showOverlayWindow-\(reason)", window: host.window)
        logOverlayDiagnostics(reason: reason, window: host.window)
        Log.info("Overlay window shown (\(reason)).")
    }

    private func logOverlayWindowLifecycle(reason: String, window: NSWindow) {
        let now = CFAbsoluteTimeGetCurrent()
        if reason == lastOverlayLifecycleReason && (now - lastOverlayLifecycleLogAt) < 0.5 {
            return
        }
        lastOverlayLifecycleLogAt = now
        lastOverlayLifecycleReason = reason

        let isOverlayHost = overlayHosts.contains(where: { $0.window == window })
        let model = overlayHosts.first(where: { $0.window == window })?.model
        let tabCount = model?.tabs.count ?? -1
        let toolbarState = window.toolbar?.isVisible == true ? "visible" : "hidden"
        let titlebarHeight = max(0, window.frame.height - window.contentLayoutRect.height)
        let title = window.title.isEmpty ? "unnamed" : window.title
        let occlusionVisible = window.occlusionState.contains(.visible)
        Log
            .trace(
                "Overlay window lifecycle (\(reason)): overlay=\(isOverlayHost) title=\(title) tabs=\(tabCount) windowNumber=\(window.windowNumber) style=\(window.styleMask.rawValue) toolbar=\(toolbarState) key=\(window.isKeyWindow) main=\(window.isMainWindow) visible=\(window.isVisible) onActiveSpace=\(window.isOnActiveSpace) mini=\(window.isMiniaturized) occlusionVisible=\(occlusionVisible) occlusion=\(window.occlusionState) frame=\(window.frame) content=\(window.contentLayoutRect) titlebarHeight=\(titlebarHeight) alpha=\(window.alphaValue)"
            )
    }

    private func applyWindowOpacity() {
        let opacity = FeatureSettings.shared.windowOpacity
        for host in overlayHosts {
            host.window.alphaValue = opacity
        }
        Log.info("Overlay window opacity updated: \(opacity)")
    }

    private func logOverlayDiagnostics(reason: String, window: NSWindow) {
        guard Log.isTraceEnabled else { return }
        guard let host = overlayHosts.first(where: { $0.window == window }) else { return }

        // Deduplicate: skip if same reason within 2 seconds
        let now = CFAbsoluteTimeGetCurrent()
        if reason == lastOverlayDiagReason, (now - lastOverlayDiagLogAt) < 2.0 {
            return
        }
        lastOverlayDiagLogAt = now
        lastOverlayDiagReason = reason

        let occlusionVisible = window.occlusionState.contains(.visible)
        let appearance = window.effectiveAppearance.name.rawValue
        let blurView = window.contentView as? NSVisualEffectView
        let blurDesc: String
        if let blurView {
            blurDesc = "material=\(blurView.material) blending=\(blurView.blendingMode) state=\(blurView.state)"
        } else {
            blurDesc = "none"
        }
        Log
            .trace(
                "Overlay window state (\(reason)): key=\(window.isKeyWindow) main=\(window.isMainWindow) visible=\(window.isVisible) onActiveSpace=\(window.isOnActiveSpace) mini=\(window.isMiniaturized) occlusionVisible=\(occlusionVisible) occlusion=\(window.occlusionState) alpha=\(window.alphaValue) level=\(window.level.rawValue) appearance=\(appearance) blur[\(blurDesc)]"
            )
        host.model.logVisualState(reason: "window:\(reason)")
    }

    private func applyAppTheme() {
        let theme = FeatureSettings.shared.appTheme
        let appearance: NSAppearance?
        switch theme {
        case .system:
            appearance = nil
        case .light:
            appearance = NSAppearance(named: .aqua)
        case .dark:
            appearance = NSAppearance(named: .darkAqua)
        }

        NSApp.appearance = appearance
        for host in overlayHosts {
            host.window.appearance = appearance
        }
        settingsWindow?.appearance = appearance
        splashController?.windowAppearance = appearance
        DebugConsoleController.shared.windowAppearance = appearance
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // Note: Cmd+C and Cmd+V are now handled directly by the terminal view
        // via performKeyEquivalent. We keep the monitor for potential future shortcuts
        // that need to be handled at the app level.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyEvent(event) ?? event
        }
        Log.info("Installed local key monitor.")
    }

    private func eventMatchesMenuShortcut(_ event: NSEvent) -> Bool {
        guard let key = normalizedKeyEquivalent(from: event) else { return false }
        let modifiers = normalizedModifierFlags(event.modifierFlags)
        return menuContainsKeyEquivalent(NSApp.mainMenu, key: key, modifiers: modifiers)
    }

    private func normalizedKeyEquivalent(from event: NSEvent) -> String? {
        if let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty {
            return key
        }
        if let key = event.characters?.lowercased(), !key.isEmpty {
            return key
        }
        return nil
    }

    private func normalizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        var normalized = flags.intersection(.deviceIndependentFlagsMask)
        normalized.remove(.capsLock)
        normalized.remove(.numericPad)
        normalized.remove(.function)
        return normalized
    }

    private func isTextInputFocused(in window: NSWindow?) -> Bool {
        guard let responder = window?.firstResponder else { return false }
        if responder is NSTextView || responder is NSTextField {
            return true
        }
        return false
    }

    /// Returns the active terminal view if one is first responder
    private func activeTerminalView(in window: NSWindow?) -> TerminalViewLike? {
        guard let window = window,
              overlayHosts.contains(where: { $0.window == window }),
              let responder = window.firstResponder else { return nil }

        if let rustView = responder as? RustTerminalView {
            return rustView
        }
        return nil
    }

    private func shouldUseAlternateTabNavigationShortcuts() -> Bool {
        let settings = FeatureSettings.shared
        let baseShortcuts = KeyboardShortcut.shortcuts(for: settings.keybindingPreset)

        func matchesBase(action: String) -> Bool {
            guard let current = settings.shortcut(for: action),
                  let base = baseShortcuts.first(where: { $0.action == action }) else {
                return true
            }
            let currentKey = current.key.lowercased()
            let baseKey = base.key.lowercased()
            let currentModifiers = Set(current.modifiers.map { $0.lowercased() })
            let baseModifiers = Set(base.modifiers.map { $0.lowercased() })
            return currentKey == baseKey && currentModifiers == baseModifiers
        }

        return matchesBase(action: "nextTab") && matchesBase(action: "previousTab")
    }

    private func menuContainsKeyEquivalent(
        _ menu: NSMenu?,
        key: String,
        modifiers: NSEvent.ModifierFlags
    ) -> Bool {
        guard let menu else { return false }
        for item in menu.items {
            if item.isEnabled {
                let itemKey = item.keyEquivalent.lowercased()
                if !itemKey.isEmpty {
                    let itemModifiers = item.keyEquivalentModifierMask
                        .intersection(.deviceIndependentFlagsMask)
                    if itemKey == key, itemModifiers == modifiers {
                        return true
                    }
                }
            }
            if menuContainsKeyEquivalent(item.submenu, key: key, modifiers: modifiers) {
                return true
            }
        }
        return false
    }

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        let flags = normalizedModifierFlags(event.modifierFlags)

        guard let window = NSApp.keyWindow else { return event }
        let isOverlayWindow = overlayHosts.contains(where: { $0.window == window })
        let overlayModel = isOverlayWindow ? activeOverlayModel : nil

        if isOverlayWindow,
           flags == [.command],
           let tabNumber = tabNumberForKeyCode(event.keyCode) {
            selectTab(number: tabNumber)
            return nil
        }

        // ⌘; (Snippets) is now handled by OverlayWindow.performKeyEquivalent
        // which fires before the local monitor.  No duplicate handling here.

        // Handle Escape key to close search/rename overlays
        if event.keyCode == KeyboardShortcuts.escapeKeyCode, let model = overlayModel {
            if model.isSearchVisible {
                model.toggleSearch()
                return nil
            }
            if model.isRenameVisible {
                model.cancelRename()
                return nil
            }
        }

        if isOverlayWindow {
            if eventMatchesMenuShortcut(event) {
                return event
            }
            if let action = KeybindingsManager.shared.actionForEvent(event) {
                if action == .closeTab {
                    closeTabFromShortcut()
                } else {
                    KeybindingsManager.shared.executeAction(action, delegate: self, overlayModel: overlayModel)
                }
                return nil
            }
        }

        if event.keyCode == KeyboardShortcuts.tabKeyCode, isOverlayWindow {
            if flags == [.control] {
                Log.info("Ctrl+Tab: switching to next tab.")
                nextTab()
                return nil
            }
            if flags == [.control, .shift] {
                Log.info("Ctrl+Shift+Tab: switching to previous tab.")
                previousTab()
                return nil
            }
        }

        if isOverlayWindow,
           flags == [.command, .option],
           shouldUseAlternateTabNavigationShortcuts(),
           !isTextInputFocused(in: window) {
            if event.keyCode == KeyboardShortcuts.rightArrowKeyCode {
                Log.info("Cmd+Opt+Right: switching to next tab.")
                nextTab()
                return nil
            }
            if event.keyCode == KeyboardShortcuts.leftArrowKeyCode {
                Log.info("Cmd+Opt+Left: switching to previous tab.")
                previousTab()
                return nil
            }
        }

        return event
    }

    private func tabNumberForKeyCode(_ keyCode: UInt16) -> Int? {
        switch keyCode {
        case UInt16(kVK_ANSI_1):
            return 1
        case UInt16(kVK_ANSI_2):
            return 2
        case UInt16(kVK_ANSI_3):
            return 3
        case UInt16(kVK_ANSI_4):
            return 4
        case UInt16(kVK_ANSI_5):
            return 5
        case UInt16(kVK_ANSI_6):
            return 6
        case UInt16(kVK_ANSI_7):
            return 7
        case UInt16(kVK_ANSI_8):
            return 8
        case UInt16(kVK_ANSI_9):
            return 9
        default:
            return nil
        }
    }

    private func allocateOverlayWindowNumber() -> Int {
        defer { nextOverlayWindowNumber += 1 }
        return nextOverlayWindowNumber
    }
}
