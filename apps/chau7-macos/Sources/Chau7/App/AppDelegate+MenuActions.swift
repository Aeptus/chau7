import AppKit
import Chau7Core

/// Menu-bar and keyboard action handlers (App / File / Edit / View / Window /
/// Help menus, plus Smart Select All and pane actions). These were split out of
/// AppDelegate.swift verbatim; they remain members of AppDelegate so menu target
/// wiring and the keybindings dispatcher continue to reach them unchanged.
///
/// Note: `showWelcomeFromMenu` (a Help action) intentionally stays in
/// AppDelegate.swift because it drives the splash/welcome lifecycle handle.
extension AppDelegate {
    private static let passwordAutofillSelector = NSSelectorFromString("_handleInsertFromPasswordsCommand:")

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

            Copyright \u{00a9} 2024-2026 Aeptus
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
        if NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) {
            Log.trace("Cut handled by responder chain.")
            return
        }

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

    // MARK: - Dashboard

    func toggleDashboard() {
        guard let model = ensureActiveOverlayModel() else { return }
        if let repoGroupID = model.selectedTab?.repoGroupID {
            model.toggleDashboard(for: repoGroupID)
        } else if let gitRoot = model.selectedTab?.session?.gitRootPath {
            model.toggleDashboard(for: gitRoot)
        }
    }

    // MARK: - Pane Actions

    func splitHorizontally() {
        ensureActiveOverlayModel()?.splitCurrentTabHorizontally()
    }

    func splitVertically() {
        ensureActiveOverlayModel()?.splitCurrentTabVertically()
    }

    func openTextEditorPane() {
        ensureActiveOverlayModel()?.toggleTextEditorInCurrentTab()
    }

    func openFilePreviewPane() {
        ensureActiveOverlayModel()?.toggleFilePreviewInCurrentTab()
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

        let accessSnapshot = ProtectedPathPolicy.ensureLiveAccessForUserInitiatedAction(
            path: dir,
            actionDescription: "load live Git status"
        )
        guard accessSnapshot.canProbeLive else { return }

        // Fallback: first dirty file in working tree
        let porcelain = GitDiffTracker.runGit(args: ["status", "--porcelain"], in: dir)
        if let file = GitDiffTracker.firstChangedPath(inStatusPorcelain: porcelain) {
            model.openDiffViewerInCurrentTab(filePath: file, directory: dir)
        }
    }

    func openRepositoryPane() {
        guard let model = ensureActiveOverlayModel(),
              let tab = model.tabs.first(where: { $0.id == model.selectedTabID }) else { return }

        // Dashboard tabs have no session — use repoGroupID instead
        let dir: String
        if let session = tab.session {
            dir = session.gitRootPath ?? session.currentDirectory
        } else if let repoGroupID = tab.repoGroupID {
            dir = repoGroupID
        } else {
            return
        }
        model.toggleRepositoryPaneInCurrentTab(directory: dir)
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

    // MARK: - Pane Focus / Selection Actions

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

    func showTechnologyLicenses() {
        HelpWindowController.shared.show(topicID: "technology-licenses")
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
        BugReportWindowController.shared.show()
    }
}
