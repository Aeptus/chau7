import Foundation
import AppKit
import Carbon
import QuartzCore
import SwiftTerm

final class Chau7TerminalView: LocalProcessTerminalView {
    var onOutput: ((Data) -> Void)?
    var onInput: ((String) -> Void)?
    var onBufferChanged: (() -> Void)?
    var onScrollChanged: (() -> Void)?
    var onScrollbackCleared: (() -> Void)?
    var onFilePathClicked: ((String, Int?, Int?) -> Void)?  // F03: Internal editor callback (path, line, column)
    var currentDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    private weak var cursorLineView: TerminalCursorLineView?
    private let inputLineTracker = InputLineTracker(maxEntries: FeatureSettings.shared.scrollbackLines)
    private var highlightContextLines = false
    private var highlightInputHistory = false
    private var isCursorLineHighlightEnabled = false
    private var snippetState: SnippetNavigationState?
    private let dimReplacement: [UInt8] = [0x1b, 0x5b, 0x33, 0x38, 0x3b, 0x35, 0x3b, 0x32, 0x34, 0x36, 0x6d] // ESC [ 38 ; 5 ; 246 m
    private let dimResetReplacement: [UInt8] = [0x1b, 0x5b, 0x33, 0x39, 0x6d] // ESC [ 39 m

    // F18: Copy-on-select tracking
    private var lastSelectionText: String?

    // Click-to-position cursor tracking (like modern text editors)
    private var mouseDownLocation: NSPoint?
    private var didDragSinceMouseDown = false
    private static let dragThreshold: CGFloat = 1.5  // Pixels of movement before considered a drag (lower = more sensitive to selections)

    // Auto-scroll during selection drag (SwiftTerm has the mechanism but no timer)
    private var autoScrollTimer: Timer?
    private var autoScrollDirection: Int = 0  // -1 = up, 0 = none, 1 = down

    // Event monitors for F03/F18/F21 (since SwiftTerm's input methods aren't open for override)
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    private var mouseDragMonitor: Any?  // For click vs drag detection
    private var mouseMoveMonitor: Any?
    private var keyDownMonitor: Any?
    private var isEventMonitoringEnabled = false

    // Debounced path detection for mouse hover (latency optimization)
    private var pathDetectionWorkItem: DispatchWorkItem?
    private static let pathDetectionQueue = DispatchQueue(label: "com.chau7.pathdetection", qos: .userInteractive)
    private var focusObservers: [NSObjectProtocol] = []
    private var appliedColorSchemeSignature: String?
    private var appliedCursorStyle: (style: String, blink: Bool)?
    private var bellConfig: (enabled: Bool, sound: String)?
    private var commandSelectionActive = false
    private var commandSelectionRange: CommandSelectionRange?
    private var commandSelectionMonitor: Any?
    private var appliedScrollbackLines: Int?

    // Command history navigation
    var tabIdentifier: String = ""
    var isAtPrompt: (() -> Bool)?
    private var historyMonitor: Any?
    private var lastHistoryCommand: String?
    private var lastHistoryWasUp: Bool = false

    // Smart Scroll: Track whether user is at the bottom of the terminal
    // When smart scroll is enabled and user has scrolled up, new output won't auto-scroll
    private var isUserAtBottom: Bool = true
    private static let scrollBottomThreshold: Double = 0.99  // Consider "at bottom" within 1% of end

    // MARK: - Color Configuration

    /// Configures colors to match Terminal.app's "Basic" profile for maximum compatibility.
    /// This ensures ANSI colors (especially greys) display correctly regardless of system appearance.
    func configureTerminalAppColors() {
        // Terminal.app Basic uses white background / black foreground
        nativeForegroundColor = NSColor(calibratedWhite: 0.0, alpha: 1.0)  // Black
        nativeBackgroundColor = NSColor(calibratedWhite: 1.0, alpha: 1.0)  // White

        // Install Terminal.app-compatible ANSI color palette
        let palette: [Color] = [
            // Standard colors (0-7)
            Color(red: 0, green: 0, blue: 0),                       // 0: Black
            Color(red: 0xC9 << 8, green: 0x1B << 8, blue: 0x00 << 8), // 1: Red
            Color(red: 0x00 << 8, green: 0xC2 << 8, blue: 0x00 << 8), // 2: Green
            Color(red: 0xC7 << 8, green: 0xC4 << 8, blue: 0x00 << 8), // 3: Yellow
            Color(red: 0x02 << 8, green: 0x25 << 8, blue: 0xC7 << 8), // 4: Blue
            Color(red: 0xC8 << 8, green: 0x30 << 8, blue: 0xC8 << 8), // 5: Magenta
            Color(red: 0x00 << 8, green: 0xC5 << 8, blue: 0xC7 << 8), // 6: Cyan
            Color(red: 0xC7 << 8, green: 0xC7 << 8, blue: 0xC7 << 8), // 7: White

            // Bright colors (8-15)
            Color(red: 0x68 << 8, green: 0x68 << 8, blue: 0x68 << 8), // 8: Bright Black
            Color(red: 0xFF << 8, green: 0x6D << 8, blue: 0x67 << 8), // 9: Bright Red
            Color(red: 0x5F << 8, green: 0xF9 << 8, blue: 0x67 << 8), // 10: Bright Green
            Color(red: 0xFE << 8, green: 0xFB << 8, blue: 0x67 << 8), // 11: Bright Yellow
            Color(red: 0x68 << 8, green: 0x71 << 8, blue: 0xFF << 8), // 12: Bright Blue
            Color(red: 0xFF << 8, green: 0x76 << 8, blue: 0xFF << 8), // 13: Bright Magenta
            Color(red: 0x5F << 8, green: 0xFD << 8, blue: 0xFF << 8), // 14: Bright Cyan
            Color(red: 0xFF << 8, green: 0xFF << 8, blue: 0xFF << 8), // 15: Bright White
        ]
        getTerminal().installPalette(colors: palette)
    }

    func applyColorScheme(_ scheme: TerminalColorScheme) {
        let signature = scheme.signature
        if appliedColorSchemeSignature == signature {
            return
        }
        appliedColorSchemeSignature = signature

        nativeBackgroundColor = scheme.nsColor(for: scheme.background)
        nativeForegroundColor = scheme.nsColor(for: scheme.foreground)
        caretColor = scheme.nsColor(for: scheme.cursor)
        selectedTextBackgroundColor = scheme.nsColor(for: scheme.selection)

        let palette: [Color] = [
            terminalColor(from: scheme.black),
            terminalColor(from: scheme.red),
            terminalColor(from: scheme.green),
            terminalColor(from: scheme.yellow),
            terminalColor(from: scheme.blue),
            terminalColor(from: scheme.magenta),
            terminalColor(from: scheme.cyan),
            terminalColor(from: scheme.white),
            terminalColor(from: scheme.brightBlack),
            terminalColor(from: scheme.brightRed),
            terminalColor(from: scheme.brightGreen),
            terminalColor(from: scheme.brightYellow),
            terminalColor(from: scheme.brightBlue),
            terminalColor(from: scheme.brightMagenta),
            terminalColor(from: scheme.brightCyan),
            terminalColor(from: scheme.brightWhite)
        ]
        getTerminal().installPalette(colors: palette)
    }

    func applyCursorStyle(style: String, blink: Bool) {
        if appliedCursorStyle?.style == style, appliedCursorStyle?.blink == blink {
            return
        }
        let cursorStyle: CursorStyle
        switch style {
        case "underline":
            cursorStyle = blink ? .blinkUnderline : .steadyUnderline
        case "bar":
            cursorStyle = blink ? .blinkBar : .steadyBar
        default:
            cursorStyle = blink ? .blinkBlock : .steadyBlock
        }
        getTerminal().setCursorStyle(cursorStyle)
        appliedCursorStyle = (style: style, blink: blink)
    }

    func applyBellSettings(enabled: Bool, sound: String) {
        bellConfig = (enabled: enabled, sound: sound)
    }

    func applyScrollbackLines(_ lines: Int) {
        if appliedScrollbackLines == lines {
            return
        }
        getTerminal().changeHistorySize(lines)
        appliedScrollbackLines = lines
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.window === window else { return nil }
        if allowMouseReporting, !event.modifierFlags.contains(.control) {
            return nil
        }
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return nil }

        window?.makeFirstResponder(self)

        let menu = NSMenu(title: L("terminal.context.title", "Terminal"))
        let canCopy = hasSelection || commandSelectionActive
        let canPaste = NSPasteboard.general.string(forType: .string) != nil

        let copyItem = NSMenuItem(title: L("terminal.context.copy", "Copy"), action: #selector(contextCopy), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = canCopy

        let pasteItem = NSMenuItem(title: L("terminal.context.paste", "Paste"), action: #selector(contextPaste), keyEquivalent: "")
        pasteItem.target = self
        pasteItem.isEnabled = canPaste

        let pasteEscapedItem = NSMenuItem(
            title: L("terminal.context.pasteEscaped", "Paste Escaped"),
            action: #selector(contextPasteEscaped),
            keyEquivalent: ""
        )
        pasteEscapedItem.target = self
        pasteEscapedItem.isEnabled = canPaste

        let selectAllItem = NSMenuItem(
            title: L("terminal.context.selectAll", "Select All"),
            action: #selector(contextSelectAll),
            keyEquivalent: ""
        )
        selectAllItem.target = self

        let clearScreenItem = NSMenuItem(
            title: L("terminal.context.clearScreen", "Clear Screen"),
            action: #selector(contextClearScreen),
            keyEquivalent: ""
        )
        clearScreenItem.target = self

        let clearScrollbackItem = NSMenuItem(
            title: L("terminal.context.clearScrollback", "Clear Scrollback"),
            action: #selector(contextClearScrollback),
            keyEquivalent: ""
        )
        clearScrollbackItem.target = self

        menu.addItem(copyItem)
        menu.addItem(pasteItem)
        menu.addItem(pasteEscapedItem)
        menu.addItem(.separator())
        menu.addItem(selectAllItem)
        menu.addItem(.separator())
        menu.addItem(clearScreenItem)
        menu.addItem(clearScrollbackItem)

        return menu
    }

    // MARK: - Terminal Delegate Overrides

    override func bell(source: Terminal) {
        guard let bellConfig, bellConfig.enabled else { return }

        switch bellConfig.sound {
        case "none":
            flashBell()
        case "subtle":
            if let sound = NSSound(named: NSSound.Name("Pop")) {
                sound.play()
            } else {
                NSSound.beep()
            }
        default:
            NSSound.beep()
        }
    }

    /// Override linefeed to preserve text selection during streaming output.
    /// SwiftTerm's default behavior clears selection on every linefeed, which causes
    /// selection flickering when content is streaming (e.g., from Claude, Codex, etc.).
    ///
    /// Note: When buffer scrolls, selection coordinates may reference shifted content.
    /// This is acceptable - preserving a slightly stale selection beats losing it.
    override func linefeed(source: Terminal) {
        // Only clear selection if user is NOT actively selecting text.
        // mouseDownLocation != nil means mouse button is held down.
        // didDragSinceMouseDown means they're dragging to select.
        // selectionActive is a simple boolean (O(1)) - avoid hasSelection which uses reflection.
        //
        // Thread safety: Minor race with mouse event monitors is acceptable;
        // worst case is one unnecessary selectNone() call during rapid streaming.
        let isActivelySelecting = mouseDownLocation != nil && didDragSinceMouseDown
        let hasExistingSelection = selectionActive

        if !isActivelySelecting && !hasExistingSelection {
            // No active selection - safe to clear (matches SwiftTerm default)
            selectNone()
        }
        // Otherwise: preserve selection during streaming
    }

    // Note: createImage and createImageFromBitmap are now handled via terminalDelegate
    // in SwiftTerm's extension, so we configure inline image support via the delegate instead

    private func flashBell() {
        let flash = NSView(frame: bounds)
        flash.wantsLayer = true
        flash.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.15).cgColor
        flash.alphaValue = 0.0
        flash.autoresizingMask = [.width, .height]
        addSubview(flash)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.05
            flash.animator().alphaValue = 1.0
        } completionHandler: {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                flash.animator().alphaValue = 0.0
            } completionHandler: {
                flash.removeFromSuperview()
            }
        }
    }

    private func terminalColor(from hex: String) -> Color {
        let nsColor = TerminalColorScheme.default.nsColor(for: hex)
        let rgb = nsColor.usingColorSpace(.deviceRGB) ?? nsColor
        let red = UInt16(rgb.redComponent * 65535)
        let green = UInt16(rgb.greenComponent * 65535)
        let blue = UInt16(rgb.blueComponent * 65535)
        return Color(red: red, green: green, blue: blue)
    }

    // MARK: - View Setup

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()

        if window != nil {
            if isEventMonitoringEnabled {
                setupEventMonitors()
                setupFocusObservers()
            }
            updateCursorLineHighlight()
        } else {
            removeEventMonitors()
            removeFocusObservers()
        }
    }

    override func layout() {
        super.layout()
        updateCursorLineHighlight()
    }

    deinit {
        removeEventMonitors()
        removeHistoryMonitor()
        removeFocusObservers()
    }

    func setEventMonitoringEnabled(_ enabled: Bool) {
        guard isEventMonitoringEnabled != enabled else { return }
        isEventMonitoringEnabled = enabled
        guard window != nil else { return }

        if enabled {
            setupEventMonitors()
            setupFocusObservers()
        } else {
            removeEventMonitors()
            removeFocusObservers()
        }
        updateCursorLineHighlight()
    }

    private func setupEventMonitors() {
        removeEventMonitors()

        let settings = FeatureSettings.shared
        let needsMouseMove = settings.isCmdClickPathsEnabled
        let needsKeyDown = settings.isSnippetsEnabled

        // Mouse down monitor: Cmd+Click paths, Option+Click cursor, click-to-position tracking
        // Always installed to support click-to-position feature
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self else { return event }

            // Only handle events in our window and view
            guard event.window === self.window else { return event }
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }

            // Track mouse down for click-to-position (like modern text editors)
            self.mouseDownLocation = location
            self.didDragSinceMouseDown = false

            // Check for Cmd+click on paths
            if event.modifierFlags.contains(.command) && FeatureSettings.shared.isCmdClickPathsEnabled {
                if self.handleCmdClick(at: location) {
                    self.mouseDownLocation = nil  // Don't position cursor for Cmd+click
                    return nil  // Consume the event
                }
            }

            // Option+click to position cursor (like iTerm2) - legacy behavior
            if event.modifierFlags.contains(.option) && FeatureSettings.shared.isOptionClickCursorEnabled {
                if self.handleOptionClick(at: location) {
                    self.mouseDownLocation = nil  // Already handled
                    return nil  // Consume the event
                }
            }

            self.updateCursorLineHighlight()
            return event
        }

        // Mouse dragged monitor: Track if user is dragging (for click vs drag detection)
        // Also handles auto-scroll when dragging outside bounds during selection
        mouseDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self = self else { return event }
            guard event.window === self.window else { return event }

            let location = self.convert(event.locationInWindow, from: nil)

            // Check if movement exceeds drag threshold
            if let downLocation = self.mouseDownLocation {
                let dx = abs(location.x - downLocation.x)
                let dy = abs(location.y - downLocation.y)
                if dx > Self.dragThreshold || dy > Self.dragThreshold {
                    self.didDragSinceMouseDown = true
                }
            }

            // Auto-scroll when dragging outside bounds during selection
            if self.didDragSinceMouseDown {
                if location.y < 0 {
                    // Dragging below view - scroll down (content moves up)
                    self.autoScrollDirection = 1
                    self.startAutoScrollTimer()
                } else if location.y > self.bounds.height {
                    // Dragging above view - scroll up (content moves down)
                    self.autoScrollDirection = -1
                    self.startAutoScrollTimer()
                } else {
                    // Inside bounds - stop auto-scroll
                    self.stopAutoScrollTimer()
                }
            }

            return event
        }

        // Mouse up monitor: Copy-on-select AND click-to-position cursor
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self = self else { return event }

            // Stop auto-scroll timer on mouse up
            self.stopAutoScrollTimer()

            // Always clear mouse tracking state on ANY mouseUp to prevent stale state
            // (even if the mouseUp is in a different window or outside bounds)
            let downLocation = self.mouseDownLocation
            let wasDrag = self.didDragSinceMouseDown
            self.mouseDownLocation = nil
            self.didDragSinceMouseDown = false

            // Only handle events in our window
            guard event.window === self.window else { return event }

            // Only process click-to-position and copy-on-select if mouseUp is within bounds
            let location = self.convert(event.locationInWindow, from: nil)
            guard self.bounds.contains(location) else { return event }

            // Click-to-position: If no drag occurred and single click, position cursor
            // Multiple safety checks to avoid interfering with selection:
            if let clickLocation = downLocation, !wasDrag {
                // Don't position cursor if:
                // - Shift is held (user wants to extend selection)
                // - It's a multi-click (double/triple click for word/line selection)
                // - There's an active selection (user just selected text)
                // - Command selection mode is active
                let isSingleClick = event.clickCount == 1
                let noModifiers = !event.modifierFlags.contains(.shift)
                let notInCommandSelection = !self.commandSelectionActive
                let noActiveSelection = !self.hasSelection
                let featureEnabled = FeatureSettings.shared.isClickToPositionEnabled

                if isSingleClick && noModifiers && notInCommandSelection && noActiveSelection && featureEnabled {
                    _ = self.handleClickToPosition(at: clickLocation)
                }
            }

            // Copy-on-select: always call handleMouseUp (it checks if feature is enabled)
            // This handles both drag-selections and keyboard selections (Shift+arrows)
            self.handleMouseUp(event: event)

            self.updateCursorLineHighlight()
            return event
        }

        // F03: Cursor change on hover with Cmd held
        // Only install if Cmd+click is enabled (latency optimization)
        if needsMouseMove {
            mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                guard let self = self else { return event }

                // Only handle events in our window and view
                guard event.window === self.window else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location) else { return event }

                self.handleMouseMove(at: location, modifiers: event.modifierFlags)
                self.updateCursorLineHighlight()
                return event
            }
        }

        // F21: Snippet placeholder navigation
        // Only install if snippets are enabled (latency optimization)
        if needsKeyDown {
            keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
                guard event.window === self.window else { return event }
                guard self.isFirstResponderInTerminal() else { return event }

                if self.handleSnippetKeyDown(event) {
                    return nil
                }
                return event
            }
        }
    }

    private func removeEventMonitors() {
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
        }
        if let monitor = mouseDragMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDragMonitor = nil
        }
        if let monitor = mouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMoveMonitor = nil
        }
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
        // NOTE: historyMonitor is NOT removed here — it has its own lifecycle
        // managed by installHistoryKeyMonitor/removeHistoryMonitor, and should
        // survive suspension/event-monitoring toggles.
    }

    private func setupFocusObservers() {
        removeFocusObservers()
        guard let window else { return }

        let center = NotificationCenter.default
        focusObservers.append(
            center.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.updateCursorLineHighlight()
            }
        )
        focusObservers.append(
            center.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                self?.updateCursorLineHighlight()
            }
        )
    }

    private func removeFocusObservers() {
        let center = NotificationCenter.default
        for observer in focusObservers {
            center.removeObserver(observer)
        }
        focusObservers.removeAll()
    }

    // MARK: - F18: Copy-on-Select

    private func handleMouseUp(event: NSEvent) {
        // Check if copy-on-select is enabled
        guard FeatureSettings.shared.isCopyOnSelectEnabled else { return }

        // Option key disables copy-on-select temporarily
        if event.modifierFlags.contains(.option) { return }

        // Check for selection and copy if present (with delay to let selection finalize)
        // Using 30ms for reliability while keeping good perceived responsiveness
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.030) { [weak self] in
            guard let self = self else { return }

            // Try the public getSelection() API first (simpler, more stable)
            if let text = self.getSelection(), !text.isEmpty {
                // Only copy if text is different from last copied text
                // But always update lastSelectionText to track current selection
                if text != self.lastSelectionText {
                    self.copyToClipboard(text)
                    Log.trace("Copy-on-select: copied \(text.count) chars via getSelection().")
                }
                self.lastSelectionText = text
                return
            }

            // Fallback: use coordinate-based extraction if getSelection() fails
            if let (startPos, endPos) = self.getSelectionCoordinates() {
                let terminal = self.getTerminal()
                let text = terminal.getText(start: startPos, end: endPos)

                if !text.isEmpty {
                    if text != self.lastSelectionText {
                        self.copyToClipboard(text)
                        Log.trace("Copy-on-select: copied \(text.count) chars via coordinates.")
                    }
                    self.lastSelectionText = text
                }
            } else {
                // No selection exists - clear lastSelectionText so the same text
                // can be copied again if user re-selects it
                self.lastSelectionText = nil
            }
        }
    }

    // MARK: - Command History Navigation

    func installHistoryKeyMonitor() {
        guard historyMonitor == nil else { return }
        historyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            guard event.window === self.window else { return event }
            guard self.isFirstResponderInTerminal() else { return event }
            if self.handleHistoryKeyDown(event) {
                return nil  // Consume event
            }
            return event
        }
    }

    private func removeHistoryMonitor() {
        if let monitor = historyMonitor {
            NSEvent.removeMonitor(monitor)
            historyMonitor = nil
        }
    }

    private func handleHistoryKeyDown(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let isUp = keyCode == UInt16(kVK_UpArrow)
        let isDown = keyCode == UInt16(kVK_DownArrow)
        guard isUp || isDown else { return false }

        // Only intercept at shell prompt — let programs like vim/less handle arrows
        guard isAtPrompt?() == true else { return false }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasOption = modifiers.contains(.option)
        // Don't intercept if Cmd/Ctrl/Shift are held (other shortcuts)
        let hasCmdCtrlShift = modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.shift)
        if hasCmdCtrlShift { return false }

        let command: String?
        if hasOption {
            // Option+Arrow: global history
            command = isUp
                ? CommandHistoryManager.shared.previousGlobal()
                : CommandHistoryManager.shared.nextGlobal()
        } else {
            // Arrow: per-tab history
            command = isUp
                ? CommandHistoryManager.shared.previousInTab(tabIdentifier)
                : CommandHistoryManager.shared.nextInTab(tabIdentifier)
        }

        guard let cmd = command else { return true }  // No more history, consume anyway

        // Avoid re-injecting the same command on key repeat (can spam the line)
        if event.isARepeat, cmd == lastHistoryCommand, lastHistoryWasUp == isUp {
            return true
        }
        lastHistoryCommand = cmd
        lastHistoryWasUp = isUp

        // Clear current input line: Ctrl+A (start of line) + Ctrl+K (kill to end)
        send(txt: "\u{01}\u{0B}")
        if !cmd.isEmpty {
            send(txt: cmd)
        }
        return true
    }

    private func handleSnippetKeyDown(_ event: NSEvent) -> Bool {
        guard let state = snippetState else { return false }
        let isTab = event.keyCode == UInt16(kVK_Tab)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommandModifiers = modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)
        if isTab && !hasCommandModifiers {
            let isBackward = modifiers.contains(.shift)
            return advanceSnippetPlaceholder(state: state, backward: isBackward)
        }
        snippetState = nil
        return false
    }

    // MARK: - F03: Cmd+Click Paths

    private func handleCmdClick(at point: NSPoint) -> Bool {
        // Get the line at click position
        guard let lineText = getLineAtPoint(point) else { return false }

        // Check for URLs first
        let urlMatches = findURLs(in: lineText)
        if let firstURL = urlMatches.first {
            PathClickHandler.openURL(firstURL)
            Log.info("Cmd+click: opened URL \(firstURL)")
            return true
        }

        // Check for file paths
        let pathMatches = PathClickHandler.findPaths(in: lineText)
        if let firstPath = pathMatches.first {
            let resolvedPath = PathClickHandler.resolvePath(firstPath.path, relativeTo: currentDirectory)

            // Verify file exists before attempting to open
            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                Log.warn("Cmd+click: file does not exist: \(resolvedPath)")
                return false
            }

            // F03: Open in internal editor if setting enabled and callback available
            if FeatureSettings.shared.cmdClickOpensInternalEditor,
               let callback = onFilePathClicked {
                callback(resolvedPath, firstPath.line, firstPath.column)
                Log.info("Cmd+click: opening in internal editor: \(resolvedPath)")
            } else {
                PathClickHandler.openPath(firstPath, relativeTo: currentDirectory)
                Log.info("Cmd+click: opened path \(firstPath.path)")
            }
            return true
        }

        return false
    }

    // MARK: - Click-to-Position Cursor (Modern Editor Style)

    /// Handle click to move cursor to clicked position (like VS Code, Sublime, etc.)
    /// Only works when clicking on the current input line (cursor row).
    /// This sends arrow key sequences to move the cursor horizontally.
    private func handleClickToPosition(at point: NSPoint) -> Bool {
        let terminal = getTerminal()
        guard terminal.rows > 0, terminal.cols > 0 else { return false }
        guard bounds.height > 0, bounds.width > 0 else { return false }

        // Calculate cell dimensions
        let cellHeight = bounds.height / CGFloat(terminal.rows)
        let cellWidth = bounds.width / CGFloat(terminal.cols)

        // Calculate clicked row and column (clamped to valid range)
        let clickedRow = max(0, min(Int((bounds.height - point.y) / cellHeight), terminal.rows - 1))
        let clickedCol = max(0, min(Int(point.x / cellWidth), terminal.cols - 1))

        // Get current cursor position
        let cursorRow = terminal.buffer.y
        let cursorCol = terminal.buffer.x

        // Only position cursor if click is on the SAME ROW as cursor (input line)
        // This prevents accidentally moving cursor when clicking on output
        guard clickedRow == cursorRow else { return false }

        let colDiff = clickedCol - cursorCol

        // Build escape sequences for horizontal cursor movement only
        var sequences = ""
        if colDiff > 0 {
            sequences = String(repeating: "\u{1b}[C", count: colDiff)  // Right arrow
        } else if colDiff < 0 {
            sequences = String(repeating: "\u{1b}[D", count: -colDiff)  // Left arrow
        }

        if !sequences.isEmpty {
            send(txt: sequences)
            Log.trace("Click-to-position: moved cursor by col=\(colDiff)")
            return true
        }

        return false
    }

    // MARK: - Option+Click Cursor Positioning

    /// Handle Option+click to move cursor to clicked position
    /// This sends arrow key sequences to move the cursor, similar to iTerm2
    private func handleOptionClick(at point: NSPoint) -> Bool {
        let terminal = getTerminal()
        guard terminal.rows > 0, terminal.cols > 0 else { return false }
        guard bounds.height > 0, bounds.width > 0 else { return false }

        // Calculate cell dimensions
        let cellHeight = bounds.height / CGFloat(terminal.rows)
        let cellWidth = bounds.width / CGFloat(terminal.cols)

        // Calculate clicked row and column
        let clickedRow = Int((bounds.height - point.y) / cellHeight)
        let clickedCol = Int(point.x / cellWidth)

        // Get current cursor position
        let cursorRow = terminal.buffer.y
        let cursorCol = terminal.buffer.x

        // Only move cursor if click is on the same row as cursor (for command line editing)
        // or within a reasonable range
        let rowDiff = clickedRow - cursorRow
        let colDiff = clickedCol - cursorCol

        // Build escape sequences for cursor movement
        var sequences = ""

        // Move vertically if needed (up/down arrows)
        if rowDiff > 0 {
            sequences += String(repeating: "\u{1b}[B", count: rowDiff)  // Down arrow
        } else if rowDiff < 0 {
            sequences += String(repeating: "\u{1b}[A", count: -rowDiff)  // Up arrow
        }

        // Move horizontally (left/right arrows)
        if colDiff > 0 {
            sequences += String(repeating: "\u{1b}[C", count: colDiff)  // Right arrow
        } else if colDiff < 0 {
            sequences += String(repeating: "\u{1b}[D", count: -colDiff)  // Left arrow
        }

        if !sequences.isEmpty {
            send(txt: sequences)
            Log.trace("Option+click: moved cursor by row=\(rowDiff), col=\(colDiff)")
            return true
        }

        return false
    }

    private func getLineAtPoint(_ point: NSPoint) -> String? {
        // Calculate row from point
        let terminal = getTerminal()
        guard terminal.rows > 0, bounds.height > 0 else { return nil }
        let cellHeight = bounds.height / CGFloat(terminal.rows)
        let row = Int((bounds.height - point.y) / cellHeight)

        // Get line from terminal buffer
        let buffer = terminal.getBufferAsData()
        let text = String(decoding: buffer, as: UTF8.self)
        let lines = text.components(separatedBy: "\n")

        let absoluteRow = terminal.buffer.yDisp + row
        guard absoluteRow >= 0 && absoluteRow < lines.count else { return nil }

        return lines[absoluteRow]
    }

    private func findURLs(in text: String) -> [String] {
        var urls: [String] = []
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)

        RegexPatterns.url.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            urls.append(nsText.substring(with: match.range))
        }

        return urls
    }

    // MARK: - Cursor Change on Hover (for clickable elements)

    private func handleMouseMove(at location: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard FeatureSettings.shared.isCmdClickPathsEnabled else { return }

        // If Command is not held, just show I-beam cursor
        guard modifiers.contains(.command) else {
            NSCursor.iBeam.set()
            return
        }

        // Get line text on main thread (fast operation)
        guard let lineText = getLineAtPoint(location) else {
            NSCursor.iBeam.set()
            return
        }

        // Cancel any pending detection work
        pathDetectionWorkItem?.cancel()

        // Debounce and run regex matching on background thread (latency optimization)
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let hasURL = !self.findURLs(in: lineText).isEmpty
            let hasPath = !PathClickHandler.findPaths(in: lineText).isEmpty
            let hasClickable = hasURL || hasPath

            DispatchQueue.main.async {
                if hasClickable {
                    NSCursor.pointingHand.set()
                } else {
                    NSCursor.iBeam.set()
                }
            }
        }
        pathDetectionWorkItem = work

        // Small debounce to avoid excessive work during rapid mouse movement
        Self.pathDetectionQueue.asyncAfter(deadline: .now() + 0.016, execute: work)
    }

    // MARK: - Copy (with SIGINT fallback)

    /// Gets selection start/end coordinates via reflection from SwiftTerm's SelectionService.
    /// This is a fallback when getSelection() returns empty despite a valid selection.
    /// Note: Reflection-based access is fragile and may break with SwiftTerm updates.
    private func getSelectionCoordinates() -> (start: Position, end: Position)? {
        // Find the selection property via Mirror traversal of class hierarchy
        var mirror: Mirror? = Mirror(reflecting: self)
        var iterationCount = 0
        let maxIterations = 10  // Guard against infinite loops in class hierarchy

        while let current = mirror, iterationCount < maxIterations {
            iterationCount += 1

            for child in current.children {
                guard child.label == "selection" else { continue }

                // Unwrap Optional if needed (selection is SelectionService!)
                let selMirror = Mirror(reflecting: child.value)
                var selectionObj: Any = child.value
                for optChild in selMirror.children {
                    if optChild.label == "some" {
                        selectionObj = optChild.value
                        break
                    }
                }

                // Extract start and end Position from SelectionService
                let serviceMirror = Mirror(reflecting: selectionObj)
                var startCol: Int?, startRow: Int?, endCol: Int?, endRow: Int?

                for prop in serviceMirror.children {
                    if prop.label == "start" {
                        let posMirror = Mirror(reflecting: prop.value)
                        for p in posMirror.children {
                            if p.label == "col", let v = p.value as? Int { startCol = v }
                            if p.label == "row", let v = p.value as? Int { startRow = v }
                        }
                    }
                    if prop.label == "end" {
                        let posMirror = Mirror(reflecting: prop.value)
                        for p in posMirror.children {
                            if p.label == "col", let v = p.value as? Int { endCol = v }
                            if p.label == "row", let v = p.value as? Int { endRow = v }
                        }
                    }
                }

                // Return coordinates only if we found all values and they represent a valid selection
                guard let sc = startCol, let sr = startRow,
                      let ec = endCol, let er = endRow else {
                    return nil
                }

                // Validate: selection must span at least one character
                guard sc != ec || sr != er else {
                    return nil
                }

                // Validate: coordinates should be non-negative
                guard sc >= 0, sr >= 0, ec >= 0, er >= 0 else {
                    return nil
                }

                return (Position(col: sc, row: sr), Position(col: ec, row: er))
            }
            mirror = current.superclassMirror
        }
        return nil
    }

    private func copyToClipboard(_ text: String) {
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
    }

    /// Selects the full current command (including wrapped rows).
    /// Used for Cmd+A to select the command being typed.
    func selectCurrentCommand() {
        guard let range = currentCommandRange() else { return }
        commandSelectionRange = range
        commandSelectionActive = true
        installCommandSelectionMonitor()
        if !applySelection(range: range) {
            // Fallback: keep command selection active for copy/delete handling.
            commandSelectionActive = true
        }
    }

    // MARK: - Paste

    override func paste(_ sender: Any) {
        // Use SwiftTerm's base implementation which handles bracketed paste mode
        super.paste(sender)
        Log.trace("Paste executed via SwiftTerm base class.")
    }

    @objc private func contextCopy(_ sender: Any?) {
        copy(self)
    }

    @objc private func contextPaste(_ sender: Any?) {
        paste(self)
    }

    @objc private func contextPasteEscaped(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        let escaped = PasteEscaper.escape(string)
        insertText(escaped, replacementRange: NSRange(location: NSNotFound, length: 0))
        Log.trace("Paste escaped executed from context menu.")
    }

    @objc private func contextSelectAll(_ sender: Any?) {
        selectAll(nil)
        clearCommandSelectionState()
    }

    @objc private func contextClearScreen(_ sender: Any?) {
        send(data: [0x0c])
        clearSelection()
        Log.trace("Clear screen executed from context menu.")
    }

    @objc private func contextClearScrollback(_ sender: Any?) {
        clearScrollbackBuffer()
        Log.trace("Clear scrollback executed from context menu.")
    }

    func clearScrollbackBuffer() {
        getTerminal().resetToInitialState()
        clearSelection()
        onScrollbackCleared?()
    }

    // MARK: - Selection Helpers

    /// Clears the current selection.
    func clearSelection() {
        selectNone()
        lastSelectionText = nil  // Clear stale copy-on-select state
        Log.trace("Selection cleared via selectNone().")
    }

    /// Returns true if there is currently selected text.
    /// Uses both public API and reflection fallback for maximum reliability.
    var hasSelection: Bool {
        // Try the public API first
        if let text = getSelection(), !text.isEmpty {
            return true
        }
        // Fallback: check via coordinates (in case getSelection() has bugs)
        if getSelectionCoordinates() != nil {
            return true
        }
        return false
    }

    // MARK: - Auto-Scroll During Selection

    /// Starts the auto-scroll timer for selection drag outside bounds.
    /// SwiftTerm has the mechanism but never creates the timer, so we implement it here.
    private func startAutoScrollTimer() {
        // Don't create multiple timers
        guard autoScrollTimer == nil else { return }

        autoScrollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.performAutoScroll()
        }
    }

    /// Stops the auto-scroll timer.
    private func stopAutoScrollTimer() {
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDirection = 0
    }

    /// Performs one step of auto-scrolling and extends selection.
    private func performAutoScroll() {
        guard autoScrollDirection != 0 else { return }

        // Scroll the terminal
        if autoScrollDirection < 0 {
            // Scroll up (show earlier content)
            scrollUp(lines: 2)
        } else {
            // Scroll down (show later content)
            scrollDown(lines: 2)
        }

        // Synthesize a mouse drag event to extend selection to new position
        // The y position should be outside bounds to continue extending
        guard let window = self.window else { return }

        let syntheticY: CGFloat
        if autoScrollDirection < 0 {
            // Scrolling up - mouse is above view
            syntheticY = bounds.height + 10
        } else {
            // Scrolling down - mouse is below view
            syntheticY = -10
        }

        let localPoint = NSPoint(x: bounds.midX, y: syntheticY)
        let windowPoint = convert(localPoint, to: nil)

        if let syntheticEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: windowPoint,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1.0
        ) {
            // Call the parent class mouseDragged to extend selection
            super.mouseDragged(with: syntheticEvent)
        }
    }

    // MARK: - Command Selection

    private struct CommandSelectionRange {
        let startRow: Int
        let endRow: Int
        let startCol: Int
        let endCol: Int
    }

    private func currentCommandRange() -> CommandSelectionRange? {
        let terminal = getTerminal()
        let cursor = terminal.getCursorLocation()
        let cursorRow = terminal.getTopVisibleRow() + cursor.y
        let endCol = min(max(cursor.x, 0), max(terminal.cols - 1, 0))
        guard let lines = bufferLinesSnapshot(), !lines.isEmpty else {
            return CommandSelectionRange(startRow: cursorRow, endRow: cursorRow, startCol: 0, endCol: endCol)
        }
        let clampedRow = min(max(cursorRow, 0), lines.count - 1)
        var startRow = clampedRow
        while startRow > 0, isWrappedLine(lines[startRow]) {
            startRow -= 1
        }
        var endRow = clampedRow
        while endRow + 1 < lines.count, isWrappedLine(lines[endRow + 1]) {
            endRow += 1
        }
        return CommandSelectionRange(startRow: startRow, endRow: endRow, startCol: 0, endCol: endCol)
    }

    private func applySelection(range: CommandSelectionRange) -> Bool {
        guard let window else { return false }
        let terminal = getTerminal()
        let topRow = terminal.getTopVisibleRow()
        let cellWidth = max(caretFrame.width, 1)
        let cellHeight = max(caretFrame.height, 1)

        func locationFor(row: Int, col: Int) -> NSPoint {
            let displayRow = row - topRow
            let x = CGFloat(col) * cellWidth + (cellWidth * 0.5)
            let y = bounds.height - (CGFloat(displayRow) + 0.5) * cellHeight
            return NSPoint(x: x, y: y)
        }

        let startPoint = locationFor(row: range.startRow, col: range.startCol)
        let endPoint = locationFor(row: range.endRow, col: range.endCol)
        let startInWindow = convert(startPoint, to: nil)
        let endInWindow = convert(endPoint, to: nil)

        let previousMouseReporting = allowMouseReporting
        allowMouseReporting = false
        defer { allowMouseReporting = previousMouseReporting }

        guard let startEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: startInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ),
        let endEvent = NSEvent.mouseEvent(
            with: .leftMouseDragged,
            location: endInWindow,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ) else {
            return false
        }

        mouseDragged(with: startEvent)
        mouseDragged(with: endEvent)
        return true
    }

    private func bufferLinesSnapshot() -> [Any?]? {
        let buffer = getTerminal().buffer
        let bufferMirror = Mirror(reflecting: buffer)
        guard let linesChild = bufferMirror.children.first(where: { $0.label == "_lines" }) else {
            return nil
        }
        let linesObject = linesChild.value
        let linesMirror = Mirror(reflecting: linesObject)

        guard let arrayChild = linesMirror.children.first(where: { $0.label == "array" }) else {
            return nil
        }
        let arrayValue = arrayChild.value
        let array: [Any?]
        if let typedArray = arrayValue as? [Any?] {
            array = typedArray
        } else {
            array = Mirror(reflecting: arrayValue).children.map { $0.value }
        }
        guard !array.isEmpty else { return nil }

        let startIndex = (linesMirror.children.first(where: { $0.label == "startIndex" })?.value as? Int) ?? 0
        let count = (linesMirror.children.first(where: { $0.label == "_count" })?.value as? Int) ?? array.count
        let limit = min(count, array.count)

        var lines: [Any?] = []
        lines.reserveCapacity(limit)
        for index in 0..<limit {
            let idx = (startIndex + index) % array.count
            lines.append(array[idx])
        }
        return lines
    }

    private func isWrappedLine(_ line: Any?) -> Bool {
        guard let unwrapped = unwrapOptional(line) else { return false }
        for child in Mirror(reflecting: unwrapped).children {
            if child.label == "isWrapped", let value = child.value as? Bool {
                return value
            }
        }
        return false
    }

    private func unwrapOptional(_ value: Any?) -> Any? {
        guard let value else { return nil }
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else { return value }
        return mirror.children.first?.value
    }

    private func clearCommandSelection() {
        commandSelectionActive = false
        commandSelectionRange = nil
        selectNone()
        lastSelectionText = nil  // Clear stale copy-on-select state
        removeCommandSelectionMonitor()
    }

    func clearCommandSelectionState() {
        commandSelectionActive = false
        commandSelectionRange = nil
        removeCommandSelectionMonitor()
    }

    private func commandSelectionText() -> String? {
        guard let range = commandSelectionRange else { return nil }
        let terminal = getTerminal()
        let start = Position(col: range.startCol, row: range.startRow)
        let end = Position(col: range.endCol, row: range.endRow)
        let text = terminal.getText(start: start, end: end)
        return text.trimmingCharacters(in: .newlines)
    }

    override func copy(_ sender: Any) {
        // Try the public getSelection() API first (consistent with copy-on-select)
        if let text = getSelection(), !text.isEmpty {
            copyToClipboard(text)
            Log.trace("Copied \(text.count) chars via getSelection().")
            return
        }

        // Fallback: try coordinate-based extraction if getSelection() fails
        if let (startPos, endPos) = getSelectionCoordinates() {
            let terminal = getTerminal()
            let text = terminal.getText(start: startPos, end: endPos)

            if !text.isEmpty {
                copyToClipboard(text)
                Log.trace("Copied \(text.count) chars via coordinates.")
                return
            }
        }

        // Try command selection (Cmd+A selected the current input)
        if commandSelectionActive, let text = commandSelectionText(), !text.isEmpty {
            copyToClipboard(text)
            Log.trace("Copied \(text.count) chars from command selection.")
            clearCommandSelection()
            return
        }

        // No selection - send Ctrl+C (SIGINT) to interrupt running process
        Log.trace("No selection - sending SIGINT.")
        send(data: [0x03])
    }

    private func installCommandSelectionMonitor() {
        guard commandSelectionMonitor == nil else { return }
        commandSelectionMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard self.commandSelectionActive else { return event }
            guard event.window === self.window else { return event }
            guard self.isFirstResponderInTerminal() else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if flags == [.command],
               event.charactersIgnoringModifiers?.lowercased() == "c" {
                self.copy(self)
                return nil
            }
            if flags.isEmpty,
               event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
                let text = self.commandSelectionText() ?? ""
                self.clearCommandSelection()
                if text.isEmpty {
                    self.send(data: [0x15])  // Ctrl+U
                } else {
                    self.send(data: [0x05])  // Ctrl+E
                    self.send(txt: String(repeating: "\u{7F}", count: text.count))
                }
                return nil
            }

            self.commandSelectionActive = false
            return event
        }
    }

    private func removeCommandSelectionMonitor() {
        if let monitor = commandSelectionMonitor {
            NSEvent.removeMonitor(monitor)
            commandSelectionMonitor = nil
        }
    }

    private func isFirstResponderInTerminal() -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self)
    }


    // MARK: - Data Flow Callbacks
    // Note: dataReceived is overridden below with local echo support

    /// Returns true if the slice contains ESC [ 2 (0x1b 0x5b 0x32) — the shared
    /// 3-byte prefix of both ESC[2m (dim) and ESC[22m (dim reset).
    private func sliceContainsDimPrefix(_ slice: ArraySlice<UInt8>) -> Bool {
        guard slice.count >= 3 else { return false }
        let start = slice.startIndex
        let limit = slice.endIndex - 2
        var i = start
        while i < limit {
            if slice[i] == 0x1b && slice[i + 1] == 0x5b && slice[i + 2] == 0x32 {
                return true
            }
            i += 1
        }
        return false
    }

    /// Replaces complete ESC[2m → ESC[38;5;246m and ESC[22m → ESC[39m in-chunk.
    /// Partial sequences at end of buffer pass through unchanged — SwiftTerm
    /// handles split sequences natively and renders them as actual dim.
    private func patchDimSequences(_ slice: ArraySlice<UInt8>) -> [UInt8] {
        var output: [UInt8] = []
        output.reserveCapacity(slice.count)

        let end = slice.endIndex
        var i = slice.startIndex

        while i < end {
            let remaining = end - i

            // Check ESC[22m (5 bytes, dim reset) before ESC[2m (4 bytes) to avoid prefix collision
            if remaining >= 5
                && slice[i] == 0x1b && slice[i + 1] == 0x5b
                && slice[i + 2] == 0x32 && slice[i + 3] == 0x32
                && slice[i + 4] == 0x6d
            {
                output.append(contentsOf: dimResetReplacement)
                i += 5
                continue
            }

            if remaining >= 4
                && slice[i] == 0x1b && slice[i + 1] == 0x5b
                && slice[i + 2] == 0x32 && slice[i + 3] == 0x6d
            {
                output.append(contentsOf: dimReplacement)
                i += 4
                continue
            }

            output.append(slice[i])
            i += 1
        }

        return output
    }

    // MARK: - Local Echo State
    // Track pending local echo to suppress PTY duplicates
    private var pendingLocalEcho: [UInt8] = []
    private var pendingLocalEchoOffset: Int = 0
    // Track pending backspaces to suppress PTY's backspace response
    private var pendingLocalBackspaces: Int = 0

    /// Checks if the PTY has echo enabled (safe for local echo).
    /// Returns false for password prompts, vim, etc. where echo is disabled.
    private var isPtyEchoEnabled: Bool {
        // Access the PTY file descriptor from LocalProcessTerminalView's process
        guard let proc = process, proc.childfd >= 0 else { return true }

        var termios = Darwin.termios()
        guard tcgetattr(proc.childfd, &termios) == 0 else { return true }

        // Check if ECHO flag is set in local modes
        return (termios.c_lflag & UInt(ECHO)) != 0
    }

    override func send(source: TerminalView, data: ArraySlice<UInt8>) {
        if let text = String(bytes: data, encoding: .utf8) {
            onInput?(text)
        }

        if data.contains(0x03) || data.contains(0x15) {
            pendingLocalEcho.removeAll()
            pendingLocalEchoOffset = 0
            pendingLocalBackspaces = 0
        }

        let localEchoEnabled = FeatureSettings.shared.isLocalEchoEnabled && isPtyEchoEnabled
        if !localEchoEnabled {
            pendingLocalEcho.removeAll()
            pendingLocalEchoOffset = 0
            pendingLocalBackspaces = 0
        }

        // LOCAL ECHO: Show printable characters IMMEDIATELY before PTY round-trip.
        // The PTY will echo the same character back, which we'll suppress in dataReceived.
        if localEchoEnabled {
            let token = FeatureProfiler.shared.begin(.localEcho, bytes: data.count)
            defer { FeatureProfiler.shared.end(token) }
            for byte in data {
                // Only local echo printable ASCII (0x20-0x7E)
                if byte >= 0x20 && byte <= 0x7E {
                    // Immediately render the character
                    feed(byteArray: [byte])
                    pendingLocalEcho.append(byte)
                } else if (byte == 0x7F || byte == 0x08) && !pendingLocalEcho.isEmpty {
                    // Backspace/Delete: Undo the last local echo visually
                    // Keep the char in pendingLocalEcho so PTY's echo is suppressed
                    // Track the backspace so we suppress PTY's backspace response too
                    pendingLocalBackspaces += 1
                    feed(byteArray: [0x08, 0x20, 0x08])  // BS, space, BS
                }
            }
            // Flush display immediately so user sees the character NOW
            CATransaction.flush()
        }

        super.send(source: source, data: data)
    }

    override func dataReceived(slice: ArraySlice<UInt8>) {
        guard !slice.isEmpty else { return }

        // SIMD pre-scan: classify incoming data for downstream optimization (zero-copy)
        let simdScanResult: SIMDTerminalParser.ScanResult? = slice.withUnsafeBufferPointer { buffer in
            SIMDTerminalParser.scan(buffer)
        }

        // DEBUG: Log suspicious escape sequences that might appear as artifacts
        #if DEBUG
        logSuspiciousSequences(slice)
        #endif

        // Smart Scroll: Save state before processing new data
        // If user had scrolled up and smart scroll is enabled, we'll restore their position
        let smartScrollEnabled = FeatureSettings.shared.isSmartScrollEnabled
        let wasAtBottom = isUserAtBottom
        let savedScrollPosition = scrollPosition

        // Suppress characters/sequences that we already local-echoed
        // Guard: skip entirely when local echo is disabled (default) — avoids per-byte overhead during AI streaming
        var filteredSlice = slice
        if !FeatureSettings.shared.isLocalEchoEnabled {
            // Local echo disabled — no pending state possible, skip suppression entirely
        } else if pendingLocalEchoOffset < pendingLocalEcho.count || pendingLocalBackspaces > 0 {
            var filtered: [UInt8] = []
            var i = slice.startIndex

            while i < slice.endIndex {
                let byte = slice[i]

                // Check for backspace sequence: 0x08 0x20 0x08 ("\b \b")
                if pendingLocalBackspaces > 0 && byte == 0x08 {
                    let remaining = slice.endIndex - i
                    if remaining >= 3 && slice[i+1] == 0x20 && slice[i+2] == 0x08 {
                        // Suppress backspace sequence we already displayed
                        pendingLocalBackspaces -= 1
                        // Also remove the char from pendingLocalEcho that was erased
                        if !pendingLocalEcho.isEmpty {
                            pendingLocalEcho.removeLast()
                        }
                        i += 3
                        continue
                    }
                }

                // Check for local echo character match
                if pendingLocalEchoOffset < pendingLocalEcho.count && byte == pendingLocalEcho[pendingLocalEchoOffset] {
                    // This byte matches our local echo - suppress it
                    pendingLocalEchoOffset += 1
                    i += 1
                    continue
                }

                // Include this byte in output
                filtered.append(byte)
                i += 1
            }

            // Compact the pendingLocalEcho buffer after suppression
            if pendingLocalEchoOffset > 0 && pendingLocalEchoOffset >= pendingLocalEcho.count {
                pendingLocalEcho.removeAll()
                pendingLocalEchoOffset = 0
            } else if pendingLocalEchoOffset > 64 && pendingLocalEchoOffset <= pendingLocalEcho.count {
                pendingLocalEcho.removeFirst(pendingLocalEchoOffset)
                pendingLocalEchoOffset = 0
            }

            // Clear stale pending state (timeout protection)
            if (pendingLocalEcho.count - pendingLocalEchoOffset) > 100 {
                pendingLocalEcho.removeAll()
                pendingLocalEchoOffset = 0
                pendingLocalBackspaces = 0
            }

            if filtered.isEmpty {
                // All bytes were suppressed
                let data = Data(slice)
                onOutput?(data)
                return
            }
            filteredSlice = filtered[...]
        }

        let data = Data(filteredSlice)
        onOutput?(data)

        // SIMD-accelerated render path: skip dim patching when no escape sequences present
        let renderToken = FeatureProfiler.shared.begin(.terminalRender, bytes: filteredSlice.count)
        if let scan = simdScanResult, scan.isPureASCII && !scan.hasEscapeSequences {
            // Fast path: pure ASCII, no escape sequences — skip all dim patching
            super.dataReceived(slice: filteredSlice)
        } else if let rustPatched = RustDimPatcher.shared.patchDim(filteredSlice) {
            super.dataReceived(slice: rustPatched[...])
        } else if sliceContainsDimPrefix(filteredSlice) {
            let patched = patchDimSequences(filteredSlice)
            super.dataReceived(slice: patched[...])
        } else {
            super.dataReceived(slice: filteredSlice)
        }
        FeatureProfiler.shared.end(renderToken)
        // Smart Scroll: Restore scroll position if user wasn't at bottom
        restoreSmartScrollIfNeeded(smartScrollEnabled: smartScrollEnabled, wasAtBottom: wasAtBottom, savedPosition: savedScrollPosition)
    }

    /// Restores scroll position if smart scroll is enabled and user wasn't at bottom.
    /// This preserves the user's reading position when new output arrives.
    private func restoreSmartScrollIfNeeded(smartScrollEnabled: Bool, wasAtBottom: Bool, savedPosition: Double) {
        // Only restore if:
        // 1. Smart scroll is enabled
        // 2. User wasn't at the bottom before new data arrived
        // 3. The scroll position actually changed (SwiftTerm auto-scrolled)
        guard smartScrollEnabled, !wasAtBottom, scrollPosition != savedPosition else { return }

        // Edge case: Don't restore to position 0 when scrollback just appeared.
        // When terminal has no scrollback, scrollPosition is forced to 0 regardless of
        // actual view state. If savedPosition was 0 and now > 0, scrollback just appeared
        // and user wasn't actually scrolled up - they were at the only position available.
        if savedPosition == 0 && scrollPosition > 0 {
            // Scrollback just appeared - let the auto-scroll to bottom happen
            isUserAtBottom = scrollPosition >= Self.scrollBottomThreshold
            return
        }

        // Restore the user's previous scroll position
        scroll(toPosition: savedPosition)
    }

    #if DEBUG
    /// Logs suspicious escape sequences that might appear as visible artifacts.
    /// These are sequences that should be processed by the terminal but sometimes leak through.
    private func logSuspiciousSequences(_ slice: ArraySlice<UInt8>) {
        // Only log if there are escape sequences
        guard slice.contains(0x1b) else { return }

        let data = Array(slice)
        var i = 0
        var suspicious: [(String, String)] = []

        while i < data.count {
            guard data[i] == 0x1b else { i += 1; continue }

            // Check for CSI sequences: ESC [
            if i + 1 < data.count && data[i + 1] == 0x5b {
                i += 2
                var seqBytes: [UInt8] = [0x1b, 0x5b]

                // Collect sequence until terminator
                while i < data.count {
                    seqBytes.append(data[i])
                    let byte = data[i]
                    i += 1
                    // CSI terminates at 0x40-0x7E
                    if byte >= 0x40 && byte <= 0x7e {
                        break
                    }
                }

                let seqStr = String(bytes: seqBytes, encoding: .utf8) ?? "?"
                let desc: String
                let terminator = seqBytes.last ?? 0

                switch terminator {
                case 0x49: // 'I' - Focus In
                    desc = "FocusIn (CSI I)"
                    suspicious.append((seqStr, desc))
                case 0x4f: // 'O' - Focus Out
                    desc = "FocusOut (CSI O)"
                    suspicious.append((seqStr, desc))
                case 0x52: // 'R' - Cursor Position Report
                    desc = "CursorPosReport (CSI R)"
                    suspicious.append((seqStr, desc))
                case 0x7e: // '~' - Various (could be bracketed paste)
                    if seqStr.contains("200") {
                        desc = "BracketedPasteStart"
                        suspicious.append((seqStr, desc))
                    } else if seqStr.contains("201") {
                        desc = "BracketedPasteEnd"
                        suspicious.append((seqStr, desc))
                    }
                default:
                    break
                }
            }
            // Check for OSC sequences: ESC ]
            else if i + 1 < data.count && data[i + 1] == 0x5d {
                i += 2
                var seqBytes: [UInt8] = [0x1b, 0x5d]

                // Collect until BEL or ST
                while i < data.count {
                    let byte = data[i]
                    seqBytes.append(byte)
                    i += 1
                    // BEL (0x07) or ESC \ (ST)
                    if byte == 0x07 { break }
                    if byte == 0x5c && seqBytes.count >= 2 && seqBytes[seqBytes.count - 2] == 0x1b { break }
                }

                let seqStr = String(bytes: seqBytes.prefix(30), encoding: .utf8) ?? "?"
                if seqStr.contains("10;") || seqStr.contains("11;") {
                    let desc = seqStr.contains("10;") ? "OSC FgColorQuery/Response" : "OSC BgColorQuery/Response"
                    suspicious.append((seqStr.prefix(40).description, desc))
                }
            } else {
                i += 1
            }
        }

        if !suspicious.isEmpty {
            let context = String(bytes: slice.prefix(50), encoding: .utf8)?
                .replacingOccurrences(of: "\u{1b}", with: "^[")
                .prefix(60) ?? "?"
            Log.warn("[EscSeq] Suspicious sequences in dataReceived: \(suspicious.map { "\($0.1)" }.joined(separator: ", "))")
            Log.trace("[EscSeq] Context: \(context)...")
        }
    }
    #endif

    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        onBufferChanged?()
        updateCursorLineHighlight()
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        onScrollChanged?()
        updateCursorLineHighlight()

        // Smart Scroll: Track if user is at or near the bottom
        // This is called for both user-initiated and programmatic scrolls
        isUserAtBottom = position >= Self.scrollBottomThreshold
    }

    func scrollToTop() {
        // Scroll to the beginning of the buffer (position 0)
        scroll(toPosition: 0)
    }

    func scrollToBottom() {
        // Scroll to the end of the buffer (position 1)
        scroll(toPosition: 1)
    }

    func getSelectedText() -> String? {
        guard let selection = getSelection(), !selection.isEmpty else {
            return nil
        }
        return selection
    }

    func attachCursorLineView(_ view: TerminalCursorLineView) {
        cursorLineView = view
        updateCursorLineHighlight()
    }

    func configureCursorLineHighlight(contextLines: Bool, inputHistory: Bool) {
        if highlightContextLines != contextLines || highlightInputHistory != inputHistory {
            highlightContextLines = contextLines
            highlightInputHistory = inputHistory
            updateCursorLineHighlight()
        }
    }

    func setCursorLineHighlightEnabled(_ enabled: Bool) {
        if isCursorLineHighlightEnabled != enabled {
            isCursorLineHighlightEnabled = enabled
            updateCursorLineHighlight()
        }
    }

    func recordInputLine() {
        let terminal = getTerminal()
        let cursor = terminal.getCursorLocation()
        let row = terminal.getTopVisibleRow() + cursor.y
        inputLineTracker.record(row: row)
        updateCursorLineHighlight()
    }

    func insertSnippet(_ insertion: SnippetInsertion) {
        let text = insertion.text
        let terminal = getTerminal()
        if terminal.bracketedPasteMode {
            send(txt: "\u{1B}[200~")
            send(txt: text)
            send(txt: "\u{1B}[201~")
        } else {
            send(txt: text)
        }
        guard !insertion.placeholders.isEmpty else {
            snippetState = nil
            return
        }
        guard !isUnsafeForPlaceholderNavigation(text) else {
            snippetState = nil
            return
        }
        var state = SnippetNavigationState(
            placeholders: insertion.placeholders,
            currentIndex: 0,
            cursorOffset: text.count,
            finalCursorOffset: insertion.finalCursorOffset
        )
        moveSnippetCursor(from: &state, to: insertion.placeholders[0].start)
        snippetState = state
    }

    private func updateCursorLineHighlight() {
        guard isCursorLineHighlightEnabled else {
            cursorLineView?.isHidden = true
            return
        }
        cursorLineView?.update(
            with: self,
            isFocused: hasFocus,
            showsContextLines: highlightContextLines,
            showsInputHistory: highlightInputHistory,
            inputLineTracker: inputLineTracker
        )
    }

    private func advanceSnippetPlaceholder(state: SnippetNavigationState, backward: Bool) -> Bool {
        var updated = state
        if backward {
            if updated.currentIndex > 0 {
                updated.currentIndex -= 1
                let target = updated.placeholders[updated.currentIndex].start
                moveSnippetCursor(from: &updated, to: target)
                snippetState = updated
                return true
            }
            moveSnippetCursor(from: &updated, to: updated.finalCursorOffset)
            snippetState = nil
            return true
        }

        if updated.currentIndex + 1 < updated.placeholders.count {
            updated.currentIndex += 1
            let target = updated.placeholders[updated.currentIndex].start
            moveSnippetCursor(from: &updated, to: target)
            snippetState = updated
            return true
        }

        moveSnippetCursor(from: &updated, to: updated.finalCursorOffset)
        snippetState = nil
        return true
    }

    private func moveSnippetCursor(from state: inout SnippetNavigationState, to targetOffset: Int) {
        let delta = state.cursorOffset - targetOffset
        if delta > 0 {
            send(txt: "\u{1B}[\(delta)D")
        } else if delta < 0 {
            send(txt: "\u{1B}[\(-delta)C")
        }
        state.cursorOffset = targetOffset
    }

    private func isUnsafeForPlaceholderNavigation(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if !scalar.isASCII {
                return true
            }
        }
        return false
    }
}

private struct SnippetNavigationState {
    var placeholders: [SnippetPlaceholder]
    var currentIndex: Int
    var cursorOffset: Int
    var finalCursorOffset: Int
}
