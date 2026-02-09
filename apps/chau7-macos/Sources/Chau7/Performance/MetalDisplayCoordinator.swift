// MARK: - Metal Display Coordinator
// Orchestrates the Metal rendering pipeline for a SwiftTerm-backed terminal.
// SwiftTerm remains the source of truth (PTY I/O, parsing, selection, scroll).
// Metal provides an alternative GPU-accelerated display path.

import Foundation
import MetalKit
import SwiftTerm

/// Coordinates SwiftTerm → TripleBuffer → Metal rendering.
/// Owns the bridge, buffers, renderer, and Metal view.
/// Attach to a TerminalContainerView to enable GPU rendering.
final class MetalDisplayCoordinator: NSObject {

    // MARK: - Components

    private let bridge: SwiftTermBridge
    private var tripleBuffer: TripleBufferedTerminal
    private let renderer: MetalTerminalRenderer
    let metalView: OptimalMetalView

    // MARK: - State

    private weak var terminalView: Chau7TerminalView?
    private var needsSync = true
    private var rows: Int
    private var cols: Int
    private var fontConfigured = false

    // MARK: - Init

    /// Creates a coordinator for the given terminal view.
    /// Returns nil if Metal is not available.
    init?(terminalView: Chau7TerminalView) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Log.warn("MetalDisplayCoordinator: Metal not available")
            return nil
        }

        guard let renderer = MetalTerminalRenderer(device: device) else {
            Log.warn("MetalDisplayCoordinator: Failed to create renderer")
            return nil
        }

        let terminal = terminalView.getTerminal()
        let rows = terminal.rows
        let cols = terminal.cols

        self.terminalView = terminalView
        self.renderer = renderer
        self.rows = rows
        self.cols = cols
        self.bridge = SwiftTermBridge(terminalView: terminalView)
        self.tripleBuffer = TripleBufferedTerminal(rows: rows, cols: cols)
        self.metalView = OptimalMetalView(frame: .zero, device: device)

        super.init()

        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.isEventPassthrough = true
        metalView.delegate = self

        // Configure font from the terminal view
        configureFont()

        Log.info("MetalDisplayCoordinator: Initialized (\(cols)x\(rows))")
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

    /// Called when SwiftTerm's buffer changes. Marks that a sync + render is needed.
    /// Dispatches to main thread if called from a background thread (PTY I/O can fire from any thread).
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
        Log.info("MetalDisplayCoordinator: Resized to \(cols)x\(rows)")
    }

    /// Called when the color scheme changes.
    func colorSchemeChanged() {
        bridge.invalidatePalette()
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

extension MetalDisplayCoordinator: MTKViewDelegate {

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Handled by resize() from the container
    }

    func draw(in view: MTKView) {
        guard needsSync else { return }
        needsSync = false

        // Ensure font is configured (may not be ready at init if window isn't available yet)
        if !fontConfigured { configureFont() }
        guard fontConfigured else { return }  // Don't render without a configured font

        let token = FeatureProfiler.shared.begin(.metalRender)

        // 1. Sync SwiftTerm state → triple buffer
        bridge.syncToTripleBuffer(tripleBuffer)

        // 2. Update cursor state from SwiftTerm
        if let view = terminalView {
            let terminal = view.getTerminal()
            renderer.cursorRow = terminal.buffer.y
            renderer.cursorCol = terminal.buffer.x
            renderer.cursorStyle = FeatureSettings.shared.cursorStyle
            renderer.cursorVisible = true
            if let cc = view.caretColor.usingColorSpace(.sRGB) {
                renderer.cursorColor = SIMD4(
                    Float(cc.redComponent),
                    Float(cc.greenComponent),
                    Float(cc.blueComponent),
                    0.8
                )
            }
        }

        // 3. Get drawable
        guard let drawable = (view.layer as? CAMetalLayer)?.nextDrawable() else {
            FeatureProfiler.shared.end(token)
            return
        }

        // 4. Render from the triple buffer
        let renderBuf = tripleBuffer.renderBuffer
        let cellCount = rows * cols
        guard cellCount > 0 else {
            FeatureProfiler.shared.end(token)
            return
        }

        let cellsPtr = UnsafeBufferPointer(renderBuf.cells)
        // Use view bounds (points) for projection, not pixel-space drawable texture.
        // Cell positions are in point-space (cellSize / scaleFactor).
        renderer.render(
            cells: cellsPtr,
            rows: rows,
            cols: cols,
            to: drawable,
            viewportSize: view.bounds.size
        )

        // 5. Advance triple buffer
        tripleBuffer.presentFrame()

        FeatureProfiler.shared.end(token)
    }
}
