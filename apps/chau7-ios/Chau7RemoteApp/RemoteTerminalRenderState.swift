import Chau7Core
import Foundation

let rustCellFlagBold: UInt8 = 1 << 0
let rustCellFlagItalic: UInt8 = 1 << 1
let rustCellFlagUnderline: UInt8 = 1 << 2
let rustCellFlagStrikethrough: UInt8 = 1 << 3
let rustCellFlagInverse: UInt8 = 1 << 4
let rustCellFlagDim: UInt8 = 1 << 5
let rustCellFlagHidden: UInt8 = 1 << 6
/// Set on the first cell of a grid row that soft-wraps from the row above.
///
/// A property of the row, not of the cell: it marks where the terminal broke a
/// logical line because the text exceeded the width, rather than because a
/// newline was emitted. Folding each physical row independently (which is what
/// the display re-composition did before this existed) chops soft-wrapped
/// prose mid-sentence at every fold; folding on logical lines does not.
let rustCellFlagWrapped: UInt8 = 1 << 7

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

/// Rows already folded to the client's width, ready to paint.
///
/// Produced by `RemoteRustTerminalPlayback.displayRows(displayCols:)`. The
/// cluster bytes are copied out of the FFI buffer before it is freed.
struct RemoteTerminalDisplayState: Sendable {
    let cells: [RustCellData]
    let clusters: Data
    /// Start offset into `cells` for each display row, plus a trailing sentinel,
    /// so row `r` is `cells[rowOffsets[r] ..< rowOffsets[r + 1]]`.
    let rowOffsets: [UInt32]
    let displayCols: Int
    let displayRows: Int

    /// Cell range backing one display row.
    func range(forRow row: Int) -> Range<Int>? {
        RemoteTerminalDisplayRowMap.range(row: row, offsets: rowOffsets, cellCount: cells.count)
    }

    /// Decode a cell's grapheme cluster. Kept off the hot path deliberately: the
    /// Rust fold removes the *index* work, but glyphs still have to be turned
    /// into strings to draw, so this is called once per painted cell per frame.
    func clusterString(for cell: RustCellData) -> String {
        guard cell.cluster_len > 0, cell.continuation == 0 else { return "" }
        let start = Int(cell.cluster_offset)
        let end = start + Int(cell.cluster_len)
        guard end <= clusters.count else { return "" }
        return String(decoding: clusters[start ..< end], as: UTF8.self)
    }
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

    /// Capture the source grid on demand, preserving grapheme clusters and wraps.
    /// Hidden cells are masked; wide-cell continuations must not duplicate text.
    var selectableText: String {
        guard cols > 0, rows > 0 else { return "" }
        var textRows: [String] = []
        var softWraps: Set<Int> = []
        for row in 0 ..< rows {
            if isSoftWrapped(row: row) { softWraps.insert(row) }
            var text = ""
            for column in 0 ..< cols {
                let index = row * cols + column
                guard index < cells.count else { break }
                let cell = cells[index]
                guard cell.continuation == 0 else { continue }
                if cell.flags & rustCellFlagHidden != 0 {
                    text += String(repeating: " ", count: max(1, Int(cell.width)))
                } else {
                    let cluster = clusterString(for: cell)
                    text += cluster.isEmpty ? " " : cluster
                }
            }
            textRows.append(text)
        }
        return TerminalClipboard.gridText(rows: textRows, softWrappedRows: softWraps)
    }

    /// Whether the grid row at `row` is a soft-wrap continuation of the logical
    /// line begun on the row above, rather than the start of a new line.
    func isSoftWrapped(row: Int) -> Bool {
        guard row > 0, row < rows, cols > 0 else { return false }
        let index = row * cols
        guard index < cells.count else { return false }
        return cells[index].flags & rustCellFlagWrapped != 0
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
