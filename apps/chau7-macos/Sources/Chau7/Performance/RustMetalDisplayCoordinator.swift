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
    grid: UnsafeMutableRawPointer,  // Points to RustTermBridge.GridSnapshot
    cursor: (col: UInt16, row: UInt16),
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
    }

    // MARK: - Font

    /// Reads font and scale factor from the terminal view and configures the renderer.
    private func configureFont() {
        guard let view = terminalView else { return }
        let font = view.font
        let scaleFactor = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        renderer.setFont(
            name: font.fontName,
            size: font.pointSize,
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
    func fontChanged() {
        configureFont()
        tripleBuffer.markFullRefresh()
        needsSync = true
    }

    /// Stops rendering (call when the tab is suspended or removed).
    func stop() {
        metalView.isPaused = true
    }
}

// MARK: - MTKViewDelegate

extension RustMetalDisplayCoordinator: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handled by resize() from the container
    }

    func draw(in view: MTKView) {
        guard needsSync else { return }
        needsSync = false

        // Ensure font is configured (may not be ready at init if window isn't available yet)
        if !fontConfigured { configureFont() }
        guard fontConfigured else { return }

        let token = FeatureProfiler.shared.begin(.metalRender)

        // 1. Get grid snapshot from Rust via the provider closure
        guard let snapshot = gridProvider?() else {
            FeatureProfiler.shared.end(token)
            return
        }
        defer { snapshot.free() }

        // 2. Convert grid pointer to typed pointer and sync to triple buffer.
        //    If the bridge returns nil, the grid dimensions changed — rebuild the
        //    triple buffer to match and re-sync immediately.
        let gridPtr = snapshot.grid.assumingMemoryBound(to: RustTermBridge.GridSnapshot.self)
        if bridge.syncToTripleBuffer(tripleBuffer, grid: gridPtr) == nil {
            let gs = gridPtr.pointee
            let newRows = Int(gs.rows)
            let newCols = Int(gs.cols)
            if newRows > 0 && newCols > 0 {
                Log.info("RustMetalDisplayCoordinator: Grid dimensions changed to \(newCols)x\(newRows), rebuilding triple buffer")
                rows = newRows
                cols = newCols
                tripleBuffer = TripleBufferedTerminal(rows: newRows, cols: newCols)
                // Re-sync with correctly sized buffer
                bridge.syncToTripleBuffer(tripleBuffer, grid: gridPtr)
            }
        }

        // 3. Update cursor state
        renderer.cursorRow = Int(snapshot.cursor.row)
        renderer.cursorCol = Int(snapshot.cursor.col)
        renderer.cursorStyle = FeatureSettings.shared.cursorStyle
        renderer.cursorVisible = true

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

        // 4. Get drawable
        guard let drawable = (view.layer as? CAMetalLayer)?.nextDrawable() else {
            FeatureProfiler.shared.end(token)
            return
        }

        // 5. Render from the triple buffer
        let renderBuf = tripleBuffer.renderBuffer
        let cellCount = rows * cols
        guard cellCount > 0 else {
            FeatureProfiler.shared.end(token)
            return
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

        // 6. Advance triple buffer
        tripleBuffer.presentFrame()

        FeatureProfiler.shared.end(token)
    }
}
