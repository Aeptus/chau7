import AppKit
import Chau7Core

// MARK: - Mouse, Selection, and Event Monitoring

extension RustTerminalView {

    // MARK: - Selection

    /// Get selected text
    func getSelection() -> String? {
        let text = rustTerminal?.getSelectionText()
        if let t = text {
            Log.trace("RustTerminalView[\(viewId)]: getSelection - Got \(t.count) chars")
        } else {
            Log.trace("RustTerminalView[\(viewId)]: getSelection - No selection")
        }
        return text
    }

    /// Clear selection
    func selectNone() {
        Log.trace("RustTerminalView[\(viewId)]: selectNone")
        rustTerminal?.clearSelection()
        lastSelectionText = nil
    }

    /// Clear selection (alias)
    func clearSelection() {
        Log.trace("RustTerminalView[\(viewId)]: clearSelection")
        selectNone()
    }

    /// Check if there's an active selection
    var hasSelection: Bool {
        if let text = getSelection(), !text.isEmpty {
            return true
        }
        return false
    }

    /// Get selected text (alias for protocol conformance)
    func getSelectedText() -> String? {
        getSelection()
    }

    // MARK: - Auto-Scroll During Selection

    /// Starts the auto-scroll timer for selection drag outside bounds.
    func startAutoScrollTimer() {
        // Don't create multiple timers
        guard autoScrollTimer == nil else { return }

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            performAutoScroll()
        }
        // Add to .common modes so the timer fires during mouse event tracking
        RunLoop.main.add(timer, forMode: .common)
        autoScrollTimer = timer
        Log.trace("RustTerminalView[\(viewId)]: startAutoScrollTimer - Started auto-scroll timer (direction=\(autoScrollDirection))")
    }

    /// Stops the auto-scroll timer.
    func stopAutoScrollTimer() {
        if autoScrollTimer != nil {
            Log.trace("RustTerminalView[\(viewId)]: stopAutoScrollTimer - Stopping auto-scroll timer")
        }
        autoScrollTimer?.invalidate()
        autoScrollTimer = nil
        autoScrollDirection = 0
    }

    /// Performs one step of auto-scrolling and extends selection.
    func performAutoScroll() {
        guard autoScrollDirection != 0 else { return }
        guard isSelecting else {
            stopAutoScrollTimer()
            return
        }

        // Scale scroll speed by distance outside bounds (accelerate further out)
        let speed = max(1, min(Int(autoScrollDistance / 20) + 1, 10))

        // Scroll the terminal (no-op if already at the edge of scrollback)
        if autoScrollDirection < 0 {
            scrollUp(lines: speed)
        } else {
            scrollDown(lines: speed)
        }

        // Always extend selection to the edge row, even when scroll is a no-op
        // (e.g., at the bottom of the buffer). This ensures the selection
        // visually covers the full visible area in the drag direction.
        guard let rust = rustTerminal else { return }
        let edgeRow: Int
        if autoScrollDirection < 0 {
            edgeRow = 0
        } else {
            edgeRow = rows - 1
        }
        let displayOffset = Int(rust.displayOffset)
        let absoluteRow = edgeRow - displayOffset
        // Scrolling up → select from start of line (col 0)
        // Scrolling down → select to end of line (last col)
        let col = autoScrollDirection < 0 ? 0 : cols - 1
        rust.updateSelection(col: Int32(col), row: Int32(absoluteRow))
        needsGridSync = true
    }

    // MARK: - Mouse Reporting

    /// Mouse mode bit flags (matching Rust implementation)
    enum MouseMode {
        static let click: UInt32 = 0x01 // Mode 1000: report button press/release
        static let drag: UInt32 = 0x02 // Mode 1002: also report motion while button down
        static let motion: UInt32 = 0x04 // Mode 1003: report all motion
        static let focusInOut: UInt32 = 0x08 // Mode 1004: focus in/out reporting
        static let sgrMode: UInt32 = 0x10 // Mode 1006: use SGR encoding (was incorrectly 0x08)
        static let anyTracking: UInt32 = 0x07 // Mask for click/drag/motion modes
    }

    /// Mouse button encoding for X10/Normal protocols
    enum MouseButton: UInt8 {
        case left = 0
        case middle = 1
        case right = 2
        case release = 3
        case scrollUp = 64
        case scrollDown = 65
        case scrollLeft = 66
        case scrollRight = 67
    }

    /// Check if mouse reporting is active
    func isMouseReportingEnabled() -> Bool {
        guard allowMouseReporting else { return false }
        let mode = rustTerminal?.mouseMode() ?? 0
        return (mode & MouseMode.anyTracking) != 0
    }

    /// Check if SGR extended mouse mode is enabled
    func isSgrMouseMode() -> Bool {
        let mode = rustTerminal?.mouseMode() ?? 0
        return (mode & MouseMode.sgrMode) != 0
    }

    /// Check if motion events should be reported while button is down
    func shouldReportDragMotion() -> Bool {
        let mode = rustTerminal?.mouseMode() ?? 0
        return (mode & MouseMode.drag) != 0 || (mode & MouseMode.motion) != 0
    }

    /// Encode and send a mouse event to the PTY
    func sendMouseEvent(button: MouseButton, col: Int, row: Int, isRelease: Bool, modifiers: NSEvent.ModifierFlags = []) {
        var buttonCode = button.rawValue
        if modifiers.contains(.shift) { buttonCode += 4 }
        if modifiers.contains(.option) { buttonCode += 8 }
        if modifiers.contains(.control) { buttonCode += 16 }

        if isSgrMouseMode() {
            let col1 = col + 1
            let row1 = row + 1
            let terminator = isRelease ? "m" : "M"
            let sequence = "\u{1b}[<\(buttonCode);\(col1);\(row1)\(terminator)"
            Log.trace("RustTerminalView[\(viewId)]: sendMouseEvent SGR - button=\(buttonCode), col=\(col1), row=\(row1)")
            send(txt: sequence)
        } else {
            let effectiveCol = min(col, 222)
            let effectiveRow = min(row, 222)
            let releaseButton: UInt8 = isRelease ? 3 : buttonCode
            let buttonByte = releaseButton + 32
            let colByte = UInt8(effectiveCol + 33)
            let rowByte = UInt8(effectiveRow + 33)
            send(data: [0x1B, 0x5B, 0x4D, buttonByte, colByte, rowByte])
        }
    }

    /// Send a mouse press event
    func sendMousePress(button: MouseButton, at location: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        let cell = pointToCell(location)
        sendMouseEvent(button: button, col: Int(cell.col), row: Int(cell.row), isRelease: false, modifiers: modifiers)
    }

    /// Send a mouse release event
    func sendMouseRelease(button: MouseButton, at location: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        let cell = pointToCell(location)
        sendMouseEvent(button: button, col: Int(cell.col), row: Int(cell.row), isRelease: true, modifiers: modifiers)
    }

    /// Send a mouse motion event
    func sendMouseMotion(at location: NSPoint, buttonDown: MouseButton?, modifiers: NSEvent.ModifierFlags = []) {
        let cell = pointToCell(location)
        let cellCol = Int(cell.col)
        let cellRow = Int(cell.row)
        var buttonCode: UInt8 = 32
        if let button = buttonDown { buttonCode += button.rawValue } else { buttonCode += 3 }
        if modifiers.contains(.shift) { buttonCode += 4 }
        if modifiers.contains(.option) { buttonCode += 8 }
        if modifiers.contains(.control) { buttonCode += 16 }

        if isSgrMouseMode() {
            let sequence = "\u{1b}[<\(buttonCode);\(cellCol + 1);\(cellRow + 1)M"
            send(txt: sequence)
        } else {
            let colByte = UInt8(min(cellCol, 222) + 33)
            let rowByte = UInt8(min(cellRow, 222) + 33)
            send(data: [0x1B, 0x5B, 0x4D, buttonCode + 32, colByte, rowByte])
        }
    }

    /// Send a scroll wheel event
    /// In X10/normal protocol: button 64 = scroll up, button 65 = scroll down
    /// In SGR protocol: button 64/65 with M suffix (no release for scroll)
    func sendScrollEvent(deltaY: CGFloat, at location: NSPoint, modifiers: NSEvent.ModifierFlags = []) {
        let cell = pointToCell(location)
        let cellCol = Int(cell.col)
        let cellRow = Int(cell.row)

        // Button codes: 64 = scroll up, 65 = scroll down
        // (In X10 protocol these are buttons 4 and 5 with bit 6 set)
        var buttonCode: UInt8 = deltaY > 0 ? 64 : 65
        if modifiers.contains(.shift) { buttonCode += 4 }
        if modifiers.contains(.option) { buttonCode += 8 }
        if modifiers.contains(.control) { buttonCode += 16 }

        Log.trace("RustTerminalView[\(viewId)]: sendScrollEvent - deltaY=\(deltaY), button=\(buttonCode), cell=(\(cellCol), \(cellRow))")

        if isSgrMouseMode() {
            let sequence = "\u{1b}[<\(buttonCode);\(cellCol + 1);\(cellRow + 1)M"
            send(txt: sequence)
        } else {
            let colByte = UInt8(min(cellCol, 222) + 33)
            let rowByte = UInt8(min(cellRow, 222) + 33)
            send(data: [0x1B, 0x5B, 0x4D, buttonCode + 32, colByte, rowByte])
        }
    }

    // MARK: - Event Monitoring

    func setEventMonitoringEnabled(_ enabled: Bool) {
        Log.trace("RustTerminalView[\(viewId)]: setEventMonitoringEnabled(\(enabled))")
        guard isEventMonitoringEnabled != enabled else {
            Log.trace("RustTerminalView[\(viewId)]: setEventMonitoringEnabled - Already \(enabled ? "enabled" : "disabled")")
            return
        }
        isEventMonitoringEnabled = enabled
        guard window != nil else {
            Log.trace("RustTerminalView[\(viewId)]: setEventMonitoringEnabled - No window, deferring")
            return
        }

        if enabled {
            setupEventMonitors()
        } else {
            removeEventMonitors()
        }
    }

    // swiftlint:disable:next cyclomatic_complexity
    func setupEventMonitors() {
        Log.trace("RustTerminalView[\(viewId)]: setupEventMonitors - Installing event monitors")
        removeEventMonitors()

        let settings = FeatureSettings.shared
        let needsMouseMove = settings.isCmdClickPathsEnabled

        // Mouse down for selection start, Cmd+click paths, Option+click cursor, mouse reporting
        mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self else { return event }
            guard event.window === window else { return event }
            let location = convert(event.locationInWindow, from: nil)
            guard bounds.contains(location) else { return event }

            // If a SwiftUI overlay is above us, don't intercept the click
            if let hitView = event.window?.contentView?.hitTest(event.locationInWindow),
               hitView !== self, !hitView.isDescendant(of: self) {
                return event
            }

            let cell = pointToCell(location)
            Log.trace("RustTerminalView[\(viewId)]: mouseDown at (\(location.x), \(location.y)) -> cell (\(cell.col), \(cell.row))")

            // Mouse reporting: Forward mouse events to TUI apps (tmux, vim, htop, etc.)
            // Control+click bypasses mouse reporting to allow context menu/selection
            if isMouseReportingEnabled(), !event.modifierFlags.contains(.control) {
                Log.trace("RustTerminalView[\(viewId)]: Mouse reporting - sending left press")
                mouseReportingButtonDown = .left
                sendMousePress(button: .left, at: location, modifiers: event.modifierFlags)
                mouseDownLocation = location // Track for drag reporting
                didDragSinceMouseDown = false
                return event
            }

            // Track mouse down for click-to-position
            mouseDownLocation = location
            didDragSinceMouseDown = false
            isSelecting = false

            // F03: Check for Cmd+click on paths/URLs
            if event.modifierFlags.contains(.command), FeatureSettings.shared.isCmdClickPathsEnabled {
                if handleCmdClick(at: location) {
                    mouseDownLocation = nil // Don't position cursor for Cmd+click
                    return nil // Consume the event
                }
            }

            // Option+click to position cursor (like iTerm2)
            if event.modifierFlags.contains(.option), FeatureSettings.shared.isOptionClickCursorEnabled {
                if handleOptionClick(at: location) {
                    mouseDownLocation = nil // Already handled
                    return nil // Consume the event
                }
            }

            // Handle double-click (word selection) and triple-click (line selection)
            let absoluteCell = pointToCellAbsolute(location)
            if event.clickCount == 2 {
                // Double-click: Select word at click location (Semantic selection)
                Log.trace("RustTerminalView[\(viewId)]: Double-click at cell (\(absoluteCell.col), \(absoluteCell.row)) - selecting word")
                rustTerminal?.startSelection(col: absoluteCell.col, row: absoluteCell.row, selectionType: 2) // Semantic
                needsGridSync = true
                mouseDownLocation = nil // Prevent cursor positioning and drag start
                scheduleCopyOnSelect()
                return event
            } else if event.clickCount >= 3 {
                // Triple-click: Select entire line (Lines selection)
                Log.trace("RustTerminalView[\(viewId)]: Triple-click at row \(absoluteCell.row) - selecting line")
                rustTerminal?.startSelection(col: 0, row: absoluteCell.row, selectionType: 3) // Lines
                needsGridSync = true
                mouseDownLocation = nil // Prevent cursor positioning and drag start
                scheduleCopyOnSelect()
                return event
            }

            // Clear any existing selection on mouse down (single click)
            rustTerminal?.clearSelection()
            needsGridSync = true

            return event
        }

        // Mouse dragged for selection OR mouse reporting
        mouseDragMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDragged) { [weak self] event in
            guard let self = self else { return event }
            guard event.window === window else { return event }

            // If a SwiftUI overlay is above us, don't intercept the drag
            if let hitView = event.window?.contentView?.hitTest(event.locationInWindow),
               hitView !== self, !hitView.isDescendant(of: self) {
                return event
            }

            let location = convert(event.locationInWindow, from: nil)

            // Mouse reporting: Forward drag events to TUI apps (mode 1002/1003)
            if mouseReportingButtonDown != nil {
                let mouseModeValue = rustTerminal?.mouseMode() ?? 0
                let isDragMode = (mouseModeValue & MouseMode.drag) != 0
                let isMotionMode = (mouseModeValue & MouseMode.motion) != 0

                if isDragMode || isMotionMode {
                    sendMouseMotion(at: location, buttonDown: mouseReportingButtonDown, modifiers: event.modifierFlags)
                }
                didDragSinceMouseDown = true
                return event // Don't do selection when mouse reporting is active
            }

            // Selection logic (only when not mouse reporting)
            if let downLocation = mouseDownLocation {
                let dx = abs(location.x - downLocation.x)
                let dy = abs(location.y - downLocation.y)
                if dx > Self.dragThreshold || dy > Self.dragThreshold {
                    // Use absolute coordinates for selection (accounts for scrollback offset)
                    let currentCell = pointToCellAbsolute(location)

                    if !didDragSinceMouseDown {
                        // First drag past threshold - start selection at mouse down location
                        let startCell = pointToCellAbsolute(downLocation)
                        Log.trace("RustTerminalView[\(viewId)]: mouseDrag - Starting selection at absolute cell (\(startCell.col), \(startCell.row))")
                        rustTerminal?.startSelection(col: startCell.col, row: startCell.row, selectionType: 0)
                        isSelecting = true
                    }

                    didDragSinceMouseDown = true

                    // Update selection end point
                    if isSelecting {
                        Log.trace("RustTerminalView[\(viewId)]: mouseDrag - Updating selection to absolute cell (\(currentCell.col), \(currentCell.row))")
                        rustTerminal?.updateSelection(col: currentCell.col, row: currentCell.row)
                        needsGridSync = true
                    }
                }
            }

            // Auto-scroll when dragging near or outside view edges during selection.
            // Use a 10px inset so the user doesn't have to leave the view entirely.
            if didDragSinceMouseDown, isSelecting {
                let edgeInset: CGFloat = 10
                if location.y < edgeInset {
                    // Near/below bottom edge - scroll down (show later content)
                    autoScrollDirection = 1
                    autoScrollDistance = max(0, edgeInset - location.y)
                    startAutoScrollTimer()
                } else if location.y > bounds.height - edgeInset {
                    // Near/above top edge - scroll up (show earlier content)
                    autoScrollDirection = -1
                    autoScrollDistance = max(0, location.y - (bounds.height - edgeInset))
                    startAutoScrollTimer()
                } else {
                    // Inside bounds - stop auto-scroll
                    stopAutoScrollTimer()
                }
            }

            return event
        }

        // Mouse up for mouse reporting, copy-on-select, AND click-to-position cursor
        mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            guard let self = self else { return event }

            // Capture and clear mouse tracking state
            let downLocation = mouseDownLocation
            let wasDrag = didDragSinceMouseDown
            let wasSelecting = isSelecting
            let wasMouseReporting = mouseReportingButtonDown

            mouseDownLocation = nil
            didDragSinceMouseDown = false
            isSelecting = false
            mouseReportingButtonDown = nil

            // Stop auto-scroll timer on mouse up
            stopAutoScrollTimer()

            guard event.window === window else { return event }
            let location = convert(event.locationInWindow, from: nil)

            // Mouse reporting: Send release event to TUI apps
            if let reportingButton = wasMouseReporting {
                Log.trace("RustTerminalView[\(viewId)]: Mouse reporting - sending \(reportingButton) release")
                sendMouseRelease(button: reportingButton, at: location, modifiers: event.modifierFlags)
                return event // Don't do click-to-position or selection when mouse reporting
            }

            guard bounds.contains(location) else { return event }

            Log.trace("RustTerminalView[\(viewId)]: mouseUp at (\(location.x), \(location.y)), wasSelecting=\(wasSelecting), wasDrag=\(wasDrag)")

            // Click-to-position: If no drag occurred and single click, position cursor
            if let clickLocation = downLocation, !wasDrag {
                let isSingleClick = event.clickCount == 1
                let noModifiers = !event.modifierFlags.contains(.shift) && !event.modifierFlags.contains(.command) && !event.modifierFlags.contains(.option)
                let noActiveSelection = !hasSelection
                let clickEnabled = FeatureSettings.shared.isClickToPositionEnabled

                if isSingleClick, noModifiers, noActiveSelection, clickEnabled {
                    if handleClickToPosition(at: clickLocation) {
                        Log.trace("RustTerminalView[\(viewId)]: Click-to-position handled")
                        return event
                    }
                }
            }

            // Copy-on-select: Option key temporarily disables
            let optionHeld = event.modifierFlags.contains(.option)
            if wasSelecting, !optionHeld {
                scheduleCopyOnSelect()
            }

            return event
        }
        // Mouse move monitor for cursor change on hover (Cmd+hover shows hand cursor for clickable paths/URLs)
        if needsMouseMove {
            mouseMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                guard let self = self else { return event }
                guard event.window === window else { return event }
                let location = convert(event.locationInWindow, from: nil)
                guard bounds.contains(location) else { return event }

                handleMouseMove(at: location, modifiers: event.modifierFlags)
                return event
            }
        }

        // Scroll wheel monitor — handles both mouse reporting AND scrollback navigation.
        // Mouse reporting mode: forward scroll events to TUI apps (vim, tmux, etc.)
        // Normal mode: navigate scrollback history (scroll up = see earlier output)
        scrollWheelMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self = self else { return event }
            guard event.window === window else { return event }
            let location = convert(event.locationInWindow, from: nil)
            guard bounds.contains(location) else { return event }

            // Mouse reporting mode: forward scroll to the terminal program
            if isMouseReportingEnabled() {
                let deltaY = event.scrollingDeltaY
                // Ignore tiny scrolls to avoid flooding the terminal
                if abs(deltaY) > 0.5 {
                    sendScrollEvent(deltaY: deltaY, at: location, modifiers: event.modifierFlags)
                    return nil // Consume event when mouse reporting
                }
                return event
            }

            // Normal mode: scrollback navigation.
            // RustTerminalView is a plain NSView (not NSScrollView), so scroll events
            // would just pass through unhandled. We handle them here directly.
            let deltaY = event.scrollingDeltaY
            if abs(deltaY) > 0.5 {
                let lines = max(1, Int(abs(deltaY) / 3.0))
                if deltaY > 0 {
                    scrollUp(lines: lines)
                } else {
                    scrollDown(lines: lines)
                }

                // If actively selecting, extend the selection to track the scroll.
                // This lets users scroll-wheel to extend selection beyond the viewport.
                if isSelecting, let rust = rustTerminal {
                    let mouseLocation = convert(event.locationInWindow, from: nil)
                    let cell = pointToCellAbsolute(mouseLocation)
                    rust.updateSelection(col: cell.col, row: cell.row)
                    needsGridSync = true
                }

                return nil // Consume the event
            }
            return event
        }

        // General key event monitor - intercept ALL key events when terminal is active
        // This ensures key input goes to Rust terminal even if a subview is first responder
        generalKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }
            guard event.window === window else { return event }
            guard isFirstResponderInTerminal() else { return event }

            // Let snippet and history monitors handle their specific keys first
            // (they run before this and return nil to consume)

            // Route to Rust terminal
            if handleTerminalKeyEvent(event) {
                markGeneralKeyEventHandled(event)
                return nil // Consume event - we handled it
            }
            return event // Let it propagate if not handled
        }

        Log.trace("RustTerminalView[\(viewId)]: setupEventMonitors - Event monitors installed (mouseMove=\(needsMouseMove), generalKey=true)")
    }

    func removeEventMonitors() {
        var removedCount = 0
        if let monitor = mouseDownMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDownMonitor = nil
            removedCount += 1
        }
        if let monitor = mouseUpMonitor {
            NSEvent.removeMonitor(monitor)
            mouseUpMonitor = nil
            removedCount += 1
        }
        if let monitor = mouseDragMonitor {
            NSEvent.removeMonitor(monitor)
            mouseDragMonitor = nil
            removedCount += 1
        }
        if let monitor = mouseMoveMonitor {
            NSEvent.removeMonitor(monitor)
            mouseMoveMonitor = nil
            removedCount += 1
        }
        if let monitor = scrollWheelMonitor {
            NSEvent.removeMonitor(monitor)
            scrollWheelMonitor = nil
            removedCount += 1
        }
        if let monitor = keyDownMonitor {
            NSEvent.removeMonitor(monitor)
            keyDownMonitor = nil
            removedCount += 1
        }
        if let monitor = generalKeyMonitor {
            NSEvent.removeMonitor(monitor)
            generalKeyMonitor = nil
            removedCount += 1
        }
        // Fix #4: Also remove history monitor to prevent leaks
        if let monitor = historyMonitor {
            NSEvent.removeMonitor(monitor)
            historyMonitor = nil
            removedCount += 1
        }
        if removedCount > 0 {
            Log.trace("RustTerminalView[\(viewId)]: removeEventMonitors - Removed \(removedCount) monitors")
        }
    }

    // MARK: - F03: Cmd+Click Paths/URLs

    struct ClickableLineHit {
        let text: String
        let clickedUTF16Index: Int
        let gridRow: Int
        let gridColumn: Int
    }

    struct URLMatch {
        let url: String
        let range: NSRange
    }

    /// Handle Cmd+click on file paths or URLs
    func handleCmdClick(at point: NSPoint) -> Bool {
        // OSC 8 hyperlink check — takes priority over text-based URL matching
        if let rust = rustTerminal {
            let cell = pointToCell(point)
            let cellIndex = Int(cell.row) * cols + Int(cell.col)
            let linkId = gridView?.linkIdAt(index: cellIndex) ?? 0
            if linkId > 0, let urlString = rust.getLinkUrl(linkId: linkId),
               let url = URL(string: urlString) {
                NSWorkspace.shared.open(url)
                Log.info("RustTerminalView[\(viewId)]: Cmd+click - opened OSC 8 hyperlink: \(urlString)")
                return true
            }
        }

        guard let lineHit = getClickableLineHit(at: point) else { return false }
        let urlMatches = findURLs(in: lineHit.text)
        let pathMatches = PathClickHandler.findPaths(in: lineHit.text)
        Log.debug(
            "RustTerminalView[\(viewId)]: Cmd+click - logical hit row=\(lineHit.gridRow) col=\(lineHit.gridColumn) index=\(lineHit.clickedUTF16Index) urls=\(urlMatches.count) paths=\(pathMatches.count)"
        )

        if let urlMatch = urlMatches.first(where: { NSLocationInRange(lineHit.clickedUTF16Index, $0.range) }) {
            PathClickHandler.openURL(urlMatch.url)
            Log.info("RustTerminalView[\(viewId)]: Cmd+click - opened URL \(urlMatch.url)")
            return true
        }

        if let pathMatch = PathClickHandler.findPath(in: lineHit.text, atUTF16Index: lineHit.clickedUTF16Index) {
            let resolvedPath = PathClickHandler.resolvePath(pathMatch.path, relativeTo: currentDirectory)
            guard FileManager.default.fileExists(atPath: resolvedPath) else {
                logMissingCmdClickPath(resolvedPath)
                return false
            }

            if FeatureSettings.shared.cmdClickOpensInternalEditor,
               let callback = onFilePathClicked {
                callback(resolvedPath, pathMatch.line, pathMatch.column)
                Log.info("RustTerminalView[\(viewId)]: Cmd+click - opening in internal editor: \(resolvedPath)")
            } else {
                PathClickHandler.openPath(pathMatch, relativeTo: currentDirectory)
                Log.info("RustTerminalView[\(viewId)]: Cmd+click - opened path \(pathMatch.path)")
            }
            return true
        }

        if !urlMatches.isEmpty || !pathMatches.isEmpty {
            Log.debug(
                "RustTerminalView[\(viewId)]: Cmd+click - no clickable target under cursor despite matches on logical line"
            )
        }
        return false
    }

    func logMissingCmdClickPath(_ path: String) {
        let now = Date()
        recentMissingCmdClickPaths = recentMissingCmdClickPaths.filter {
            now.timeIntervalSince($0.value) < missingCmdClickWarningCooldown
        }

        if let last = recentMissingCmdClickPaths[path],
           now.timeIntervalSince(last) < missingCmdClickWarningCooldown {
            Log.trace("RustTerminalView[\(viewId)]: Cmd+click - repeated missing path suppressed: \(path)")
            return
        }

        recentMissingCmdClickPaths[path] = now
        Log.warn("RustTerminalView[\(viewId)]: Cmd+click - file does not exist: \(path)")
    }

    // MARK: - Click-to-Position Cursor

    func handleClickToPosition(at point: NSPoint) -> Bool {
        guard let rust = rustTerminal else { return false }
        guard bounds.height > 0, bounds.width > 0 else { return false }
        guard cols > 0, rows > 0 else { return false }

        // Standard macOS coordinates: y=0 at bottom, row 0 at top of terminal
        let clickedRow = max(0, min(Int((bounds.height - point.y) / cellHeight), rows - 1))
        let clickedCol = max(0, min(Int(point.x / cellWidth), cols - 1))
        let cursor = rust.cursorPosition
        let rowDiff = clickedRow - Int(cursor.row)
        let colDiff = clickedCol - Int(cursor.col)

        // Limit vertical movement to nearby rows (within 5) to avoid jumping
        // deep into scrollback when the user intended to select text.
        guard abs(rowDiff) <= 5 else { return false }

        var sequences = ""
        if rowDiff > 0 { sequences += String(repeating: "\u{1b}[B", count: rowDiff) }
        else if rowDiff < 0 { sequences += String(repeating: "\u{1b}[A", count: -rowDiff) }
        if colDiff > 0 { sequences += String(repeating: "\u{1b}[C", count: colDiff) }
        else if colDiff < 0 { sequences += String(repeating: "\u{1b}[D", count: -colDiff) }
        if !sequences.isEmpty {
            send(txt: sequences)
            Log.trace("RustTerminalView[\(viewId)]: Click-to-position - moved cursor by row=\(rowDiff), col=\(colDiff)")
            return true
        }
        return false
    }

    // MARK: - Option+Click Cursor Positioning

    func handleOptionClick(at point: NSPoint) -> Bool {
        guard let rust = rustTerminal else { return false }
        guard bounds.height > 0, bounds.width > 0 else { return false }
        guard cols > 0, rows > 0 else { return false }

        // Standard macOS coordinates: y=0 at bottom, row 0 at top of terminal
        let clickedRow = Int((bounds.height - point.y) / cellHeight)
        let clickedCol = Int(point.x / cellWidth)
        let cursor = rust.cursorPosition
        let rowDiff = clickedRow - Int(cursor.row)
        let colDiff = clickedCol - Int(cursor.col)
        var sequences = ""
        if rowDiff > 0 { sequences += String(repeating: "\u{1b}[B", count: rowDiff) }
        else if rowDiff < 0 { sequences += String(repeating: "\u{1b}[A", count: -rowDiff) }
        if colDiff > 0 { sequences += String(repeating: "\u{1b}[C", count: colDiff) }
        else if colDiff < 0 { sequences += String(repeating: "\u{1b}[D", count: -colDiff) }
        if !sequences.isEmpty {
            send(txt: sequences)
            Log.trace("RustTerminalView[\(viewId)]: Option+click - moved cursor by row=\(rowDiff), col=\(colDiff)")
            return true
        }
        return false
    }

    // MARK: - Path/URL Detection Helpers

    func getClickableLineHit(at point: NSPoint) -> ClickableLineHit? {
        guard let rust = rustTerminal else { return nil }
        guard bounds.height > 0, rows > 0 else { return nil }
        let cell = pointToCell(point)
        let screenRow = Int(cell.row)
        let screenCol = Int(cell.col)

        // Account for display offset when scrolled up.
        // When displayOffset > 0, we're viewing scrollback. The visible row 0 corresponds
        // to Line(-displayOffset), not Line(0). We need to convert screen coordinates
        // to grid coordinates to get the correct line content.
        let displayOffset = Int(rust.displayOffset)
        let gridRow = screenRow - displayOffset
        guard let logicalHit = rust.getLogicalLineHit(row: gridRow, column: screenCol) else {
            return nil
        }

        return ClickableLineHit(
            text: logicalHit.text,
            clickedUTF16Index: logicalHit.clickedUTF16Offset,
            gridRow: gridRow,
            gridColumn: screenCol
        )
    }

    func findURLs(in text: String) -> [URLMatch] {
        var urls: [URLMatch] = []
        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        RegexPatterns.url.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            guard let match = match else { return }
            urls.append(URLMatch(url: nsText.substring(with: match.range), range: match.range))
        }
        return urls
    }

    func handleMouseMove(at location: NSPoint, modifiers: NSEvent.ModifierFlags) {
        guard FeatureSettings.shared.isCmdClickPathsEnabled else { return }
        guard modifiers.contains(.command) else {
            NSCursor.iBeam.set()
            return
        }
        guard let lineHit = getClickableLineHit(at: location) else {
            NSCursor.iBeam.set()
            return
        }
        pathDetectionWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            let hasClickable = findURLs(in: lineHit.text).contains {
                NSLocationInRange(lineHit.clickedUTF16Index, $0.range)
            } || PathClickHandler.findPath(in: lineHit.text, atUTF16Index: lineHit.clickedUTF16Index) != nil
            DispatchQueue.main.async {
                if hasClickable { NSCursor.pointingHand.set() }
                else { NSCursor.iBeam.set() }
            }
        }
        pathDetectionWorkItem = work
        DispatchQueue.global(qos: .userInteractive).asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    // MARK: - Context Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard event.window === window else { return nil }
        let location = convert(event.locationInWindow, from: nil)
        guard bounds.contains(location) else { return nil }

        // Check if Shift is held - this always forces the context menu to appear
        // This is the standard way to bypass mouse reporting in terminal apps
        let forceMenu = event.modifierFlags.contains(.shift)

        // If mouse reporting is active (and not forced by Shift), send the right-click
        // to the PTY instead of showing the context menu. This enables proper mouse
        // interaction in TUI apps like vim, tmux, htop.
        if !forceMenu, isMouseReportingEnabled() {
            Log.trace("RustTerminalView[\(viewId)]: menu(for:) - Mouse reporting active, sending right-click to PTY")
            sendMousePress(button: .right, at: location, modifiers: event.modifierFlags)
            // Send release too since context menu won't consume the mouse-up event
            sendMouseRelease(button: .right, at: location, modifiers: event.modifierFlags)
            return nil // Don't show context menu
        }

        Log.trace("RustTerminalView[\(viewId)]: menu(for:) - Building context menu at (\(location.x), \(location.y))")
        window?.makeFirstResponder(self)

        let menu = NSMenu(title: "Terminal")
        // Prevent macOS from injecting system Services items (e.g. "Convert text to Chinese")
        // into our context menu. The view's validRequestor(forSendType:returnType:) advertises
        // text capabilities, which causes the Services subsystem to add unwanted entries.
        menu.allowsContextMenuPlugIns = false
        let canCopy = hasSelection
        let canPaste = NSPasteboard.general.string(forType: .string) != nil
        let insertFromPasswordsSelector = NSSelectorFromString("_handleInsertFromPasswordsCommand:")
        let canAutoFillFromPasswords = NSApp.target(forAction: insertFromPasswordsSelector, to: nil, from: self) != nil

        // -- Edit group (standard clipboard operations) --
        let copyItem = NSMenuItem(title: "Copy", action: #selector(contextCopy), keyEquivalent: "")
        copyItem.target = self
        copyItem.isEnabled = canCopy

        let pasteItem = NSMenuItem(title: "Paste", action: #selector(contextPaste), keyEquivalent: "")
        pasteItem.target = self
        pasteItem.isEnabled = canPaste

        let pasteEscapedItem = NSMenuItem(
            title: L("terminal.context.pasteEscaped", "Paste Escaped"),
            action: #selector(contextPasteEscaped),
            keyEquivalent: ""
        )
        pasteEscapedItem.target = self
        pasteEscapedItem.isEnabled = canPaste

        let selectAllItem = NSMenuItem(title: "Select All", action: #selector(contextSelectAll), keyEquivalent: "")
        selectAllItem.target = self

        // -- Autofill --
        let autoFillItem = NSMenuItem(
            title: L("terminal.context.autofillPasswords", "AutoFill from Passwords..."),
            action: #selector(contextAutoFillFromPasswords),
            keyEquivalent: ""
        )
        autoFillItem.target = self
        autoFillItem.isEnabled = canAutoFillFromPasswords

        // -- Terminal operations --
        let clearScreenItem = NSMenuItem(title: "Clear Screen", action: #selector(contextClearScreen), keyEquivalent: "")
        clearScreenItem.target = self

        let clearScrollbackItem = NSMenuItem(title: "Clear Scrollback", action: #selector(contextClearScrollback), keyEquivalent: "")
        clearScrollbackItem.target = self

        // Build menu in conventional order:
        // 1. Copy/Paste/Select All (standard Edit menu items)
        // 2. AutoFill (system feature, separated)
        // 3. Terminal-specific actions (Clear)
        menu.addItem(copyItem)
        menu.addItem(pasteItem)
        menu.addItem(pasteEscapedItem)
        menu.addItem(selectAllItem)
        menu.addItem(.separator())
        if canAutoFillFromPasswords {
            menu.addItem(autoFillItem)
            menu.addItem(.separator())
        }
        menu.addItem(clearScreenItem)
        menu.addItem(clearScrollbackItem)

        return menu
    }

    @objc func contextCopy(_ sender: Any?) {
        Log.trace("RustTerminalView[\(viewId)]: contextCopy")
        copy(self)
    }

    @objc func contextPaste(_ sender: Any?) {
        Log.trace("RustTerminalView[\(viewId)]: contextPaste")
        paste(self)
    }

    @objc func contextAutoFillFromPasswords(_ sender: Any?) {
        window?.makeFirstResponder(self)
        let selector = NSSelectorFromString("_handleInsertFromPasswordsCommand:")
        if NSApp.sendAction(selector, to: nil, from: self) {
            Log.info("RustTerminalView[\(viewId)]: Invoked Password AutoFill command")
        } else {
            Log.warn("RustTerminalView[\(viewId)]: Password AutoFill command unavailable in responder chain")
        }
    }

    @objc func contextPasteEscaped(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string) else { return }
        let escaped = PasteEscaper.escape(string)
        Log.trace("RustTerminalView[\(viewId)]: contextPasteEscaped - Pasting \(escaped.count) chars (escaped from \(string.count))")
        send(txt: escaped)
    }

    @objc func contextSelectAll(_ sender: Any?) {
        Log.trace("RustTerminalView[\(viewId)]: contextSelectAll")
        // Use Rust's native selection so getSelection() returns correct text
        // This ensures getSelection() returns the correct text after select-all
        rustTerminal?.selectAll()
        needsGridSync = true
    }

    @objc func contextClearScreen(_ sender: Any?) {
        Log.trace("RustTerminalView[\(viewId)]: contextClearScreen")
        // Send form feed (Ctrl+L) to the PTY - the shell will respond with clear screen sequences
        // which get processed by the Rust terminal via poll()
        send(data: [0x0C])
        clearSelection()
        // Ensure grid sync happens after PTY processes the clear
        needsGridSync = true
    }

    @objc func contextClearScrollback(_ sender: Any?) {
        Log.trace("RustTerminalView[\(viewId)]: contextClearScrollback")
        clearScrollbackBuffer()
    }

}
