import AppKit
import Chau7Core

// MARK: - Rendering, Grid Sync, and Event-Driven Polling

extension RustTerminalView {
    func refreshObservabilityTimerScope() {
        Chau7ObservabilityService.shared.updateTimerScope(
            renderLoopTimerID,
            tabID: observabilityTabID,
            sessionID: observabilitySessionID
        )
    }

    // MARK: - Polling Lifecycle

    func stopPollingLoop() {
        Log.trace("RustTerminalView[\(viewId)]: stopPollingLoop - Stopping all polling")
        stopEventDrain()
        BackgroundTerminalDrainService.shared.unregister(self)
        RenderPipelineProfiler.shared.updateRenderLoopState(
            viewID: viewId,
            active: false,
            tabID: observabilityTabID,
            sessionID: observabilitySessionID,
            mode: "stopped",
            reasons: profilerReasons
        )
        Chau7ObservabilityService.shared.setTimerActive(renderLoopTimerID, active: false)
    }

    private var renderLoopTimerID: String {
        "terminal_render_loop_view_\(viewId)"
    }

    /// Poll Rust terminal and sync to renderer if needed
    static var pollAndSyncCounter: UInt64 = 0
    static var lastPollAndSyncLogTime: CFAbsoluteTime = 0
    static var syncCount: UInt64 = 0

    func emitProcessTerminatedOnce(exitCode: Int32?, reason: String) {
        guard !didEmitProcessTermination else { return }
        didEmitProcessTermination = true
        Log.info("RustTerminalView[\(viewId)]: Process terminated (\(reason), exitCode=\(String(describing: exitCode)))")
        DispatchQueue.main.async { [weak self] in
            self?.onProcessTerminated?(exitCode)
        }
    }

    @discardableResult
    private func drainPTYAndProcessTerminalState(rust: RustTerminalFFI) -> Bool {
        terminalPollAccessLock.lock()
        defer { terminalPollAccessLock.unlock() }
        let flags = rust.pollEvents(timeout: 0)
        return processTerminalStateAfterPollLocked(
            rust: rust,
            changed: flags.contains(.gridChanged)
        )
    }

    @discardableResult
    func processTerminalStateAfterPollLocked(rust: RustTerminalFFI, changed: Bool) -> Bool {
        if changed {
            retainedFrameContentVersion &+= 1
        }
        RenderPipelineProfiler.shared.recordPoll(
            viewID: viewId,
            changed: changed
        )

        // Check for bell events from Rust terminal and trigger audio/visual feedback
        if rust.checkBell() {
            handleBell()
        }

        // Check for current working directory change (OSC 7). Captured by the
        // Rust ANSI parser as bytes arrive — race-free even when multiple
        // Swift views share the same Rust terminal (the prior `last_output`
        // byte scan dropped OSC 7 whenever a sibling view drained first).
        if let cwdPayload = rust.getPendingCwd() {
            Log.info("RustTerminalView[\(viewId)]: OSC 7 sequence: \(cwdPayload)")
            processOSC7URL(cwdPayload)
        }

        // Check for terminal title changes (OSC 0/1/2)
        if let title = rust.getPendingTitle() {
            let stableTitle = TerminalTitleChurnPolicy.stableDisplayTitle(from: title)
            if TerminalTitleChurnPolicy.shouldDeliverTitle(
                title,
                lastDeliveredTitle: lastDeliveredTerminalTitle
            ) {
                lastDeliveredTerminalTitle = stableTitle
                if stableTitle != lastLoggedTitle {
                    Log.trace("RustTerminalView[\(viewId)]: Terminal title changed to \"\(stableTitle)\"")
                    lastLoggedTitle = stableTitle
                }
                DispatchQueue.main.async { [weak self] in
                    self?.onTitleChanged?(stableTitle)
                }
            }
        }

        // Check for clipboard events (OSC 52). These fire on every terminal
        // copy/paste so they're logged at .debug rather than .info to avoid
        // drowning the signal stream during AI-heavy sessions.
        if let clipboardText = rust.getPendingClipboard() {
            Log.debug("RustTerminalView[\(viewId)]: OSC 52 clipboard store: \(clipboardText.count) chars")
            DispatchQueue.main.async {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(clipboardText, forType: .string)
            }
        }
        if rust.hasClipboardRequest() {
            Log.debug("RustTerminalView[\(viewId)]: OSC 52 clipboard load request")
            let clipboardContent = NSPasteboard.general.string(forType: .string) ?? ""
            rust.respondClipboard(text: clipboardContent)
        }

        // Check for OSC 133 shell integration events
        let shellEvents = rust.getPendingShellIntegrationEvents()
        if !shellEvents.isEmpty {
            DispatchQueue.main.async { [weak self] in
                for event in shellEvents {
                    self?.onShellIntegrationEvent?(event)
                }
            }
        }

        // Check for child process exit
        if let exitCode = rust.getPendingExitCode() {
            emitProcessTerminatedOnce(exitCode: exitCode, reason: "exit-code")
        }

        // Check for PTY closed (without exit code - e.g., connection lost)
        if rust.isPtyClosed() {
            emitProcessTerminatedOnce(exitCode: nil, reason: "pty-closed")
        }

        // Update application cursor mode (DECCKM) from terminal state
        // This affects how arrow keys are encoded (CSI vs SS3 sequences)
        let cursorMode = rust.isApplicationCursorMode()
        if cursorMode != applicationCursorMode {
            applicationCursorMode = cursorMode
            Log.trace("RustTerminalView[\(viewId)]: Application cursor mode changed to \(cursorMode)")
        }

        // Retrieve raw output bytes from the last poll and forward to onOutput callback.
        // This enables shell integration, logging, and output detectors to receive data.
        // (Ensures onOutput callback fires so shell integration and detectors receive data)
        if var outputData = rust.getLastOutput(), !outputData.isEmpty {
            // Cancel the shell-startup-slow timer on first PTY output
            if startupBytesLogged == 0 {
                isAwaitingInitialPTYOutput = false
                shellStartupTimeoutWork?.cancel()
                shellStartupTimeoutWork = nil
                updatePollingMode(reason: "firstPTYOutput")
            }

            // Keep raw PTY startup previews out of the main log unless trace is enabled.
            if startupBytesLogged < 2048 {
                let bytesToLog = min(outputData.count, 2048 - startupBytesLogged)
                let preview = outputData.prefix(bytesToLog)
                let printable = preview.map { b -> Character in
                    if b >= 32, b < 127 { return Character(UnicodeScalar(b)) }
                    else if b == 10 { return "↵" }
                    else if b == 13 { return "←" }
                    else if b == 27 { return "⎋" }
                    else { return "·" }
                }
                Log.trace("RustTerminalView[\(viewId)]: PTY startup output (\(outputData.count) bytes): \(String(printable))")
                startupBytesLogged += bytesToLog
            }

            let extraction = extractInlineImages(from: outputData)
            outputData = extraction.0
            if !extraction.1.isEmpty, notifyUpdateChanges {
                renderInlineImages(extraction.1)
            }

            // Phase 4: Check for Rust-intercepted image sequences (Sixel, Kitty).
            // iTerm2 images are still handled by the Swift extractInlineImages path above,
            // since the raw bytes pass through last_output before the Rust interceptor.
            // Sixel/Kitty images only come through this Rust path.
            if let images = rust.getPendingImages() {
                for img in images {
                    let protocolName = img.protocol == 0 ? "iTerm2" : img.protocol == 1 ? "Sixel" : "Kitty"
                    Log.info("RustTerminalView[\(viewId)]: Received \(protocolName) image (\(img.data.count) bytes) at row=\(img.anchorRow), col=\(img.anchorCol)")
                    // TODO: Sixel decoding → RGBA → InlineImageView (Phase 4 future)
                    // TODO: Kitty protocol state management (Phase 4 future)
                    // For now, images are intercepted and logged. The infrastructure is in place
                    // for Sixel/Kitty rendering when decoders are added.
                }
            }

            // Parse Chau7 shell integration markers before prompt/CWD handling so
            // downstream prompt detection can consume the reported exit status.
            parseOSC9Events(from: outputData)

            // OSC 7 now handled by Rust ANSI parser via `getPendingCwd` above —
            // see processTerminalStateAfterPollLocked. Swift no longer scans
            // raw bytes for OSC 7, which closes the multi-view drain race.

            // Smart Scroll: Save state before feeding data to the renderer
            // If user had scrolled up and smart scroll is enabled, we'll restore their position
            let smartScrollEnabled = FeatureSettings.shared.isSmartScrollEnabled
            let wasAtBottom = isUserAtBottom
            let savedScrollPosition = scrollPosition

            // Smart Scroll: Restore position if user wasn't at bottom
            if notifyUpdateChanges {
                restoreSmartScrollIfNeeded(
                    smartScrollEnabled: smartScrollEnabled,
                    wasAtBottom: wasAtBottom,
                    savedPosition: savedScrollPosition
                )
            }

            if !outputData.isEmpty {
                onOutput?(outputData)
            }
        }

        return changed
    }

    private func presentLatestTerminalStateFromPump() {
        Self.syncCount += 1
        instanceSyncCount += 1
        needsGridSync = false

        if !isMetalRenderingActive {
            syncGridToRenderer(force: true)
            updateDangerousRowTints()
            gridView?.tickCursorBlink(now: CFAbsoluteTimeGetCurrent())
        }

        onBufferChanged?()
        onDisplaySyncNeeded?()
    }

    func performAuthoritativeRevealPass(reason: String) {
        guard !isBeingDeallocated else { return }
        guard let rust = rustTerminal else { return }

        updatePollingMode(reason: "authoritativeReveal:\(reason)")

        let changed = drainPTYAndProcessTerminalState(rust: rust)
        let requiresAuthoritativeReveal = consumeAuthoritativeRevealPending()

        if changed || needsGridSync || requiresAuthoritativeReveal {
            Self.syncCount += 1
            instanceSyncCount += 1
            needsGridSync = false
            if !isMetalRenderingActive {
                syncGridToRenderer(force: requiresAuthoritativeReveal)
            }
            onBufferChanged?()
            onDisplaySyncNeeded?()
        }

        if !isMetalRenderingActive {
            updateDangerousRowTints()
            gridView?.tickCursorBlink(now: CFAbsoluteTimeGetCurrent())
        }
    }

    func pollAndSync() {
        let startedAt = CFAbsoluteTimeGetCurrent()
        defer {
            let durationMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0
            WakeupProfiler.shared.record("terminal.pollAndSync", durationMs: durationMs)
            FeatureProfiler.shared.record(feature: .terminalPoll, durationMs: durationMs)
        }
        guard !isBeingDeallocated else { return }
        guard let rust = rustTerminal else { return }

        // Poll the Rust terminal to drain PTY buffer (non-blocking).
        let changed = drainPTYAndProcessTerminalState(rust: rust)

        // Skip UI updates when suspended — PTY is drained above.
        guard notifyUpdateChanges else { return }

        if changed || needsGridSync {
            Self.syncCount += 1
            instanceSyncCount += 1
            needsGridSync = false
            let requiresAuthoritativeReveal = consumeAuthoritativeRevealPending()
            // When Metal is active, skip the CPU sync — Metal reads the grid
            // directly via its gridProvider closure.
            if !isMetalRenderingActive {
                syncGridToRenderer(force: requiresAuthoritativeReveal)
            }
            onBufferChanged?()
            onDisplaySyncNeeded?()
        }

        if !isMetalRenderingActive {
            updateDangerousRowTints()
            gridView?.tickCursorBlink(now: CFAbsoluteTimeGetCurrent())
        }

        // Rate-limited status logging
        Self.pollAndSyncCounter += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - Self.lastPollAndSyncLogTime > 10.0 {
            Log.trace("RustTerminalView[\(viewId)]: pollAndSync - Status: \(Self.pollAndSyncCounter) polls, \(Self.syncCount) syncs")
            Self.lastPollAndSyncLogTime = now
        }
    }

    // MARK: - Metal GPU Rendering Support

    /// Creates a grid provider closure for the RustMetalDisplayCoordinator.
    /// Returns nil if the Rust terminal is not available (library not loaded).
    /// The closure captures the FFI instance and provides grid snapshot + cursor + free.
    func makeGridProvider() -> RustGridProvider? {
        guard let rust = rustTerminal else {
            Log.warn("RustTerminalView[\(viewId)]: makeGridProvider - No Rust terminal available")
            return nil
        }

        return { [weak self, weak rust] in
            guard let rust = rust else { return nil }
            guard let (grid, freeGrid) = rust.getGrid() else { return nil }

            let cursor = rust.cursorPosition
            let cursorVisible = grid.pointee.cursor_visible != 0
            self?.cachedScrollbackRows = Int(grid.pointee.scrollback_rows)
            // grid is UnsafeMutablePointer<RustGridSnapshot>, cast to raw for the generic provider
            let rawPtr = UnsafeMutableRawPointer(grid)
            return (grid: rawPtr, cursor: cursor, cursorVisible: cursorVisible, free: freeGrid)
        }
    }

    // MARK: - Grid Synchronization (Optimized with dirty-row tracking and rate limiting)

    /// Sync Rust terminal grid to the native renderer.
    /// Uses dirty row detection and rate limiting to minimize CPU usage during high-output scenarios.
    ///
    /// Optimizations implemented:
    /// 1. Rate limiting - Skip syncs that happen too close together (allows up to 120fps)
    /// 2. Unchanged grid detection - Skip entirely if grid and cursor haven't changed
    /// 3. Dirty row tracking - Only rebuild escape sequences for rows that actually changed
    /// 4. Partial sync - When fewer than half the rows changed, update only those rows
    /// 5. Efficient comparison - Cell-by-cell comparison with early exit per row
    func syncGridToRenderer(force: Bool = false) {
        guard let rust = rustTerminal else {
            Log.trace("RustTerminalView[\(viewId)]: syncGridToRenderer - No Rust terminal")
            return
        }

        // Rate limiting: Skip if we synced very recently (allows up to 120fps for responsiveness)
        let now = CFAbsoluteTimeGetCurrent()
        if !force, now - lastSyncTime < Self.minSyncInterval {
            skippedSyncCount += 1
            return
        }

        guard let (grid, freeGrid) = rust.getGrid() else {
            Log.trace("RustTerminalView[\(viewId)]: syncGridToRenderer - getGrid returned nil")
            return
        }
        defer { freeGrid() }

        let snapshot = grid.pointee
        guard let cells = snapshot.cells else {
            Log.trace("RustTerminalView[\(viewId)]: syncGridToRenderer - Grid has no cells")
            return
        }

        let gridCols = Int(snapshot.cols)
        let gridRows = Int(snapshot.rows)
        let totalCells = gridCols * gridRows
        let cursor = rust.cursorPosition
        let cursorVisible = snapshot.cursor_visible != 0

        logCursorInputRowDiagnosticIfNeeded(
            cells: cells,
            cols: gridCols,
            rows: gridRows,
            cursor: cursor,
            source: "cpu-grid"
        )

        // Cache scrollback size for renderTopVisibleRow (lightweight access)
        cachedScrollbackRows = Int(snapshot.scrollback_rows)

        // Update CPU renderer cursor visibility (DECTCEM)
        gridView?.cursorVisible = cursorVisible

        // Fast path: Check if grid dimensions changed (requires full rebuild)
        let dimensionsChanged = gridCols != previousGridCols || gridRows != previousGridRows

        // Determine which rows have changed by comparing with previous grid
        var dirtyRows: Set<Int> = []
        let canCompare = !force && !dimensionsChanged && previousGrid.count == totalCells
        var cursorMoved = false

        if canCompare {
            // Compare cell-by-cell to find dirty rows (with early exit per row)
            for row in 0 ..< gridRows {
                let rowStart = row * gridCols
                var rowDirty = false
                for col in 0 ..< gridCols {
                    let idx = rowStart + col
                    let newCell = cells[idx]
                    let oldCell = previousGrid[idx]

                    if !cellsEqual(newCell, oldCell) {
                        rowDirty = true
                        break // Row is dirty, no need to check more cells in this row
                    }
                }
                if rowDirty {
                    dirtyRows.insert(row)
                }
            }

            // Also check if cursor moved
            cursorMoved = cursor.col != previousCursorCol || cursor.row != previousCursorRow

            // If nothing changed at all, skip the sync entirely
            if dirtyRows.isEmpty, !cursorMoved {
                skippedSyncCount += 1
                return
            }
        }

        // Update timestamp for rate limiting
        lastSyncTime = now

        // Update previous state for next comparison
        previousGridCols = gridCols
        previousGridRows = gridRows
        previousCursorCol = cursor.col
        previousCursorRow = cursor.row

        if canCompare, dirtyRows.isEmpty, cursorMoved {
            gridView?.updateCursor(cursor)
        } else {
            // Copy current grid for future comparison using efficient buffer copy
            previousGrid.removeAll(keepingCapacity: true)
            previousGrid.reserveCapacity(totalCells)
            let cellBuffer = UnsafeBufferPointer(start: cells, count: totalCells)
            previousGrid.append(contentsOf: cellBuffer)

            let usePartialSync = GridSyncStrategyPolicy.shouldUsePartialSync(
                canCompare: canCompare,
                dirtyRowCount: dirtyRows.count,
                gridRows: gridRows
            )

            if usePartialSync {
                partialSyncCount += 1
                Log.trace("RustTerminalView[\(viewId)]: syncGridToRenderer - Partial sync for \(dirtyRows.count)/\(gridRows) dirty rows")
                gridView?.updateGrid(
                    cells: cells,
                    clusters: snapshot.clusters_utf8,
                    clustersLen: snapshot.clusters_len,
                    cols: gridCols,
                    rows: gridRows,
                    cursor: cursor,
                    dirtyRows: dirtyRows
                )
            } else {
                fullSyncCount += 1
                Log.trace("RustTerminalView[\(viewId)]: syncGridToRenderer - Full sync for \(gridCols)x\(gridRows) grid (dims changed: \(dimensionsChanged), dirty: \(dirtyRows.count))")
                gridView?.updateGrid(
                    cells: cells,
                    clusters: snapshot.clusters_utf8,
                    clustersLen: snapshot.clusters_len,
                    cols: gridCols,
                    rows: gridRows,
                    cursor: cursor,
                    dirtyRows: nil
                )
            }
        }

        hasRetainedFrameSourceReady = true
        retainedFrameSourceVersion = retainedFrameContentVersion

        // Periodic stats logging (every 1000 syncs)
        if (fullSyncCount + partialSyncCount).isMultiple(of: 1000) {
            Log.trace("RustTerminalView[\(viewId)]: syncStats - full:\(fullSyncCount) partial:\(partialSyncCount) skipped:\(skippedSyncCount)")
        }

        updateInlineImagePositions()
    }

    func logCursorInputRowDiagnosticIfNeeded(
        cells: UnsafePointer<RustCellData>,
        cols: Int,
        rows: Int,
        cursor: (col: UInt16, row: UInt16),
        source: String
    ) {
        guard cols > 0, rows > 0 else { return }
        let cursorRow = Int(cursor.row)
        let cursorCol = Int(cursor.col)
        guard cursorRow >= 0, cursorRow < rows else { return }
        let absRow = renderTopVisibleRow + cursorRow

        // Anomaly detection — only on the Metal-render path, since cpu-grid
        // gets its absRow recomputed via fresh `cachedScrollbackRows` and
        // legitimately moves with scrollback growth. The Metal path reads
        // `cachedScrollbackRows` (last value written by the cpu path) and
        // `cursor.row` together; large absRow jumps between consecutive
        // metal-grid calls indicate either a real scroll storm OR the
        // grid/cursor desync producing the visible "output overflowing
        // input field, mixed glyphs" symptom. Flag for offline inspection.
        if source == "metal-grid", EnvVars.isEnabled(EnvVars.inputDiagnostics) {
            if let previous = lastMetalGridAbsRow {
                let delta = absRow - previous
                if abs(delta) > Self.metalGridAnomalyDeltaThreshold {
                    TerminalOutputCapture.shared.recordMarker(
                        "view=\(viewId) source=metal-grid absRow_jump previous=\(previous) current=\(absRow) delta=\(delta) viewportRow=\(cursorRow) cursorCol=\(cursorCol) renderTopVisibleRow=\(renderTopVisibleRow) cachedScrollbackRows=\(cachedScrollbackRows)"
                    )
                }
            }
            lastMetalGridAbsRow = absRow
        }

        guard EnvVars.isEnabled(EnvVars.renderRowDiagnostics) else { return }

        let rowCells = UnsafeBufferPointer(
            start: cells.advanced(by: cursorRow * cols),
            count: cols
        )
        let window = Self.diagnosticWindow(for: rowCells, cursorCol: cursorCol)
        guard !window.isEmpty else { return }

        var hasher = Hasher()
        hasher.combine(source)
        hasher.combine(absRow)
        hasher.combine(cursorCol)
        hasher.combine(window.lowerBound)
        hasher.combine(window.upperBound)
        for col in window {
            let cell = rowCells[col]
            hasher.combine(cell.cluster_offset)
            hasher.combine(cell.cluster_len)
            hasher.combine(cell.flags)
            hasher.combine(cell.underline_style)
        }
        let diagnosticKey = "\(source):\(hasher.finalize())"
        guard diagnosticKey != lastInputRowDiagnosticKey else { return }
        lastInputRowDiagnosticKey = diagnosticKey

        // Diagnostic preview omits cluster bytes — those live in the snapshot's
        // clusters buffer which isn't threaded into this helper. Renderer-side
        // diagnostics in MetalTerminalRenderer show the actual bytes.
        let cellSummary = window.map { col -> String in
            let cell = rowCells[col]
            return "\(col):L=\(cell.cluster_len)/w=\(cell.width)\(cell.continuation != 0 ? "/CONT" : "") f=\(String(format: "%02X", cell.flags)) u=\(cell.underline_style & 0x07)"
        }.joined(separator: " ")
        let textPreview = ""

        Log.debug(
            "RustTerminalView[\(viewId)]: input-row diag source=\(source) absRow=\(absRow) viewportRow=\(cursorRow) cursorCol=\(cursorCol) cols=\(window.lowerBound)-\(window.upperBound) text=\(textPreview.debugDescription) cells=[\(cellSummary)]"
        )
    }

    /// Threshold used by the metal-grid anomaly detector. A normal newline
    /// produces +1 absRow; small scrolls produce a few rows. Jumps larger
    /// than this are suspicious enough to warrant marking the PTY log.
    /// Tuned to skip routine page-up/page-down (~viewport rows) but catch
    /// the desync pattern observed on Redb (cells shifting many rows).
    private static let metalGridAnomalyDeltaThreshold = 5

    private static func diagnosticWindow(
        for rowCells: UnsafeBufferPointer<RustCellData>,
        cursorCol: Int,
        maxWidth: Int = 48
    ) -> ClosedRange<Int> {
        guard !rowCells.isEmpty else { return 0 ... 0 }
        let cursor = min(max(cursorCol, 0), rowCells.count - 1)
        let interestingCols = rowCells.indices.filter { col in
            let cell = rowCells[col]
            return col == cursor || cell.cluster_len > 0 || cell.flags != 0 || cell.underline_style != 0
        }

        let rawStart = interestingCols.min() ?? cursor
        let rawEnd = interestingCols.max() ?? cursor
        var start = max(0, rawStart - 2)
        var end = min(rowCells.count - 1, rawEnd + 2)

        if end - start + 1 > maxWidth {
            start = max(0, cursor - (maxWidth / 2))
            end = min(rowCells.count - 1, start + maxWidth - 1)
            start = max(0, end - maxWidth + 1)
        }

        return start ... end
    }

    /// Updates the grid view's row tints from the danger tints provider.
    /// Runs every display-link frame — the provider returns cached data so this is cheap.
    func updateDangerousRowTints() {
        guard let provider = dangerousRowTintsProvider else {
            if !(gridView?.rowTints.isEmpty ?? true) {
                gridView?.rowTints = [:]
            }
            return
        }
        let yDisp = renderTopVisibleRow
        let gridRows = rows
        guard gridRows > 0 else { return }
        let tints = provider(yDisp, yDisp + gridRows - 1)
        var viewportTints: [Int: NSColor] = [:]
        for (absRow, color) in tints {
            let vr = absRow - yDisp
            if vr >= 0, vr < gridRows {
                viewportTints[vr] = color
            }
        }
        gridView?.rowTints = viewportTints
    }

    /// Compare two cells for equality (inlined for performance).
    /// `cluster_offset` is unstable across frames (snapshot rebuilds the buffer
    /// from scratch), so cells whose only difference is offset will trigger an
    /// over-paint of their row. That's preferable to hashing the bytes on the
    /// hot path; the actual byte-content equality check lives in
    /// `clusterBytesEqual(...)` for callers that need it.
    @inline(__always)
    func cellsEqual(_ a: RustCellData, _ b: RustCellData) -> Bool {
        return a.cluster_offset == b.cluster_offset &&
            a.cluster_len == b.cluster_len &&
            a.width == b.width &&
            a.continuation == b.continuation &&
            a.fg_r == b.fg_r && a.fg_g == b.fg_g && a.fg_b == b.fg_b &&
            a.bg_r == b.bg_r && a.bg_g == b.bg_g && a.bg_b == b.bg_b &&
            a.flags == b.flags && a.underline_style == b.underline_style && a.link_id == b.link_id
    }

    /// Reset grid sync state (call on resize or other major changes)
    func resetGridSyncState() {
        previousGrid.removeAll()
        previousGridCols = 0
        previousGridRows = 0
        previousCursorCol = 0
        previousCursorRow = 0
        hasRetainedFrameSourceReady = false
        retainedFrameSourceVersion = 0
        needsGridSync = true
    }

    func hideTipOverlay() {
        tipOverlayView?.removeFromSuperview()
        tipOverlayView = nil
    }

    func updateTipOverlayPosition() {
        guard let tip = tipOverlayView else { return }
        let size = tip.frame.size
        let renderBounds = overlayContainer?.bounds ?? bounds
        let origin = NSPoint(x: (renderBounds.width - size.width) / 2, y: renderBounds.height - size.height - 20)
        tip.frame.origin = origin
    }

    func showTipOverlay(message: String) {
        guard tipOverlayView == nil else { return }
        let container = PassthroughView(frame: .zero)
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        container.layer?.cornerRadius = 8
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        let label = NSTextField(labelWithString: message)
        label.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        label.textColor = NSColor.labelColor
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let padding: CGFloat = 10
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: padding),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -padding),
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: padding),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -padding)
        ])

        overlayContainer.addSubview(container)
        tipOverlayView = container

        let renderBounds = overlayContainer?.bounds ?? bounds
        let maxWidth = min(renderBounds.width * 0.75, 460)
        let maxLabelWidth = maxWidth - (padding * 2)
        let labelRect = label.attributedStringValue.boundingRect(
            with: NSSize(width: maxLabelWidth, height: 200),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        let labelSize = NSSize(width: ceil(labelRect.width), height: ceil(labelRect.height))
        let containerSize = NSSize(width: maxWidth, height: labelSize.height + (padding * 2))
        let origin = NSPoint(x: (renderBounds.width - containerSize.width) / 2, y: renderBounds.height - containerSize.height - 20)
        container.frame = NSRect(origin: origin, size: containerSize)
    }

    func extractInlineImages(from data: Data) -> (Data, [InlineImage]) {
        guard InlineImageHandler.shared.isEnabled else { return (data, []) }
        guard let text = String(data: data, encoding: .utf8) else { return (data, []) }

        let marker = "\u{1b}]1337;File="
        var output = String()
        output.reserveCapacity(text.count)
        var images: [InlineImage] = []

        var idx = text.startIndex
        while idx < text.endIndex {
            if text[idx...].hasPrefix(marker) {
                var end = idx
                var foundTerminator = false
                var scan = idx
                while scan < text.endIndex {
                    let ch = text[scan]
                    if ch == "\u{07}" {
                        end = scan
                        foundTerminator = true
                        scan = text.index(after: scan)
                        break
                    }
                    if ch == "\u{1b}" {
                        let next = text.index(after: scan)
                        if next < text.endIndex, text[next] == "\\" {
                            end = scan
                            foundTerminator = true
                            scan = text.index(after: next)
                            break
                        }
                    }
                    scan = text.index(after: scan)
                }

                if foundTerminator {
                    let seq = String(text[idx ..< end])
                    if let image = InlineImageHandler.shared.parseImageSequence(seq) {
                        images.append(image)
                    }
                    idx = scan
                    continue
                }
            }

            output.append(text[idx])
            idx = text.index(after: idx)
        }

        return (Data(output.utf8), images)
    }

    func renderInlineImages(_ images: [InlineImage]) {
        guard let rust = rustTerminal else { return }
        guard InlineImageHandler.shared.isEnabled else { return }
        let cellSize = NSSize(width: cellWidth, height: cellHeight)
        let maxCells = (width: cols, height: rows)
        let cursor = rust.cursorPosition
        let displayOffset = Int(rust.displayOffset)
        let anchorRow = Int(cursor.row) - displayOffset
        let anchorCol = Int(cursor.col)

        for image in images where image.args.inline {
            guard let scaled = InlineImageHandler.shared.renderImage(image, cellSize: cellSize, maxCells: maxCells) else {
                continue
            }
            let inline = InlineImage(image: scaled, args: image.args)
            let view = InlineImageView(image: inline, frame: .zero)
            overlayContainer.addSubview(view)
            var placement = InlineImagePlacement(view: view, args: image.args, size: scaled.size, anchorRow: anchorRow, anchorCol: anchorCol)
            positionInlineImage(&placement, displayOffset: displayOffset)
            inlineImages.append(placement)
        }
        pruneInlineImagesIfNeeded(displayOffset: displayOffset, reason: "append")
    }

    func rescaleInlineImages() {
        guard InlineImageHandler.shared.isEnabled else { return }
        let cellSize = NSSize(width: cellWidth, height: cellHeight)
        let maxCells = (width: cols, height: rows)
        for index in inlineImages.indices {
            let original = InlineImage(image: inlineImages[index].view.currentImage, args: inlineImages[index].args)
            if let scaled = InlineImageHandler.shared.renderImage(original, cellSize: cellSize, maxCells: maxCells) {
                inlineImages[index].size = scaled.size
                inlineImages[index].view.setImage(scaled)
            }
        }
        updateInlineImagePositions()
    }

    func updateInlineImagePositions() {
        guard let rust = rustTerminal else { return }
        let displayOffset = Int(rust.displayOffset)
        pruneInlineImagesIfNeeded(displayOffset: displayOffset, reason: "scroll")
        if displayOffset == lastDisplayOffset, !inlineImages.isEmpty {
            // Still update positions on resize/layout.
        }
        lastDisplayOffset = displayOffset

        for index in inlineImages.indices {
            var placement = inlineImages[index]
            positionInlineImage(&placement, displayOffset: displayOffset)
            inlineImages[index] = placement
        }
    }

    func positionInlineImage(_ placement: inout InlineImagePlacement, displayOffset: Int) {
        let visibleRow = placement.anchorRow + displayOffset
        guard visibleRow >= 0, visibleRow < rows else {
            placement.view.isHidden = true
            return
        }
        placement.view.isHidden = false
        let x = CGFloat(placement.anchorCol) * cellWidth
        let renderHeight = overlayContainer?.bounds.height ?? (gridView?.bounds.height ?? bounds.height)
        let topY = renderHeight - CGFloat(visibleRow) * cellHeight
        let y = topY - placement.size.height
        placement.view.frame = CGRect(x: x, y: y, width: placement.size.width, height: placement.size.height)
    }

    func pruneInlineImagesIfNeeded(displayOffset: Int, reason: String) {
        guard !inlineImages.isEmpty else { return }

        let retainedIndices = RenderMemoryPressurePolicy.retainedInlineImageIndices(
            anchorRows: inlineImages.map(\.anchorRow),
            displayOffset: displayOffset,
            visibleRows: rows,
            rowMargin: Self.inlineImageRetentionRowMargin,
            maxRetained: Self.maxRetainedInlineImages
        )
        guard retainedIndices.count != inlineImages.count else { return }

        let retainedSet = Set(retainedIndices)
        var retainedPlacements: [InlineImagePlacement] = []
        retainedPlacements.reserveCapacity(retainedIndices.count)

        for (index, placement) in inlineImages.enumerated() {
            if retainedSet.contains(index) {
                retainedPlacements.append(placement)
            } else {
                placement.view.removeFromSuperview()
            }
        }

        Log.warn(
            "RustTerminalView[\(viewId)]: pruned inline images removed=\(inlineImages.count - retainedPlacements.count) remaining=\(retainedPlacements.count) reason=\(reason)"
        )
        inlineImages = retainedPlacements
    }

    func clearInlineImages() {
        guard !inlineImages.isEmpty else { return }
        inlineImages.forEach { $0.view.removeFromSuperview() }
        inlineImages.removeAll(keepingCapacity: false)
    }

    // MARK: - OSC 9 parsing

    func parseOSC9Events(from data: Data) {
        let events = osc9Parser.ingest(data)
        guard !events.isEmpty else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for event in events {
                switch event {
                case .chau7(key: "exit", value: let value):
                    guard let exitCode = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
                    onExitStatusChanged?(exitCode)
                case .chau7(key: "branch", value: let value):
                    onBranchChanged?(value)
                case .chau7(key: "repo-root", value: let value):
                    onRepoRootChanged?(value)
                case .chau7:
                    continue
                case .foreign(message: let message):
                    onForeignDesktopNotification?(message)
                }
            }
        }
    }

    /// Process the URL from OSC 7 and extract the directory path.
    /// URL format: file://hostname/path
    func processOSC7URL(_ urlString: String) {
        // Parse the file:// URL
        if let url = URL(string: urlString) {
            let path = url.path
            if path.isEmpty {
                Log.warn("RustTerminalView[\(viewId)]: OSC 7 URL parsed but path empty: \(urlString)")
                return
            }
            if path == currentDirectory {
                Log.info("RustTerminalView[\(viewId)]: OSC 7 same-cwd: \(path)")
                return
            }
            Log.info("RustTerminalView[\(viewId)]: OSC 7 directory update: \(path)")
            currentDirectory = path
            DispatchQueue.main.async { [weak self] in
                self?.onDirectoryChanged?(path)
            }
        } else if urlString.hasPrefix("file://") {
            // Fallback: manual parsing for malformed URLs
            let pathStart = urlString.index(urlString.startIndex, offsetBy: 7)
            var path = String(urlString[pathStart...])
            // Remove hostname if present (format: file://hostname/path)
            if let slashIndex = path.firstIndex(of: "/") {
                path = String(path[slashIndex...])
            }
            // URL decode
            path = path.removingPercentEncoding ?? path
            if path.isEmpty {
                Log.warn("RustTerminalView[\(viewId)]: OSC 7 fallback parse produced empty path: \(urlString)")
                return
            }
            if path == currentDirectory {
                Log.info("RustTerminalView[\(viewId)]: OSC 7 same-cwd (fallback): \(path)")
                return
            }
            Log.info("RustTerminalView[\(viewId)]: OSC 7 directory update (fallback): \(path)")
            currentDirectory = path
            DispatchQueue.main.async { [weak self] in
                self?.onDirectoryChanged?(path)
            }
        } else {
            Log.warn("RustTerminalView[\(viewId)]: OSC 7 URL unrecognized scheme: \(urlString)")
        }
    }

}
