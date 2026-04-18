// MARK: - Rust Metal Display Coordinator

// Orchestrates the Metal rendering pipeline for the Rust terminal backend.
// pollAndSync() → onDisplaySyncNeeded → setNeedsSync() → draw(in:) reads grid
// via gridProvider → converts RustCellData directly into CellInstance ring buffer
// → renderer submits single-pass draw call.

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

/// Coordinates Rust Terminal → CellInstance → Metal rendering.
/// Owns the renderer and Metal view. Converts Rust cells directly into GPU buffers.
final class RustMetalDisplayCoordinator: NSObject {

    // MARK: - Components

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

    /// Dangerous-row tint cache (viewport-relative row → packed RGBA)
    private var rowTints: [Int: UInt32] = [:]

    /// Default colors from color scheme (packed RGBA)
    private var defaultFgPacked: UInt32 = CellInstance.packColor(1, 1, 1, 1)
    private var defaultBgPacked: UInt32 = CellInstance.packColor(0, 0, 0, 1)

    /// Per-frame profiler delta tracking
    private var lastGlyphLookupCount = 0
    private var lastGlyphMissCount = 0

    /// Previous frame's Rust cell data for dirty-row detection.
    /// Only rows that actually changed get reconverted + re-uploaded.
    private var previousCells: UnsafeMutableBufferPointer<RustCellData>?
    private var previousCellCapacity = 0
    /// When true, the next sync frame skips dirty detection and converts all rows.
    /// Set by font changes, color scheme changes, and forced refreshes.
    private var forceFullConversion = true

    // MARK: - Blink Timer

    private var blinkTimer: Timer?
    private var lastActivityTime = Date()

    // MARK: - Init

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
        self.metalView = OptimalMetalView(frame: .zero, device: device)

        super.init()

        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.isEventPassthrough = true
        metalView.delegate = self

        configureFont()
        updateColorScheme()

        // Pre-allocate ring buffers for current grid size
        renderer.ensureCapacity(cells: rows * cols)

        Log.trace("RustMetalDisplayCoordinator: Initialized (\(cols)x\(rows))")
        startBlinkTimer()
    }

    deinit {
        blinkTimer?.invalidate()
        previousCells?.baseAddress?.deinitialize(count: previousCellCapacity)
        previousCells?.baseAddress?.deallocate()
    }

    // MARK: - Font

    private func configureFont() {
        guard let view = terminalView else { return }
        let font = view.font
        let scaleFactor = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0

        renderer.setFont(nsFont: font, scaleFactor: scaleFactor)

        if let metalLayer = metalView.layer as? CAMetalLayer {
            metalLayer.contentsScale = scaleFactor
        }

        fontConfigured = true
    }

    // MARK: - Color Scheme

    private func updateColorScheme() {
        let scheme = FeatureSettings.shared.currentColorScheme

        // Parse scheme background for clear color
        let bgHex = scheme.background
        let bgColor = hexToRGB(bgHex)
        renderer.clearColor = bgColor
        defaultBgPacked = CellInstance.packColor(bgColor.r, bgColor.g, bgColor.b, 1.0)

        let fgHex = scheme.foreground
        let fgColor = hexToRGB(fgHex)
        defaultFgPacked = CellInstance.packColor(fgColor.r, fgColor.g, fgColor.b, 1.0)
    }

    private func hexToRGB(_ hex: String) -> (r: Float, g: Float, b: Float) {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let val = UInt32(h, radix: 16) else {
            return (0.5, 0.5, 0.5)
        }
        return (
            Float((val >> 16) & 0xFF) / 255.0,
            Float((val >> 8) & 0xFF) / 255.0,
            Float(val & 0xFF) / 255.0
        )
    }

    // MARK: - Lifecycle (Public Interface — preserved exactly)

    func setNeedsSync() {
        needsSync = true
        needsPresent = true
        lastActivityTime = Date()
        renderer.cursorBlinkPhase = true
        requestDraw()
    }

    func forceAuthoritativeRefresh(reason: String) {
        needsSync = true
        needsPresent = true
        forceFullConversion = true
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

    func resize(rows: Int, cols: Int) {
        guard rows != self.rows || cols != self.cols else { return }
        self.rows = rows
        self.cols = cols
        renderer.ensureCapacity(cells: rows * cols)
        renderer.resetBlinkTracking(rows: rows)
        needsSync = true
        needsPresent = true
        forceFullConversion = true
        Log.info("RustMetalDisplayCoordinator: Resized to \(cols)x\(rows)")
        requestDraw()
    }

    func colorSchemeChanged() {
        updateColorScheme()
        needsSync = true
        needsPresent = true
        forceFullConversion = true
        requestDraw()
    }

    func fontChanged() {
        configureFont()
        needsSync = true
        needsPresent = true
        forceFullConversion = true
        requestDraw()
    }

    // MARK: - Blink & Watchdog

    /// Whether the blink timer is in active (500ms) or watchdog (2s) mode.
    private var blinkTimerActive = true

    func pauseBlinkTimer() {
        // Don't kill the timer — downgrade to a slow watchdog that can
        // self-recover if the tab lifecycle system fails to resume us.
        guard blinkTimerActive else { return }
        blinkTimerActive = false
        installBlinkTimer()
    }

    func resumeBlinkTimer() {
        guard !blinkTimerActive else { return }
        blinkTimerActive = true
        installBlinkTimer()
        // Force an immediate sync so the user sees content right away
        needsSync = true
        needsPresent = true
        requestDraw()
    }

    private func installBlinkTimer() {
        blinkTimer?.invalidate()
        let interval: TimeInterval = blinkTimerActive ? 0.5 : 2.0
        blinkTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.handleBlinkTick()
        }
    }

    private func startBlinkTimer() {
        blinkTimerActive = true
        installBlinkTimer()
    }

    private func handleBlinkTick() {
        guard let window = metalView.window,
              window.isVisible,
              window.occlusionState.contains(.visible) else {
            return
        }

        if blinkTimerActive {
            // Normal blink mode: toggle cursor and text blink phases
            let timeSinceActivity = Date().timeIntervalSince(lastActivityTime)
            if timeSinceActivity < 1.0 {
                renderer.cursorBlinkPhase = true
            } else {
                renderer.cursorBlinkPhase.toggle()
            }
            renderer.textBlinkPhase.toggle()

            if renderer.cursorBlinkEnabled || renderer.hasBlinkingCells {
                needsPresent = true
                requestDraw()
            }
        } else {
            // Watchdog mode: the tab lifecycle system paused us, but if the
            // window is visible and the terminal view is supposed to be live,
            // force a recovery. This catches the case where SwiftUI's
            // updateNSView never fires to reconcile the polling mode.
            guard let view = terminalView,
                  view.notifyUpdateChanges,
                  !view.isHidden else {
                return
            }
            Log.info("RustMetalDisplayCoordinator: watchdog recovery — terminal visible but rendering paused, forcing resume")
            blinkTimerActive = true
            installBlinkTimer()
            needsSync = true
            needsPresent = true
            lastActivityTime = Date()
            renderer.cursorBlinkPhase = true
            requestDraw()
            // Also kick the terminal view's polling loop back to life
            view.updatePollingMode(reason: "metalWatchdogRecovery")
        }
    }

    func stop() {
        blinkTimer?.invalidate()
        blinkTimer = nil
        metalView.isPaused = true
    }

    // MARK: - Memory Volatility

    func markTexturesVolatile() {
        _ = renderer.setAtlasPurgeableState(.volatile)
    }

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

        guard shouldSync else {
            // Present-only (blink phase change): re-render with existing instance data
            presentCurrentBuffer(view: view, token: token)
            return
        }

        // 1. Get grid snapshot from Rust
        guard let snapshot = gridProvider?() else {
            // Grid not available yet (terminal starting up). Restore needsSync so
            // the next poll cycle re-enters the sync path instead of falling through
            // to present-only (which would fire restoration callbacks prematurely).
            needsSync = true
            let now = CFAbsoluteTimeGetCurrent()
            if now - Self.lastWarningLogTime > Self.warningCooldown {
                Log.debug("RustMetalDisplayCoordinator: draw skipped — gridProvider returned nil")
                Self.lastWarningLogTime = now
            }
            FeatureProfiler.shared.end(token)
            return
        }
        defer { snapshot.free() }

        let gridPtr = snapshot.grid.assumingMemoryBound(to: RustGridSnapshot.self)
        let gs = gridPtr.pointee
        let gridRows = Int(gs.rows)
        let gridCols = Int(gs.cols)

        // Handle grid dimension changes
        if gridRows != rows || gridCols != cols {
            if gridRows > 0, gridCols > 0 {
                rows = gridRows
                cols = gridCols
                renderer.ensureCapacity(cells: gridRows * gridCols)
                renderer.resetBlinkTracking(rows: gridRows)
            }
        }

        let cellCount = rows * cols
        guard cellCount > 0 else {
            needsSync = true
            FeatureProfiler.shared.end(token)
            return
        }

        guard let rustCells = gs.cells else {
            needsSync = true
            FeatureProfiler.shared.end(token)
            return
        }

        // 2. Sync settings + cursor state (needed before dirty-row detection)
        renderer.ligaturesEnabled = FeatureSettings.shared.enableLigatures
        renderer.cursorRow = Int(snapshot.cursor.row)
        renderer.cursorCol = Int(snapshot.cursor.col)
        renderer.cursorStyle = FeatureSettings.shared.cursorStyle
        renderer.cursorVisible = snapshot.cursorVisible

        let scheme = FeatureSettings.shared.currentColorScheme
        let cursorNSColor = scheme.nsColor(for: scheme.cursor)
        if let cc = cursorNSColor.usingColorSpace(.sRGB) {
            renderer.cursorColor = SIMD4(
                Float(cc.redComponent), Float(cc.greenComponent), Float(cc.blueComponent), 0.8
            )
        }

        // 3. Update dangerous row tints
        updateRowTints()

        // 4. Dirty-row detection: compare current Rust cells against previous frame.
        // Only rows with actual cell changes get reconverted. Unchanged rows are
        // copied from the previous instance buffer (a memcpy of CellInstance structs).
        let instanceStartedAt = CFAbsoluteTimeGetCurrent()
        renderer.ensureCapacity(cells: cellCount)

        let syncRows = min(gridRows, rows)
        let syncCols = min(gridCols, cols)
        let rustCellStride = MemoryLayout<RustCellData>.stride

        // The previousCells buffer uses a fixed layout of `cols` cells per row
        // (matching the instance buffer). We only compare `syncCols` cells per
        // row so the comparison window is safe for both source and destination.
        // If grid dimensions changed, force a full refresh to avoid misaligned reads.
        let dimensionMismatch = gridCols != cols || gridRows != rows

        // Ensure previous-frame cell buffer is allocated
        let needsBufferRealloc = previousCellCapacity < cellCount
        if needsBufferRealloc {
            previousCells?.baseAddress?.deinitialize(count: previousCellCapacity)
            previousCells?.baseAddress?.deallocate()
            let ptr = UnsafeMutablePointer<RustCellData>.allocate(capacity: cellCount)
            memset(ptr, 0, cellCount * rustCellStride)
            previousCells = UnsafeMutableBufferPointer(start: ptr, count: cellCount)
            previousCellCapacity = cellCount
        }

        // Determine which rows need conversion
        let mustConvertAll = needsBufferRealloc || forceFullConversion || dimensionMismatch
        forceFullConversion = false

        var dirtyRowSet = IndexSet()
        if mustConvertAll {
            dirtyRowSet = IndexSet(integersIn: 0 ..< syncRows)
        } else if let prevCells = previousCells?.baseAddress {
            let compareBytes = syncCols * rustCellStride
            for row in 0 ..< syncRows {
                let offset = row * cols
                if memcmp(
                    rustCells.advanced(by: row * gridCols),
                    prevCells.advanced(by: offset),
                    compareBytes
                ) != 0 {
                    dirtyRowSet.insert(row)
                }
            }
        }

        // Also mark cursor rows dirty (old + new position)
        let cursorState = renderer.currentCursorRenderState(cellCount: cellCount, cols: cols)
        let cursorDirty = renderer.cursorDirtyRows(currentState: cursorState, totalRows: syncRows)
        dirtyRowSet.formUnion(cursorDirty)

        // Get the ring buffer. For unchanged rows, copy from previous instance buffer.
        let instanceBuffer = renderer.nextInstanceBuffer()
        let instances = instanceBuffer.contents().bindMemory(to: CellInstance.self, capacity: cellCount)

        // Copy previous instance data for clean rows (if we have a previous buffer)
        if !mustConvertAll, renderer.instanceBuffers.count == MetalTerminalRenderer.ringBufferCount {
            let bufCount = MetalTerminalRenderer.ringBufferCount
            let prevRingIndex = (renderer.ringIndex + bufCount - 1) % bufCount
            let prevBuffer = renderer.instanceBuffers[prevRingIndex]
            let prevInstances = prevBuffer.contents().bindMemory(to: CellInstance.self, capacity: cellCount)
            let instanceStride = MemoryLayout<CellInstance>.stride
            for row in 0 ..< syncRows where !dirtyRowSet.contains(row) {
                let rowStart = row * cols
                memcpy(
                    instances.advanced(by: rowStart),
                    prevInstances.advanced(by: rowStart),
                    cols * instanceStride
                )
            }
        }

        // Convert only dirty rows
        for row in dirtyRowSet where row < syncRows {
            var ligatureSkip = 0
            var ligatureRect = CGRect.zero
            var ligatureSpan = 0
            var ligatureSlice = 0

            for col in 0 ..< syncCols {
                let rustIndex = row * gridCols + col
                let outIndex = row * cols + col
                let cell = rustCells[rustIndex]

                let isBold = (cell.flags & RustCellFlags.bold) != 0
                let isItalic = (cell.flags & RustCellFlags.italic) != 0

                // Convert colors: u8 RGB → SIMD4<Float>, apply inverse/dim/hidden, then pack
                var fgR = Float(cell.fg_r) / 255.0
                var fgG = Float(cell.fg_g) / 255.0
                var fgB = Float(cell.fg_b) / 255.0
                var bgR = Float(cell.bg_r) / 255.0
                var bgG = Float(cell.bg_g) / 255.0
                var bgB = Float(cell.bg_b) / 255.0

                if cell.flags & RustCellFlags.inverse != 0 {
                    swap(&fgR, &bgR)
                    swap(&fgG, &bgG)
                    swap(&fgB, &bgB)
                }
                if cell.flags & RustCellFlags.dim != 0 {
                    fgR *= 0.6
                    fgG *= 0.6
                    fgB *= 0.6
                }

                var fgPacked = CellInstance.packColor(fgR, fgG, fgB, 1.0)
                var bgPacked = CellInstance.packColor(bgR, bgG, bgB, 1.0)

                if cell.flags & RustCellFlags.hidden != 0 {
                    fgPacked = bgPacked
                }

                // Blend dangerous-row tint
                if let tintPacked = rowTints[row] {
                    bgPacked = blendTint(base: bgPacked, tint: tintPacked)
                }

                // Map Rust flags → Metal flags (bits 0-3: bold, italic, underline, strikethrough)
                // Note: Rust's inverse/dim/hidden are handled above as color transforms.
                // Rust does not expose a blink flag — blink (Metal bit 4) is unused from Rust.
                let metalFlags = UInt32(cell.flags & RustCellFlags.metalStyleMask)
                    | (UInt32(cell._pad & 0x07) << 8) // underline variant in bits 8-10

                // Glyph lookup (with ligature support)
                var texCoord = SIMD4<Float>(0, 0, 0, 0)

                if renderer.ligaturesEnabled, cell.character >= 0x21, cell.character < 0x7F, ligatureSkip <= 0 {
                    if let lig = renderer.tryLigature(
                        cells: rustCells, index: rustIndex, count: gridRows * gridCols,
                        cols: gridCols, bold: isBold, italic: isItalic
                    ) {
                        let sliceWidth = Float(lig.textureRect.width) / Float(lig.cellSpan)
                        texCoord = SIMD4(
                            Float(lig.textureRect.origin.x),
                            Float(lig.textureRect.origin.y),
                            sliceWidth,
                            Float(lig.textureRect.height)
                        )
                        ligatureSkip = lig.cellSpan - 1
                        ligatureRect = lig.textureRect
                        ligatureSpan = lig.cellSpan
                        ligatureSlice = 1
                    }
                }

                if ligatureSkip > 0, texCoord == SIMD4(0, 0, 0, 0) {
                    let sliceWidth = Float(ligatureRect.width) / Float(ligatureSpan)
                    texCoord = SIMD4(
                        Float(ligatureRect.origin.x) + sliceWidth * Float(ligatureSlice),
                        Float(ligatureRect.origin.y),
                        sliceWidth,
                        Float(ligatureRect.height)
                    )
                    ligatureSlice += 1
                    ligatureSkip -= 1
                } else if texCoord == SIMD4(0, 0, 0, 0),
                          let info = renderer.lookupGlyph(codePoint: cell.character, bold: isBold, italic: isItalic) {
                    texCoord = SIMD4(
                        Float(info.textureRect.origin.x),
                        Float(info.textureRect.origin.y),
                        Float(info.textureRect.width),
                        Float(info.textureRect.height)
                    )
                }

                instances[outIndex] = CellInstance(
                    texCoord: texCoord,
                    colors: SIMD2(fgPacked, bgPacked),
                    flags: metalFlags
                )
            }

            // Fill remaining columns if grid is narrower than our buffer
            if syncCols < cols {
                for col in syncCols ..< cols {
                    let outIndex = row * cols + col
                    instances[outIndex] = CellInstance(
                        texCoord: SIMD4(0, 0, 0, 0),
                        colors: SIMD2(defaultFgPacked, defaultBgPacked),
                        flags: 0
                    )
                }
            }

            renderer.updateBlinkForRow(row, hasBlink: false)
        }

        // Fill remaining rows
        for row in syncRows ..< rows {
            for col in 0 ..< cols {
                let outIndex = row * cols + col
                instances[outIndex] = CellInstance(
                    texCoord: SIMD4(0, 0, 0, 0),
                    colors: SIMD2(defaultFgPacked, defaultBgPacked),
                    flags: 0
                )
            }
            renderer.updateBlinkForRow(row, hasBlink: false)
        }

        renderer.finalizeBlinkState()

        // Save current Rust cells for next-frame dirty detection.
        // Layout: `cols` cells per row (matching instance buffer), copying
        // only `syncCols` cells from the Rust grid per row.
        if let prevPtr = previousCells?.baseAddress, !dimensionMismatch {
            for row in 0 ..< syncRows {
                memcpy(
                    prevPtr.advanced(by: row * cols),
                    rustCells.advanced(by: row * gridCols),
                    syncCols * rustCellStride
                )
            }
        }

        let instanceDurationMs = (CFAbsoluteTimeGetCurrent() - instanceStartedAt) * 1000.0
        FeatureProfiler.shared.record(feature: .metalInstanceBuffer, durationMs: instanceDurationMs)

        // Profiler: record sync stats for the render pipeline dashboard
        let frameGlyphLookups = renderer.glyphLookupCount - lastGlyphLookupCount
        let frameGlyphMisses = renderer.glyphCacheMisses - lastGlyphMissCount
        lastGlyphLookupCount = renderer.glyphLookupCount
        lastGlyphMissCount = renderer.glyphCacheMisses
        if let viewID = terminalView?.viewId {
            RenderPipelineProfiler.shared.recordSync(
                viewID: viewID,
                rows: gridRows,
                cols: gridCols,
                syncedRows: syncRows,
                syncedCols: syncCols,
                mismatched: gridRows != rows || gridCols != cols,
                bytesWritten: cellCount * MemoryLayout<CellInstance>.stride
            )
            RenderPipelineProfiler.shared.recordInstanceBuffer(
                cells: cellCount,
                bufferBytes: cellCount * MemoryLayout<CellInstance>.stride,
                saturated: false,
                glyphLookups: frameGlyphLookups,
                glyphMisses: frameGlyphMisses,
                glyphCacheSize: renderer.glyphCacheCount,
                ligatureCacheSize: renderer.ligatureCacheCount
            )
        }

        // 5. Apply cursor to instance data
        renderer.applyCursor(to: instances, cellCount: cellCount, cols: cols, cursorState: cursorState)

        // 6. Render
        guard view.bounds.width > 0, view.bounds.height > 0 else {
            FeatureProfiler.shared.end(token)
            return
        }
        guard let drawable = (view.layer as? CAMetalLayer)?.nextDrawable() else {
            let now = CFAbsoluteTimeGetCurrent()
            if now - Self.lastNoDrawableWarningLogTime > Self.warningCooldown {
                Log.debug("RustMetalDisplayCoordinator: draw skipped — no drawable")
                Self.lastNoDrawableWarningLogTime = now
            }
            FeatureProfiler.shared.end(token)
            return
        }

        let renderStartedAt = CFAbsoluteTimeGetCurrent()
        renderer.render(
            instanceBuffer: instanceBuffer,
            cellCount: cellCount,
            rows: rows,
            cols: cols,
            to: drawable,
            viewportSize: view.bounds.size
        )
        let renderDurationMs = (CFAbsoluteTimeGetCurrent() - renderStartedAt) * 1000.0
        FeatureProfiler.shared.record(feature: .metalDrawStage, durationMs: renderDurationMs)

        // Periodic logging
        let now = CFAbsoluteTimeGetCurrent()
        if now - Self.lastDrawLogTime > 5.0 {
            Self.lastDrawLogTime = now
            Log.trace("RustMetalDisplayCoordinator: Metal render — \(cols)x\(rows) (\(cellCount) cells), drawCalls=\(Self.drawCallCount)")
        }

        terminalView?.onDisplayFramePresented?()
        terminalView?.onFramePresented?()

        if let viewID = terminalView?.viewId {
            RenderPipelineProfiler.shared.recordDraw(viewID: viewID, cellCount: cellCount)
        }

        FeatureProfiler.shared.end(token)
    }

    // MARK: - Present-Only (Blink)

    /// Re-renders using the most recently written ring buffer slot (for blink phase changes).
    /// The instance data is already populated — we just need a new draw call with updated uniforms.
    private func presentCurrentBuffer(view: MTKView, token: FeatureProfiler.Token) {
        let cellCount = rows * cols
        guard cellCount > 0,
              view.bounds.width > 0, view.bounds.height > 0,
              let drawable = (view.layer as? CAMetalLayer)?.nextDrawable() else {
            FeatureProfiler.shared.end(token)
            return
        }

        // The ring index was advanced after the last write (by nextInstanceBuffer()),
        // so the most recent data is in the buffer one slot behind current.
        let bufCount = MetalTerminalRenderer.ringBufferCount
        let lastIndex = (renderer.ringIndex + bufCount - 1) % bufCount
        let buffer = renderer.instanceBuffers[lastIndex]

        renderer.render(
            instanceBuffer: buffer,
            cellCount: cellCount,
            rows: rows,
            cols: cols,
            to: drawable,
            viewportSize: view.bounds.size
        )

        // Do NOT fire onDisplayFramePresented/onFramePresented from present-only
        // redraws. These callbacks trigger the restore overlay handoff. Firing them
        // from a blink-only redraw (which may use zero-initialized buffer data if
        // no sync frame has been rendered yet) causes premature handoff — showing
        // the Metal clear color before the terminal has actual content.
        FeatureProfiler.shared.end(token)
    }

    // MARK: - Row Tints

    private func updateRowTints() {
        guard let provider = terminalView?.dangerousRowTintsProvider else {
            rowTints = [:]
            return
        }
        let yDisp = terminalView?.renderTopVisibleRow ?? 0
        let viewRows = rows
        let absTints = provider(yDisp, yDisp + viewRows - 1)
        var packed: [Int: UInt32] = [:]
        for (absRow, color) in absTints {
            let vr = absRow - yDisp
            if vr >= 0, vr < viewRows {
                let c = color.usingColorSpace(.sRGB) ?? color
                packed[vr] = CellInstance.packColor(
                    Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), Float(c.alphaComponent)
                )
            }
        }
        rowTints = packed
    }

    /// Blend a tint over a base color (both packed RGBA u8). Alpha-weighted.
    @inline(__always)
    private func blendTint(base: UInt32, tint: UInt32) -> UInt32 {
        let bR = Float(base & 0xFF) / 255.0
        let bG = Float((base >> 8) & 0xFF) / 255.0
        let bB = Float((base >> 16) & 0xFF) / 255.0
        let tR = Float(tint & 0xFF) / 255.0
        let tG = Float((tint >> 8) & 0xFF) / 255.0
        let tB = Float((tint >> 16) & 0xFF) / 255.0
        let tA = Float((tint >> 24) & 0xFF) / 255.0

        let rR = bR * (1 - tA) + tR * tA
        let rG = bG * (1 - tA) + tG * tA
        let rB = bB * (1 - tA) + tB * tA
        return CellInstance.packColor(rR, rG, rB, 1.0)
    }
}
