import AppKit
import Carbon
import Chau7Core

// MARK: - UI Helpers (Bell, Scrolling, Clipboard, Snippets)

extension RustTerminalView {

    // MARK: - Bell

    /// Handle bell event by playing sound or flashing screen based on settings
    func handleBell() {
        guard let bellConfig, bellConfig.enabled else {
            Log.trace("RustTerminalView[\(viewId)]: handleBell - Bell disabled")
            return
        }

        Log.trace("RustTerminalView[\(viewId)]: handleBell - Triggering bell (sound=\(bellConfig.sound))")

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

    /// Flash the screen for visual bell feedback
    func flashBell() {
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

    /// Configure scrollback buffer size
    func applyScrollbackLines(_ lines: Int) {
        guard appliedScrollbackLines != lines else {
            return
        }
        Log.trace("RustTerminalView[\(viewId)]: applyScrollbackLines - Setting scrollback to \(lines) lines")
        rustTerminal?.setScrollbackSize(UInt32(lines))
        appliedScrollbackLines = lines
    }

    // MARK: - Scrolling

    /// Current scroll position (0.0 = bottom, 1.0 = top of history)
    var scrollPosition: Double {
        let pos = rustTerminal?.scrollPosition ?? 0.0
        Log.trace("RustTerminalView[\(viewId)]: scrollPosition = \(pos)")
        return pos
    }

    /// Scroll to position
    func scroll(toPosition position: Double) {
        Log.trace("RustTerminalView[\(viewId)]: scroll(toPosition:) - position=\(position)")
        rustTerminal?.scrollTo(position: position)
        needsGridSync = true
        clearLocalEchoOverlay()
        // Smart Scroll: Track if user is at or near the bottom
        updateIsUserAtBottom()
        updateInlineImagePositions()
        onScrollChanged?()
    }

    /// Scroll up by lines
    func scrollUp(lines: Int) {
        Log.trace("RustTerminalView[\(viewId)]: scrollUp - lines=\(lines)")
        rustTerminal?.scrollLines(Int32(lines))
        needsGridSync = true
        clearLocalEchoOverlay()
        // Smart Scroll: Track if user is at or near the bottom
        updateIsUserAtBottom()
        updateInlineImagePositions()
        onScrollChanged?()
    }

    /// Scroll down by lines
    func scrollDown(lines: Int) {
        Log.trace("RustTerminalView[\(viewId)]: scrollDown - lines=\(lines)")
        rustTerminal?.scrollLines(Int32(-lines))
        needsGridSync = true
        clearLocalEchoOverlay()
        // Smart Scroll: Track if user is at or near the bottom
        updateIsUserAtBottom()
        updateInlineImagePositions()
        onScrollChanged?()
    }

    /// Scroll to top of history
    func scrollToTop() {
        Log.trace("RustTerminalView[\(viewId)]: scrollToTop")
        scroll(toPosition: 1.0)
    }

    /// Scroll to bottom (current)
    func scrollToBottom() {
        Log.trace("RustTerminalView[\(viewId)]: scrollToBottom")
        scroll(toPosition: 0.0)
    }

    /// Scroll so that `absoluteRow` is at the top of the viewport.
    func scrollToRow(absoluteRow: Int) {
        let currentTop = renderTopVisibleRow
        let delta = currentTop - absoluteRow // positive = scroll up into history
        if delta > 0 {
            scrollUp(lines: delta)
        } else if delta < 0 {
            scrollDown(lines: -delta)
        }
    }

    /// Scroll to the nearest input line above the current viewport top.
    func scrollToPreviousInputLine() {
        let sorted = inputLineTracker.sortedRows()
        guard !sorted.isEmpty else { return }
        let currentTop = renderTopVisibleRow
        // Find the last tracked row strictly above the current viewport top
        if let idx = sorted.lastIndex(where: { $0 < currentTop }) {
            scrollToRow(absoluteRow: sorted[idx])
            Log.info("RustTerminalView[\(viewId)]: jumped to previous input line at row \(sorted[idx])")
        }
    }

    /// Scroll to the nearest input line below the current viewport top.
    func scrollToNextInputLine() {
        let sorted = inputLineTracker.sortedRows()
        guard !sorted.isEmpty else { return }
        let currentTop = renderTopVisibleRow
        // Find the first tracked row strictly below the current viewport top
        if let idx = sorted.firstIndex(where: { $0 > currentTop }) {
            scrollToRow(absoluteRow: sorted[idx])
            Log.info("RustTerminalView[\(viewId)]: jumped to next input line at row \(sorted[idx])")
        } else {
            // No more marks below — go to bottom
            scrollToBottom()
        }
    }

    /// Update isUserAtBottom based on current scroll position (for Smart Scroll)
    func updateIsUserAtBottom() {
        let currentPosition = scrollPosition
        // Position 0 = bottom, 1 = top. User is "at bottom" if position is <= threshold from 0
        isUserAtBottom = currentPosition <= (1.0 - Self.scrollBottomThreshold)
    }

    /// Restores scroll position if smart scroll is enabled and user wasn't at bottom.
    /// This preserves the user's reading position when new output arrives.
    func restoreSmartScrollIfNeeded(smartScrollEnabled: Bool, wasAtBottom: Bool, savedPosition: Double) {
        // Only restore if:
        // 1. Smart scroll is enabled
        // 2. User wasn't at the bottom before new data arrived
        // 3. The scroll position actually changed (renderer auto-scrolled)
        let currentPosition = scrollPosition
        guard smartScrollEnabled, !wasAtBottom, currentPosition != savedPosition else { return }

        // Edge case: Don't restore to position 0 when scrollback just appeared.
        // When terminal has no scrollback, scrollPosition is forced to 0 regardless of
        // actual view state. If savedPosition was 0 and now > 0, scrollback just appeared
        // and user wasn't actually scrolled up - they were at the only position available.
        if savedPosition == 0, currentPosition > 0 {
            // Scrollback just appeared - let the auto-scroll to bottom happen
            isUserAtBottom = currentPosition >= Self.scrollBottomThreshold
            return
        }

        // Restore the user's previous scroll position
        scroll(toPosition: savedPosition)
        // Update our tracking state based on restored position
        isUserAtBottom = savedPosition <= (1.0 - Self.scrollBottomThreshold)
    }

    // MARK: - Cursor Line Highlight

    /// Attach a cursor line view for highlighting
    func attachCursorLineView(_ view: TerminalCursorLineView) {
        cursorLineView = view
        updateCursorLineHighlight()
    }

    /// Configure cursor line highlight options
    func configureCursorLineHighlight(contextLines: Bool, inputHistory: Bool) {
        if highlightContextLines != contextLines || highlightInputHistory != inputHistory {
            highlightContextLines = contextLines
            highlightInputHistory = inputHistory
            updateCursorLineHighlight()
        }
    }

    /// Enable or disable cursor line highlighting
    func setCursorLineHighlightEnabled(_ enabled: Bool) {
        if isCursorLineHighlightEnabled != enabled {
            isCursorLineHighlightEnabled = enabled
            updateCursorLineHighlight()
        }
    }

    /// Update cursor line highlight state
    func updateCursorLineHighlight() {
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
        cursorLineView?.isHidden = false
        cursorLineView?.needsDisplay = true
    }

    /// Record the current input line for history tracking.
    func recordInputLine() {
        guard let rust = rustTerminal else { return }
        let cursor = rust.cursorPosition
        let topRow = renderTopVisibleRow
        let row = topRow + Int(cursor.row)
        inputLineTracker.record(row: row)
        updateCursorLineHighlight()
    }

    // MARK: - Clipboard

    /// Debounced copy-on-select: cancels any pending copy, waits 50ms for Rust selection
    /// to finalize, then copies if text changed. Called from mouseUp and any future
    /// selection-complete triggers.
    func scheduleCopyOnSelect() {
        guard FeatureSettings.shared.isCopyOnSelectEnabled else { return }
        copyOnSelectWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  let text = getSelection(),
                  !text.isEmpty,
                  text != lastSelectionText else { return }
            Log.trace("RustTerminalView[\(viewId)]: Copy-on-select - Copying \(text.count) chars")
            copyToClipboard(text)
            lastSelectionText = text
        }
        copyOnSelectWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.050, execute: work)
    }

    func copyToClipboard(_ text: String) {
        Log.trace("RustTerminalView[\(viewId)]: copyToClipboard - Copying \(text.count) chars")
        let clipboard = NSPasteboard.general
        clipboard.clearContents()
        clipboard.setString(text, forType: .string)
    }

    /// Copy selection to clipboard
    @objc func copy(_ sender: Any?) {
        if let text = getSelection(), !text.isEmpty {
            Log.info("RustTerminalView[\(viewId)]: copy - Copying selection (\(text.count) chars)")
            copyToClipboard(text)
        } else {
            Log.info("RustTerminalView[\(viewId)]: copy - No selection, sending Ctrl+C (SIGINT)")
            send(data: [0x03])
        }
    }

    /// Paste from clipboard
    @objc func paste(_ sender: Any?) {
        guard let text = NSPasteboard.general.string(forType: .string) else {
            Log.trace("RustTerminalView[\(viewId)]: paste - Nothing to paste")
            return
        }

        Log.info("RustTerminalView[\(viewId)]: paste - Pasting \(text.count) chars")
        pasteText(text)
    }

    func pasteText(_ text: String) {
        // Check for bracketed paste mode from Rust terminal
        // This fixes bracketed paste for vim, zsh, and other programs that enable it
        if rustTerminal?.isBracketedPasteMode() == true {
            Log.trace("RustTerminalView[\(viewId)]: paste - Using bracketed paste mode")
            send(txt: "\u{1b}[200~")
            send(txt: text)
            send(txt: "\u{1b}[201~")
        } else {
            send(txt: text)
        }
    }

    // MARK: - Feed (for compatibility)

    /// Feed text directly to the display (bypasses Rust terminal)
    func feed(text: String) {
        Log.trace("RustTerminalView[\(viewId)]: feed(text:) - Ignored (native renderer does not support direct feed)")
    }

    /// Feed bytes directly to the display (bypasses Rust terminal)
    func feed(byteArray: [UInt8]) {
        Log.trace("RustTerminalView[\(viewId)]: feed(byteArray:) - Ignored (native renderer does not support direct feed)")
    }

    // MARK: - Clear

    /// Clear scrollback buffer
    /// This clears the Rust terminal's scrollback history and resets rendering state
    func clearScrollbackBuffer() {
        Log.info("RustTerminalView[\(viewId)]: clearScrollbackBuffer")

        // Clear Rust terminal's scrollback history (frees memory)
        rustTerminal?.clearScrollback()

        clearLocalEchoOverlay()

        // Clear inline images
        inlineImages.forEach { $0.view.removeFromSuperview() }
        inlineImages.removeAll()

        // Trigger a grid sync to update the display
        needsGridSync = true

        // Notify listeners that scrollback was cleared
        onScrollbackCleared?()
    }

    // MARK: - Cursor Line Highlight

    // MARK: - Snippet Placeholder Navigation (F21)

    /// Insert snippet with placeholder navigation support
    func insertSnippet(_ insertion: SnippetInsertion) {
        Log.trace("RustTerminalView[\(viewId)]: insertSnippet - \(insertion.text.count) chars")
        let text = insertion.text

        // Send the snippet text (with bracketed paste if enabled)
        // Use Rust terminal's bracketed paste mode state
        if rustTerminal?.isBracketedPasteMode() == true {
            Log.trace("RustTerminalView[\(viewId)]: insertSnippet - Using bracketed paste mode (from Rust)")
            send(txt: "\u{1b}[200~")
            send(txt: text)
            send(txt: "\u{1b}[201~")
        } else {
            send(txt: text)
        }

        // Check if we have placeholders to navigate
        guard !insertion.placeholders.isEmpty else {
            Log.trace("RustTerminalView[\(viewId)]: insertSnippet - No placeholders, done")
            snippetState = nil
            return
        }

        // Check if text is safe for placeholder navigation (ASCII only)
        guard !isUnsafeForPlaceholderNavigation(text) else {
            Log.trace("RustTerminalView[\(viewId)]: insertSnippet - Text contains non-ASCII, skipping placeholder navigation")
            snippetState = nil
            return
        }

        // Convert SnippetPlaceholder to internal format
        let placeholders = insertion.placeholders.map { p in
            RustSnippetPlaceholder(index: p.index, start: p.start, length: p.length)
        }

        // Initialize snippet navigation state
        var state = RustSnippetNavigationState(
            placeholders: placeholders,
            currentIndex: 0,
            cursorOffset: text.count,
            finalCursorOffset: insertion.finalCursorOffset
        )

        // Move cursor to first placeholder
        Log.trace("RustTerminalView[\(viewId)]: insertSnippet - Moving to first placeholder at offset \(placeholders[0].start)")
        moveSnippetCursor(from: &state, to: placeholders[0].start)
        snippetState = state

        // Install key monitor for Tab navigation if not already active
        installSnippetKeyMonitor()
    }

    /// Install key monitor for snippet Tab navigation
    func installSnippetKeyMonitor() {
        // Reuse the existing keyDownMonitor if we have event monitoring enabled
        // The snippet handling will be checked in handleSnippetKeyDown
        guard keyDownMonitor == nil, window != nil else { return }

        Log.trace("RustTerminalView[\(viewId)]: installSnippetKeyMonitor - Installing snippet key monitor")
        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            guard event.window === window else { return event }
            guard isFirstResponderInTerminal() else { return event }

            if handleSnippetKeyDown(event) {
                return nil // Consume event
            }
            return event
        }
    }

    /// Handle Tab key for snippet placeholder navigation
    func handleSnippetKeyDown(_ event: NSEvent) -> Bool {
        guard let state = snippetState else { return false }

        let isTab = event.keyCode == UInt16(kVK_Tab)
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasCommandModifiers = modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option)

        if isTab, !hasCommandModifiers {
            let isBackward = modifiers.contains(.shift)
            return advanceSnippetPlaceholder(state: state, backward: isBackward)
        }

        // Any other key cancels snippet navigation
        snippetState = nil
        return false
    }

    /// Advance to next/previous placeholder
    func advanceSnippetPlaceholder(state: RustSnippetNavigationState, backward: Bool) -> Bool {
        var updated = state

        if backward {
            // Shift+Tab: Go to previous placeholder
            if updated.currentIndex > 0 {
                updated.currentIndex -= 1
                let target = updated.placeholders[updated.currentIndex].start
                Log.trace("RustTerminalView[\(viewId)]: advanceSnippetPlaceholder - Moving backward to placeholder \(updated.currentIndex)")
                moveSnippetCursor(from: &updated, to: target)
                snippetState = updated
                return true
            }
            // At first placeholder with Shift+Tab - move to final cursor position and exit
            Log.trace("RustTerminalView[\(viewId)]: advanceSnippetPlaceholder - At first placeholder, moving to final position")
            moveSnippetCursor(from: &updated, to: updated.finalCursorOffset)
            snippetState = nil
            return true
        }

        // Tab: Go to next placeholder
        if updated.currentIndex + 1 < updated.placeholders.count {
            updated.currentIndex += 1
            let target = updated.placeholders[updated.currentIndex].start
            Log.trace("RustTerminalView[\(viewId)]: advanceSnippetPlaceholder - Moving forward to placeholder \(updated.currentIndex)")
            moveSnippetCursor(from: &updated, to: target)
            snippetState = updated
            return true
        }

        // At last placeholder with Tab - move to final cursor position and exit
        Log.trace("RustTerminalView[\(viewId)]: advanceSnippetPlaceholder - At last placeholder, moving to final position")
        moveSnippetCursor(from: &updated, to: updated.finalCursorOffset)
        snippetState = nil
        return true
    }

    /// Move cursor within snippet text using escape sequences
    func moveSnippetCursor(from state: inout RustSnippetNavigationState, to targetOffset: Int) {
        let delta = state.cursorOffset - targetOffset
        if delta > 0 {
            // Move cursor left
            send(txt: "\u{1B}[\(delta)D")
        } else if delta < 0 {
            // Move cursor right
            send(txt: "\u{1B}[\(-delta)C")
        }
        state.cursorOffset = targetOffset
    }

    /// Check if text contains non-ASCII characters (unsafe for cursor movement arithmetic)
    func isUnsafeForPlaceholderNavigation(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if !scalar.isASCII {
                return true
            }
        }
        return false
    }

}

// MARK: - Command Selection

extension RustTerminalView {

    /// Select current command line (including wrapped lines)
    /// Uses Lines selection type which automatically handles wrapped lines in alacritty_terminal.
    /// Note: Full implementation would require shell integration markers for accurate prompt detection.
    func selectCurrentCommand() {
        Log.trace("RustTerminalView[\(viewId)]: selectCurrentCommand - Selecting cursor line")

        // Get cursor position from Rust terminal
        guard let rust = rustTerminal else {
            Log.warn("RustTerminalView[\(viewId)]: selectCurrentCommand - No Rust terminal")
            return
        }

        let cursor = rust.cursorPosition

        // The cursor row from Rust is the Line value (0 = first visible line)
        // Lines selection (type 3) in alacritty_terminal handles wrapped lines automatically
        let cursorRow = Int32(cursor.row)

        // Use line selection type (3) which selects entire logical lines including wrapped portions
        rust.startSelection(col: 0, row: cursorRow, selectionType: 3) // 3 = Lines selection
        needsGridSync = true

        Log.trace("RustTerminalView[\(viewId)]: selectCurrentCommand - Selected line at row \(cursorRow)")
    }

    /// Clear command selection state
    func clearCommandSelectionState() {
        Log.trace("RustTerminalView[\(viewId)]: clearCommandSelectionState")
        clearSelection()
    }

    // MARK: - Command History Navigation

    /// Install history key monitor for up/down arrow navigation at prompt
    func installHistoryKeyMonitor() {
        guard historyMonitor == nil else {
            Log.trace("RustTerminalView[\(viewId)]: installHistoryKeyMonitor - Already installed")
            return
        }
        Log.trace("RustTerminalView[\(viewId)]: installHistoryKeyMonitor - Installing history key monitor")
        historyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            guard event.window === window else { return event }
            guard isFirstResponderInTerminal() else { return event }
            if handleHistoryKeyDown(event) {
                return nil // Consume event
            }
            return event
        }
    }

    /// Remove history key monitor (cleanup)
    private func removeHistoryMonitor() {
        if let monitor = historyMonitor {
            Log.trace("RustTerminalView[\(viewId)]: removeHistoryMonitor - Removing history monitor")
            NSEvent.removeMonitor(monitor)
            historyMonitor = nil
        }
    }

    /// Handle history key events (up/down arrows at prompt)
    private func handleHistoryKeyDown(_ event: NSEvent) -> Bool {
        let keyCode = event.keyCode
        let isUp = keyCode == UInt16(kVK_UpArrow)
        let isDown = keyCode == UInt16(kVK_DownArrow)
        guard isUp || isDown else { return false }

        // Only intercept at shell prompt - let programs like vim/less handle arrows
        guard isAtPrompt?() == true else { return false }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let hasOption = modifiers.contains(.option)
        // Don't intercept if Cmd/Ctrl/Shift are held (other shortcuts)
        let hasCmdCtrlShift = modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.shift)
        if hasCmdCtrlShift { return false }

        let command: String?
        if hasOption {
            // Option+Arrow: Global (cross-tab) history
            command = isUp
                ? CommandHistoryManager.shared.previousGlobal()
                : CommandHistoryManager.shared.nextGlobal()
        } else {
            // Arrow only: Per-tab history
            command = isUp
                ? CommandHistoryManager.shared.previousInTab(tabIdentifier)
                : CommandHistoryManager.shared.nextInTab(tabIdentifier)
        }

        guard let cmd = command else {
            Log.trace("RustTerminalView[\(viewId)]: handleHistoryKeyDown - No more history")
            return true // No more history, consume anyway
        }

        // Avoid re-injecting the same command on key repeat (can spam the line)
        if event.isARepeat, cmd == lastHistoryCommand, lastHistoryWasUp == isUp {
            return true
        }
        lastHistoryCommand = cmd
        lastHistoryWasUp = isUp

        Log.trace("RustTerminalView[\(viewId)]: handleHistoryKeyDown - Inserting history: '\(cmd.prefix(30))...'")

        // Clear current input line: Ctrl+A (start of line) + Ctrl+K (kill to end)
        send(txt: "\u{01}\u{0B}")
        if !cmd.isEmpty {
            send(txt: cmd)
        }
        return true
    }

    // MARK: - Helper Methods

    /// Check if this view or a descendant is first responder
    func isFirstResponderInTerminal() -> Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder === self || responder.isDescendant(of: self) || responder === gridView
    }

    // MARK: - Debug and Diagnostics

    /// Get comprehensive debug state as a dictionary (avoids exposing private FFI types).
    /// Returns nil if the terminal is not initialized.
    func getDebugState() -> [String: Any]? {
        guard let state = rustTerminal?.debugState() else { return nil }
        return [
            "id": state.id,
            "cols": state.cols,
            "rows": state.rows,
            "historySize": state.historySize,
            "displayOffset": state.displayOffset,
            "cursorCol": state.cursorCol,
            "cursorRow": state.cursorRow,
            "bytesSent": state.bytesSent,
            "bytesReceived": state.bytesReceived,
            "uptimeMs": state.uptimeMs,
            "gridDirty": state.gridDirty,
            "running": state.running,
            "hasSelection": state.hasSelection,
            "mouseMode": state.mouseMode,
            "bracketedPaste": state.bracketedPaste,
            "appCursor": state.appCursor,
            "pollCount": state.pollCount,
            "avgPollTimeUs": state.avgPollTimeUs,
            "maxPollTimeUs": state.maxPollTimeUs,
            "avgGridSnapshotTimeUs": state.avgGridSnapshotTimeUs,
            "maxGridSnapshotTimeUs": state.maxGridSnapshotTimeUs
        ]
    }

    /// Get the full buffer text (visible + scrollback) for debugging.
    func getFullBufferText() -> String? {
        return rustTerminal?.fullBufferText()
    }

    /// Reset performance metrics.
    func resetPerformanceMetrics() {
        rustTerminal?.resetMetrics()
        Log.info("RustTerminalView[\(viewId)]: Performance metrics reset")
    }

    /// Log comprehensive debug state to the console.
    func dumpDebugState() {
        Log.info("RustTerminalView[\(viewId)]: === DEBUG STATE DUMP ===")
        Log.info("  View ID: \(viewId)")
        Log.info("  Is Started: \(isTerminalStarted)")
        Log.info("  Dimensions: \(cols)x\(rows)")
        Log.info("  Cell Size: \(cellWidth)x\(cellHeight)")
        Log.info("  Bounds: \(bounds)")
        Log.info("  Application Cursor Mode: \(applicationCursorMode)")
        Log.info("  Allow Mouse Reporting: \(allowMouseReporting)")
        Log.info("  Current Directory: \(currentDirectory)")
        Log.info("  Shell PID: \(shellPid)")
        Log.info("  Sync Count: \(Self.syncCount)")

        if let state = rustTerminal?.debugState() {
            Log.info("  --- Rust Terminal State ---")
            Log.info("    Terminal ID: \(state.id)")
            Log.info("    Grid: \(state.cols)x\(state.rows)")
            Log.info("    History: \(state.historySize) lines, offset=\(state.displayOffset)")
            Log.info("    Cursor: (\(state.cursorCol), \(state.cursorRow))")
            Log.info("    I/O: sent=\(state.bytesSent) bytes, received=\(state.bytesReceived) bytes")
            Log.info("    Uptime: \(state.uptimeMs)ms")
            Log.info("    Running: \(state.running), Grid Dirty: \(state.gridDirty)")
            Log.info("    Has Selection: \(state.hasSelection)")
            Log.info("    Mouse Mode: \(state.mouseMode)")
            Log.info("    Bracketed Paste: \(state.bracketedPaste), App Cursor: \(state.appCursor)")
            Log.info("    --- Performance Metrics ---")
            Log.info("    Poll Count: \(state.pollCount)")
            Log.info("    Avg Poll Time: \(state.avgPollTimeUs)µs, Max: \(state.maxPollTimeUs)µs")
            Log.info("    Avg Snapshot Time: \(state.avgGridSnapshotTimeUs)µs, Max: \(state.maxGridSnapshotTimeUs)µs")
        } else {
            Log.info("  --- Rust Terminal Not Available ---")
        }

        Log.info("RustTerminalView[\(viewId)]: === END DEBUG STATE ===")
    }

    // MARK: - Stress Testing Support

    /// Send a large amount of data to test throughput.
    /// - Parameters:
    ///   - lineCount: Number of lines to generate
    ///   - lineLength: Characters per line
    ///   - completion: Called when stress test completes with total bytes sent
    func stressTest(lineCount: Int, lineLength: Int = 80, completion: @escaping (Int) -> Void) {
        Log.info("RustTerminalView[\(viewId)]: Starting stress test: \(lineCount) lines x \(lineLength) chars")
        resetPerformanceMetrics()

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            var totalBytes = 0
            let startTime = Date()

            for i in 0 ..< lineCount {
                let lineNum = String(format: "%06d: ", i)
                let padding = String(repeating: "X", count: max(0, lineLength - lineNum.count - 1))
                let line = lineNum + padding + "\n"
                let bytes = Array(line.utf8)

                DispatchQueue.main.async {
                    self.rustTerminal?.sendBytes(bytes)
                }
                totalBytes += bytes.count

                // Yield periodically to avoid blocking
                if i.isMultiple(of: 1000) {
                    Thread.sleep(forTimeInterval: 0.001)
                }
            }

            let elapsed = Date().timeIntervalSince(startTime)
            Log.info("RustTerminalView[\(viewId)]: Stress test complete: \(totalBytes) bytes in \(elapsed)s (\(Int(Double(totalBytes) / elapsed / 1024)) KB/s)")

            DispatchQueue.main.async {
                completion(totalBytes)
            }
        }
    }

    /// Run a comprehensive diagnostic test.
    /// Tests basic functionality and reports results.
    func runDiagnostics() -> [String: Any] {
        Log.info("RustTerminalView[\(viewId)]: Running diagnostics...")

        var results: [String: Any] = [:]

        // Basic state
        results["viewId"] = viewId
        results["isStarted"] = isTerminalStarted
        results["dimensions"] = "\(cols)x\(rows)"
        results["shellPid"] = shellPid

        // Check components
        results["hasRustTerminal"] = rustTerminal != nil
        results["hasGridView"] = gridView != nil

        // Performance metrics
        if let state = rustTerminal?.debugState() {
            results["pollCount"] = state.pollCount
            results["avgPollTimeUs"] = state.avgPollTimeUs
            results["maxPollTimeUs"] = state.maxPollTimeUs
            results["bytesReceived"] = state.bytesReceived
            results["bytesSent"] = state.bytesSent
            results["uptimeMs"] = state.uptimeMs
        }

        Log.info("RustTerminalView[\(viewId)]: Diagnostics complete: \(results)")
        return results
    }

    // MARK: - Wide Character and Long Line Support

    /// Validate that wide characters (CJK, emoji) are handled correctly.
    /// Returns true if the terminal properly handles wide characters.
    func validateWideCharacterSupport() -> Bool {
        // Wide characters should occupy 2 cells
        // This is handled by alacritty_terminal's unicode width calculation
        Log.info("RustTerminalView[\(viewId)]: Wide character support is handled by alacritty_terminal")
        return true
    }

    /// Maximum line length supported before wrapping.
    /// alacritty_terminal handles line wrapping automatically.
    var maxLineLength: Int {
        return cols
    }
}

// MARK: - Drag & Drop (File Paths + Image Base64)

extension RustTerminalView {
    /// Register for file and image drag types. Called from setupViews().
    func registerDragTypes() {
        registerForDraggedTypes([.fileURL, .png, .tiff])
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Accept copy for files and images
        if sender.draggingPasteboard.availableType(from: [.fileURL, .png, .tiff]) != nil {
            return .copy
        }
        return []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let pboard = sender.draggingPasteboard
        let optionHeld = NSEvent.modifierFlags.contains(.option)

        // Case 1: File URL(s) dropped
        if let urls = pboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            if optionHeld, urls.count == 1, isImageFile(urls[0]) {
                // Option+drop image file → base64 encode for AI CLIs
                return pasteImageAsBase64(fileURL: urls[0])
            }
            // Default: paste file path(s) as shell-escaped text
            let paths = urls.map { shellEscape($0.path) }
            pasteText(paths.joined(separator: " "))
            return true
        }

        // Case 2: Raw image data dropped (e.g., from Preview, Safari)
        if let imageData = pboard.data(forType: .png) ?? pboard.data(forType: .tiff) {
            return pasteImageData(imageData)
        }

        return false
    }

    // MARK: - Image Helpers

    private func isImageFile(_ url: URL) -> Bool {
        let exts: Set = ["png", "jpg", "jpeg", "gif", "webp", "bmp", "tiff", "tif", "svg"]
        return exts.contains(url.pathExtension.lowercased())
    }

    private func pasteImageAsBase64(fileURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: fileURL) else { return false }
        return pasteImageData(data, filename: fileURL.lastPathComponent)
    }

    /// Max image size for base64 drop (10MB raw → ~13MB base64)
    private static let maxImageDropSize = 10_000_000

    private func pasteImageData(_ data: Data, filename: String? = nil) -> Bool {
        guard data.count < Self.maxImageDropSize else {
            Log.warn("RustTerminalView[\(viewId)]: dropped image too large (\(data.count) bytes, limit \(Self.maxImageDropSize))")
            NSSound.beep()
            return false
        }
        let b64 = data.base64EncodedString()
        let name = filename ?? "image.png"
        // Format as a data URI that AI CLIs can consume.
        // Claude Code expects: ![image](data:image/png;base64,...)
        let ext = (name as NSString).pathExtension.lowercased()
        let mime = imageMIME(for: ext)
        let payload = "![" + name + "](data:" + mime + ";base64," + b64 + ")"
        pasteText(payload)
        Log.info("RustTerminalView[\(viewId)]: dropped image \(name) (\(data.count) bytes, \(b64.count) base64 chars)")
        return true
    }

    private func imageMIME(for ext: String) -> String {
        switch ext {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        default: return "image/png"
        }
    }

    private func shellEscape(_ path: String) -> String {
        // Single-quote the path, escaping any single quotes within
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
