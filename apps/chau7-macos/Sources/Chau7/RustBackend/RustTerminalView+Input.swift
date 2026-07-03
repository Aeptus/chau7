import AppKit
import Chau7Core

// MARK: - Helpers

extension RustTerminalView {

    private func isReturnKey(_ keyCode: UInt16) -> Bool {
        KeyboardShortcuts.isReturnKeyCode(keyCode)
    }

    func firstResponderDebugName() -> String {
        guard let responder = window?.firstResponder else { return "nil" }
        return String(describing: type(of: responder))
    }

    // MARK: - Input Handling

    func shouldSuppressRawTextFallback(afterInputContextHandled handled: Bool) -> Bool {
        handled || markedTextStorage != nil
    }

    func makeInputEventSignature(_ event: NSEvent) -> String {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.characters ?? ""
        let charactersIgnoringModifiers = event.charactersIgnoringModifiers ?? ""
        return "\(event.timestamp)|\(event.keyCode)|\(characters)|\(charactersIgnoringModifiers)|\(flags.rawValue)"
    }

    func markGeneralKeyEventHandled(_ event: NSEvent) {
        let signature = makeInputEventSignature(event)
        lastMonitorHandledKeyEventSignature = signature
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            if lastMonitorHandledKeyEventSignature == signature {
                lastMonitorHandledKeyEventSignature = nil
            }
        }
    }

    func isEventHandledByGeneralMonitor(_ event: NSEvent) -> Bool {
        guard let signature = lastMonitorHandledKeyEventSignature else { return false }
        return signature == makeInputEventSignature(event)
    }

    override func keyDown(with event: NSEvent) {
        guard let rust = rustTerminal else {
            Log.trace("RustTerminalView[\(viewId)]: keyDown - No Rust terminal")
            return
        }
        if isEventHandledByGeneralMonitor(event) {
            Log.trace("RustTerminalView[\(viewId)]: keyDown - Skipping event already handled by general monitor")
            return
        }
        if EnvVars.isEnabled(EnvVars.inputDiagnostics) {
            let preview = (event.charactersIgnoringModifiers ?? "").prefix(6)
            Log.info(
                "RustTerminalView[\(viewId)]: keyDown firing keyCode=\(event.keyCode) chars='\(preview)' firstResponder=\(firstResponderDebugName())"
            )
        }
        // Command key combinations are handled by app commands (copy/paste/menus), not terminal input
        if event.modifierFlags.contains(.command) {
            return
        }
        hideTipOverlay()
        // Typing must not wait out an idle throttle — snap the loop back to
        // full rate before we push the byte to the PTY.
        snapToFastPolling()

        let keyCode = event.keyCode
        let modifiers = event.modifierFlags

        if EnvVars.isEnabled(EnvVars.inputDiagnostics), isReturnKey(keyCode) {
            Log.info(
                "RustTerminalView[\(viewId)]: keyDown Return hasFocus=\(hasFocus) " +
                    "firstResponder=\(firstResponderDebugName())"
            )
        }

        // Generate terminal escape sequence for this key event
        if let sequence = generateTerminalSequence(keyCode: keyCode, modifiers: modifiers, event: event) {
            let hexPreview = sequence.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            Log.trace("RustTerminalView[\(viewId)]: keyDown - Sending escape sequence: [\(hexPreview)] (keyCode=\(keyCode))")
            if EnvVars.isEnabled(EnvVars.inputDiagnostics), isReturnKey(keyCode) {
                Log.info(
                    "RustTerminalView[\(viewId)]: keyDown Return generated terminal sequence [\(hexPreview)] " +
                        "hasFocus=\(hasFocus)"
                )
            }
            _ = dispatchTerminalSequence(sequence, rust: rust, logContext: "keyDown")
            return
        }

        // Route regular text input through NSTextInputContext so that
        // Password AutoFill and IME can deliver text via insertText.
        _ = routeTextInputThroughInputContext(event, logContext: "keyDown", keyCode: keyCode)
    }

    /// Run the post-generation forwarding chain for a terminal escape
    /// sequence: command-guard check, backspace local-echo, `onInput`
    /// callback, then `rust.sendBytes`. Returns `true` when the sequence
    /// was forwarded, `false` when the command guard suppressed it. Both
    /// `keyDown` and `handleTerminalKeyEvent` route through here; the
    /// only per-caller difference is the `logContext` string used in the
    /// suppress log.
    private func dispatchTerminalSequence(
        _ sequence: [UInt8], rust: any TerminalBackend, logContext: String
    ) -> Bool {
        if let text = String(bytes: sequence, encoding: .utf8),
           !(shouldAcceptUserText?(text) ?? true) {
            Log.info("RustTerminalView[\(viewId)]: \(logContext) - Suppressed user input by command guard")
            return false
        }
        if let text = String(bytes: sequence, encoding: .utf8) {
            onInput?(text)
        }
        rust.sendBytes(sequence)
        return true
    }

    /// Handle key event from event monitor - routes to Rust terminal
    /// Returns true if the event was handled, false otherwise
    func handleTerminalKeyEvent(_ event: NSEvent) -> Bool {
        guard let rust = rustTerminal else {
            return false // No Rust terminal, let event propagate
        }
        hideTipOverlay()

        let keyCode = event.keyCode
        let modifiers = event.modifierFlags

        if EnvVars.isEnabled(EnvVars.inputDiagnostics), isReturnKey(keyCode) {
            Log.info(
                "RustTerminalView[\(viewId)]: handleTerminalKeyEvent Return hasFocus=\(hasFocus) " +
                    "firstResponder=\(firstResponderDebugName())"
            )
        }

        // Command key combinations are handled by the app menu, not terminal
        if modifiers.contains(.command) {
            return false
        }

        // Generate terminal escape sequence for this key event
        if let sequence = generateTerminalSequence(keyCode: keyCode, modifiers: modifiers, event: event) {
            let hexPreview = sequence.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            Log.trace("RustTerminalView[\(viewId)]: handleTerminalKeyEvent - Sending escape sequence: [\(hexPreview)] (keyCode=\(keyCode))")
            if EnvVars.isEnabled(EnvVars.inputDiagnostics), isReturnKey(keyCode) {
                Log.info(
                    "RustTerminalView[\(viewId)]: handleTerminalKeyEvent Return generated terminal sequence [\(hexPreview)] " +
                        "hasFocus=\(hasFocus)"
                )
            }
            _ = dispatchTerminalSequence(sequence, rust: rust, logContext: "handleTerminalKeyEvent")
            return true
        }

        return routeTextInputThroughInputContext(event, logContext: "handleTerminalKeyEvent", keyCode: keyCode)
    }

    func routeTextInputThroughInputContext(_ event: NSEvent, logContext: String, keyCode: UInt16) -> Bool {
        handlingKeyDown = true
        let inputContextHandled = inputContext?.handleEvent(event) ?? false
        handlingKeyDown = false

        if shouldSuppressRawTextFallback(afterInputContextHandled: inputContextHandled) {
            if !inputContextHandled, let markedTextStorage, !markedTextStorage.isEmpty {
                let escaped = markedTextStorage.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
                Log.trace(
                    "RustTerminalView[\(viewId)]: \(logContext) - Preserving marked text composition: '\(escaped)' (keyCode=\(keyCode))"
                )
            }
            return true
        }

        return sendFallbackTextInput(event, logContext: logContext, keyCode: keyCode)
    }

    func sendFallbackTextInput(_ event: NSEvent, logContext: String, keyCode: UInt16) -> Bool {
        if let chars = event.characters, !chars.isEmpty {
            let escaped = chars.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            Log.trace("RustTerminalView[\(viewId)]: \(logContext) - Sending characters (fallback): '\(escaped)' (keyCode=\(keyCode))")
            guard shouldAcceptUserText?(chars) ?? true else {
                Log.info("RustTerminalView[\(viewId)]: \(logContext) - Suppressed fallback characters by command guard")
                return true
            }
            send(txt: chars)
            return true
        }

        if let charsNoMod = event.charactersIgnoringModifiers, !charsNoMod.isEmpty {
            let escaped = charsNoMod.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
            Log.trace("RustTerminalView[\(viewId)]: \(logContext) - Sending chars (no mod, fallback): '\(escaped)' (keyCode=\(keyCode))")
            guard shouldAcceptUserText?(charsNoMod) ?? true else {
                Log.info("RustTerminalView[\(viewId)]: \(logContext) - Suppressed fallback chars (no mod) by command guard")
                return true
            }
            send(txt: charsNoMod)
            return true
        }

        Log.trace("RustTerminalView[\(viewId)]: \(logContext) - No characters to send (keyCode=\(keyCode))")
        return false
    }

    // MARK: - Terminal Escape Sequence Generation

    /// Generates the appropriate terminal escape sequence for a key event.
    /// Returns nil if the key should be handled via regular character input.
    func generateTerminalSequence(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, event: NSEvent) -> [UInt8]? {
        let hasControl = modifiers.contains(.control)
        let hasOption = modifiers.contains(.option)
        let hasShift = modifiers.contains(.shift)
        let hasCommand = modifiers.contains(.command)

        // Command key is typically handled by the app, not sent to terminal
        if hasCommand {
            return nil
        }

        // Check for special keys first (arrows, function keys, etc.)
        if let specialSequence = generateSpecialKeySequence(keyCode: keyCode, modifiers: modifiers) {
            return specialSequence
        }

        // Handle Ctrl+letter combinations
        if hasControl, let char = event.charactersIgnoringModifiers?.lowercased().first {
            if let controlCode = controlCharacter(for: char) {
                // Option+Ctrl sends ESC prefix + control code
                if hasOption {
                    return [0x1B, controlCode]
                }
                return [controlCode]
            }
        }

        if OptionModifiedTextRouting.shouldTreatAsLiteralText(
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            hasOption: hasOption,
            hasControl: hasControl,
            hasCommand: hasCommand
        ) {
            // Let NSTextInputContext deliver the rendered character for
            // international layouts that use Option to produce punctuation.
            return nil
        }

        // Handle Option/Alt+letter (sends ESC prefix for meta key)
        if hasOption, !hasControl {
            if let char = event.charactersIgnoringModifiers?.first {
                // Send ESC + character for Alt+key (meta key behavior)
                var bytes: [UInt8] = [0x1B]
                if hasShift {
                    // Shift+Alt sends uppercase
                    bytes.append(contentsOf: String(char).uppercased().utf8)
                } else {
                    bytes.append(contentsOf: String(char).utf8)
                }
                return bytes
            }
        }

        return nil
    }

    /// Translate AppKit modifier flags into the pure encoder's modifiers.
    private func terminalKeyModifiers(_ modifiers: NSEvent.ModifierFlags) -> TerminalKeyEncoder.Modifiers {
        var result: TerminalKeyEncoder.Modifiers = []
        if modifiers.contains(.shift) { result.insert(.shift) }
        if modifiers.contains(.option) { result.insert(.option) }
        if modifiers.contains(.control) { result.insert(.control) }
        return result
    }

    /// Generates escape sequences for special keys (arrows, function keys, etc.)
    /// Thin forwarder into the pure `TerminalKeyEncoder` in Chau7Core; the
    /// view contributes only its DECCKM (application cursor mode) state.
    func generateSpecialKeySequence(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> [UInt8]? {
        TerminalKeyEncoder.specialKeySequence(
            keyCode: keyCode,
            modifiers: terminalKeyModifiers(modifiers),
            applicationCursorMode: applicationCursorMode
        )
    }

    /// Converts a character to its control character equivalent (Ctrl+A = 0x01, etc.)
    func controlCharacter(for char: Character) -> UInt8? {
        TerminalKeyEncoder.controlCharacter(for: char)
    }

    /// Sets the application cursor mode (DECCKM).
    /// This is typically called when the terminal receives ESC[?1h (enable) or ESC[?1l (disable)
    func setApplicationCursorMode(_ enabled: Bool) {
        applicationCursorMode = enabled
        Log.trace("RustTerminalView[\(viewId)]: Application cursor mode \(enabled ? "enabled" : "disabled")")
    }

    /// Send raw bytes to the PTY
    func send(data bytes: [UInt8]) {
        let preview = bytes.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
        let suffix = bytes.count > 8 ? " ...<\(bytes.count - 8) more>" : ""
        Log.trace("RustTerminalView[\(viewId)]: send(data:) - Sending \(bytes.count) bytes: [\(preview)\(suffix)]")
        hideTipOverlay()
        // Smart scroll: Scroll to bottom on user input (standard terminal behavior)
        // When the user types, they expect to see the current prompt
        if rustTerminal?.displayOffset ?? 0 > 0 {
            rustTerminal?.scrollTo(position: 0.0)
            needsGridSync = true
        }

        rustTerminal?.sendBytes(bytes)
    }

    /// Send a normalized key press to the PTY using terminal-specific encoding.
    func send(keyPress: TerminalKeyPress) {
        do {
            let encoded = try keyPress.encode(applicationCursorMode: applicationCursorMode)
            let preview = encoded.bytes.prefix(8).map { String(format: "%02X", $0) }.joined(separator: " ")
            let suffix = encoded.bytes.count > 8 ? " ...<\(encoded.bytes.count - 8) more>" : ""
            Log.trace("RustTerminalView[\(viewId)]: send(keyPress:) - key=\(keyPress.key) modifiers=\(keyPress.sortedModifierNames.joined(separator: "+")) bytes=[\(preview)\(suffix)]")
            if EnvVars.isEnabled(EnvVars.inputDiagnostics),
               encoded.bytes.contains(0x0D) || encoded.bytes.contains(0x0A) {
                Log.info(
                    "RustTerminalView[\(viewId)]: send(keyPress:) newline-ish bytes=[\(preview)\(suffix)] " +
                        "key=\(keyPress.key)"
                )
            }
            hideTipOverlay()

            if rustTerminal?.displayOffset ?? 0 > 0 {
                rustTerminal?.scrollTo(position: 0.0)
                needsGridSync = true
            }

            if let text = encoded.text ?? String(bytes: encoded.bytes, encoding: .utf8) {
                onInput?(text)
            }

            rustTerminal?.sendBytes(encoded.bytes)
        } catch {
            Log.warn("RustTerminalView[\(viewId)]: send(keyPress:) failed: \(error.localizedDescription)")
        }
    }

    /// Send text to the PTY
    func send(txt text: String) {
        Log.trace("RustTerminalView[\(viewId)]: send(txt:) - Sending \(text.count) chars")
        if EnvVars.isEnabled(EnvVars.inputDiagnostics),
           text.contains("\r") || text.contains("\n") {
            let escaped = text
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\n", with: "\\n")
            Log.info(
                "RustTerminalView[\(viewId)]: send(txt:) newline-ish text='\(escaped.prefix(120))' chars=\(text.count)"
            )
        }
        hideTipOverlay()

        // Smart scroll: Scroll to bottom on user input (standard terminal behavior)
        // When the user types, they expect to see the current prompt
        if rustTerminal?.displayOffset ?? 0 > 0 {
            rustTerminal?.scrollTo(position: 0.0)
            needsGridSync = true
        }

        onInput?(text)
        rustTerminal?.sendText(text)
    }

    /// Inject output directly into the terminal (no PTY write).
    /// Used for UI-only content like the power user tip header.
    func injectOutput(_ text: String) {
        guard let rustTerminal else {
            Log.warn("RustTerminalView[\(viewId)]: injectOutput - No Rust terminal")
            return
        }
        let data = Data(text.utf8)
        guard !data.isEmpty else { return }
        Log.trace("RustTerminalView[\(viewId)]: injectOutput - Injecting \(data.count) bytes")
        rustTerminal.injectOutput(data)
        needsGridSync = true
    }

}

// MARK: - Snippet Navigation State (Internal)

/// Internal state for snippet placeholder navigation in RustTerminalView
struct RustSnippetNavigationState {
    var placeholders: [RustSnippetPlaceholder]
    var currentIndex: Int
    var cursorOffset: Int
    var finalCursorOffset: Int
}

/// Internal placeholder representation
struct RustSnippetPlaceholder {
    let index: Int
    let start: Int
    let length: Int
}

// MARK: - NSTextInputClient

extension RustTerminalView: NSTextInputClient {

    func insertText(_ string: Any, replacementRange: NSRange) {
        // Clear marked text — composition is now committed
        markedTextStorage = nil
        markedSelectedRange = NSRange(location: NSNotFound, length: 0)
        // IME commit = real input; escape any idle throttle.
        snapToFastPolling()

        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            return
        }
        guard !text.isEmpty else { return }

        if handlingKeyDown {
            // Regular keyboard input routed through inputContext — send directly
            guard shouldAcceptUserText?(text) ?? true else {
                Log.info("RustTerminalView[\(viewId)]: insertText - Suppressed keyboard input by command guard")
                return
            }
            Log.trace("RustTerminalView[\(viewId)]: insertText (keyboard) — \(text.count) chars")
            send(txt: text)
        } else {
            // External injection (Password AutoFill, Services, programmatic)
            Log.info("RustTerminalView[\(viewId)]: insertText (external, e.g. Password AutoFill) — \(text.count) chars")
            pasteText(text)
        }
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let text: String
        if let s = string as? String {
            text = s
        } else if let attr = string as? NSAttributedString {
            text = attr.string
        } else {
            text = ""
        }
        if text.isEmpty {
            markedTextStorage = nil
            markedSelectedRange = NSRange(location: NSNotFound, length: 0)
        } else {
            markedTextStorage = text
            markedSelectedRange = selectedRange
        }
    }

    func unmarkText() {
        markedTextStorage = nil
        markedSelectedRange = NSRange(location: NSNotFound, length: 0)
    }

    func selectedRange() -> NSRange {
        return NSRange(location: NSNotFound, length: 0)
    }

    func markedRange() -> NSRange {
        guard let marked = markedTextStorage else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return NSRange(location: 0, length: marked.utf16.count)
    }

    func hasMarkedText() -> Bool {
        return markedTextStorage != nil
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        return nil
    }

    func validAttributedString(for proposedString: NSAttributedString, selectedRange: NSRange) -> NSAttributedString? {
        return proposedString
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        // Return the cursor position so popups (e.g. IME candidate window) appear nearby.
        // caretFrame is in view-local coordinates — must convert to window coords first.
        let viewFrame = caretFrame
        guard let window = window else { return .zero }
        let windowFrame = convert(viewFrame, to: nil)
        return window.convertToScreen(windowFrame)
    }

    func characterIndex(for point: NSPoint) -> Int {
        return NSNotFound
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }
}
