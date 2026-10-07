import Chau7Core

// Bridge to the Rust terminal emulator for grid-based rendering.
//
// Wraps `Chau7Core`'s Rust FFI terminal, injecting output byte chunks
// and extracting cell grids (character, foreground/background color, flags)
// for rendering in `RemoteTerminalCanvasView`. Cell flags map to ANSI
// text attributes: bold, italic, underline, strikethrough, inverse, dim, hidden.
import Foundation

struct RustGridSnapshot {
    var cells: UnsafeMutablePointer<RustCellData>?
    var clusters_utf8: UnsafeMutablePointer<UInt8>?
    var clusters_len: Int
    var clusters_capacity: Int
    var cols: UInt16
    var rows: UInt16
    var cursor_visible: UInt8
    var _pad: (UInt8, UInt8, UInt8)
    var scrollback_rows: UInt32
    var display_offset: UInt32
    var capacity: Int
}

/// iOS mirror of the Rust `DisplayRowBuffer` (see chau7_terminal.h).
///
/// The grid already folded to a width the client can paint, so the renderer
/// blits rows straight out of it instead of re-deriving cell indices through a
/// source-to-display mapping.
struct RustDisplayRowBuffer {
    var cells: UnsafeMutablePointer<RustCellData>?
    var cells_capacity: Int
    var clusters_utf8: UnsafeMutablePointer<UInt8>?
    var clusters_len: Int
    var clusters_capacity: Int
    var row_offsets: UnsafeMutablePointer<UInt32>?
    var row_offsets_len: Int
    var row_offsets_capacity: Int
    var cell_count: Int
    var display_cols: UInt16
    var display_rows: UInt16
    var source_cols: UInt16
    var source_rows: UInt16
}

@_silgen_name("chau7_terminal_create_headless")
private nonisolated func chau7_terminal_create_headless(_ cols: UInt16, _ rows: UInt16) -> UnsafeMutableRawPointer?

@_silgen_name("chau7_terminal_destroy")
private nonisolated func chau7_terminal_destroy(_ term: UnsafeMutableRawPointer?)

@_silgen_name("chau7_terminal_resize")
private nonisolated func chau7_terminal_resize(_ term: UnsafeMutableRawPointer?, _ cols: UInt16, _ rows: UInt16)

@_silgen_name("chau7_terminal_get_grid")
private nonisolated func chau7_terminal_get_grid(_ term: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<RustGridSnapshot>?

@_silgen_name("chau7_terminal_free_grid")
private nonisolated func chau7_terminal_free_grid(_ grid: UnsafeMutablePointer<RustGridSnapshot>?)

@_silgen_name("chau7_terminal_inject_output")
private nonisolated func chau7_terminal_inject_output(_ term: UnsafeMutableRawPointer?, _ data: UnsafePointer<UInt8>?, _ len: Int)

@_silgen_name("chau7_terminal_scroll_to")
private nonisolated func chau7_terminal_scroll_to(_ term: UnsafeMutableRawPointer?, _ position: Double)

@_silgen_name("chau7_terminal_cursor_position")
private nonisolated func chau7_terminal_cursor_position(_ term: UnsafeMutableRawPointer?, _ col: UnsafeMutablePointer<UInt16>?, _ row: UnsafeMutablePointer<UInt16>?)

/// C signature of `chau7_terminal_set_colors` (see rust `ffi.rs`):
/// `void set_colors(term, fg_r, fg_g, fg_b, bg_r, bg_g, bg_b,
///                  cursor_r, cursor_g, cursor_b, const uint8_t *palette)`
/// where `palette` points at 48 bytes (16 RGB triplets). The iOS target links
/// the Rust crate as a static archive, so this direct declaration is both
/// safer and cheaper than resolving the symbol dynamically.
@_silgen_name("chau7_terminal_set_colors")
private nonisolated func chau7_terminal_set_colors(
    _ term: UnsafeMutableRawPointer?,
    _ fgR: UInt8, _ fgG: UInt8, _ fgB: UInt8,
    _ bgR: UInt8, _ bgG: UInt8, _ bgB: UInt8,
    _ cursorR: UInt8, _ cursorG: UInt8, _ cursorB: UInt8,
    _ palette: UnsafePointer<UInt8>?
) -> Void

/// C signature of `chau7_terminal_get_display_rows` (see rust `ffi.rs`):
/// `DisplayRowBuffer *chau7_terminal_get_display_rows(term, u16 display_cols)`.
/// The result is already folded to `display_cols`, joined across soft-wrapped
/// rows, and must be released with `chau7_terminal_free_display_rows`.
@_silgen_name("chau7_terminal_get_display_rows")
private nonisolated func chau7_terminal_get_display_rows(
    _ term: UnsafeMutableRawPointer?,
    _ displayCols: UInt16
) -> UnsafeMutablePointer<RustDisplayRowBuffer>?

/// C signature of `chau7_terminal_free_display_rows`:
/// `void chau7_terminal_free_display_rows(DisplayRowBuffer *)`.
@_silgen_name("chau7_terminal_free_display_rows")
private nonisolated func chau7_terminal_free_display_rows(
    _ buffer: UnsafeMutablePointer<RustDisplayRowBuffer>?
) -> Void

final nonisolated class RemoteRustTerminalPlayback {
    private var handle: UnsafeMutableRawPointer?
    private(set) var cols: Int
    private(set) var rows: Int

    init?(cols: Int, rows: Int, colorScheme: TerminalColorScheme = .default) {
        guard cols > 0, rows > 0 else { return nil }
        guard let handle = chau7_terminal_create_headless(UInt16(cols), UInt16(rows)) else { return nil }
        self.handle = handle
        self.cols = cols
        self.rows = rows
        // Push the scheme immediately so default cells render on the scheme's
        // background/foreground instead of the Rust white-on-black default.
        applyColorScheme(colorScheme)
    }

    /// Pushes a color scheme into the Rust terminal so its grid snapshots carry
    /// the scheme's foreground/background/cursor and 16-color ANSI palette.
    func applyColorScheme(_ scheme: TerminalColorScheme) {
        guard let handle else { return }
        let fg = scheme.foregroundRGB888
        let bg = scheme.backgroundRGB888
        let cursor = scheme.cursorRGB888
        scheme.paletteBytes.withUnsafeBufferPointer { buffer in
            chau7_terminal_set_colors(
                handle,
                fg.0, fg.1, fg.2,
                bg.0, bg.1, bg.2,
                cursor.0, cursor.1, cursor.2,
                buffer.baseAddress
            )
        }
    }

    deinit {
        chau7_terminal_destroy(handle)
    }

    func resize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        guard cols != self.cols || rows != self.rows else { return }
        self.cols = cols
        self.rows = rows
        chau7_terminal_resize(handle, UInt16(cols), UInt16(rows))
    }

    func inject(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            chau7_terminal_inject_output(handle, baseAddress, data.count)
        }
    }

    /// Scrolls to a fraction of the live scrollback, where 0 is the newest
    /// output and 1 is the oldest retained row.
    ///
    /// The fraction is resolved against the engine's *current* history size
    /// inside Rust, so a viewport never lands at a row computed from a
    /// `scrollbackRows` value captured before the mutation was queued.
    func scrollToNormalized(_ fraction: Double) {
        chau7_terminal_scroll_to(handle, min(max(fraction, 0), 1))
    }

    /// Fold the engine grid down to `displayCols` phone-width rows.
    ///
    /// The fold is done in Rust because that is the layer that knows which
    /// physical rows are soft-wrap continuations of the line above. Doing it
    /// here would mean re-deriving `row * cols + col` through a source-to-display
    /// mapping on every frame.
    ///
    /// Returns nil if the engine cannot produce a buffer, so the caller can fall
    /// back to folding in Swift.
    func displayRows(displayCols: Int) -> RemoteTerminalDisplayState? {
        guard let handle, displayCols > 0, displayCols <= Int(UInt16.max) else { return nil }
        guard let raw = chau7_terminal_get_display_rows(handle, UInt16(displayCols)) else { return nil }
        defer { chau7_terminal_free_display_rows(raw) }

        let buffer = raw.pointee
        guard buffer.display_rows > 0, buffer.display_cols > 0 else { return nil }
        guard let cellsPointer = buffer.cells, buffer.cell_count > 0 else { return nil }
        guard let offsetsPointer = buffer.row_offsets, buffer.row_offsets_len >= 2 else { return nil }

        let cells = Array(UnsafeBufferPointer(start: cellsPointer, count: buffer.cell_count))
        let rowOffsets = Array(UnsafeBufferPointer(start: offsetsPointer, count: buffer.row_offsets_len))

        // Copy cluster bytes before the defer frees the FFI buffer.
        let clusters: Data
        if let base = buffer.clusters_utf8, buffer.clusters_len > 0 {
            clusters = Data(bytes: base, count: buffer.clusters_len)
        } else {
            clusters = Data()
        }

        return RemoteTerminalDisplayState(
            cells: cells,
            clusters: clusters,
            rowOffsets: rowOffsets,
            displayCols: Int(buffer.display_cols),
            displayRows: Int(buffer.display_rows)
        )
    }

    func snapshot() -> RemoteTerminalRenderState? {
        guard let gridPointer = chau7_terminal_get_grid(handle) else { return nil }
        defer { chau7_terminal_free_grid(gridPointer) }

        let snapshot = gridPointer.pointee
        let cols = Int(snapshot.cols)
        let rows = Int(snapshot.rows)
        guard cols > 0, rows > 0, let cellsPointer = snapshot.cells else { return nil }

        let totalCells = cols * rows
        let cells = Array(UnsafeBufferPointer(start: cellsPointer, count: totalCells))

        // Copy the FFI cluster bytes before the snapshot is freed by the defer.
        let clusters: Data
        if let base = snapshot.clusters_utf8, snapshot.clusters_len > 0 {
            clusters = Data(bytes: base, count: snapshot.clusters_len)
        } else {
            clusters = Data()
        }

        var cursorCol: UInt16 = 0
        var cursorRow: UInt16 = 0
        chau7_terminal_cursor_position(handle, &cursorCol, &cursorRow)

        return RemoteTerminalRenderState(
            cells: cells,
            clusters: clusters,
            cols: cols,
            rows: rows,
            cursorCol: Int(cursorCol),
            cursorRow: Int(cursorRow),
            cursorVisible: snapshot.cursor_visible != 0,
            scrollbackRows: Int(snapshot.scrollback_rows),
            displayOffset: Int(snapshot.display_offset)
        )
    }
}
