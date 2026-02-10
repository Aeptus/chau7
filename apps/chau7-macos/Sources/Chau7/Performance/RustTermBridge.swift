// MARK: - Rust Terminal to Metal Bridge
// Converts Rust's CellData (pre-resolved u8 RGB) into TerminalCell structs
// for GPU rendering via the TripleBufferedTerminal.
//
// Unlike SwiftTermBridge, no palette lookup is needed here: the Rust backend
// resolves colors via ThemeColors before building the GridSnapshot.  The bridge
// simply converts u8 RGB → SIMD4<Float> (divide by 255.0) and maps cell flags.

import Foundation
import simd

/// Bridges a Rust terminal's GridSnapshot to the Metal rendering pipeline.
/// Reads cell data from the FFI GridSnapshot pointer, converts colors to
/// SIMD4<Float>, and writes TerminalCell structs into the TripleBufferedTerminal.
final class RustTermBridge {

    // MARK: - Types (must match RustTerminalView.swift / chau7_terminal.h)

    /// Cell attribute flags from Rust (matches CellFlags in RustTerminalView.swift)
    private struct RustFlags {
        static let bold: UInt8       = 1 << 0
        static let italic: UInt8     = 1 << 1
        static let underline: UInt8  = 1 << 2
        static let strikethrough: UInt8 = 1 << 3
        static let inverse: UInt8    = 1 << 4
        static let dim: UInt8        = 1 << 5
        static let hidden: UInt8     = 1 << 6
    }

    /// C-compatible cell data matching Rust's CellData.
    /// Must be identical in layout to the struct in RustTerminalView.swift.
    struct CellData {
        var character: UInt32
        var fg_r: UInt8
        var fg_g: UInt8
        var fg_b: UInt8
        var bg_r: UInt8
        var bg_g: UInt8
        var bg_b: UInt8
        var flags: UInt8
        var _pad: UInt8
        var link_id: UInt16  // OSC 8 hyperlink ID (0 = no link)
    }

    /// C-compatible grid snapshot matching Rust's GridSnapshot
    struct GridSnapshot {
        var cells: UnsafeMutablePointer<CellData>?
        var cols: UInt16
        var rows: UInt16
        var cursor_visible: UInt8  // DECTCEM: 0 = hidden, 1 = visible
        var _pad: (UInt8, UInt8, UInt8)  // Alignment padding to next UInt32
        var scrollback_rows: UInt32
        var display_offset: UInt32
        var capacity: Int  // Must match Rust's usize (8 bytes on 64-bit)
    }

    // MARK: - Properties

    /// Default foreground for the current color scheme (used when Rust sends 0,0,0 fg for default)
    private var defaultFg: SIMD4<Float> = SIMD4(1, 1, 1, 1)
    private var defaultBg: SIMD4<Float> = SIMD4(0, 0, 0, 1)

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
    func syncToTripleBuffer(_ buffer: TripleBufferedTerminal, grid: UnsafeMutablePointer<GridSnapshot>) -> (rows: Int, cols: Int)? {
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
                let metalCell = convertCell(rustCell)
                buffer.setCell(row: row, col: col, metalCell)
            }
        }

        buffer.commitUpdate()
        return mismatch ? nil : (rows: syncRows, cols: syncCols)
    }

    // MARK: - Cell Conversion

    /// Converts a single Rust CellData to a Metal TerminalCell.
    @inline(__always)
    private func convertCell(_ cell: CellData) -> TerminalCell {
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
        if flags & RustFlags.inverse != 0 {
            swap(&fg, &bg)
        }

        // Handle dim: reduce fg intensity
        if flags & RustFlags.dim != 0 {
            fg = SIMD4(fg.x * 0.6, fg.y * 0.6, fg.z * 0.6, fg.w)
        }

        // Handle hidden: make fg match bg
        if flags & RustFlags.hidden != 0 {
            fg = bg
        }

        // Map Rust style flags to Metal TerminalCell flags.
        // Metal flags layout:
        //   bits 0-4:  bold=1, italic=2, underline=4, strikethrough=8, blink=16
        //   bit  5:    cursor present
        //   bits 6-7:  cursor style
        //   bits 8-10: underline variant (0=none, 1=single, 2=double, 3=curl, 4=dotted, 5=dashed)
        // Rust flags:  bold=1, italic=2, underline=4, strikethrough=8 (same bit positions!)
        // Inverse/dim/hidden are handled above in color conversion, not passed through.
        var metalFlags: UInt32 = 0
        if flags & RustFlags.bold != 0       { metalFlags |= 1 }
        if flags & RustFlags.italic != 0     { metalFlags |= 2 }
        if flags & RustFlags.underline != 0  { metalFlags |= 4 }
        if flags & RustFlags.strikethrough != 0 { metalFlags |= 8 }
        // Encode underline variant in bits 8-10 (from _pad byte)
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
