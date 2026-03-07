// MARK: - Rust Metal Display Coordinator

// Orchestrates the Metal rendering pipeline for the Rust terminal backend.
// The Rust terminal is the source of truth (PTY I/O, parsing, selection, scroll).
// Metal provides GPU-accelerated display, replacing the CPU-based RustGridView.
//
// Architecture: RustTerminalView.pollAndSync() calls onBufferChanged
//  → container chains setNeedsSync() → draw(in:) reads grid via closure → bridge
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
    private var rows: Int
    private var cols: Int
    private var fontConfigured = false

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

        Log.info("RustMetalDisplayCoordinator: Initialized (\(cols)x\(rows))")

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
        // Record activity — this pauses cursor blink for 1 second after typing
        lastActivityTime = Date()
        renderer.cursorBlinkPhase = true // Show cursor immediately on activity
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
        Log.info("RustMetalDisplayCoordinator: Resized to \(cols)x\(rows)")
    }

    /// Called when the color scheme changes.
    func colorSchemeChanged() {
        bridge.colorSchemeChanged()
        tripleBuffer.markFullRefresh()
        needsSync = true
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
    }

    // MARK: - Blink

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
        // Cursor blink: pause for 1 second after keyboard activity
        let timeSinceActivity = Date().timeIntervalSince(lastActivityTime)
        if timeSinceActivity < 1.0 {
            // Recent activity — keep cursor visible, don't blink
            renderer.cursorBlinkPhase = true
        } else {
            renderer.cursorBlinkPhase.toggle()
        }

        // Text blink: always toggles (independent of keyboard activity)
        renderer.textBlinkPhase.toggle()

        // Only trigger a redraw if cursor or blinking cells need update
        let needsRedraw = renderer.cursorBlinkEnabled || renderer.hasBlinkingCells
        if needsRedraw {
            needsSync = true
            metalView.draw()
        }
    }

    /// Stops rendering (call when the tab is suspended or removed).
    func stop() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        metalView.isPaused = true
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
        guard needsSync else { return }
        needsSync = false

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

        let token = FeatureProfiler.shared.begin(.metalRender)

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
        //    If the bridge returns nil, the grid dimensions changed — rebuild the
        //    triple buffer to match and re-sync immediately.
        let gridPtr = snapshot.grid.assumingMemoryBound(to: RustGridSnapshot.self)
        if bridge.syncToTripleBuffer(tripleBuffer, grid: gridPtr) == nil {
            let gs = gridPtr.pointee
            let newRows = Int(gs.rows)
            let newCols = Int(gs.cols)
            if newRows > 0, newCols > 0 {
                Log.info("RustMetalDisplayCoordinator: Grid dimensions changed to \(newCols)x\(newRows), rebuilding triple buffer")
                rows = newRows
                cols = newCols
                tripleBuffer = TripleBufferedTerminal(rows: newRows, cols: newCols)
                // Re-sync with correctly sized buffer
                bridge.syncToTripleBuffer(tripleBuffer, grid: gridPtr)
            }
        }

        // 4. Update cursor state
        renderer.cursorRow = Int(snapshot.cursor.row)
        renderer.cursorCol = Int(snapshot.cursor.col)
        renderer.cursorStyle = FeatureSettings.shared.cursorStyle
        renderer.cursorVisible = snapshot.cursorVisible

        // Set cursor color from the current color scheme
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
        let renderBuf = tripleBuffer.renderBuffer
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

        let cellsPtr = UnsafeBufferPointer(renderBuf.cells)
        // Use view bounds (points) for the projection matrix, not drawable texture
        // (pixels). Cell positions are calculated in point-space
        // (cw = cellSize.width / scaleFactor), so the orthographic projection
        // must map point-space coordinates. The Metal viewport itself targets
        // the full pixel-space drawable automatically.
        renderer.render(
            cells: cellsPtr,
            rows: rows,
            cols: cols,
            to: drawable,
            viewportSize: view.bounds.size
        )

        // 7. Advance triple buffer
        tripleBuffer.presentFrame()

        FeatureProfiler.shared.end(token)
    }
}
