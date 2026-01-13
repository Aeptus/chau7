import Foundation
import AppKit
import Carbon
import QuartzCore
import SwiftTerm

final class Chau7TerminalView: LocalProcessTerminalView {
    var onOutput: ((Data) -> Void)?
    var onInput: ((String) -> Void)?
    var onBufferChanged: (() -> Void)?
    var currentDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path
    private weak var cursorLineView: TerminalCursorLineView?
    private let inputLineTracker = InputLineTracker(maxEntries: FeatureSettings.shared.scrollbackLines)
    private var highlightContextLines = false
    private var highlightInputHistory = false
    private var isCursorLineHighlightEnabled = false
    private var snippetState: SnippetNavigationState?
    private var dimPatchRemainderBytes: [UInt8] = []
    private let dimSequence: [UInt8] = [0x1b, 0x5b, 0x32, 0x6d] // ESC [ 2 m
    private let dimResetSequence: [UInt8] = [0x1b, 0x5b, 0x32, 0x32, 0x6d] // ESC [ 22 m
    private let dimReplacement: [UInt8] = [0x1b, 0x5b, 0x33, 0x38, 0x3b, 0x35, 0x3b, 0x32, 0x34, 0x36, 0x6d] // ESC [ 38 ; 5 ; 246 m
    private let dimResetReplacement: [UInt8] = [0x1b, 0x5b, 0x33, 0x39, 0x6d] // ESC [ 39 m

    // F18: Copy-on-select tracking
    private var lastSelectionText: String?

    // Event monitors for F03/F18/F21 (since SwiftTerm's input methods aren't open for override)
    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
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
    private var appliedScrollbackLines: Int?

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
        let needsMouseDown = settings.isCmdClickPathsEnabled || settings.isOptionClickCursorEnabled
        let needsMouseUp = settings.isCopyOnSelectEnabled
        let needsMouseMove = settings.isCmdClickPathsEnabled
        let needsKeyDown = settings.isSnippetsEnabled

        // F03: Cmd+Click for paths/URLs, Option+Click for cursor positioning - monitor mouse down
        // Only install if at least one click feature is enabled (latency optimization)
        if needsMouseDown {
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self = self else { return event }

                // Only handle events in our window and view
                guard event.window === self.window else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location) else { return event }

                // Check for Cmd+click on paths
                if event.modifierFlags.contains(.command) && FeatureSettings.shared.isCmdClickPathsEnabled {
                    if self.handleCmdClick(at: location) {
                        return nil  // Consume the event
                    }
                }

                // Option+click to position cursor (like iTerm2)
                if event.modifierFlags.contains(.option) && FeatureSettings.shared.isOptionClickCursorEnabled {
                    if self.handleOptionClick(at: location) {
                        return nil  // Consume the event
                    }
                }

                self.updateCursorLineHighlight()
                return event
            }
        }

        // F18: Copy-on-select - monitor mouse up
        // Only install if copy-on-select is enabled (latency optimization)
        if needsMouseUp {
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
                guard let self = self else { return event }

                // Only handle events in our window and view
                guard event.window === self.window else { return event }
                let location = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(location) else { return event }

                self.handleMouseUp(event: event)
                self.updateCursorLineHighlight()
                return event
            }
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
                guard self.window?.firstResponder === self else { return event }

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
        if let monitor = mouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMoveMonitor = nil
        }
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
        }
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

        // Check for selection and copy if present (with minimal delay to let selection finalize)
        // Reduced from 50ms to 15ms for better perceived responsiveness
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
            guard let self = self else { return }
            if let (startPos, endPos) = self.getSelectionCoordinates() {
                let terminal = self.getTerminal()
                let text = terminal.getText(start: startPos, end: endPos)

                if !text.isEmpty && text != self.lastSelectionText {
                    self.copyToClipboard(text)
                    self.lastSelectionText = text
                    Log.trace("Copy-on-select: copied \(text.count) chars.")
                }
            }
        }
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
            PathClickHandler.openPath(firstPath, relativeTo: currentDirectory)
            Log.info("Cmd+click: opened path \(firstPath.path)")
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

    /// Copies selected text to clipboard. If no selection exists, sends Ctrl+C (SIGINT)
    /// to interrupt the running process - matching standard terminal behavior.
    override func copy(_ sender: Any) {
        // Get selection coordinates via reflection and extract text
        if let (startPos, endPos) = getSelectionCoordinates() {
            let terminal = getTerminal()
            let text = terminal.getText(start: startPos, end: endPos)

            if !text.isEmpty {
                copyToClipboard(text)
                Log.trace("Copied \(text.count) chars from selection.")
                return
            }
        }

        // No selection - send Ctrl+C (SIGINT) to interrupt running process
        Log.trace("No selection - sending SIGINT.")
        send(data: [0x03])
    }

    /// Gets selection start/end coordinates via reflection from SwiftTerm's SelectionService.
    /// SwiftTerm's getSelection() has a bug where it returns empty even with valid selection,
    /// so we bypass it by reading the coordinates directly and calling getText().
    private func getSelectionCoordinates() -> (start: Position, end: Position)? {
        // Find the selection property via Mirror traversal of class hierarchy
        var mirror: Mirror? = Mirror(reflecting: self)
        while let current = mirror {
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
                var startCol = 0, startRow = 0, endCol = 0, endRow = 0
                var foundStart = false, foundEnd = false

                for prop in serviceMirror.children {
                    if prop.label == "start" {
                        let posMirror = Mirror(reflecting: prop.value)
                        for p in posMirror.children {
                            if p.label == "col", let v = p.value as? Int { startCol = v }
                            if p.label == "row", let v = p.value as? Int { startRow = v }
                        }
                        foundStart = true
                    }
                    if prop.label == "end" {
                        let posMirror = Mirror(reflecting: prop.value)
                        for p in posMirror.children {
                            if p.label == "col", let v = p.value as? Int { endCol = v }
                            if p.label == "row", let v = p.value as? Int { endRow = v }
                        }
                        foundEnd = true
                    }
                }

                // Return coordinates only if we found both and they differ
                if foundStart && foundEnd && (startCol != endCol || startRow != endRow) {
                    return (Position(col: startCol, row: startRow), Position(col: endCol, row: endRow))
                }
                return nil
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

    /// Selects the current input line (the line where the cursor is).
    /// Used for Cmd+A to select just the current command being typed.
    func selectCurrentLine() {
        // Use selectAll as fallback since internal SwiftTerm APIs are not accessible
        selectAll(nil)
    }

    // MARK: - Paste

    override func paste(_ sender: Any) {
        // Use SwiftTerm's base implementation which handles bracketed paste mode
        super.paste(sender)
        Log.trace("Paste executed via SwiftTerm base class.")
    }

    // MARK: - Selection Helpers

    /// Clears the current selection.
    func clearSelection() {
        selectNone()
        Log.trace("Selection cleared via selectNone().")
    }

    /// Returns true if there is currently selected text.
    var hasSelection: Bool {
        if let text = getSelection(), !text.isEmpty {
            return true
        }
        return false
    }


    // MARK: - Data Flow Callbacks
    // Note: dataReceived is overridden below with local echo support

    private func patchDimSequences(_ incoming: [UInt8]) -> [UInt8] {
        let buffer: [UInt8] = dimPatchRemainderBytes + incoming
        dimPatchRemainderBytes = []

        var output: [UInt8] = []
        output.reserveCapacity(buffer.count)

        var i = 0
        while i < buffer.count {
            let remaining = buffer.count - i
            if remaining >= dimResetSequence.count,
               matches(sequence: dimResetSequence, in: buffer, at: i) {
                output.append(contentsOf: dimResetReplacement)
                i += dimResetSequence.count
                continue
            }
            if remaining >= dimSequence.count,
               matches(sequence: dimSequence, in: buffer, at: i) {
                output.append(contentsOf: dimReplacement)
                i += dimSequence.count
                continue
            }

            if buffer[i] == 0x1b, isPrefix(in: buffer, at: i, of: dimResetSequence) || isPrefix(in: buffer, at: i, of: dimSequence) {
                dimPatchRemainderBytes = Array(buffer[i...])
                break
            }

            output.append(buffer[i])
            i += 1
        }

        return output
    }

    private func matches(sequence: [UInt8], in buffer: [UInt8], at index: Int) -> Bool {
        guard index + sequence.count <= buffer.count else { return false }
        for offset in 0..<sequence.count {
            if buffer[index + offset] != sequence[offset] {
                return false
            }
        }
        return true
    }

    private func isPrefix(in buffer: [UInt8], at index: Int, of sequence: [UInt8]) -> Bool {
        let remaining = buffer.count - index
        guard remaining < sequence.count else { return false }
        for offset in 0..<remaining {
            if buffer[index + offset] != sequence[offset] {
                return false
            }
        }
        return true
    }

    // MARK: - Local Echo State
    // Track pending local echo to suppress PTY duplicates
    private var pendingLocalEcho: [UInt8] = []
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

        // LOCAL ECHO: Show printable characters IMMEDIATELY before PTY round-trip.
        // This is the key to matching Terminal.app's perceived latency.
        // The PTY will echo the same character back, which we'll suppress in dataReceived.
        //
        // IMPORTANT: Only do local echo when PTY has echo enabled.
        // Password prompts disable echo, so we check tcgetattr() to detect this.
        if isPtyEchoEnabled {
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

        // Suppress characters/sequences that we already local-echoed
        var filteredSlice = slice
        if !pendingLocalEcho.isEmpty || pendingLocalBackspaces > 0 {
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
                if !pendingLocalEcho.isEmpty && byte == pendingLocalEcho[0] {
                    // This byte matches our local echo - suppress it
                    pendingLocalEcho.removeFirst()
                    i += 1
                    continue
                }

                // Include this byte in output
                filtered.append(byte)
                i += 1
            }

            // Clear stale pending state (timeout protection)
            if pendingLocalEcho.count > 100 {
                pendingLocalEcho.removeAll()
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

        // Fast path: no escape sequences AND no pending partial sequence
        if dimPatchRemainderBytes.isEmpty && !filteredSlice.contains(0x1b) {
            super.dataReceived(slice: filteredSlice)
            return
        }

        // Slow path: needs patching
        let patched = patchDimSequences(Array(filteredSlice))
        super.dataReceived(slice: patched[...])
    }

    override func rangeChanged(source: TerminalView, startY: Int, endY: Int) {
        super.rangeChanged(source: source, startY: startY, endY: endY)
        onBufferChanged?()
        updateCursorLineHighlight()
    }

    override func scrolled(source: TerminalView, position: Double) {
        super.scrolled(source: source, position: position)
        onBufferChanged?()
        updateCursorLineHighlight()
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
