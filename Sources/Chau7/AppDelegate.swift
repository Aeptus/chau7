import AppKit
import SwiftUI
import SwiftTerm

private final class OverlayBlurView: NSVisualEffectView {
    weak var hostedView: NSView?

    override func layout() {
        super.layout()
        guard let hostedView else { return }
        hostedView.frame = window?.contentLayoutRect ?? bounds
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var model: AppModel?
    var overlayModel: OverlayTabsModel?
    private struct OverlayHost {
        let window: NSWindow
        let model: OverlayTabsModel
    }
    private var overlayHosts: [OverlayHost] = []
    private weak var activeOverlayModel: OverlayTabsModel?
    private var keyMonitor: Any?
    private var opacityObserver: Any?
    private var appThemeObserver: Any?
    private var splashController: SplashWindowController?
    private var settingsWindow: NSWindow?
    private var isClosingTab: Bool = false  // Flag to prevent windowShouldClose from hiding window during tab close
    private var nextOverlayWindowNumber: Int = 1

    // MARK: - App Nap Prevention
    // Activity token to prevent App Nap from throttling the terminal
    private var activityToken: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("AppDelegate did finish launching.")

        // CRITICAL: Prevent App Nap from throttling the terminal
        // This eliminates the "first keystroke lag" issue
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
            reason: "Terminal requires low-latency input processing"
        )
        Log.info("App Nap prevention enabled with latency-critical activity")

        NSApp.activate(ignoringOtherApps: true)

        opacityObserver = NotificationCenter.default.addObserver(
            forName: .terminalOpacityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyWindowOpacity()
        }

        appThemeObserver = NotificationCenter.default.addObserver(
            forName: .appThemeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyAppTheme()
        }

        // Show splash screen while initializing
        splashController = SplashWindowController()
        splashController?.show()

        model?.bootstrap()
        applyAppTheme()
        installKeyMonitor()

        // Initialize status bar controller (replaces MenuBarExtra for multi-monitor support)
        if let model {
            StatusBarController.shared.setup(model: model)
        }

        // Create overlay window hidden behind splash - this starts the shell
        setupOverlayWindow()

        // Initialize debug console controller
        if let model, let overlayModel {
            DebugConsoleController.shared.configure(appModel: model, overlayModel: overlayModel)
        }

        // Initialize command palette controller
        CommandPaletteController.shared.setup(appDelegate: self)

        // Initialize SSH connection manager
        SSHConnectionWindowController.shared.appDelegate = self

        // Keep overlay hidden initially
        for host in overlayHosts {
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
            // Now show the overlay window
            if let host = self?.overlayHosts.first {
                host.window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                host.model.focusSelected()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
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
            host.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            host.model.focusSelected()
        } else if let host = overlayHosts.first {
            host.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            host.model.focusSelected()
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
        let settingsView = SettingsWindowView(model: model)
        let hostingView = NSHostingView(rootView: settingsView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Chau7 Settings"
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
        let tabsModel = OverlayTabsModel(appModel: model)
        let windowNumber = allocateOverlayWindowNumber()
        let window = createOverlayWindow(tabsModel: tabsModel, windowNumber: windowNumber)
        overlayHosts.append(OverlayHost(window: window, model: tabsModel))
        activeOverlayModel = tabsModel
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
            window.orderOut(nil)
            Log.info("Overlay window hidden via Close Window.")
        } else {
            window.close()
            Log.info("Window closed.")
        }
    }

    func printTerminal() {
        guard let window = NSApp.keyWindow,
              overlayHosts.contains(where: { $0.window == window }),
              let terminalView = window.firstResponder as? Chau7TerminalView
        else {
            Log.trace("Print: no active terminal found.")
            return
        }

        let printInfo = NSPrintInfo.shared
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = true
        printInfo.isVerticallyCentered = false

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

        if NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) {
            Log.info("Copy action sent via responder chain.")
            return
        }
        Log.info("Responder chain failed, using overlay model fallback.")
        ensureActiveOverlayModel()?.copyOrInterrupt()
    }

    func paste() {
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
        guard let window = NSApp.keyWindow,
              overlayHosts.contains(where: { $0.window == window }),
              let terminalView = window.firstResponder as? Chau7TerminalView
        else {
            Log.trace("Clear scrollback: no active terminal found.")
            return
        }
        // Clear scrollback buffer and screen
        terminalView.getTerminal().resetToInitialState()
        terminalView.clearSelection()
        Log.info("Scrollback cleared.")
    }

    func clearScreen() {
        guard let window = NSApp.keyWindow,
              overlayHosts.contains(where: { $0.window == window }),
              let terminalView = window.firstResponder as? Chau7TerminalView
        else {
            Log.trace("Clear screen: no active terminal found.")
            return
        }
        // Send Ctrl+L to the shell - it will clear screen and redraw prompt
        terminalView.send(data: [0x0c])
        terminalView.clearSelection()
        Log.info("Sent Ctrl+L to shell for clear screen.")
    }

    // MARK: - App Menu Actions

    func showAbout() {
        let credits = """
        A modern terminal emulator designed for AI-assisted development.

        Features:
        - AI CLI Detection (Claude, Codex, Gemini)
        - Command Palette
        - SSH Connection Manager
        - Inline Images
        - Split Panes
        - Snippets & More

        Built with SwiftUI and SwiftTerm.

        Copyright \u{00a9} 2024-2025
        """

        let attributedCredits = NSMutableAttributedString(string: credits)
        attributedCredits.addAttributes(
            [.font: NSFont.systemFont(ofSize: 11)],
            range: NSRange(location: 0, length: credits.count)
        )

        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Chau7",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
            .credits: attributedCredits
        ])
    }

    // MARK: - File Menu Actions

    func openLocation() {
        let alert = NSAlert()
        alert.messageText = "Open Location"
        alert.informativeText = "Enter a directory path to open in a new tab:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        textField.stringValue = FileManager.default.homeDirectoryForCurrentUser.path
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
        guard let window = NSApp.keyWindow,
              overlayHosts.contains(where: { $0.window == window }),
              let terminalView = window.firstResponder as? Chau7TerminalView
        else {
            Log.trace("Export text: no active terminal found.")
            return
        }

        let savePanel = NSSavePanel()
        savePanel.allowedContentTypes = [.plainText]
        savePanel.nameFieldStringValue = "terminal-output.txt"
        savePanel.title = "Export Terminal Text"

        if savePanel.runModal() == .OK, let url = savePanel.url {
            // Select all text and get it
            terminalView.selectAll(nil)
            let text = terminalView.getSelectedText() ?? ""
            terminalView.clearSelection()
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

    // MARK: - Edit Menu Actions

    func cut() {
        // In terminal, cut = copy (we can't cut from terminal output)
        copyOrInterrupt()
    }

    func pasteEscaped() {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        // Escape special shell characters
        let escaped = string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "!", with: "\\!")

        guard let window = NSApp.keyWindow,
              overlayHosts.contains(where: { $0.window == window }),
              let terminalView = window.firstResponder as? Chau7TerminalView
        else { return }

        terminalView.insertText(escaped, replacementRange: NSRange(location: NSNotFound, length: 0))
        Log.info("Pasted escaped text.")
    }

    // MARK: - Smart Select All (Cmd+A / Cmd+A Cmd+A)
    private var lastSelectAllTime: Date?
    private let doubleTapThreshold: TimeInterval = 0.4  // 400ms for double-tap

    func selectAll() {
        guard let window = NSApp.keyWindow,
              overlayHosts.contains(where: { $0.window == window }),
              let terminalView = window.firstResponder as? Chau7TerminalView
        else { return }

        let now = Date()

        // Check if this is a double-tap (Cmd+A Cmd+A)
        if let lastTime = lastSelectAllTime,
           now.timeIntervalSince(lastTime) < doubleTapThreshold {
            // Double-tap: Select entire terminal buffer
            terminalView.selectAll(nil)
            Log.info("Cmd+A Cmd+A: Selected all terminal buffer.")
            lastSelectAllTime = nil  // Reset for next sequence
        } else {
            // Single tap: Select current input line
            selectCurrentInputLine(in: terminalView)
            Log.info("Cmd+A: Selected current input line.")
            lastSelectAllTime = now
        }
    }

    private func selectCurrentInputLine(in terminalView: Chau7TerminalView) {
        terminalView.selectCurrentLine()
    }

    func clearToPreviousMark() {
        // This is like Cmd+L in iTerm - clears screen but keeps scrollback
        clearScreen()
    }

    func useSelectionForFind() {
        guard let window = NSApp.keyWindow,
              overlayHosts.contains(where: { $0.window == window }),
              let terminalView = window.firstResponder as? Chau7TerminalView
        else { return }

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
        guard let window = NSApp.keyWindow,
              overlayHosts.contains(where: { $0.window == window }),
              let terminalView = window.firstResponder as? Chau7TerminalView
        else { return }

        terminalView.scrollToTop()
        Log.info("Scrolled to top.")
    }

    func scrollToBottom() {
        guard let window = NSApp.keyWindow,
              overlayHosts.contains(where: { $0.window == window }),
              let terminalView = window.firstResponder as? Chau7TerminalView
        else { return }

        terminalView.scrollToBottom()
        Log.info("Scrolled to bottom.")
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
        alert.messageText = "What's New in Chau7"
        alert.informativeText = """
        Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")

        Recent Updates:
        - Command Palette (⇧⌘P)
        - SSH Connection Manager
        - Inline Image Support (imgcat)
        - Keyboard Shortcuts Editor
        - Built-in Help Documentation
        - Option+Click cursor positioning
        - Auto-focus on new tabs
        - Improved menu bar organization
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    func reportIssue() {
        let alert = NSAlert()
        alert.messageText = "Report an Issue"
        alert.informativeText = """
        To report a bug or request a feature:

        1. Open Debug Console (⇧⌘L) to capture logs
        2. Note the steps to reproduce the issue
        3. Include your macOS version and Chau7 version

        You can export logs from Debug Console → Export Logs.
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Debug Console")
        alert.addButton(withTitle: "Cancel")

        if alert.runModal() == .alertFirstButtonReturn {
            DebugConsoleController.shared.toggle()
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
            sender.orderOut(nil)
            return false
        }
        Log.info("windowShouldClose: allowing window to close")
        return true
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if let host = overlayHosts.first(where: { $0.window == window }) {
            activeOverlayModel = host.model
            host.model.focusSelected()
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
            Log.error("AppModel missing; cannot create overlay window.")
            return NSWindow()
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

        window.title = "Chau7 - Window \(windowNumber)"
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
            window.toolbarStyle = .unified
            window.titlebarSeparatorStyle = .none
        }

        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.alphaValue = FeatureSettings.shared.windowOpacity
        window.level = .normal
        window.collectionBehavior = [.managed]
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = blur

        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        tabsModel.overlayWindow = window
        tabsModel.onCloseLastTab = { [weak window] in
            window?.orderOut(nil)
        }
        tabsModel.focusSelected()
        Log.info("Overlay window created and shown.")
        return window
    }

    private func applyWindowOpacity() {
        let opacity = FeatureSettings.shared.windowOpacity
        for host in overlayHosts {
            host.window.alphaValue = opacity
        }
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
        // Note: Cmd+C and Cmd+V are now handled directly by Chau7TerminalView
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
        return normalized
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
                    if itemKey == key && itemModifiers == modifiers {
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
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        guard let window = NSApp.keyWindow else { return event }
        let isOverlayWindow = overlayHosts.contains(where: { $0.window == window })
        let overlayModel = isOverlayWindow ? activeOverlayModel : nil

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

        return event
    }

    private func allocateOverlayWindowNumber() -> Int {
        defer { nextOverlayWindowNumber += 1 }
        return nextOverlayWindowNumber
    }
}
