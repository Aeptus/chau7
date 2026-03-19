import CoreText
import Chau7Core
import Foundation
import UIKit

let rustCellFlagBold: UInt8 = 1 << 0
let rustCellFlagItalic: UInt8 = 1 << 1
let rustCellFlagUnderline: UInt8 = 1 << 2
let rustCellFlagStrikethrough: UInt8 = 1 << 3
let rustCellFlagInverse: UInt8 = 1 << 4
let rustCellFlagDim: UInt8 = 1 << 5
let rustCellFlagHidden: UInt8 = 1 << 6

struct RustCellData {
    var character: UInt32
    var fg_r: UInt8
    var fg_g: UInt8
    var fg_b: UInt8
    var bg_r: UInt8
    var bg_g: UInt8
    var bg_b: UInt8
    var flags: UInt8
    var _pad: UInt8
    var link_id: UInt16
}

struct RustGridSnapshot {
    var cells: UnsafeMutablePointer<RustCellData>?
    var cols: UInt16
    var rows: UInt16
    var cursor_visible: UInt8
    var _pad: (UInt8, UInt8, UInt8)
    var scrollback_rows: UInt32
    var display_offset: UInt32
    var capacity: Int
}

struct RemoteTerminalRenderState {
    let cells: [RustCellData]
    let cols: Int
    let rows: Int
    let cursorCol: Int
    let cursorRow: Int
    let cursorVisible: Bool
    let scrollbackRows: Int
    let displayOffset: Int

    var totalRows: Int { rows + scrollbackRows }
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
nonisolated
private func chau7_terminal_create_headless(_ cols: UInt16, _ rows: UInt16) -> UnsafeMutableRawPointer?

@_silgen_name("chau7_terminal_destroy")
nonisolated
private func chau7_terminal_destroy(_ term: UnsafeMutableRawPointer?)

@_silgen_name("chau7_terminal_resize")
nonisolated
private func chau7_terminal_resize(_ term: UnsafeMutableRawPointer?, _ cols: UInt16, _ rows: UInt16)

@_silgen_name("chau7_terminal_get_grid")
nonisolated
private func chau7_terminal_get_grid(_ term: UnsafeMutableRawPointer?) -> UnsafeMutablePointer<RustGridSnapshot>?

@_silgen_name("chau7_terminal_free_grid")
nonisolated
private func chau7_terminal_free_grid(_ grid: UnsafeMutablePointer<RustGridSnapshot>?)

@_silgen_name("chau7_terminal_inject_output")
nonisolated
private func chau7_terminal_inject_output(_ term: UnsafeMutableRawPointer?, _ data: UnsafePointer<UInt8>?, _ len: Int)

@_silgen_name("chau7_terminal_scroll_to")
nonisolated
private func chau7_terminal_scroll_to(_ term: UnsafeMutableRawPointer?, _ position: Double)

@_silgen_name("chau7_terminal_cursor_position")
nonisolated
private func chau7_terminal_cursor_position(_ term: UnsafeMutableRawPointer?, _ col: UnsafeMutablePointer<UInt16>?, _ row: UnsafeMutablePointer<UInt16>?)

@MainActor
final class RemoteRustTerminalPlayback {
    private var handle: UnsafeMutableRawPointer?
    private(set) var cols: Int
    private(set) var rows: Int

    init?(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return nil }
        guard let handle = chau7_terminal_create_headless(UInt16(cols), UInt16(rows)) else { return nil }
        self.handle = handle
        self.cols = cols
        self.rows = rows
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

        var cursorCol: UInt16 = 0
        var cursorRow: UInt16 = 0
        chau7_terminal_cursor_position(handle, &cursorCol, &cursorRow)

        return RemoteTerminalRenderState(
            cells: cells,
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
