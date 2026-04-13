import AppKit
import Carbon
import Chau7Core

// MARK: - Local Echo (Latency Optimization)

extension RustTerminalView {

    private func isReturnKey(_ keyCode: UInt16) -> Bool {
        keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter)
    }

    private func firstResponderDebugName() -> String {
        guard let responder = window?.firstResponder else { return "nil" }
        return String(describing: type(of: responder))
    }

    // MARK: - Local Echo (Latency Optimization)

    /// Process PTY output to suppress characters we already locally echoed
    /// Returns the filtered data with echoed characters removed
    func processOutputForLocalEcho(_ data: Data) -> Data {
        // Fast path: no pending echo, return as-is
        guard !pendingLocalEcho.isEmpty || pendingLocalBackspaces > 0 else {
            // Check for echo-disabling patterns in output (password prompts, etc.)
            detectEchoMode(in: data)
            return data
        }

        var filtered: [UInt8] = []
        filtered.reserveCapacity(data.count)

        var i = data.startIndex
        while i < data.endIndex {
            let byte = data[i]

            // Check for PTY backspace/delete confirmations (e.g. DEL, BS, or BS space BS)
            if pendingLocalBackspaces > 0 {
                let remaining = data.endIndex - i
                if byte == 0x08 && remaining >= 3 && data[i + 1] == 0x20 &&
                    (data[i + 2] == 0x08 || data[i + 2] == 0x7F) {
                    // Suppress backspace sequence we already displayed: "\b \b" or "\b \x7f"
                    pendingLocalBackspaces -= 1
                    removeLastPendingLocalEchoChar()
                    i += 3
                    continue
                }

                if byte == 0x08 || byte == 0x7F {
                    // Suppress single-byte backspace/delete echo
                    pendingLocalBackspaces -= 1
                    removeLastPendingLocalEchoChar()
                    i += 1
                    continue
                }
            }

            // Check for local echo character match
            if pendingLocalEchoOffset < pendingLocalEcho.count, byte == pendingLocalEcho[pendingLocalEchoOffset] {
                // This byte matches our local echo queue - suppress it
                pendingLocalEchoOffset += 1
                i += 1
                continue
            }

            // Include this byte in output
            filtered.append(byte)
            i += 1
        }

        compactConsumedLocalEchoIfNeeded()

        // Clear stale pending state (timeout protection)
        // If we have too much pending prediction state, something is out of sync
        if (pendingLocalEcho.count - pendingLocalEchoOffset) > Self.maxPendingLocalEcho || pendingLocalBackspaces > Self.maxPendingLocalEcho {
            Log.trace("RustTerminalView[\(viewId)]: Local echo buffer overflow, clearing")
            clearLocalEchoState()
            clearLocalEchoOverlay()
        }

        // Check for echo-disabling patterns in the filtered output
        detectEchoMode(in: Data(filtered))

        if pendingLocalEcho.isEmpty, pendingLocalBackspaces == 0 {
            clearLocalEchoOverlay()
        }

        if filtered.isEmpty {
            // All bytes were suppressed
            return Data()
        }

        return Data(filtered)
    }

    /// Detect patterns that indicate echo should be disabled (password prompts, raw mode)
    func detectEchoMode(in data: Data) {
        // Check for timeout recovery: re-enable echo after timeout
        let now = CFAbsoluteTimeGetCurrent()
        if !isPtyEchoLikelyEnabled, now - echoDisabledTime > Self.echoDisabledTimeout {
            isPtyEchoLikelyEnabled = true
            Log.trace("RustTerminalView[\(viewId)]: Echo re-enabled after timeout")
        }

        // Look for common password prompt patterns that indicate echo is off
        // These heuristics work since we can't query termios directly
        guard let text = String(data: data, encoding: .utf8) else { return }

        let lowercased = text.lowercased()

        // Password prompt patterns (echo disabled)
        let passwordPatterns = [
            "password:",
            "password for",
            "passphrase:",
            "passphrase for",
            "enter passphrase",
            "sudo password",
            "pin:",
            "secret:",
            "[sudo]"
        ]

        for pattern in passwordPatterns {
            if lowercased.contains(pattern) {
                isPtyEchoLikelyEnabled = false
                echoDisabledTime = now
                clearLocalEchoState()
                clearLocalEchoOverlay()
                Log.trace("RustTerminalView[\(viewId)]: Echo disabled (detected password prompt)")
                return
            }
        }

        // If we see a shell prompt ($ # %) after being disabled, re-enable echo
        // This indicates we're back at a normal prompt
        if !isPtyEchoLikelyEnabled {
            let promptPatterns = ["$ ", "# ", "% ", "> "]
            for pattern in promptPatterns {
                if text.hasSuffix(pattern) || text.contains(pattern + "\n") {
                    isPtyEchoLikelyEnabled = true
                    Log.trace("RustTerminalView[\(viewId)]: Echo re-enabled (detected shell prompt)")
                    return
                }
            }
        }
    }

    /// Apply local echo for user input (display immediately before PTY round-trip)
    /// This reduces perceived latency by showing typed characters instantly
    func applyLocalEcho(for bytes: [UInt8]) {
        // Check if local echo is enabled in settings
        guard supportsLocalEcho else { return }
        guard FeatureSettings.shared.isLocalEchoEnabled else {
            if !pendingLocalEcho.isEmpty || pendingLocalEchoOffset > 0 || pendingLocalBackspaces > 0 {
                clearLocalEchoState()
                clearLocalEchoOverlay()
            }
            return
        }

        // Check if PTY echo is likely enabled (not in password mode, etc.)
        guard isPtyEchoLikelyEnabled else {
            if !pendingLocalEcho.isEmpty || pendingLocalEchoOffset > 0 || pendingLocalBackspaces > 0 {
                clearLocalEchoState()
                clearLocalEchoOverlay()
            }
            return
        }

        let token = FeatureProfiler.shared.begin(.localEcho, bytes: bytes.count)
        defer { FeatureProfiler.shared.end(token) }

        if cols <= 0 || rows <= 0 { return }
        var cursor = localEchoCursor ?? {
            if let rust = rustTerminal {
                return (row: Int(rust.cursorPosition.row), col: Int(rust.cursorPosition.col))
            }
            return (row: 0, col: 0)
        }()
        cursor.row = max(0, min(rows - 1, cursor.row))
        cursor.col = max(0, min(cols - 1, cursor.col))

        for byte in bytes {
            // Only local echo printable ASCII (0x20-0x7E)
            if byte >= 0x20 && byte <= 0x7E {
                pendingLocalEcho.append(byte)
                let idx = cursor.row * cols + cursor.col
                var cell = baseCellForLocalEcho(row: cursor.row, col: cursor.col)
                cell.character = UInt32(byte)
                localEchoOverlay[idx] = cell
                advanceLocalEchoCursor(&cursor)
            } else if byte == 0x7F || byte == 0x08 {
                // Backspace/Delete: Undo the last local echo visually
                // Track the backspace so we suppress PTY's backspace response too
                pendingLocalBackspaces += 1
                retreatLocalEchoCursor(&cursor)
                let idx = cursor.row * cols + cursor.col
                localEchoOverlay.removeValue(forKey: idx)
                removeLastPendingLocalEchoChar()
                if !pendingLocalEcho.isEmpty, pendingLocalEchoOffset > pendingLocalEcho.count {
                    pendingLocalEchoOffset = pendingLocalEcho.count
                }
            } else if byte == 0x03 || byte == 0x15 {
                // Ctrl+C (0x03) or Ctrl+U (0x15): Clear local echo buffer
                // These typically abort/clear the current line
                clearLocalEchoState()
                clearLocalEchoOverlay()
                localEchoCursor = nil
                return
            } else if byte == 0x0A || byte == 0x0D {
                clearLocalEchoOverlay()
                clearLocalEchoState()
                localEchoCursor = nil
                return
            }
        }

        compactConsumedLocalEchoIfNeeded()

        localEchoCursor = cursor
        updateLocalEchoOverlay()
    }

    /// Apply local echo for text input
    func applyLocalEchoForText(_ text: String) {
        let bytes = Array(text.utf8)
        applyLocalEcho(for: bytes)
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
        // Command key combinations are handled by app commands (copy/paste/menus), not terminal input
        if event.modifierFlags.contains(.command) {
            return
        }
        hideTipOverlay()

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
            if let text = String(bytes: sequence, encoding: .utf8),
               !(shouldAcceptUserText?(text) ?? true) {
                Log.info("RustTerminalView[\(viewId)]: keyDown - Suppressed user input by command guard")
                return
            }
            if sequence == [0x7F] || sequence == [0x08], let text = String(bytes: sequence, encoding: .utf8) {
                applyLocalEchoForText(text)
            }
            if let text = String(bytes: sequence, encoding: .utf8) {
                onInput?(text)
            }
            rust.sendBytes(sequence)
            return
        }

        // Route regular text input through NSTextInputContext so that
        // Password AutoFill and IME can deliver text via insertText.
        _ = routeTextInputThroughInputContext(event, logContext: "keyDown", keyCode: keyCode)
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
            if let text = String(bytes: sequence, encoding: .utf8),
               !(shouldAcceptUserText?(text) ?? true) {
                Log.info("RustTerminalView[\(viewId)]: handleTerminalKeyEvent - Suppressed user input by command guard")
                return true
            }
            if sequence == [0x7F] || sequence == [0x08], let text = String(bytes: sequence, encoding: .utf8) {
                applyLocalEchoForText(text)
            }
            if let text = String(bytes: sequence, encoding: .utf8) {
                onInput?(text)
            }
            rust.sendBytes(sequence)
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
            applyLocalEchoForText(chars)
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
            applyLocalEchoForText(charsNoMod)
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

    /// Generates escape sequences for special keys (arrows, function keys, etc.)
    func generateSpecialKeySequence(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> [UInt8]? {
        let hasControl = modifiers.contains(.control)
        let hasOption = modifiers.contains(.option)
        let hasShift = modifiers.contains(.shift)

        // Calculate xterm modifier parameter
        // 1 = none, 2 = shift, 3 = alt, 4 = shift+alt, 5 = ctrl, 6 = shift+ctrl, 7 = alt+ctrl, 8 = shift+alt+ctrl
        var modParam = 1
        if hasShift { modParam += 1 }
        if hasOption { modParam += 2 }
        if hasControl { modParam += 4 }
        let hasModifiers = modParam > 1

        switch Int(keyCode) {
        // Arrow keys
        case kVK_UpArrow:
            return arrowKeySequence("A", modParam: modParam, hasModifiers: hasModifiers)
        case kVK_DownArrow:
            return arrowKeySequence("B", modParam: modParam, hasModifiers: hasModifiers)
        case kVK_RightArrow:
            return arrowKeySequence("C", modParam: modParam, hasModifiers: hasModifiers)
        case kVK_LeftArrow:
            return arrowKeySequence("D", modParam: modParam, hasModifiers: hasModifiers)
        // Navigation keys
        case kVK_Home:
            return hasModifiers ? csiSequenceWithMod("1", modParam: modParam, terminator: "H") : csiSequence("H")
        case kVK_End:
            return hasModifiers ? csiSequenceWithMod("1", modParam: modParam, terminator: "F") : csiSequence("F")
        case kVK_PageUp:
            return hasModifiers ? csiSequenceWithMod("5", modParam: modParam, terminator: "~") : csiSequence("5~")
        case kVK_PageDown:
            return hasModifiers ? csiSequenceWithMod("6", modParam: modParam, terminator: "~") : csiSequence("6~")
        // Editing keys
        case kVK_ForwardDelete:
            return hasModifiers ? csiSequenceWithMod("3", modParam: modParam, terminator: "~") : csiSequence("3~")
        case kVK_Help: // Insert key on some keyboards
            return hasModifiers ? csiSequenceWithMod("2", modParam: modParam, terminator: "~") : csiSequence("2~")
        // Function keys F1-F12
        case kVK_F1:
            return functionKeySequence(1, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F2:
            return functionKeySequence(2, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F3:
            return functionKeySequence(3, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F4:
            return functionKeySequence(4, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F5:
            return functionKeySequence(5, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F6:
            return functionKeySequence(6, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F7:
            return functionKeySequence(7, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F8:
            return functionKeySequence(8, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F9:
            return functionKeySequence(9, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F10:
            return functionKeySequence(10, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F11:
            return functionKeySequence(11, modParam: modParam, hasModifiers: hasModifiers)
        case kVK_F12:
            return functionKeySequence(12, modParam: modParam, hasModifiers: hasModifiers)
        // Special character keys
        case kVK_Escape:
            return [0x1B]
        case kVK_Tab:
            if hasShift {
                return csiSequence("Z") // Shift+Tab sends CSI Z (backtab)
            }
            return [0x09] // Regular tab
        case kVK_Return:
            return [0x0D] // Carriage return
        case kVK_Delete: // Backspace key
            if hasControl {
                return [0x08] // Ctrl+Backspace sends BS
            }
            return [0x7F] // Regular backspace sends DEL
        default:
            return nil
        }
    }

    /// Generates arrow key sequences, respecting application cursor mode (DECCKM)
    func arrowKeySequence(_ direction: Character, modParam: Int, hasModifiers: Bool) -> [UInt8] {
        if hasModifiers {
            // With modifiers: ESC [ 1 ; <mod> <direction>
            return Array("\u{1b}[1;\(modParam)\(direction)".utf8)
        } else if applicationCursorMode {
            // Application cursor mode: ESC O <direction> (SS3 sequence)
            return Array("\u{1b}O\(direction)".utf8)
        } else {
            // Normal mode: ESC [ <direction>
            return Array("\u{1b}[\(direction)".utf8)
        }
    }

    /// Generates a simple CSI sequence: ESC [ <content>
    func csiSequence(_ content: String) -> [UInt8] {
        return Array("\u{1b}[\(content)".utf8)
    }

    /// Generates a CSI sequence with modifier: ESC [ <prefix> ; <mod> <terminator>
    func csiSequenceWithMod(_ prefix: String, modParam: Int, terminator: String) -> [UInt8] {
        return Array("\u{1b}[\(prefix);\(modParam)\(terminator)".utf8)
    }

    /// Generates function key sequences (xterm-style)
    func functionKeySequence(_ fKey: Int, modParam: Int, hasModifiers: Bool) -> [UInt8] {
        // F1-F4 use SS3 sequences without modifiers (legacy vt100 compatibility)
        // F1-F4 with modifiers and F5-F12 use CSI sequences with numeric codes
        //
        // Without modifiers:
        //   F1: ESC O P, F2: ESC O Q, F3: ESC O R, F4: ESC O S
        //   F5: ESC [15~, F6: ESC [17~, F7: ESC [18~, F8: ESC [19~
        //   F9: ESC [20~, F10: ESC [21~, F11: ESC [23~, F12: ESC [24~
        //
        // With modifiers:
        //   F1: ESC [11;Pm~, etc.

        if !hasModifiers, fKey <= 4 {
            // F1-F4 without modifiers use SS3 sequences
            let codes: [Character] = ["P", "Q", "R", "S"]
            return Array("\u{1b}O\(codes[fKey - 1])".utf8)
        }

        // F5+ and F1-F4 with modifiers use CSI ~ sequences
        // Map function key number to xterm numeric code
        let xtermKeyCode: Int
        switch fKey {
        case 1: xtermKeyCode = 11
        case 2: xtermKeyCode = 12
        case 3: xtermKeyCode = 13
        case 4: xtermKeyCode = 14
        case 5: xtermKeyCode = 15
        case 6: xtermKeyCode = 17 // Note: 16 is skipped
        case 7: xtermKeyCode = 18
        case 8: xtermKeyCode = 19
        case 9: xtermKeyCode = 20
        case 10: xtermKeyCode = 21
        case 11: xtermKeyCode = 23 // Note: 22 is skipped
        case 12: xtermKeyCode = 24
        default: xtermKeyCode = 15 + fKey
        }

        if hasModifiers {
            return Array("\u{1b}[\(xtermKeyCode);\(modParam)~".utf8)
        } else {
            return Array("\u{1b}[\(xtermKeyCode)~".utf8)
        }
    }

    /// Converts a character to its control character equivalent (Ctrl+A = 0x01, etc.)
    func controlCharacter(for char: Character) -> UInt8? {
        guard let ascii = char.asciiValue else { return nil }

        // Control characters are lowercase letter's ASCII value minus 0x60
        // Or uppercase letter's ASCII value minus 0x40
        // a-z: 0x61-0x7A -> Ctrl codes 0x01-0x1A
        // A-Z: 0x41-0x5A -> Ctrl codes 0x01-0x1A (same result)
        if ascii >= 0x61, ascii <= 0x7A {
            return ascii - 0x60
        }
        if ascii >= 0x41, ascii <= 0x5A {
            return ascii - 0x40
        }

        // Special control characters
        switch char {
        case "[", "{":
            return 0x1B // Ctrl+[ is ESC
        case "\\":
            return 0x1C // Ctrl+\ is FS
        case "]", "}":
            return 0x1D // Ctrl+] is GS
        case "^", "~":
            return 0x1E // Ctrl+^ is RS
        case "_", "?":
            return 0x1F // Ctrl+_ is US
        case "@", " ":
            return 0x00 // Ctrl+@ or Ctrl+Space is NUL
        case "2":
            return 0x00 // Ctrl+2 is NUL
        case "3":
            return 0x1B // Ctrl+3 is ESC
        case "4":
            return 0x1C // Ctrl+4 is FS
        case "5":
            return 0x1D // Ctrl+5 is GS
        case "6":
            return 0x1E // Ctrl+6 is RS
        case "7":
            return 0x1F // Ctrl+7 is US
        case "8":
            return 0x7F // Ctrl+8 is DEL
        default:
            return nil
        }
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
               (encoded.bytes.contains(0x0D) || encoded.bytes.contains(0x0A)) {
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

            if encoded.bytes == [0x7F] || encoded.bytes == [0x08],
               let text = String(bytes: encoded.bytes, encoding: .utf8) {
                applyLocalEchoForText(text)
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
           (text.contains("\r") || text.contains("\n")) {
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

        rustTerminal?.sendText(text)
        onInput?(text)
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
            applyLocalEchoForText(text)
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
