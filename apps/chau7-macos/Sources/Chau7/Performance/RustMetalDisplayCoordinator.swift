// MARK: - Rust Metal Display Coordinator

// Orchestrates the Metal rendering pipeline for the Rust terminal backend.
// The Rust terminal is the source of truth (PTY I/O, parsing, selection, scroll).
// Metal provides GPU-accelerated display, replacing the CPU-based RustGridView.
//
// Architecture: RustTerminalView.pollAndSync() calls onDisplaySyncNeeded
//  → container wires setNeedsSync() → draw(in:) reads grid via closure → bridge
//  → TripleBufferedTerminal → MetalTerminalRenderer → CAMetalDrawable

import Foundation
import MetalKit
import Chau7Core

enum RustGridPayload {
    case full(UnsafeMutablePointer<RustGridSnapshot>)
    case delta(UnsafeMutablePointer<RustGridDeltaSnapshot>)
}

/// Grid provider keyed by the last generation consumed by this display. A
/// generation of zero requests a complete viewport for cold start, resize,
/// theme/tint changes, diagnostics, and renderer restoration.
typealias RustGridProvider = (_ generation: UInt64) -> (
    payload: RustGridPayload,
    cursor: (col: UInt16, row: UInt16),
    cursorVisible: Bool, // DECTCEM: false when app hides cursor (ESC[?25l)
    scrollbackRows: Int,
    free: () -> Void
)?

/// Coordinates Rust Terminal → TripleBuffer → Metal rendering.
/// Owns the bridge, buffers, renderer, and Metal view.
/// Attach to a RustTerminalContainerView to enable GPU rendering.
final class RustMetalDisplayCoordinator: NSObject {

    private struct FontConfigurationSignature: Equatable {
        let fontName: String
        let pointSize: CGFloat
        let scaleFactor: CGFloat
    }

    private struct PreparedFrame {
        let ticket: MetalFramePreparationTicket
        let buffer: TripleBufferedTerminal
        let rows: Int
        let cols: Int
        let cursor: (col: UInt16, row: UInt16)
        let cursorVisible: Bool
        let scrollbackRows: Int
        let diagnosticCells: [RustCellData]?
    }

    // MARK: - Components

    private let bridge: RustTermBridge
    private var tripleBuffer: TripleBufferedTerminal
    private let renderer: MetalTerminalRenderer
    let metalView: OptimalMetalView

    /// Rust snapshot acquisition and O(rows × cols) cell conversion live on
    /// this serial queue. AppKit's `draw(in:)` only consumes an already-
    /// prepared triple-buffer frame and submits it to Metal.
    private let framePreparationQueue = DispatchQueue(
        label: "com.chau7.metal-frame-preparation",
        qos: .userInteractive
    )

    // MARK: - State

    private weak var terminalView: RustTerminalView?
    private var gridProvider: RustGridProvider?
    private var renderRequests = TerminalRenderRequestCoalescer()
    private var framePreparationState = MetalFramePreparationState()
    private var preparedFrame: PreparedFrame?
    private var forceFullRefreshForNextPreparation = true
    private var lastPreparedRowTints: [Int: SIMD4<Float>] = [:]
    private var tripleBufferFootprintBytes = 0
    private var rows: Int
    private var cols: Int
    private var requestedRows: Int
    private var requestedCols: Int
    private var fontConfigured = false
    private var lastFontConfigurationSignature: FontConfigurationSignature?
    /// Set on tab switch, cleared by the first committed frame — the
    /// tab-switch-to-first-paint responsiveness metric.
    private var tabSwitchPaintStartedAt: CFAbsoluteTime?
    /// Generation-gated two-phase handoff. The incoming pane continues to
    /// display its CPU frame until the GPU completes the matching first frame.
    private var handoffState = MetalRendererHandoffState()

    /// Combined renderer + triple-buffer memory attribution for this window's
    /// coordinator. O(1); consumed by TerminalMemoryReport.
    struct MemoryFootprint {
        let rendererFootprint: MetalTerminalRenderer.MemoryFootprint
        let tripleBufferBytes: Int
        let gridCols: Int
        let gridRows: Int
    }

    var memoryFootprint: MemoryFootprint {
        MemoryFootprint(
            rendererFootprint: renderer.memoryFootprint,
            // Cluster capacity changes on the preparation queue. Read the
            // main-thread cache published with the last completed frame rather
            // than racing the producer's mutable storage.
            tripleBufferBytes: tripleBufferFootprintBytes,
            gridCols: cols,
            gridRows: rows
        )
    }

    private var lastLigaturesEnabled: Bool?
    private var lastCursorBlinkEnabled: Bool?
    private var pendingRetryDisplay = false
    private var pendingCircuitBreakerRetry = false
    private var retryState = TerminalRenderRetryState()

    // MARK: - Blink Timer

    private var blinkTimer: Timer?
    private var blinkTimerInterval: TimeInterval?
    /// Time of last keyboard/PTY activity (used to pause cursor blink during typing)
    private var lastActivityTime = Date()

    // MARK: - Scroll-Storm Throttling

    /// AI TUIs that stream log-style output (Codex, Claude Code, build watchers)
    /// dirty nearly every row of the visible grid every frame, so the dirty-tracking
    /// optimisation degenerates to full-buffer uploads. At 30+ fps on a fullscreen
    /// viewport that's ~50 MB/s of GPU sync per visible tab — enough to saturate
    /// the Metal command queue and stall the main thread (multi-second input lag
    /// observed in 2026-04-30 freeze trace). Cap to ~15 fps once we've seen a
    /// short run of mostly-full-grid redraws; perceptually equivalent for scrolling
    /// content, materially lowers the cost.
    ///
    /// The "nearly" matters: a Claude session that pressured the app to ~1.2 GB
    /// resident on 2026-05-04 was rendering 21294/21567 ≈ 98.7 % of cells dirty
    /// per frame. Later logs showed active AI output around 91 %, so thresholding
    /// at 95 % missed real workloads. Keep the classifier at 85 % and require
    /// consecutive frames so ordinary partial redraws do not enter the throttle.
    private var consecutiveFullDirtyFrames = 0
    private var consecutiveLowDirtyFrames = 0
    private var inScrollStorm = false
    private var lastSyncRequestAt: CFAbsoluteTime = 0
    private var pendingDeferredSync = false
    private static let scrollStormFrameThreshold = 3
    private static let scrollStormMinIntervalSec: CFAbsoluteTime = 0.066
    /// Exit threshold: dirty ratio (50 %) AND a run of consecutive low-dirty
    /// frames. The throttle's deferred re-fires (`scheduleDeferredSync`)
    /// produce ~0-dirty frames when no new PTY data arrived in the 66 ms gap;
    /// without a multi-frame exit run, a single such frame would flip the
    /// storm off and the next AI burst would flip it back on, creating the
    /// 800+ enter/exit-per-2h flapping observed on 2026-05-05 (effective
    /// throttle of ~30 fps instead of the intended 15 fps).
    private static let scrollStormExitFrameThreshold = 3

    // MARK: - Init

    /// Creates a coordinator for the given Rust terminal view.
    /// Returns nil if Metal is not available.
    /// - Parameters:
    ///   - terminalView: The RustTerminalView to render for
    ///   - gridProvider: Closure that provides the current grid snapshot + cursor + free
    init?(terminalView: RustTerminalView, gridProvider: @escaping RustGridProvider) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Log.warn("RustMetalDisplayCoordinator: Metal not available")
            return nil
        }

        guard let renderer = MetalTerminalRenderer(device: device) else {
            Log.warn("RustMetalDisplayCoordinator: Failed to create renderer")
            return nil
        }

        let rows = terminalView.renderRows
        let cols = terminalView.renderCols

        self.terminalView = terminalView
        self.gridProvider = gridProvider
        self.renderer = renderer
        self.rows = rows
        self.cols = cols
        self.requestedRows = rows
        self.requestedCols = cols
        self.bridge = RustTermBridge()
        self.tripleBuffer = TripleBufferedTerminal(rows: rows, cols: cols)
        self.metalView = OptimalMetalView(frame: .zero, device: device)

        super.init()

        self.tripleBufferFootprintBytes = tripleBuffer.estimatedFootprintBytes

        // A GPU-failed frame already consumed its render request; without a
        // forced full-refresh redraw the view would strand on a stale frame
        // until the next PTY change.
        renderer.onCommandBufferError = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                Log.warn("RustMetalDisplayCoordinator: GPU frame failed; forcing full-refresh redraw")
                self.requestFullFramePreparation()
            }
        }

        // Dragging the window between Retina and non-Retina displays changes
        // the backing scale; without reconfiguring, glyphs render at the old
        // scale (blurry or oversampled) until the next tab switch/font change.
        metalView.onBackingPropertiesChanged = { [weak self] in
            guard let self else { return }
            if configureFont() {
                Log.info("RustMetalDisplayCoordinator: backing scale changed; reconfigured font and forcing full refresh")
                requestFullFramePreparation()
            }
        }

        metalView.isPaused = true
        // enableSetNeedsDisplay = true lets us mark the view dirty via
        // needsDisplay. Core Animation coalesces multiple marks within one
        // frame into a single draw(in:) call at vsync — automatic frame cap.
        metalView.enableSetNeedsDisplay = true
        metalView.isEventPassthrough = true
        metalView.delegate = self

        // Configure font from the terminal view
        configureFont()

        // Initialize bridge with current color scheme
        enqueueBridgeColorSchemeUpdate()
        syncRendererFeatureSettings()

        syncClearColor()

        Log.trace("RustMetalDisplayCoordinator: Initialized (\(cols)x\(rows))")

        // Blink timer is NOT started at init — only the active (selected) tab's
        // coordinator should have a running timer. The lifecycle (updateNSView)
        // calls resumeBlinkTimer when the tab becomes interactive.
    }

    deinit {
        blinkTimer?.invalidate()
    }

    // MARK: - Font

    /// Reads font and scale factor from the terminal view and configures the renderer.
    @discardableResult
    private func configureFont(force: Bool = false) -> Bool {
        guard let view = terminalView else { return false }
        let font = view.font
        let scaleFactor = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
        let signature = FontConfigurationSignature(
            fontName: font.fontName,
            pointSize: font.pointSize,
            scaleFactor: scaleFactor
        )

        if !force, fontConfigured, signature == lastFontConfigurationSignature {
            return false
        }

        renderer.setFont(
            nsFont: font,
            scaleFactor: scaleFactor
        )

        // Configure Metal layer for Retina
        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.contentsScale = scaleFactor
        }

        fontConfigured = true
        lastFontConfigurationSignature = signature
        return true
    }

    /// Keeps renderer feature flags aligned with user settings. Ligature changes
    /// alter instance UVs, so they require a full refresh once the initial value
    /// has been observed.
    @discardableResult
    private func syncRendererFeatureSettings() -> Bool {
        var needsRedraw = false
        let settings = FeatureSettings.shared
        let ligaturesEnabled = settings.enableLigatures
        if renderer.ligaturesEnabled != ligaturesEnabled {
            renderer.ligaturesEnabled = ligaturesEnabled
            if lastLigaturesEnabled != nil {
                forceFullRefreshForNextPreparation = true
                requestSyncRender()
                needsRedraw = true
            }
        }
        lastLigaturesEnabled = ligaturesEnabled

        let cursorBlinkEnabled = settings.cursorBlink
        if lastCursorBlinkEnabled != nil, lastCursorBlinkEnabled != cursorBlinkEnabled {
            requestPresentRender()
            needsRedraw = true
        }
        lastCursorBlinkEnabled = cursorBlinkEnabled

        renderer.cursorBlinkEnabled = cursorBlinkEnabled
        if !cursorBlinkEnabled {
            renderer.cursorBlinkPhase = true
        }
        return needsRedraw
    }

    private func currentBlinkInterval() -> TimeInterval {
        let rate = FeatureSettings.shared.cursorBlinkRate
        return max(0.3, min(rate, 2.0))
    }

    // MARK: - Lifecycle

    /// Called when Rust terminal's buffer changes. Marks that a sync + render is needed.
    /// Uses `needsDisplay` for vsync-coalesced rendering — multiple calls within one
    /// frame period produce exactly one `draw(in:)` at the next display refresh.
    ///
    /// Inside a detected scroll storm, requests under the min-interval are dropped
    /// from the immediate path and replaced with a single deferred fire — that way
    /// no data is lost when a chunk ends mid-throttle, but back-to-back PTY pumps
    /// don't queue 30+ Metal frames per second.
    func setNeedsSync() {
        if inScrollStorm {
            let now = CFAbsoluteTimeGetCurrent()
            let elapsed = now - lastSyncRequestAt
            if elapsed < Self.scrollStormMinIntervalSec {
                scheduleDeferredSync(after: Self.scrollStormMinIntervalSec - elapsed)
                return
            }
            lastSyncRequestAt = now
        }
        requestSyncRender()
        // Record activity — this pauses cursor blink for 1 second after typing
        lastActivityTime = Date()
        renderer.cursorBlinkPhase = true // Show cursor immediately on activity
    }

    private func requestSyncRender() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.requestSyncRender()
            }
            return
        }
        renderRequests.requestSync()
        requestFramePreparation()
    }

    private func requestFullFramePreparation() {
        forceFullRefreshForNextPreparation = true
        requestSyncRender()
    }

    /// Starts at most one off-main snapshot/conversion job. Additional sync
    /// requests set the pure preparation state's pending bit; after the
    /// prepared frame is presented, exactly one latest-state follow-up starts.
    private func requestFramePreparation() {
        guard !TerminalRenderCircuitBreaker.shared.isOpen else {
            scheduleCircuitBreakerRetry()
            return
        }
        guard let ticket = framePreparationState.request() else { return }
        launchFramePreparation(ticket)
    }

    /// A confirmed main-thread stall keeps the render request pending but
    /// postpones CPU/GPU paint work. Once the independent monitor observes
    /// progress again, one coalesced retry renders the newest frame.
    private func scheduleCircuitBreakerRetry() {
        guard !pendingCircuitBreakerRetry else { return }
        pendingCircuitBreakerRetry = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            pendingCircuitBreakerRetry = false
            guard renderRequests.drawRequest() != nil else { return }
            if TerminalRenderCircuitBreaker.shared.isOpen {
                scheduleCircuitBreakerRetry()
                return
            }
            if renderRequests.drawRequest()?.shouldSync == true {
                requestFramePreparation()
            }
            scheduleDisplay()
        }
    }

    private func launchFramePreparation(_ ticket: MetalFramePreparationTicket) {
        guard let provider = gridProvider,
              let terminalView else {
            _ = framePreparationState.complete(ticket, succeeded: false)
            schedulePreparationRetry()
            return
        }

        let existingBuffer = tripleBuffer
        let renderViewID = terminalView.viewId
        let shouldForceFullRefresh = forceFullRefreshForNextPreparation
        forceFullRefreshForNextPreparation = false
        let rowTints = currentRowTints(for: terminalView)
        let rowTintsChanged = rowTints != lastPreparedRowTints
        lastPreparedRowTints = rowTints
        let captureDiagnostics = EnvVars.isEnabled(EnvVars.inputDiagnostics)
            || EnvVars.isEnabled(EnvVars.renderRowDiagnostics)
        let requestedGeneration = shouldForceFullRefresh || rowTintsChanged || captureDiagnostics
            ? 0
            : existingBuffer.latestGeneration

        framePreparationQueue.async { [weak self] in
            guard let self else { return }
            guard let snapshot = provider(requestedGeneration) else {
                DispatchQueue.main.async { [weak self] in
                    self?.finishFramePreparation(ticket, frame: nil)
                }
                return
            }
            defer { snapshot.free() }

            let gridRows: Int
            let gridCols: Int
            switch snapshot.payload {
            case let .full(grid):
                gridRows = Int(grid.pointee.rows)
                gridCols = Int(grid.pointee.cols)
            case let .delta(delta):
                gridRows = Int(delta.pointee.rows)
                gridCols = Int(delta.pointee.cols)
            }
            guard gridRows > 0, gridCols > 0 else {
                DispatchQueue.main.async { [weak self] in
                    self?.finishFramePreparation(ticket, frame: nil)
                }
                return
            }

            let targetBuffer: TripleBufferedTerminal
            if existingBuffer.rows == gridRows, existingBuffer.cols == gridCols {
                targetBuffer = existingBuffer
            } else {
                targetBuffer = TripleBufferedTerminal(rows: gridRows, cols: gridCols)
            }
            bridge.rowTints = rowTints
            let syncResult: (rows: Int, cols: Int)?
            switch snapshot.payload {
            case let .full(grid):
                syncResult = bridge.syncToTripleBuffer(
                    targetBuffer,
                    grid: grid,
                    viewID: renderViewID
                )
            case let .delta(delta):
                syncResult = bridge.syncDeltaToTripleBuffer(
                    targetBuffer,
                    delta: delta,
                    viewID: renderViewID
                )
            }
            guard syncResult != nil else {
                DispatchQueue.main.async { [weak self] in
                    self?.finishFramePreparation(ticket, frame: nil)
                }
                return
            }

            let diagnosticCells: [RustCellData]?
            if captureDiagnostics {
                switch snapshot.payload {
                case let .full(grid):
                    if let cells = grid.pointee.cells {
                        diagnosticCells = Array(
                            UnsafeBufferPointer(start: cells, count: gridRows * gridCols)
                        )
                    } else {
                        diagnosticCells = nil
                    }
                case let .delta(delta):
                    if delta.pointee.full_refresh != 0,
                       Int(delta.pointee.row_count) == gridRows,
                       let cells = delta.pointee.cells {
                        diagnosticCells = Array(
                            UnsafeBufferPointer(start: cells, count: gridRows * gridCols)
                        )
                    } else {
                        diagnosticCells = nil
                    }
                }
            } else {
                diagnosticCells = nil
            }

            let frame = PreparedFrame(
                ticket: ticket,
                buffer: targetBuffer,
                rows: gridRows,
                cols: gridCols,
                cursor: snapshot.cursor,
                cursorVisible: snapshot.cursorVisible,
                scrollbackRows: snapshot.scrollbackRows,
                diagnosticCells: diagnosticCells
            )
            DispatchQueue.main.async { [weak self] in
                self?.finishFramePreparation(ticket, frame: frame)
            }
        }
    }

    private func finishFramePreparation(
        _ ticket: MetalFramePreparationTicket,
        frame: PreparedFrame?
    ) {
        let completion = framePreparationState.complete(
            ticket,
            succeeded: frame != nil
        )
        guard completion == .publish, let frame else {
            if ticket.bindingGeneration == framePreparationState.bindingGeneration {
                schedulePreparationRetry()
            }
            return
        }

        preparedFrame = frame
        tripleBuffer = frame.buffer
        rows = frame.rows
        cols = frame.cols
        tripleBufferFootprintBytes = frame.buffer.estimatedFootprintBytes
        terminalView?.cachedScrollbackRows = frame.scrollbackRows
        if let cells = frame.diagnosticCells {
            cells.withUnsafeBufferPointer { buffer in
                guard let base = buffer.baseAddress else { return }
                terminalView?.logCursorInputRowDiagnosticIfNeeded(
                    cells: base,
                    cols: frame.cols,
                    rows: frame.rows,
                    cursor: frame.cursor,
                    source: "metal-grid"
                )
            }
        }
        scheduleDisplay()
    }

    private func schedulePreparationRetry() {
        let decision = retryState.recordFailure(reason: .gridUnavailable)
        guard !pendingRetryDisplay else { return }
        pendingRetryDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + decision.delay) { [weak self] in
            guard let self else { return }
            pendingRetryDisplay = false
            guard renderRequests.drawRequest()?.shouldSync == true else { return }
            requestFramePreparation()
        }
    }

    private func currentRowTints(for terminalView: RustTerminalView) -> [Int: SIMD4<Float>] {
        guard let provider = terminalView.dangerousRowTintsProvider else { return [:] }
        let yDisp = terminalView.renderTopVisibleRow
        let viewRows = max(rows, terminalView.renderRows)
        let absTints = provider(yDisp, yDisp + viewRows - 1)
        var result: [Int: SIMD4<Float>] = [:]
        result.reserveCapacity(absTints.count)
        for (absRow, color) in absTints {
            let viewportRow = absRow - yDisp
            guard viewportRow >= 0, viewportRow < viewRows else { continue }
            let converted = color.usingColorSpace(.sRGB) ?? color
            result[viewportRow] = SIMD4(
                Float(converted.redComponent),
                Float(converted.greenComponent),
                Float(converted.blueComponent),
                Float(converted.alphaComponent)
            )
        }
        return result
    }

    private func enqueueBridgeColorSchemeUpdate() {
        let scheme = FeatureSettings.shared.currentColorScheme
        let foreground = scheme.foreground
        let background = scheme.background
        framePreparationQueue.async { [bridge] in
            bridge.setDefaultColors(
                foregroundHex: foreground,
                backgroundHex: background
            )
        }
    }

    private func requestPresentRender() {
        renderRequests.requestPresent()
    }

    var renderSurfaceDiagnostics: TerminalRenderSurfaceReport.CoordinatorDiagnostics {
        TerminalRenderSurfaceReport.CoordinatorDiagnostics(
            renderRequests: renderRequests.diagnostics,
            retry: retryState.snapshot
        )
    }

    /// Coalesce throttled `setNeedsSync` calls into one deferred fire so the
    /// final frame of a streaming chunk still gets rendered when no further
    /// data arrives.
    private func scheduleDeferredSync(after delay: CFAbsoluteTime) {
        guard !pendingDeferredSync else { return }
        pendingDeferredSync = true
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            pendingDeferredSync = false
            setNeedsSync()
        }
    }

    /// Update the scroll-storm classifier based on what the just-rendered frame
    /// actually looked like. Called from `draw(in:)` after a successful commit.
    private func updateScrollStormState(dirtyCells: Int, frameCells: Int) {
        guard frameCells > 0 else { return }
        let isFullDirty = ScrollStormThrottlePolicy.shouldEnterScrollStorm(
            dirtyCells: dirtyCells,
            frameCells: frameCells
        )
        let isLowDirty = ScrollStormThrottlePolicy.shouldCountAsLowDirtyFrame(
            dirtyCells: dirtyCells,
            frameCells: frameCells
        )
        if isFullDirty {
            consecutiveFullDirtyFrames += 1
            consecutiveLowDirtyFrames = 0
            if consecutiveFullDirtyFrames >= Self.scrollStormFrameThreshold, !inScrollStorm {
                inScrollStorm = true
                Log.info(
                    "RustMetalDisplayCoordinator: entering scroll storm (dirty=\(dirtyCells)/\(frameCells), throttling sync to ~15 fps)"
                )
            }
        } else {
            consecutiveFullDirtyFrames = 0
            // Exit only after a run of low-dirty frames. A single deferred
            // re-fire from the throttle itself would otherwise flip the storm
            // off and force the next AI burst to re-enter, producing flapping
            // and a much higher effective frame rate than the throttle target.
            if isLowDirty {
                consecutiveLowDirtyFrames += 1
                if consecutiveLowDirtyFrames >= Self.scrollStormExitFrameThreshold, inScrollStorm {
                    inScrollStorm = false
                    Log.info(
                        "RustMetalDisplayCoordinator: exiting scroll storm (dirty=\(dirtyCells)/\(frameCells))"
                    )
                }
            } else {
                consecutiveLowDirtyFrames = 0
            }
        }
    }

    func forceAuthoritativeRefresh(reason: String) {
        requestFullFramePreparation()
        lastActivityTime = Date()
        renderer.cursorBlinkPhase = true
        Log.trace("RustMetalDisplayCoordinator: forceAuthoritativeRefresh[\(reason)]")
    }

    /// Marks the Metal view for redraw at the next display refresh.
    /// Core Animation coalesces multiple calls into one draw(in:).
    private func scheduleDisplay() {
        if Thread.isMainThread {
            metalView.needsDisplay = true
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.metalView.needsDisplay = true
            }
        }
    }

    /// Re-arms paused/setNeedsDisplay-driven MTKView rendering after transient
    /// bails such as zero bounds, missing drawables, or a temporarily missing
    /// provider. Without this, the request remains pending but no future draw
    /// is guaranteed.
    private func scheduleRetryDisplay(reason: TerminalRenderRetryReason) {
        let decision = retryState.recordFailure(reason: reason)
        if decision.shouldLog {
            Log.debug(
                "RustMetalDisplayCoordinator: scheduling retry reason=\(reason.rawValue) attempt=\(decision.consecutiveFailureCount) delay=\(decision.delay)s"
            )
        }
        guard !pendingRetryDisplay else { return }
        pendingRetryDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + decision.delay) { [weak self] in
            guard let self else { return }
            pendingRetryDisplay = false
            guard renderRequests.drawRequest() != nil else { return }
            scheduleDisplay()
        }
    }

    /// Called when the terminal is resized.
    func resize(rows: Int, cols: Int) {
        guard rows != requestedRows || cols != requestedCols else { return }
        requestedRows = rows
        requestedCols = cols
        requestFullFramePreparation()
        Log.info("RustMetalDisplayCoordinator: Resized to \(cols)x\(rows)")
        terminalView?.logRenderSurfaceReport(reason: "metal-resize", force: true)
    }

    /// Called when the color scheme changes.
    func colorSchemeChanged() {
        enqueueBridgeColorSchemeUpdate()
        syncClearColor()
        requestFullFramePreparation()
    }

    /// Syncs the Metal clear color to the terminal color scheme background.
    private func syncClearColor() {
        let scheme = FeatureSettings.shared.currentColorScheme
        let bg = scheme.nsColor(for: scheme.background)
        if let c = bg.usingColorSpace(.sRGB) {
            let clearColor = MTLClearColor(
                red: Double(c.redComponent),
                green: Double(c.greenComponent),
                blue: Double(c.blueComponent),
                alpha: 1.0
            )
            metalView.clearColor = clearColor
            renderer.backgroundClearColor = clearColor
        }
        if let link = NSColor.linkColor.usingColorSpace(.sRGB) {
            renderer.linkUnderlineColor = SIMD4(
                Float(link.redComponent),
                Float(link.greenComponent),
                Float(link.blueComponent),
                Float(link.alphaComponent)
            )
        }
    }

    /// Called when the font changes.
    /// Reconfigures the renderer's font/atlas but does NOT resize the triple buffer.
    /// The authoritative resize happens in container.layout() after the terminal
    /// view's needsLayout triggers layout() → updateCellDimensions() → renderRows/renderCols.
    /// Doing resize() here would use stale bounds (layout hasn't run yet) and cause a
    /// double-resize with potentially divergent row/col counts.
    func fontChanged() {
        configureFont(force: true)
        requestFullFramePreparation()
    }

    // MARK: - Shared Renderer Tab Switch

    /// Switch the shared coordinator to render a different terminal view.
    /// Moves the Metal view into the new container, swaps the grid provider,
    /// resizes if needed, and renders one immediate frame. ~1ms total.
    ///
    /// Called by `OverlayTabsModel` on tab switch. The old view's rendering
    /// callbacks are disconnected; the new view's are wired up.
    func switchToView(
        _ newView: RustTerminalView,
        container: RustTerminalContainerView
    ) {
        let oldView = terminalView

        // Skip when this view is already fully wired — avoids redundant
        // reparenting and the brief `isMetalRenderingActive=false` flash
        // during the thundering herd of terminalDidStart notifications at
        // startup (27 tabs × 2 windows).
        //
        // The `isMetalRenderingActive` check is load-bearing. The
        // immediate post-init case (`coordinator.switchToView(focusedView, ...)`
        // right after `RustMetalDisplayCoordinator(terminalView: focusedView, ...)`)
        // also has `newView === oldView` because init pre-sets
        // `self.terminalView = newView`. But at that moment the view has
        // NOT yet had `onDisplaySyncNeeded` / `isMetalRenderingActive` /
        // `container.metalCoordinator` wired by this function. Skipping
        // here would leave the coordinator un-wired and silently never
        // draw — surfaced as polls > 0, changed > 0, draws = 0 across the
        // entire session and visible as "tab content frozen / duplicated"
        // because the CG fallback path inside `RustTerminalView` ends up
        // painting instead.
        if newView === oldView, newView.isMetalRenderingActive {
            setNeedsSync()
            return
        }
        if newView === oldView, handoffState.isAwaitingFirstFrame {
            forceAuthoritativeRefresh(reason: "switchToView-pending")
            return
        }

        // Responsiveness instrument: elapsed time from here to the first
        // committed Metal frame of the incoming view is the user-perceived
        // tab-switch paint latency. Recorded in draw(in:) after commit.
        tabSwitchPaintStartedAt = CFAbsoluteTimeGetCurrent()

        // 1. Disconnect old view/container — only when actually switching
        // from a different view. Same-view first-attach must skip this
        // block; otherwise we'd flip `isMetalRenderingActive` back to
        // false a few lines before setting it to true at the bottom of
        // this function.
        if let oldView, oldView !== newView {
            oldView.detachFromSharedMetalRendererForHandoff()
            if let oldContainer = oldView.superview as? RustTerminalContainerView {
                oldContainer.metalCoordinator = nil
            }

            // The coordinator is shared across tabs, so stale present-only
            // requests from the previous view must not survive the handoff.
            // Otherwise a rebinding can briefly present the old frame into the
            // new container before the new grid sync lands.
            renderRequests.reset()
            retryState.recordSuccess()
            pendingRetryDisplay = false
            pendingDeferredSync = false
        }

        // 2. Swap grid provider + view reference
        framePreparationState.resetForNewBinding()
        preparedFrame = nil
        forceFullRefreshForNextPreparation = true
        lastPreparedRowTints = [:]
        gridProvider = newView.makeGridProvider()
        terminalView = newView
        let handoffGeneration = handoffState.begin()

        // 3. Reparent Metal view into the new container
        metalView.removeFromSuperview()
        let newGeometry = newView.currentRenderGeometry
        metalView.frame = newGeometry.surfaceFrame
        container.addSubview(metalView, positioned: .above, relativeTo: newView)
        container.metalCoordinator = self
        // Keep the drawable live but transparent. Hiding/removing it prevents
        // CAMetalLayer from vending a drawable; alpha zero lets the retained
        // CPU frame remain visible while the first GPU frame is prepared.
        metalView.alphaValue = 0

        // 4. Move HighlightView above Metal in the new container
        for subview in newView.subviews {
            if subview is TerminalHighlightView {
                subview.removeFromSuperview()
                subview.frame = container.bounds
                container.addSubview(subview, positioned: .above, relativeTo: metalView)
                break
            }
        }

        // 5. Wire new view's sync callback
        newView.onDisplaySyncNeeded = { [weak self] in
            self?.setNeedsSync()
        }
        newView.prepareForSharedMetalRendererHandoff()
        newView.logInitialRenderSurfaceReportIfNeeded(reason: "metal-initial")

        // 6. Reconfigure font if the new view uses a different font/scale
        configureFont()

        // 7. Resize triple buffer if grid dimensions changed
        let newRows = newGeometry.canResizePTY ? newGeometry.rows : newView.renderRows
        let newCols = newGeometry.canResizePTY ? newGeometry.cols : newView.renderCols
        if newRows > 1,
           newCols > 1,
           newRows != requestedRows || newCols != requestedCols {
            resize(rows: newRows, cols: newCols)
        }

        // 8. Sync color scheme
        syncClearColor()

        // 9. Render: immediate draw + deferred draw on next runloop tick.
        // The immediate draw works when the Metal view already has valid bounds.
        // The deferred draw catches the case where the view was just reparented
        // and needs one layout pass before CAMetalLayer commits its size.
        forceAuthoritativeRefresh(reason: "switchToView")
        DispatchQueue.main.async { [weak self] in
            self?.forceAuthoritativeRefresh(reason: "switchToView-deferred")
        }

        Log.info(
            "RustMetalDisplayCoordinator: switchToView → view \(newView.viewId) " +
                "(\(newCols)x\(newRows)) handoff=\(handoffGeneration)"
        )
    }

    // MARK: - Blink

    /// Pause the blink timer when the tab is suspended (saves CPU).
    func pauseBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        blinkTimerInterval = nil
    }

    /// Resume the blink timer when the tab is unsuspended.
    func resumeBlinkTimer() {
        let desiredInterval = currentBlinkInterval()
        if blinkTimer != nil, blinkTimerInterval == desiredInterval { return }
        startBlinkTimer()
    }

    /// Starts the blink timer using the user-configured cursor blink interval.
    private func startBlinkTimer() {
        blinkTimer?.invalidate()
        let interval = currentBlinkInterval()
        blinkTimerInterval = interval
        blinkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            handleBlinkTick()
        }
    }

    /// Called every 500ms to toggle blink phases.
    private func handleBlinkTick() {
        // Skip entirely when window is not visible (hidden, occluded, miniaturized)
        guard let window = metalView.window,
              window.isVisible,
              window.occlusionState.contains(.visible) else {
            return
        }

        let featureSettingsNeedRedraw = syncRendererFeatureSettings()
        let desiredInterval = currentBlinkInterval()
        if blinkTimerInterval != desiredInterval {
            startBlinkTimer()
            return
        }

        // Cursor blink: pause for 1 second after keyboard activity
        let timeSinceActivity = Date().timeIntervalSince(lastActivityTime)
        if !renderer.cursorBlinkEnabled || timeSinceActivity < 1.0 {
            renderer.cursorBlinkPhase = true
        } else {
            renderer.cursorBlinkPhase.toggle()
        }

        // Text blink: always toggles (independent of keyboard activity)
        renderer.textBlinkPhase.toggle()

        // Only trigger a redraw if cursor or blinking cells need update
        let needsRedraw = featureSettingsNeedRedraw || renderer.cursorBlinkEnabled || renderer.hasBlinkingCells
        if needsRedraw {
            requestPresentRender()
            scheduleDisplay()
        }
    }

    /// Stops rendering (call when the tab is suspended or removed).
    func stop() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        metalView.isPaused = true
    }

    // MARK: - Memory Volatility

    /// Whether the renderer's GPU resources are currently marked volatile.
    /// Window-level state: this coordinator is shared by every tab in its
    /// window, so volatility may only apply while the whole window is
    /// invisible (driven by `TerminalMemoryReclaimer` under critical
    /// pressure). Promotion happens at the top of the next draw.
    private(set) var texturesAreVolatile = false

    /// Marks the renderer's GPU textures and buffers as volatile. The OS may
    /// reclaim them under memory pressure; if it does, the next promotion will
    /// rebuild. If no pressure occurs, the data is preserved and promotion is
    /// free.
    func markTexturesVolatile() {
        guard !texturesAreVolatile else { return }
        texturesAreVolatile = true
        _ = renderer.setAtlasPurgeableState(.volatile)
        Log.info("RustMetalDisplayCoordinator: GPU resources marked volatile")
    }

    /// Marks the renderer's GPU resources as non-volatile and rebuilds them.
    ///
    /// Rebuild is UNCONDITIONAL, not gated on the `.empty` prior state:
    /// occluded windows keep drawing in event-drain mode, so the volatile
    /// marking can race an in-flight GPU frame — and a purge during use makes
    /// the prior-state signal unreliable. That exact failure shipped once: a
    /// purged atlas came back with prior == .volatile and every glyph in the
    /// window rendered invisible (backgrounds only) until relaunch. The
    /// rebuild is ~5ms of ASCII pre-rasterization on a rare transition.
    func markTexturesNonVolatileAndRebuildIfNeeded() {
        guard texturesAreVolatile else { return }
        texturesAreVolatile = false
        let prior = renderer.setAtlasPurgeableState(.nonVolatile)
        Log.info("RustMetalDisplayCoordinator: GPU resources promoted (prior=\(prior.rawValue)) — rebuilding atlas")
        renderer.clearGlyphCache()
        requestFullFramePreparation()
    }

    /// Drops large regenerable renderer allocations for a fully invisible
    /// window. The latest triple buffer remains resident so restoring the
    /// window never waits on disk or loses terminal/session state.
    @discardableResult
    func evictInactiveResources() -> Int {
        let window = metalView.window
        let isWindowInvisible = window.map {
            !$0.isVisible || $0.isMiniaturized || !$0.occlusionState.contains(.visible)
        } ?? true
        let allocatedBytes = renderer.allocatedResourceBytes
        guard TerminalMemoryBudgetPolicy.shouldEvictRenderer(
            isWindowInvisible: isWindowInvisible,
            allocatedBytes: allocatedBytes
        ) else {
            return 0
        }

        let releasedBytes = renderer.evictResources()
        guard releasedBytes > 0 else { return 0 }
        texturesAreVolatile = false
        fontConfigured = false
        lastFontConfigurationSignature = nil
        forceFullRefreshForNextPreparation = true
        Log.info("RustMetalDisplayCoordinator: evicted \(releasedBytes / (1024 * 1024))MB from invisible renderer")
        return releasedBytes
    }

    /// Restores an evicted renderer and asks the off-main preparation path for
    /// one authoritative full frame. Returning false deliberately defers this
    /// draw rather than flashing an incomplete atlas or stale instance buffer.
    private func restoreRendererResourcesIfNeeded() -> Bool {
        guard renderer.resourcesAreEvicted else { return true }
        guard renderer.restoreResourcesIfNeeded() else {
            scheduleRetryDisplay(reason: .fontNotConfigured)
            return false
        }
        fontConfigured = false
        lastFontConfigurationSignature = nil
        requestFullFramePreparation()
        Log.info("RustMetalDisplayCoordinator: restored renderer resources; preparing authoritative frame")
        return false
    }
}

// MARK: - MTKViewDelegate

extension RustMetalDisplayCoordinator: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handled by resize() from the container
    }

    private static var drawCallCount: UInt64 = 0
    private static var lastDrawLogTime: CFAbsoluteTime = 0
    private static var lastWarningLogTime: CFAbsoluteTime = 0
    private static var lastNoDrawableWarningLogTime: CFAbsoluteTime = 0
    private static let warningCooldown = 1.0

    func draw(in view: MTKView) {
        Self.drawCallCount += 1
        guard !TerminalRenderCircuitBreaker.shared.isOpen else {
            scheduleCircuitBreakerRetry()
            return
        }
        guard restoreRendererResourcesIfNeeded() else { return }
        // Promote volatile GPU resources before any encode touches them —
        // a no-op flag check in the common case.
        markTexturesNonVolatileAndRebuildIfNeeded()
        // A `metalView.needsDisplay = true` set before the bound view flipped
        // to drain-only (typical during a tab switch — `applyRenderPhase(.warm)`
        // sets `notifyUpdateChanges = false` synchronously, but a CADisplayLink
        // tick may already be queued) would otherwise render and upload the
        // outgoing tab's grid to the GPU. During rapid switching with a chatty
        // AI tab on the previous slot, that adds tens of MB of wasted GPU sync
        // per second to an already-saturated command queue. Bail early.
        if let view = terminalView, !view.notifyUpdateChanges {
            return
        }
        syncRendererFeatureSettings()
        guard let renderRequest = renderRequests.drawRequest() else { return }
        let shouldSync = renderRequest.shouldSync
        // Do NOT clear render requests here — any of the early-return
        // guards below (font / gridProvider / bounds / drawable / cellCount)
        // would otherwise eat the request and strand the view on a stale
        // frame. Requests are completed only after a frame commits, and only
        // for the generation this draw actually consumed.

        // Ensure font is configured (may not be ready at init if window isn't available yet)
        if !fontConfigured { configureFont() }
        guard fontConfigured else {
            let now = CFAbsoluteTimeGetCurrent()
            if now - Self.lastWarningLogTime > Self.warningCooldown {
                Log.debug("RustMetalDisplayCoordinator: draw skipped — font not configured")
                Self.lastWarningLogTime = now
            }
            scheduleRetryDisplay(reason: .fontNotConfigured)
            return
        }

        let token = FeatureProfiler.shared.begin(.metalRender, metadata: shouldSync ? "sync" : "present-only")

        if shouldSync {
            // Snapshot acquisition and cell conversion happen on the serial
            // preparation queue. A sync draw never falls back to touching Rust
            // or copying the terminal grid on AppKit's main thread.
            guard let frame = preparedFrame else {
                FeatureProfiler.shared.end(token)
                requestFramePreparation()
                return
            }
            renderer.cursorRow = Int(frame.cursor.row)
            renderer.cursorCol = Int(frame.cursor.col)
            renderer.cursorStyle = FeatureSettings.shared.cursorStyle
            renderer.cursorVisible = frame.cursorVisible

            let scheme = FeatureSettings.shared.currentColorScheme
            let cursorNSColor = scheme.nsColor(for: scheme.cursor)
            if let cc = cursorNSColor.usingColorSpace(.sRGB) {
                renderer.cursorColor = SIMD4(
                    Float(cc.redComponent),
                    Float(cc.greenComponent),
                    Float(cc.blueComponent),
                    0.8
                )
            }
        }

        // 5. Get drawable (skip silently when window has zero bounds — minimized/hidden)
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            FeatureProfiler.shared.end(token)
            scheduleRetryDisplay(reason: .zeroBounds)
            return
        }
        guard let drawable = (view.layer as? CAMetalLayer)?.nextDrawable() else {
            let now = CFAbsoluteTimeGetCurrent()
            if now - Self.lastNoDrawableWarningLogTime > Self.warningCooldown {
                Log.debug("RustMetalDisplayCoordinator: draw skipped — no drawable (bounds=\(view.bounds))")
                Self.lastNoDrawableWarningLogTime = now
            }
            FeatureProfiler.shared.end(token)
            scheduleRetryDisplay(reason: .noDrawable)
            return
        }

        // 6. Render from the triple buffer
        let sourceBuffer = shouldSync ? tripleBuffer.renderBuffer : tripleBuffer.displayBuffer
        let dirtyRows = shouldSync ? tripleBuffer.dirtyRows : IndexSet()
        let rawFullRefresh = shouldSync ? tripleBuffer.needsFullRefresh : false
        let fullRefresh = shouldSync ? MetalFullRefreshPolicy.shouldForceFullRefresh(
            rowCount: rows,
            dirtyRowCount: dirtyRows.count,
            alreadyFullRefresh: rawFullRefresh,
            inScrollStorm: inScrollStorm,
            isInteractive: terminalView?.isInteractiveForRendering ?? true,
            allowsLivePresentation: terminalView?.allowsLivePresentationForRendering ?? true
        ) : false
        let cellCount = rows * cols
        guard cellCount > 0 else {
            let now = CFAbsoluteTimeGetCurrent()
            if now - Self.lastWarningLogTime > Self.warningCooldown {
                Log.debug("RustMetalDisplayCoordinator: draw skipped — cellCount is 0 (rows=\(rows), cols=\(cols))")
                Self.lastWarningLogTime = now
            }
            FeatureProfiler.shared.end(token)
            scheduleRetryDisplay(reason: .zeroCells)
            return
        }

        // Periodic logging to confirm Metal is actively rendering
        let now = CFAbsoluteTimeGetCurrent()
        if now - Self.lastDrawLogTime > 5.0 {
            Self.lastDrawLogTime = now
            Log.trace("RustMetalDisplayCoordinator: Metal render — \(cols)x\(rows) (\(cellCount) cells), drawCalls=\(Self.drawCallCount), viewport=\(view.bounds.size)")
        }

        if let viewID = terminalView?.viewId {
            RenderPipelineProfiler.shared.recordDraw(
                viewID: viewID,
                cellCount: cellCount
            )
        }
        // Use view bounds (points) for the projection matrix, not drawable texture
        // (pixels). Cell positions are calculated in point-space
        // (cw = cellSize.width / scaleFactor), so the orthographic projection
        // must map point-space coordinates. The Metal viewport itself targets
        // the full pixel-space drawable automatically.
        let presentedView = terminalView
        let presentedGeneration = handoffState.generation
        let didCommit = renderer.render(
            buffer: sourceBuffer,
            rows: rows,
            cols: cols,
            dirtyRows: dirtyRows,
            fullRefresh: fullRefresh,
            to: drawable,
            viewportSize: view.bounds.size,
            onCompleted: { [weak self, weak presentedView] in
                DispatchQueue.main.async {
                    guard let self,
                          let presentedView,
                          self.terminalView === presentedView,
                          self.handoffState.owns(presentedGeneration)
                    else {
                        return
                    }

                    if self.handoffState.commitFirstFrame(generation: presentedGeneration) {
                        presentedView.isMetalRenderingActive = true
                        self.metalView.alphaValue = 1
                        Log.info(
                            "RustMetalDisplayCoordinator: committed handoff=\(presentedGeneration) " +
                                "view=\(presentedView.viewId)"
                        )
                    }

                    presentedView.noteDisplayFramePresented()
                    presentedView.onDisplayFramePresented?()
                    presentedView.onFramePresented?()
                }
            }
        )
        guard didCommit else {
            FeatureProfiler.shared.end(token)
            scheduleRetryDisplay(reason: .renderCommitFailed)
            return
        }
        retryState.recordSuccess()

        if let switchStartedAt = tabSwitchPaintStartedAt {
            tabSwitchPaintStartedAt = nil
            TerminalWorkProfiler.shared.record(
                .tabSwitchFirstPaint,
                context: TerminalWorkContext(
                    renderPhase: terminalView?.currentRenderPhase.rawValue ?? "unknown",
                    visibility: "live",
                    caller: "switchToView"
                ),
                durationMs: (CFAbsoluteTimeGetCurrent() - switchStartedAt) * 1000.0,
                bytes: cellCount * MemoryLayout<TerminalCell>.stride
            )
        }

        // 7. Advance triple buffer only when we consumed fresh synced terminal state.
        if shouldSync {
            let consumedTicket = preparedFrame?.ticket
            tripleBuffer.presentFrame()
            preparedFrame = nil
            // Track how dirty this frame was. AI-tab log streams routinely
            // dirty every row, defeating dirty-tracking; the storm classifier
            // notices and the next setNeedsSync caps to ~15 fps.
            let dirtyCellCount = fullRefresh ? cellCount : dirtyRows.count * cols
            updateScrollStormState(dirtyCells: dirtyCellCount, frameCells: cellCount)
            if let consumedTicket,
               let followUp = framePreparationState.consume(consumedTicket) {
                launchFramePreparation(followUp)
            }
        }

        // Complete only the request generation consumed by this draw. If PTY
        // output, blink, theme, or resize requested another frame while this
        // one was being prepared/committed, keep it pending and re-arm the
        // coalesced display path.
        if renderRequests.completeCommittedDraw(renderRequest) {
            scheduleDisplay()
        }

        FeatureProfiler.shared.end(token)
    }
}
