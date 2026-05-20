// MARK: - Rust Terminal to Metal Bridge

// Converts Rust's CellData (pre-resolved u8 RGB) into TerminalCell structs
// for GPU rendering via the TripleBufferedTerminal.
//
// No palette lookup is needed: the Rust backend resolves colors via ThemeColors
// before building the GridSnapshot. The bridge simply converts u8 RGB →
// SIMD4<Float> (divide by 255.0) and maps cell flags.

import Foundation
import simd

/// Bridges a Rust terminal's GridSnapshot to the Metal rendering pipeline.
/// Reads cell data from the FFI GridSnapshot pointer, converts colors to
/// SIMD4<Float>, and writes TerminalCell structs into the TripleBufferedTerminal.
final class RustTermBridge {

    // MARK: - Properties

    /// Default foreground for the current color scheme (used when Rust sends 0,0,0 fg for default)
    private var defaultFg: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    private var defaultBg: SIMD4<Float> = SIMD4(0, 0, 0, 1)

    /// Viewport-relative row tints. Set before each syncToTripleBuffer call.
    /// Key = viewport row (0-based), value = SIMD4 RGBA tint color.
    var rowTints: [Int: SIMD4<Float>] = [:]

    // MARK: - Init

    init() {
        // Default colors will be updated when colorSchemeChanged() is called
    }

    // MARK: - Color Scheme

    /// Updates the default foreground/background from the current color scheme.
    /// Call this when the color scheme changes.
    func colorSchemeChanged() {
        let scheme = FeatureSettings.shared.currentColorScheme
        defaultFg = hexToSIMD(scheme.foreground)
        defaultBg = hexToSIMD(scheme.background)
    }

    // MARK: - Sync

    /// Syncs a Rust GridSnapshot into the triple buffer.
    /// - Parameters:
    ///   - buffer: The triple-buffered terminal to write into
    ///   - grid: Pointer to a GridSnapshot obtained from `chau7_terminal_get_grid()`
    /// - Returns: `(rows, cols)` actually synced, or `nil` if the grid should trigger a resize
    @discardableResult
    func syncToTripleBuffer(
        _ buffer: TripleBufferedTerminal,
        grid: UnsafeMutablePointer<RustGridSnapshot>,
        viewID: UInt64
    ) -> (rows: Int, cols: Int)? {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let snapshot = grid.pointee
        guard let cells = snapshot.cells else { return nil }
        let clustersBase = snapshot.clusters_utf8
        let clustersLen = snapshot.clusters_len

        let gridRows = Int(snapshot.rows)
        let gridCols = Int(snapshot.cols)

        // If dimensions differ, signal the caller to resize by returning nil.
        // But still render whatever overlaps so the screen isn't blank during the transition.
        let mismatch = gridRows != buffer.rows || gridCols != buffer.cols

        // Sync the overlapping region — avoids blank frames during resize transitions.
        let syncRows = min(gridRows, buffer.rows)
        let syncCols = min(gridCols, buffer.cols)

        // Rebuild the cluster bytes on the update buffer. Offsets in cells point
        // into this buffer; we reset it each frame so stale ranges can't be read.
        let updateBuf = buffer.updateBuffer
        updateBuf.resetClusters()

        for row in 0 ..< syncRows {
            for col in 0 ..< syncCols {
                let idx = row * gridCols + col
                let rustCell = cells[idx]
                let metalCell = convertCell(
                    rustCell,
                    row: row,
                    sourceClusters: clustersBase,
                    sourceClustersLen: clustersLen,
                    destBuffer: updateBuf
                )
                buffer.setCell(row: row, col: col, metalCell)
            }
        }

        let commitStats = buffer.commitUpdate()
        let durationMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0
        let bytesWritten = syncRows * syncCols * MemoryLayout<TerminalCell>.stride
        RenderPipelineProfiler.shared.recordSync(
            viewID: viewID,
            rows: gridRows,
            cols: gridCols,
            syncedRows: syncRows,
            syncedCols: syncCols,
            mismatched: mismatch,
            bytesWritten: bytesWritten
        )
        FeatureProfiler.shared.record(
            feature: .tripleBufferSync,
            durationMs: durationMs,
            bytes: bytesWritten
        )
        FeatureProfiler.shared.record(
            feature: .tripleBufferCommit,
            durationMs: commitStats.durationMs,
            bytes: commitStats.bytesCopied
        )
        return mismatch ? nil : (rows: syncRows, cols: syncCols)
    }

    // MARK: - Cell Conversion

    /// Converts a single Rust CellData to a Metal TerminalCell, blending any row tint.
    /// Copies the cell's UTF-8 grapheme cluster from the snapshot's cluster buffer
    /// into the destination TerminalBuffer's `clusters` array.
    @inline(__always)
    private func convertCell(
        _ cell: RustCellData,
        row: Int,
        sourceClusters: UnsafeMutablePointer<UInt8>?,
        sourceClustersLen: Int,
        destBuffer: TripleBufferedTerminal.TerminalBuffer
    ) -> TerminalCell {
        let flags = cell.flags

        // Convert u8 RGB → SIMD4<Float>
        var fg = SIMD4<Float>(
            Float(cell.fg_r) / 255.0,
            Float(cell.fg_g) / 255.0,
            Float(cell.fg_b) / 255.0,
            1.0
        )
        var bg = SIMD4<Float>(
            Float(cell.bg_r) / 255.0,
            Float(cell.bg_g) / 255.0,
            Float(cell.bg_b) / 255.0,
            1.0
        )

        // Handle inverse: swap fg/bg
        if flags & RustCellFlags.inverse != 0 {
            swap(&fg, &bg)
        }

        // Handle dim: reduce fg intensity
        if flags & RustCellFlags.dim != 0 {
            fg = SIMD4(fg.x * 0.6, fg.y * 0.6, fg.z * 0.6, fg.w)
        }

        // Handle hidden: make fg match bg
        if flags & RustCellFlags.hidden != 0 {
            fg = bg
        }

        // Blend dangerous-row tint if present
        if let tint = rowTints[row] {
            let alpha = tint.w
            bg = bg * (1.0 - alpha) + SIMD4(tint.x, tint.y, tint.z, 1.0) * alpha
        }

        // Bits 0-3 (bold, italic, underline, strikethrough) have identical positions
        // in Rust and Metal — use a single bitwise widening instead of per-flag branches.
        var metalFlags = UInt32(flags & RustCellFlags.metalStyleMask)
        // Underline variant in bits 8-10
        metalFlags |= UInt32(cell.underline_style & 0x07) << 8
        if cell.link_id > 0, flags & RustCellFlags.underline == 0 {
            metalFlags |= TerminalCell.linkUnderlineFlag
        }

        // Copy the cluster bytes into the destination buffer. Continuation cells
        // and blanks contribute no bytes — they render as background only.
        //
        // If the cluster offset is corrupt or mid-resize, drop the cluster
        // rather than ship a TerminalCell with `clusterLen > 0` pointing at
        // offset 0 — that would make the renderer read unrelated bytes or
        // trap on an empty destination cluster array.
        var clusterStart: UInt32 = 0
        var clusterLen: UInt16 = 0
        if cell.cluster_len > 0 {
            if let src = sourceClusters,
               Int(cell.cluster_offset) + Int(cell.cluster_len) <= sourceClustersLen {
                let slice = UnsafeBufferPointer(
                    start: src.advanced(by: Int(cell.cluster_offset)),
                    count: Int(cell.cluster_len)
                )
                clusterStart = destBuffer.appendCluster(slice)
                clusterLen = cell.cluster_len
            }
        }

        return TerminalCell(
            clusterStart: clusterStart,
            clusterLen: clusterLen,
            foreground: fg,
            background: bg,
            flags: metalFlags,
            width: cell.width,
            continuation: cell.continuation
        )
    }

    // MARK: - Utilities

    /// Converts hex color string (e.g. "#RRGGBB") to SIMD4<Float>
    private func hexToSIMD(_ hex: String) -> SIMD4<Float> {
        var h = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let val = UInt32(h, radix: 16) else {
            return SIMD4(0.5, 0.5, 0.5, 1.0)
        }
        let r = Float((val >> 16) & 0xFF) / 255.0
        let g = Float((val >> 8) & 0xFF) / 255.0
        let b = Float(val & 0xFF) / 255.0
        return SIMD4(r, g, b, 1.0)
    }
}
