import AppKit
import SwiftUI
import SwiftTerm

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
    private var splashController: SplashWindowController?
    private var settingsWindow: NSWindow?
    private var isClosingTab: Bool = false  // Flag to prevent windowShouldClose from hiding window during tab close
    private var nextOverlayWindowNumber: Int = 1

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.info("AppDelegate did finish launching.")
        NSApp.activate(ignoringOtherApps: true)

        opacityObserver = NotificationCenter.default.addObserver(
            forName: .terminalOpacityChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.applyWindowOpacity()
        }

        // Show splash screen while initializing
        splashController = SplashWindowController()
        splashController?.show()

        model?.bootstrap()
        installKeyMonitor()

        // Initialize status bar controller (replaces MenuBarExtra for multi-monitor support)
        if let model {
            StatusBarController.shared.setup(model: model)
        }

        // F04: Initialize dropdown terminal controller
        if let model {
            DropdownController.shared.setup(appModel: model)
        }

        // Create overlay window hidden behind splash - this starts the shell
        setupOverlayWindow()

        // Initialize debug console controller
        if let model, let overlayModel {
            DebugConsoleController.shared.configure(appModel: model, overlayModel: overlayModel)
        }

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
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if let opacityObserver {
            NotificationCenter.default.removeObserver(opacityObserver)
            self.opacityObserver = nil
        }
        // Cleanup status bar controller
        StatusBarController.shared.cleanup()
        // F04: Cleanup dropdown controller
        DropdownController.shared.cleanup()
    }

    // F04: Toggle dropdown terminal
    func toggleDropdown() {
        DropdownController.shared.toggleDropdown()
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

    func closeTab() {
        ensureActiveOverlayModel()?.closeCurrentTab()
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
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Chau7",
            .applicationVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            .version: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1",
            .credits: NSAttributedString(string: "A modern terminal for AI-assisted development.\n\nCopyright \u{00a9} 2024\nhttps://github.com/yourrepo/chau7")
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

    func selectAll() {
        guard let window = NSApp.keyWindow,
              overlayHosts.contains(where: { $0.window == window }),
              let terminalView = window.firstResponder as? Chau7TerminalView
        else { return }

        terminalView.selectAll(nil)
        Log.info("Selected all text.")
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

    // MARK: - Help Menu Actions

    func showHelp() {
        if let url = URL(string: "https://github.com/yourrepo/chau7#readme") {
            NSWorkspace.shared.open(url)
        }
    }

    func showKeyboardShortcuts() {
        // Show settings window focused on keyboard shortcuts section
        showSettings()
        // TODO: Navigate to keyboard shortcuts section
    }

    func showReleaseNotes() {
        if let url = URL(string: "https://github.com/yourrepo/chau7/releases") {
            NSWorkspace.shared.open(url)
        }
    }

    func reportIssue() {
        if let url = URL(string: "https://github.com/yourrepo/chau7/issues/new") {
            NSWorkspace.shared.open(url)
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

        let overlay = Chau7OverlayView(overlayModel: tabsModel, appModel: model)
        let hostingView = NSHostingView(rootView: overlay)
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.addSubview(hostingView)

        NSLayoutConstraint.activate([
            hostingView.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            hostingView.topAnchor.constraint(equalTo: blur.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: blur.bottomAnchor)
        ])

        let window = OverlayWindow(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Chau7 - Window \(windowNumber)"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
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
        DropdownController.shared.applyOpacity(opacity)
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

    private func handleKeyEvent(_ event: NSEvent) -> NSEvent? {
        // Check if this is a command-key event in an overlay terminal
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Handle Escape key to close search/rename overlays
        if event.keyCode == KeyboardShortcuts.escapeKeyCode {
            if let model = activeOverlayModel {
                if model.isSearchVisible {
                    model.toggleSearch()
                    return nil
                }
                if model.isRenameVisible {
                    model.cancelRename()
                    return nil
                }
            }
        }

        if event.keyCode == KeyboardShortcuts.tabKeyCode {
            guard let window = NSApp.keyWindow,
                  overlayHosts.contains(where: { $0.window == window })
            else {
                return event
            }
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

        // Only process command-key combinations
        guard flags.contains(.command),
              let chars = event.charactersIgnoringModifiers?.lowercased()
        else {
            return event
        }

        // Handle Cmd+Shift+D to toggle debug console (works globally)
        if chars == "d", flags == [.command, .shift] {
            Log.info("Cmd+Shift+D: toggling debug console.")
            DebugConsoleController.shared.toggle()
            return nil
        }

        // Check if we're in an overlay window with terminal as first responder
        guard let window = NSApp.keyWindow,
              overlayHosts.contains(where: { $0.window == window })
        else {
            return event
        }

        // Handle Cmd+K to clear terminal screen
        if chars == "k", flags == .command {
            if let terminalView = window.firstResponder as? Chau7TerminalView {
                Log.info("Cmd+K: sending Ctrl+L to shell.")
                terminalView.send(data: [0x0c])
                terminalView.clearSelection()
                return nil
            }
        }

        // Handle Cmd+Shift+W to close window
        if chars == "w", flags == [.command, .shift] {
            Log.info("Cmd+Shift+W: closing window.")
            closeWindow()
            return nil
        }

        // Handle Cmd+W to close tab (not window)
        if chars == "w", flags == .command {
            Log.info("Cmd+W: closing current tab.")
            isClosingTab = true
            closeTab()
            // Reset flag after a short delay to allow windowShouldClose to see it
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.isClosingTab = false
            }
            return nil  // Consume event to prevent window close
        }

        // Note: Cmd+C and Cmd+V are handled by Chau7TerminalView.performKeyEquivalent
        // via the menu command system and sendAction, so we don't duplicate them here.

        return event
    }

    private func allocateOverlayWindowNumber() -> Int {
        defer { nextOverlayWindowNumber += 1 }
        return nextOverlayWindowNumber
    }
}
