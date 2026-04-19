import AppKit
import QuartzCore
import Chau7Core

// MARK: - Rendering, Grid Sync, and Display Link

extension RustTerminalView {
    func refreshObservabilityTimerScope() {
        Chau7ObservabilityService.shared.updateTimerScope(
            renderLoopTimerID,
            tabID: observabilityTabID,
            sessionID: observabilitySessionID
        )
    }

    // MARK: - Polling Loop

    func setupPollingLoop() {
        Log.trace("RustTerminalView[\(viewId)]: setupPollingLoop - Creating polling loop")

        // Try CVDisplayLink first for vsync-aligned updates
        var link: CVDisplayLink?
        let result = CVDisplayLinkCreateWithActiveCGDisplays(&link)

        if result == kCVReturnSuccess, let link = link {
            let box = DisplayLinkWeakBox(self)
            displayLinkBox = box
            CVDisplayLinkSetOutputCallback(link, { _, _, _, _, _, userInfo -> CVReturn in
                guard let userInfo = userInfo else { return kCVReturnSuccess }
                let box = Unmanaged<DisplayLinkWeakBox>.fromOpaque(userInfo).takeUnretainedValue()
                guard let view = box.view else { return kCVReturnSuccess }
                WakeupProfiler.shared.record("terminal.displayLink")
                DispatchQueue.main.async { [weak view] in
                    view?.pollAndSync()
                }
                return kCVReturnSuccess
            }, Unmanaged.passRetained(box).toOpaque())

            CVDisplayLinkStart(link)
            displayLink = link
            RenderPipelineProfiler.shared.updateRenderLoopState(
                viewID: viewId,
                active: true,
                tabID: observabilityTabID,
                sessionID: observabilitySessionID,
                mode: "display_link",
                reasons: profilerReasons
            )
            Chau7ObservabilityService.shared.registerTimer(
                id: renderLoopTimerID,
                kind: "display_link",
                label: "terminal-render-loop",
                subsystem: "renderer",
                queueLabel: "com.chau7.renderer.main",
                intervalMs: displayRefreshInterval * 1000,
                leewayMs: 0,
                active: true,
                tabID: observabilityTabID,
                sessionID: observabilitySessionID
            )
            Log.info("RustTerminalView[\(viewId)]: setupPollingLoop - Using CVDisplayLink for 60fps polling")
        } else {
            Log.warn("RustTerminalView[\(viewId)]: setupPollingLoop - CVDisplayLink failed (result=\(result)), falling back to Timer")
            pollTimer = Timer.scheduledTimer(withTimeInterval: displayRefreshInterval, repeats: true) { [weak self] _ in
                WakeupProfiler.shared.record("terminal.pollTimer")
                self?.pollAndSync()
            }
            RenderPipelineProfiler.shared.updateRenderLoopState(
                viewID: viewId,
                active: true,
                tabID: observabilityTabID,
                sessionID: observabilitySessionID,
                mode: "timer",
                reasons: profilerReasons
            )
            Chau7ObservabilityService.shared.registerTimer(
                id: renderLoopTimerID,
                kind: "timer",
                label: "terminal-render-loop",
                subsystem: "renderer",
                queueLabel: "com.chau7.renderer.main",
                intervalMs: displayRefreshInterval * 1000,
                leewayMs: 0,
                active: true,
                tabID: observabilityTabID,
                sessionID: observabilitySessionID
            )
            Log.info("RustTerminalView[\(viewId)]: setupPollingLoop - Using Timer fallback for polling")
        }
        updatePollingMode(reason: "setupPollingLoop")
    }

    func stopPollingLoop() {
        Log.trace("RustTerminalView[\(viewId)]: stopPollingLoop - Stopping polling loop")
        // Clear adaptive-polling state so a future setupPollingLoop starts clean.
        consecutiveIdlePolls = 0
        isIdleThrottled = false
        currentActiveHz = nil
        if let link = displayLink {
            Log.trace("RustTerminalView[\(viewId)]: stopPollingLoop - Stopping CVDisplayLink")
            CVDisplayLinkStop(link)
            displayLink = nil
        }
        // Release the retained DisplayLinkWeakBox. After CVDisplayLinkStop
        // completes, no more callbacks will fire, so it's safe to release.
        if let box = displayLinkBox {
            Unmanaged.passUnretained(box).release()
            displayLinkBox = nil
        }
        if pollTimer != nil {
            Log.trace("RustTerminalView[\(viewId)]: stopPollingLoop - Invalidating Timer")
            pollTimer?.invalidate()
            pollTimer = nil
        }
        RenderPipelineProfiler.shared.updateRenderLoopState(
            viewID: viewId,
            active: false,
            tabID: observabilityTabID,
            sessionID: observabilitySessionID,
            mode: "stopped",
            reasons: profilerReasons
        )
        Chau7ObservabilityService.shared.setTimerActive(renderLoopTimerID, active: false)
        BackgroundTerminalDrainService.shared.unregister(self)
    }

    // MARK: - Display Link Pause/Resume (Background Tab Optimization)

    /// Pause the CVDisplayLink and start a slow background drain timer.
    /// Background tabs only need to drain the PTY buffer to prevent the shell from
    /// blocking — they don't need 60fps rendering. A 500ms timer is sufficient.
    func pauseDisplayLink() {
        // Keep shell bootstrap state alive until first PTY bytes or the actual
        // startup timeout. An early pause during restore/window attachment must
        // not silently end startup polling, or shells can appear hung forever.
        if !isAwaitingInitialPTYOutput {
            shellStartupTimeoutWork?.cancel()
            shellStartupTimeoutWork = nil
        }

        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
            Log.info("RustTerminalView[\(viewId)]: pauseDisplayLink - CVDisplayLink paused (tab suspended)")
        }
        pollTimer?.invalidate()
        pollTimer = nil
        // Idle throttle is an active-loop concept — leaving the active loop
        // clears it so the next resume picks the right Hz from scratch.
        consecutiveIdlePolls = 0
        isIdleThrottled = false
        currentActiveHz = nil
        RenderPipelineProfiler.shared.updateRenderLoopState(
            viewID: viewId,
            active: false,
            tabID: observabilityTabID,
            sessionID: observabilitySessionID,
            mode: "background_drain",
            reasons: profilerReasons
        )
        Chau7ObservabilityService.shared.setTimerActive(renderLoopTimerID, active: false)

        BackgroundTerminalDrainService.shared.register(self)
    }

    /// Resume active polling and stop the slow background drain.
    /// Chooses CVDisplayLink (display-native refresh) or Timer (capped or idle-
    /// throttled) based on `effectiveActiveHz()`. Forces an immediate full sync
    /// so the user sees current content without waiting for the next tick.
    func resumeDisplayLink() {
        BackgroundTerminalDrainService.shared.unregister(self)

        let targetHz = effectiveActiveHz() // nil = CVDisplayLink at native refresh

        if targetHz == nil {
            // Native refresh via CVDisplayLink.
            pollTimer?.invalidate()
            pollTimer = nil
            currentActiveHz = nil

            if let link = displayLink, !CVDisplayLinkIsRunning(link) {
                CVDisplayLinkStart(link)
                publishRenderLoopProfiling(mode: "display_link", intervalMs: displayRefreshInterval * 1000, kind: "display_link")
                Log.info("RustTerminalView[\(viewId)]: resumeDisplayLink - CVDisplayLink resumed (native refresh)")
            } else if displayLink == nil, pollTimer == nil {
                // Display link unavailable — fall back to a timer at native refresh.
                installActivePollTimer(intervalSeconds: displayRefreshInterval)
            }
        } else {
            // Capped or idle-throttled — drive the loop from a Timer at targetHz.
            if let link = displayLink, CVDisplayLinkIsRunning(link) {
                CVDisplayLinkStop(link)
            }
            let interval = 1.0 / Double(targetHz!)
            if pollTimer == nil || currentActiveHz != targetHz {
                installActivePollTimer(intervalSeconds: interval)
                currentActiveHz = targetHz
            }
        }

        // Force an immediate sync so the user sees fresh content
        needsGridSync = true
        pollAndSync()
    }

    /// Replaces `pollTimer` with a fresh `Timer.scheduledTimer` on the main run
    /// loop at the given interval and publishes the render-loop profiling state.
    private func installActivePollTimer(intervalSeconds: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            WakeupProfiler.shared.record("terminal.pollTimer")
            self?.pollAndSync()
        }
        publishRenderLoopProfiling(mode: "timer", intervalMs: intervalSeconds * 1000, kind: "timer")
    }

    private func publishRenderLoopProfiling(mode: String, intervalMs: Double, kind: String) {
        RenderPipelineProfiler.shared.updateRenderLoopState(
            viewID: viewId,
            active: true,
            tabID: observabilityTabID,
            sessionID: observabilitySessionID,
            mode: mode,
            reasons: profilerReasons
        )
        Chau7ObservabilityService.shared.registerTimer(
            id: renderLoopTimerID,
            kind: kind,
            label: "terminal-render-loop",
            subsystem: "renderer",
            queueLabel: "com.chau7.renderer.main",
            intervalMs: intervalMs,
            leewayMs: 0,
            active: true,
            tabID: observabilityTabID,
            sessionID: observabilitySessionID
        )
    }

    /// Visible but noninteractive tabs stay current at a lower cadence so they
    /// do not burn a full display link when they are simply being observed.
    func resumeTimerPolling() {
        BackgroundTerminalDrainService.shared.unregister(self)

        if let link = displayLink, CVDisplayLinkIsRunning(link) {
            CVDisplayLinkStop(link)
        }
        // Passive mode runs at its own fixed cadence — clear any active-loop
        // idle-throttle state to avoid Hz confusion when we return to active.
        consecutiveIdlePolls = 0
        isIdleThrottled = false
        currentActiveHz = nil
        if pollTimer == nil {
            pollTimer = Timer.scheduledTimer(
                withTimeInterval: Self.passiveVisiblePollingInterval,
                repeats: true
            ) { [weak self] _ in
                WakeupProfiler.shared.record("terminal.pollTimer")
                self?.pollAndSync()
            }
        }
        RenderPipelineProfiler.shared.updateRenderLoopState(
            viewID: viewId,
            active: true,
            tabID: observabilityTabID,
            sessionID: observabilitySessionID,
            mode: "timer",
            reasons: profilerReasons
        )
        Chau7ObservabilityService.shared.registerTimer(
            id: renderLoopTimerID,
            kind: "timer",
            label: "terminal-render-loop",
            subsystem: "renderer",
            queueLabel: "com.chau7.renderer.main",
            intervalMs: Self.passiveVisiblePollingInterval * 1000,
            leewayMs: 0,
            active: true,
            tabID: observabilityTabID,
            sessionID: observabilitySessionID
        )

        needsGridSync = true
        pollAndSync()
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
        let changed = rust.poll(timeout: 0)
        return processTerminalStateAfterPollLocked(rust: rust, changed: changed)
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

        // Check for terminal title changes (OSC 0/1/2)
        if let title = rust.getPendingTitle() {
            // Rate-limit: only log when the title actually changes (spinner animations
            // like ⠂/⠐/✳ trigger ~1 update/sec, producing 10K+ log entries/day)
            if title != lastLoggedTitle {
                Log.trace("RustTerminalView[\(viewId)]: Terminal title changed to \"\(title)\"")
                lastLoggedTitle = title
            }
            DispatchQueue.main.async { [weak self] in
                self?.onTitleChanged?(title)
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
            parseChau7Exit(from: outputData)

            // Parse OSC 7 (current working directory) before processing
            // OSC 7 format: ESC ] 7 ; file://hostname/path BEL
            parseOSC7(from: outputData)

            // Parse OSC 9 chau7 shell integration reports (git branch + repo root)
            // Format: ESC ] 9 ; chau7;branch=NAME BEL
            //         ESC ] 9 ; chau7;repo-root=PATH BEL
            parseChau7Branch(from: outputData)
            parseChau7RepoRoot(from: outputData)

            // Parse OSC 9 desktop notifications emitted by foreign programs
            // (e.g. Codex CLI TUI). Format: ESC ] 9 ; <message> BEL where the
            // message does NOT start with "chau7;" (those are handled above).
            parseForeignDesktopNotifications(from: outputData)

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

            // LOCAL ECHO SUPPRESSION: Filter out characters we already displayed locally
            // This prevents "double echo" when PTY confirms what we predicted
            outputData = processOutputForLocalEcho(outputData)

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
        // Safety: Check if view is being deallocated (CVDisplayLink callback protection)
        guard !isBeingDeallocated else { return }
        guard let rust = rustTerminal else { return }

        // ALWAYS poll the Rust terminal to drain PTY buffer, even when suspended.
        // This prevents the PTY reader thread from blocking when the buffer fills up.
        // (Without this, suspended state blocks the PTY by not draining its buffer)
        //
        // Selection preservation: Rust manages selection state internally. If poll()
        // processes output that scrolls the terminal, Rust may clear its selection.
        // During an active drag (isSelecting == true), the next mouseDragged event
        // re-establishes the selection via rust.updateSelection(). However, if the
        // user holds the mouse still during scrolling, no drag events fire and the
        // selection stays cleared until the next mouse movement. The 60fps
        // CVDisplayLink render loop minimizes visible flicker in the common case.
        // If flicker becomes noticeable, a Rust FFI flag
        // (preserve_selection_during_scroll) would be the proper fix.
        let changed = drainPTYAndProcessTerminalState(rust: rust)

        // Adaptive-polling bookkeeping (Fix B). Must run before the snap-out
        // reconcile so the reconciler sees fresh state. Only tracked when live —
        // background drain maintains its own slow cadence independently.
        if notifyUpdateChanges {
            if changed {
                consecutiveIdlePolls = 0
                if isIdleThrottled {
                    // Snap back to the full-rate loop immediately; this same poll
                    // still finishes the UI work below so the first byte is
                    // visible on the current frame.
                    isIdleThrottled = false
                    updatePollingMode(reason: "idleExit")
                }
            } else {
                consecutiveIdlePolls &+= 1
            }
        }

        // Skip UI updates when suspended, but we've already drained the PTY above
        guard notifyUpdateChanges else { return }

        if changed || needsGridSync {
            Self.syncCount += 1
            instanceSyncCount += 1
            needsGridSync = false
            let requiresAuthoritativeReveal = consumeAuthoritativeRevealPending()
            // When Metal is active, skip the CPU sync — Metal reads the grid
            // directly via its gridProvider closure. This avoids ~70% CPU waste
            // from invisible RustGridView.draw() and cell array copies.
            if !isMetalRenderingActive {
                syncGridToRenderer(force: requiresAuthoritativeReveal)
            }
            onBufferChanged?()
            onDisplaySyncNeeded?()
        }

        // Skip downstream per-frame work when idle-throttled — the data didn't
        // change, so tints and cursor-blink work have nothing to do. Keeping
        // them in the hot path would erase most of the adaptive-polling wins.
        if !isIdleThrottled {
            // Update dangerous row tints every frame (cheap lookup, scrolls in-sync with grid)
            if !isMetalRenderingActive {
                updateDangerousRowTints()
            }

            // Metal has its own cursor blink timer (RustMetalDisplayCoordinator.handleBlinkTick)
            if !isMetalRenderingActive {
                gridView?.tickCursorBlink(now: CFAbsoluteTimeGetCurrent())
            }
        }

        // Enter idle throttle if we've seen enough consecutive no-data polls.
        if !isIdleThrottled,
           consecutiveIdlePolls >= Self.idleEntryThreshold,
           desiredPollingMode() == .displayLink {
            isIdleThrottled = true
            updatePollingMode(reason: "idleEntry")
        }

        // Rate-limited status logging
        Self.pollAndSyncCounter += 1
        let now = CFAbsoluteTimeGetCurrent()
        if now - Self.lastPollAndSyncLogTime > 10.0 { // Log every 10 seconds
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

        return { [weak rust] in
            guard let rust = rust else { return nil }
            guard let (grid, freeGrid) = rust.getGrid() else { return nil }

            let cursor = rust.cursorPosition
            let cursorVisible = grid.pointee.cursor_visible != 0
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
                gridView?.updateGrid(cells: cells, cols: gridCols, rows: gridRows, cursor: cursor, dirtyRows: dirtyRows)
            } else {
                fullSyncCount += 1
                Log.trace("RustTerminalView[\(viewId)]: syncGridToRenderer - Full sync for \(gridCols)x\(gridRows) grid (dims changed: \(dimensionsChanged), dirty: \(dirtyRows.count))")
                gridView?.updateGrid(cells: cells, cols: gridCols, rows: gridRows, cursor: cursor, dirtyRows: nil)
            }
        }

        hasRetainedFrameSourceReady = true
        retainedFrameSourceVersion = retainedFrameContentVersion

        // Periodic stats logging (every 1000 syncs)
        if (fullSyncCount + partialSyncCount).isMultiple(of: 1000) {
            Log.trace("RustTerminalView[\(viewId)]: syncStats - full:\(fullSyncCount) partial:\(partialSyncCount) skipped:\(skippedSyncCount)")
        }

        if pendingLocalEcho.isEmpty, pendingLocalBackspaces == 0 {
            clearLocalEchoOverlay()
        }

        updateInlineImagePositions()
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

    /// Compare two cells for equality (inlined for performance)
    @inline(__always)
    func cellsEqual(_ a: RustCellData, _ b: RustCellData) -> Bool {
        return a.character == b.character &&
            a.fg_r == b.fg_r && a.fg_g == b.fg_g && a.fg_b == b.fg_b &&
            a.bg_r == b.bg_r && a.bg_g == b.bg_g && a.bg_b == b.bg_b &&
            a.flags == b.flags && a.link_id == b.link_id
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
        clearLocalEchoOverlay()
    }

    func clearLocalEchoOverlay() {
        localEchoOverlay.removeAll()
        localEchoCursor = nil
        gridView?.clearOverlay()
        clearLocalEchoState()
    }

    func clearLocalEchoState() {
        pendingLocalEcho.removeAll()
        pendingLocalEchoOffset = 0
        pendingLocalBackspaces = 0
    }

    func removeLastPendingLocalEchoChar() {
        guard !pendingLocalEcho.isEmpty else { return }
        pendingLocalEcho.removeLast()
        if pendingLocalEchoOffset > pendingLocalEcho.count {
            pendingLocalEchoOffset = pendingLocalEcho.count
        }
    }

    func compactConsumedLocalEchoIfNeeded() {
        guard pendingLocalEchoOffset > 0 else { return }
        if pendingLocalEchoOffset >= pendingLocalEcho.count {
            pendingLocalEcho.removeAll()
            pendingLocalEchoOffset = 0
            return
        }
        if pendingLocalEchoOffset > 64 {
            pendingLocalEcho.removeFirst(pendingLocalEchoOffset)
            pendingLocalEchoOffset = 0
        }
    }

    func baseCellForLocalEcho(row: Int, col: Int) -> RustCellData {
        let idx = row * cols + col
        if idx >= 0, idx < previousGrid.count {
            return previousGrid[idx]
        }
        return RustCellData(character: 0, fg_r: 255, fg_g: 255, fg_b: 255, bg_r: 0, bg_g: 0, bg_b: 0, flags: 0, _pad: 0, link_id: 0)
    }

    func updateLocalEchoOverlay() {
        if localEchoOverlay.isEmpty {
            gridView?.clearOverlay()
        } else {
            gridView?.setOverlayCells(localEchoOverlay)
        }
    }

    func advanceLocalEchoCursor(_ cursor: inout (row: Int, col: Int)) {
        cursor.col += 1
        if cursor.col >= cols {
            cursor.col = 0
            cursor.row = min(rows - 1, cursor.row + 1)
        }
    }

    func retreatLocalEchoCursor(_ cursor: inout (row: Int, col: Int)) {
        if cursor.col > 0 {
            cursor.col -= 1
        } else if cursor.row > 0 {
            cursor.row -= 1
            cursor.col = max(0, cols - 1)
        }
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

    // MARK: - OSC 7 Directory Parsing

    /// Parse OSC 7 (current working directory) from raw PTY output.
    /// OSC 7 format: ESC ] 7 ; file://hostname/path BEL (0x07) or ESC \ (ST)
    func parseOSC7(from data: Data) {
        // Look for OSC 7 sequence: ESC (0x1b) ] (0x5d) 7 ; ...
        // Terminated by BEL (0x07) or ESC \
        let bytes = Array(data)
        var i = 0

        while i < bytes.count - 5 { // Need at least ESC ] 7 ; x BEL
            // Look for ESC ]
            if bytes[i] == 0x1B, i + 1 < bytes.count, bytes[i + 1] == 0x5D {
                // Found ESC ], check for '7;'
                if i + 3 < bytes.count, bytes[i + 2] == 0x37, bytes[i + 3] == 0x3B {
                    // Found OSC 7 ; - extract the URL
                    let start = i + 4 // After "ESC ] 7 ;"

                    // Find terminator: BEL (0x07) or ESC \ (0x1b 0x5c)
                    var end = start
                    while end < bytes.count {
                        if bytes[end] == 0x07 {
                            break // BEL terminator
                        }
                        if bytes[end] == 0x1B, end + 1 < bytes.count, bytes[end + 1] == 0x5C {
                            break // ST (ESC \) terminator
                        }
                        end += 1
                    }

                    if end < bytes.count, end > start {
                        // Extract the URL string
                        let urlBytes = Array(bytes[start ..< end])
                        if let urlString = String(bytes: urlBytes, encoding: .utf8) {
                            processOSC7URL(urlString)
                        }
                    }
                }
            }
            i += 1
        }
    }

    // MARK: - OSC 9 chau7;... parsing

    private static let branchMarkerPrefix = Array("\u{1b}]9;chau7;branch=".utf8)
    private static let exitMarkerPrefix = Array("\u{1b}]9;chau7;exit=".utf8)
    private static let repoRootMarkerPrefix = Array("\u{1b}]9;chau7;repo-root=".utf8)
    private static let belTerminator: UInt8 = 0x07

    /// Extract last command exit status from OSC 9;chau7;exit=CODE sequences.
    func parseChau7Exit(from data: Data) {
        parseChau7Marker(data: data, prefix: Self.exitMarkerPrefix) { [weak self] value in
            guard let exitCode = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            self?.onExitStatusChanged?(exitCode)
        }
    }

    /// Extract git branch name from OSC 9;chau7;branch=NAME sequences in terminal output.
    /// The shell integration precmd hook emits this on every prompt when inside a git repo.
    func parseChau7Branch(from data: Data) {
        parseChau7Marker(data: data, prefix: Self.branchMarkerPrefix) { [weak self] value in
            self?.onBranchChanged?(value)
        }
    }

    /// Extract git repo root path from OSC 9;chau7;repo-root=PATH sequences.
    /// Emitted by the shell integration precmd hook alongside the branch, so the app
    /// learns the repo root even in protected directories where live git probing is blocked.
    func parseChau7RepoRoot(from data: Data) {
        parseChau7Marker(data: data, prefix: Self.repoRootMarkerPrefix) { [weak self] value in
            self?.onRepoRootChanged?(value)
        }
    }

    private static let osc9Prefix: [UInt8] = [0x1B, 0x5D, 0x39, 0x3B] // ESC ] 9 ;
    private static let chau7PrefixWithinOsc9 = Array("chau7;".utf8)

    /// Extract desktop-notification payloads from OSC 9 sequences emitted by programs
    /// OTHER than Chau7's own shell integration. Format: `ESC ] 9 ; <message> BEL`.
    ///
    /// Messages that start with `chau7;` are produced by Chau7's shell hooks and are
    /// handled by `parseChau7Branch` / `parseChau7RepoRoot`; this parser skips them.
    /// The Codex CLI TUI is the main current source — it emits OSC 9 for every
    /// notification kind (approval requested, user input requested, plan mode prompt,
    /// elicitation requested, edit approval, agent turn complete) with a short
    /// human-readable message as the payload.
    func parseForeignDesktopNotifications(from data: Data) {
        let bytes = Array(data)
        let prefix = Self.osc9Prefix
        let chau7Prefix = Self.chau7PrefixWithinOsc9
        guard bytes.count > prefix.count else { return }

        var i = 0
        while i <= bytes.count - prefix.count {
            var matched = true
            for j in 0 ..< prefix.count {
                if bytes[i + j] != prefix[j] {
                    matched = false
                    break
                }
            }
            if !matched {
                i += 1
                continue
            }

            let start = i + prefix.count

            // Skip our own chau7;KEY=VALUE payloads — those are handled elsewhere.
            if start + chau7Prefix.count <= bytes.count {
                var isChau7 = true
                for j in 0 ..< chau7Prefix.count {
                    if bytes[start + j] != chau7Prefix[j] {
                        isChau7 = false
                        break
                    }
                }
                if isChau7 {
                    i = start + chau7Prefix.count
                    continue
                }
            }

            // Find terminator: BEL (0x07) or ST (ESC \)
            var end = start
            while end < bytes.count, bytes[end] != Self.belTerminator {
                if bytes[end] == 0x1B, end + 1 < bytes.count, bytes[end + 1] == 0x5C { break }
                end += 1
            }

            if end > start, let message = String(bytes: bytes[start ..< end], encoding: .utf8) {
                let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        self?.onForeignDesktopNotification?(trimmed)
                    }
                }
            }
            i = max(end + 1, i + 1)
        }
    }

    /// Generic OSC 9 chau7;KEY=VALUE BEL parser. Scans `data` for every occurrence of
    /// `prefix` (ending in `=`), captures the value up to the BEL or ESC\ terminator,
    /// trims whitespace, and dispatches the non-empty result to `handler` on the main queue.
    private func parseChau7Marker(data: Data, prefix: [UInt8], handler: @escaping (String) -> Void) {
        let bytes = Array(data)
        guard bytes.count > prefix.count else { return }

        var i = 0
        while i <= bytes.count - prefix.count {
            var matched = true
            for j in 0 ..< prefix.count {
                if bytes[i + j] != prefix[j] {
                    matched = false
                    break
                }
            }
            if matched {
                let start = i + prefix.count
                var end = start
                while end < bytes.count, bytes[end] != Self.belTerminator {
                    if bytes[end] == 0x1B, end + 1 < bytes.count, bytes[end + 1] == 0x5C { break }
                    end += 1
                }
                if end > start, let value = String(bytes: bytes[start ..< end], encoding: .utf8) {
                    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty {
                        DispatchQueue.main.async {
                            handler(trimmed)
                        }
                    }
                }
                i = end + 1
            } else {
                i += 1
            }
        }
    }

    /// Process the URL from OSC 7 and extract the directory path.
    /// URL format: file://hostname/path
    func processOSC7URL(_ urlString: String) {
        // Parse the file:// URL
        if let url = URL(string: urlString) {
            let path = url.path
            if !path.isEmpty, path != currentDirectory {
                Log.info("RustTerminalView[\(viewId)]: OSC 7 directory update: \(path)")
                currentDirectory = path
                DispatchQueue.main.async { [weak self] in
                    self?.onDirectoryChanged?(path)
                }
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
            if !path.isEmpty, path != currentDirectory {
                Log.info("RustTerminalView[\(viewId)]: OSC 7 directory update (fallback): \(path)")
                currentDirectory = path
                DispatchQueue.main.async { [weak self] in
                    self?.onDirectoryChanged?(path)
                }
            }
        }
    }

}
