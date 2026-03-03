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
    func syncToTripleBuffer(_ buffer: TripleBufferedTerminal, grid: UnsafeMutablePointer<RustGridSnapshot>) -> (rows: Int, cols: Int)? {
        let snapshot = grid.pointee
        guard let cells = snapshot.cells else { return nil }

        let gridRows = Int(snapshot.rows)
        let gridCols = Int(snapshot.cols)

        // If dimensions differ, signal the caller to resize by returning nil.
        // But still render whatever overlaps so the screen isn't blank during the transition.
        let mismatch = gridRows != buffer.rows || gridCols != buffer.cols

        // Sync the overlapping region — avoids blank frames during resize transitions.
        let syncRows = min(gridRows, buffer.rows)
        let syncCols = min(gridCols, buffer.cols)

        for row in 0..<syncRows {
            for col in 0..<syncCols {
                let idx = row * gridCols + col
                let rustCell = cells[idx]
                let metalCell = convertCell(rustCell, row: row)
                buffer.setCell(row: row, col: col, metalCell)
            }
        }

        buffer.commitUpdate()
        return mismatch ? nil : (rows: syncRows, cols: syncCols)
    }

    // MARK: - Cell Conversion

    /// Converts a single Rust CellData to a Metal TerminalCell, blending any row tint.
    @inline(__always)
    private func convertCell(_ cell: RustCellData, row: Int) -> TerminalCell {
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
        // Underline variant in bits 8-10 (from _pad bits 0-2)
        metalFlags |= UInt32(cell._pad & 0x07) << 8

        return TerminalCell(
            character: cell.character,
            foreground: fg,
            background: bg,
            flags: metalFlags
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
