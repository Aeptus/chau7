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

/// Grid snapshot provider: reads the Rust grid and returns (snapshot pointer, free closure).
/// The coordinator calls this each frame to get current grid state + cursor position.
typealias RustGridProvider = () -> (
    grid: UnsafeMutableRawPointer, // Points to RustGridSnapshot
    cursor: (col: UInt16, row: UInt16),
    cursorVisible: Bool, // DECTCEM: false when app hides cursor (ESC[?25l)
    free: () -> Void
)?

/// Coordinates Rust Terminal → TripleBuffer → Metal rendering.
/// Owns the bridge, buffers, renderer, and Metal view.
/// Attach to a RustTerminalContainerView to enable GPU rendering.
final class RustMetalDisplayCoordinator: NSObject {

    // MARK: - Components

    private let bridge: RustTermBridge
    private var tripleBuffer: TripleBufferedTerminal
    private let renderer: MetalTerminalRenderer
    let metalView: OptimalMetalView

    // MARK: - State

    private weak var terminalView: RustTerminalView?
    private var gridProvider: RustGridProvider?
    private var needsSync = true
    private var needsPresent = true
    private var rows: Int
    private var cols: Int
    private var fontConfigured = false
    private var lastTripleBufferRebuildSignature = ""
    private var lastTripleBufferRebuildAt: CFAbsoluteTime = 0

    // MARK: - Blink Timer

    private var blinkTimer: Timer?
    /// Time of last keyboard/PTY activity (used to pause cursor blink during typing)
    private var lastActivityTime = Date()

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
        self.bridge = RustTermBridge()
        self.tripleBuffer = TripleBufferedTerminal(rows: rows, cols: cols)
        self.metalView = OptimalMetalView(frame: .zero, device: device)

        super.init()

        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.isEventPassthrough = true
        metalView.delegate = self

        // Configure font from the terminal view
        configureFont()

        // Initialize bridge with current color scheme
        bridge.colorSchemeChanged()

        syncClearColor()

        Log.trace("RustMetalDisplayCoordinator: Initialized (\(cols)x\(rows))")

        // Start blink timer (500ms interval, matching standard terminal blink rate)
        startBlinkTimer()
    }

    deinit {
        blinkTimer?.invalidate()
    }

    // MARK: - Font

    /// Reads font and scale factor from the terminal view and configures the renderer.
    private func configureFont() {
        guard let view = terminalView else { return }
        let font = view.font
        let scaleFactor = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        renderer.setFont(
            nsFont: font,
            scaleFactor: scaleFactor
        )

        // Configure Metal layer for Retina
        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.contentsScale = scaleFactor
        }

        fontConfigured = true
    }

    // MARK: - Lifecycle

    /// Called when Rust terminal's buffer changes. Marks that a sync + render is needed.
    /// Dispatches to main thread if called from a background thread.
    func setNeedsSync() {
        needsSync = true
        needsPresent = true
        // Record activity — this pauses cursor blink for 1 second after typing
        lastActivityTime = Date()
        renderer.cursorBlinkPhase = true // Show cursor immediately on activity
        requestDraw()
    }

    func forceAuthoritativeRefresh(reason: String) {
        tripleBuffer.markFullRefresh()
        needsSync = true
        needsPresent = true
        lastActivityTime = Date()
        renderer.cursorBlinkPhase = true
        Log.trace("RustMetalDisplayCoordinator: forceAuthoritativeRefresh[\(reason)]")
        requestDraw()
    }

    private func requestDraw() {
        if Thread.isMainThread {
            metalView.draw()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.metalView.draw()
            }
        }
    }

    /// Called when the terminal is resized.
    func resize(rows: Int, cols: Int) {
        guard rows != self.rows || cols != self.cols else { return }
        self.rows = rows
        self.cols = cols
        tripleBuffer = TripleBufferedTerminal(rows: rows, cols: cols)
        tripleBuffer.markFullRefresh()
        needsSync = true
        needsPresent = true
        Log.info("RustMetalDisplayCoordinator: Resized to \(cols)x\(rows)")
        requestDraw()
    }

    /// Called when the color scheme changes.
    func colorSchemeChanged() {
        bridge.colorSchemeChanged()
        syncClearColor()
        tripleBuffer.markFullRefresh()
        needsSync = true
        needsPresent = true
        requestDraw()
    }

    /// Syncs the Metal clear color to the terminal color scheme background.
    private func syncClearColor() {
        let scheme = FeatureSettings.shared.currentColorScheme
        let bg = scheme.nsColor(for: scheme.background)
        if let c = bg.usingColorSpace(.sRGB) {
            metalView.clearColor = MTLClearColor(
                red: Double(c.redComponent),
                green: Double(c.greenComponent),
                blue: Double(c.blueComponent),
                alpha: 1.0
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
        configureFont()
        tripleBuffer.markFullRefresh()
        needsSync = true
        needsPresent = true
        requestDraw()
    }

    // MARK: - Blink

    /// Pause the blink timer when the tab is suspended (saves CPU).
    func pauseBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = nil
    }

    /// Resume the blink timer when the tab is unsuspended.
    func resumeBlinkTimer() {
        guard blinkTimer == nil else { return }
        startBlinkTimer()
    }

    /// Starts the blink timer (cursor and text blink on 500ms cycle).
    private func startBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
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

        // Cursor blink: pause for 1 second after keyboard activity
        let timeSinceActivity = Date().timeIntervalSince(lastActivityTime)
        if timeSinceActivity < 1.0 {
            renderer.cursorBlinkPhase = true
        } else {
            renderer.cursorBlinkPhase.toggle()
        }

        // Text blink: always toggles (independent of keyboard activity)
        renderer.textBlinkPhase.toggle()

        // Only trigger a redraw if cursor or blinking cells need update
        let needsRedraw = renderer.cursorBlinkEnabled || renderer.hasBlinkingCells
        if needsRedraw {
            needsPresent = true
            requestDraw()
        }
    }

    /// Stops rendering (call when the tab is suspended or removed).
    func stop() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        metalView.isPaused = true
    }

    // MARK: - Memory Volatility

    /// Marks the renderer's GPU textures and buffers as volatile. The OS may
    /// reclaim them under memory pressure; if it does, the next promotion will
    /// rebuild. If no pressure occurs, the data is preserved and promotion is
    /// free.
    func markTexturesVolatile() {
        _ = renderer.setAtlasPurgeableState(.volatile)
    }

    /// Marks the renderer's GPU resources as non-volatile and detects whether
    /// the OS reclaimed them while volatile. If reclaimed, clears the CPU glyph
    /// cache so the next draw re-rasterizes into a fresh atlas.
    func markTexturesNonVolatileAndRebuildIfNeeded() {
        let prior = renderer.setAtlasPurgeableState(.nonVolatile)
        if prior == .empty {
            Log.info("RustMetalDisplayCoordinator: atlas reclaimed by OS — rebuilding on next draw")
            renderer.clearGlyphCache()
            needsSync = true
            requestDraw()
        }
    }
}

// MARK: - TabMetalVolatility

extension RustMetalDisplayCoordinator: TabMetalVolatility {
    func setTexturesVolatile(_ volatile: Bool) {
        if volatile {
            markTexturesVolatile()
        } else {
            markTexturesNonVolatileAndRebuildIfNeeded()
        }
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
        let shouldSync = needsSync
        let shouldPresent = needsPresent || shouldSync
        guard shouldPresent else { return }
        needsSync = false
        needsPresent = false

        // Ensure font is configured (may not be ready at init if window isn't available yet)
        if !fontConfigured { configureFont() }
        guard fontConfigured else {
            let now = CFAbsoluteTimeGetCurrent()
            if now - Self.lastWarningLogTime > Self.warningCooldown {
                Log.debug("RustMetalDisplayCoordinator: draw skipped — font not configured")
                Self.lastWarningLogTime = now
            }
            return
        }

        let token = FeatureProfiler.shared.begin(.metalRender, metadata: shouldSync ? "sync" : "present-only")

        if shouldSync {
            // 1. Get grid snapshot from Rust via the provider closure
            guard let snapshot = gridProvider?() else {
                let now = CFAbsoluteTimeGetCurrent()
                if now - Self.lastWarningLogTime > Self.warningCooldown {
                    Log.debug("RustMetalDisplayCoordinator: draw skipped — gridProvider returned nil")
                    Self.lastWarningLogTime = now
                }
                FeatureProfiler.shared.end(token)
                return
            }
            defer { snapshot.free() }

            // 2. Update dangerous row tints for bridge-level blending
            if let provider = terminalView?.dangerousRowTintsProvider {
                let yDisp = terminalView?.renderTopVisibleRow ?? 0
                let viewRows = rows
                let absTints = provider(yDisp, yDisp + viewRows - 1)
                var simdTints: [Int: SIMD4<Float>] = [:]
                for (absRow, color) in absTints {
                    let vr = absRow - yDisp
                    if vr >= 0, vr < viewRows {
                        let c = color.usingColorSpace(.sRGB) ?? color
                        simdTints[vr] = SIMD4(
                            Float(c.redComponent),
                            Float(c.greenComponent),
                            Float(c.blueComponent),
                            Float(c.alphaComponent)
                        )
                    }
                }
                bridge.rowTints = simdTints
            } else {
                bridge.rowTints = [:]
            }

            // 3. Convert grid pointer to typed pointer and sync to triple buffer.
            let gridPtr = snapshot.grid.assumingMemoryBound(to: RustGridSnapshot.self)
            let renderViewID = terminalView?.viewId ?? 0
            if bridge.syncToTripleBuffer(tripleBuffer, grid: gridPtr, viewID: renderViewID) == nil {
                let gs = gridPtr.pointee
                let newRows = Int(gs.rows)
                let newCols = Int(gs.cols)
                if newRows > 0, newCols > 0 {
                    let rebuildSignature = "\(newCols)x\(newRows)"
                    let rebuildStartedAt = CFAbsoluteTimeGetCurrent()
                    let sameDimensions = newRows == rows && newCols == cols
                    let isRapidDuplicate = sameDimensions && rebuildSignature == lastTripleBufferRebuildSignature
                        && rebuildStartedAt - lastTripleBufferRebuildAt < 0.25

                    if isRapidDuplicate {
                        tripleBuffer.markFullRefresh()
                    } else {
                        if rebuildSignature != lastTripleBufferRebuildSignature || rebuildStartedAt - lastTripleBufferRebuildAt >= 1.0 {
                            Log.info("RustMetalDisplayCoordinator: Grid dimensions changed to \(rebuildSignature), rebuilding triple buffer")
                        }
                        rows = newRows
                        cols = newCols
                        tripleBuffer = TripleBufferedTerminal(rows: newRows, cols: newCols)
                        lastTripleBufferRebuildSignature = rebuildSignature
                        lastTripleBufferRebuildAt = rebuildStartedAt
                    }

                    bridge.syncToTripleBuffer(tripleBuffer, grid: gridPtr, viewID: renderViewID)
                    FeatureProfiler.shared.recordMainThreadStallIfNeeded(
                        operation: "RustMetalDisplayCoordinator.rebuildTripleBuffer",
                        startedAt: rebuildStartedAt,
                        thresholdMs: 120,
                        metadata: "grid=\(rebuildSignature) duplicate=\(isRapidDuplicate)"
                    )
                }
            }

            // 4. Update cursor state
            renderer.cursorRow = Int(snapshot.cursor.row)
            renderer.cursorCol = Int(snapshot.cursor.col)
            renderer.cursorStyle = FeatureSettings.shared.cursorStyle
            renderer.cursorVisible = snapshot.cursorVisible

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
            return
        }
        guard let drawable = (view.layer as? CAMetalLayer)?.nextDrawable() else {
            let now = CFAbsoluteTimeGetCurrent()
            if now - Self.lastNoDrawableWarningLogTime > Self.warningCooldown {
                Log.debug("RustMetalDisplayCoordinator: draw skipped — no drawable (bounds=\(view.bounds))")
                Self.lastNoDrawableWarningLogTime = now
            }
            FeatureProfiler.shared.end(token)
            return
        }

        // 6. Render from the triple buffer
        let sourceBuffer = shouldSync ? tripleBuffer.renderBuffer : tripleBuffer.displayBuffer
        let dirtyRows = shouldSync ? tripleBuffer.dirtyRows : IndexSet()
        let fullRefresh = shouldSync ? tripleBuffer.needsFullRefresh : false
        let cellCount = rows * cols
        guard cellCount > 0 else {
            let now = CFAbsoluteTimeGetCurrent()
            if now - Self.lastWarningLogTime > Self.warningCooldown {
                Log.debug("RustMetalDisplayCoordinator: draw skipped — cellCount is 0 (rows=\(rows), cols=\(cols))")
                Self.lastWarningLogTime = now
            }
            FeatureProfiler.shared.end(token)
            return
        }

        // Periodic logging to confirm Metal is actively rendering
        let now = CFAbsoluteTimeGetCurrent()
        if now - Self.lastDrawLogTime > 5.0 {
            Self.lastDrawLogTime = now
            Log.trace("RustMetalDisplayCoordinator: Metal render — \(cols)x\(rows) (\(cellCount) cells), drawCalls=\(Self.drawCallCount), viewport=\(view.bounds.size)")
        }

        let cellsPtr = UnsafeBufferPointer(sourceBuffer.cells)
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
        renderer.render(
            cells: cellsPtr,
            rows: rows,
            cols: cols,
            dirtyRows: dirtyRows,
            fullRefresh: fullRefresh,
            to: drawable,
            viewportSize: view.bounds.size
        )

        terminalView?.onDisplayFramePresented?()
        terminalView?.onFramePresented?()

        // 7. Advance triple buffer only when we consumed fresh synced terminal state.
        if shouldSync {
            tripleBuffer.presentFrame()
        }

        FeatureProfiler.shared.end(token)
    }
}
