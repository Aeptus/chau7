import Chau7Core

// Bridge to the Rust terminal emulator for grid-based rendering.
//
// Wraps `Chau7Core`'s Rust FFI terminal, injecting output byte chunks
// and extracting cell grids (character, foreground/background color, flags)
// for rendering in `RemoteTerminalCanvasView`. Cell flags map to ANSI
// text attributes: bold, italic, underline, strikethrough, inverse, dim, hidden.
import CoreText
import Foundation
import UIKit

let rustCellFlagBold: UInt8 = 1 << 0
let rustCellFlagItalic: UInt8 = 1 << 1
let rustCellFlagUnderline: UInt8 = 1 << 2
let rustCellFlagStrikethrough: UInt8 = 1 << 3
let rustCellFlagInverse: UInt8 = 1 << 4
let rustCellFlagDim: UInt8 = 1 << 5
let rustCellFlagHidden: UInt8 = 1 << 6

/// iOS mirror of the macOS `RustCellData` (see chau7_terminal.h).
///
/// Cells reference UTF-8 grapheme clusters stored in
/// `RemoteTerminalRenderState.clusters` via `(cluster_offset, cluster_len)`.
struct RustCellData: Sendable {
    var cluster_offset: UInt32 = 0
    var fg_r: UInt8 = 255
    var fg_g: UInt8 = 255
    var fg_b: UInt8 = 255
    var bg_r: UInt8 = 0
    var bg_g: UInt8 = 0
    var bg_b: UInt8 = 0
    var cluster_len: UInt16 = 0
    var width: UInt8 = 1
    var continuation: UInt8 = 0
    var flags: UInt8 = 0
    var underline_style: UInt8 = 0
    var link_id: UInt16 = 0
}

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

struct RemoteTerminalRenderState: Sendable {
    let cells: [RustCellData]
    /// Packed UTF-8 cluster bytes referenced by `cells[i].cluster_offset`. The
    /// renderer decodes a Swift `String` from a slice on demand.
    let clusters: Data
    let cols: Int
    let rows: Int
    let cursorCol: Int
    let cursorRow: Int
    let cursorVisible: Bool
    let scrollbackRows: Int
    let displayOffset: Int

    var totalRows: Int {
        rows + scrollbackRows
    }

    /// Decode a cell's grapheme cluster bytes as a String. Returns "" for blank
    /// cells, continuation cells, or out-of-range offsets.
    func clusterString(for cell: RustCellData) -> String {
        guard cell.cluster_len > 0, cell.continuation == 0 else { return "" }
        let start = Int(cell.cluster_offset)
        let end = start + Int(cell.cluster_len)
        guard end <= clusters.count else { return "" }
        return String(decoding: clusters[start ..< end], as: UTF8.self)
    }
}

enum RemoteTerminalRenderStateDecoder {
    static func decodeGridSnapshot(_ data: Data) -> RemoteTerminalRenderState? {
        guard MemoryLayout<RustCellData>.stride == RemoteTerminalGridSnapshotLayout.cellStride else {
            return nil
        }
        guard let snapshot = try? RemoteTerminalGridSnapshot.decode(from: data) else {
            return nil
        }
        let cellCount = snapshot.cellCount
        guard snapshot.cells.count == cellCount * MemoryLayout<RustCellData>.stride else {
            return nil
        }
        let cells: [RustCellData] = snapshot.cells.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.bindMemory(to: RustCellData.self).baseAddress else { return [] }
            return Array(UnsafeBufferPointer(start: baseAddress, count: cellCount))
        }
        guard cells.count == cellCount else { return nil }
        return RemoteTerminalRenderState(
            cells: cells,
            clusters: snapshot.clusters,
            cols: Int(snapshot.cols),
            rows: Int(snapshot.rows),
            cursorCol: Int(snapshot.cursorCol),
            cursorRow: Int(snapshot.cursorRow),
            cursorVisible: snapshot.cursorVisible,
            scrollbackRows: Int(snapshot.scrollbackRows),
            displayOffset: Int(snapshot.displayOffset)
        )
    }
}

enum RemoteTerminalFontMetrics {
    static let baseFont = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)

    static func cellSize(for font: UIFont = baseFont) -> CGSize {
        let ctFont = font as CTFont
        var characters = (32 ... 126).map { UniChar($0) }
        var glyphs = [CGGlyph](repeating: 0, count: characters.count)
        CTFontGetGlyphsForCharacters(ctFont, &characters, &glyphs, characters.count)
        var advances = [CGSize](repeating: .zero, count: characters.count)
        CTFontGetAdvancesForGlyphs(ctFont, .horizontal, glyphs, &advances, glyphs.count)
        let width = max(1, ceil(advances.map(\.width).max() ?? 0))

        let ascent = CTFontGetAscent(ctFont)
        let descent = CTFontGetDescent(ctFont)
        let leading = CTFontGetLeading(ctFont)
        let height = max(1, ceil(ascent + descent + leading))

        return CGSize(width: width, height: height)
    }
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

    func scrollTo(displayOffset: Int, scrollbackRows: Int) {
        guard scrollbackRows > 0 else {
            chau7_terminal_scroll_to(handle, 0)
            return
        }
        let clampedOffset = min(max(displayOffset, 0), scrollbackRows)
        let normalized = Double(clampedOffset) / Double(scrollbackRows)
        chau7_terminal_scroll_to(handle, normalized)
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
