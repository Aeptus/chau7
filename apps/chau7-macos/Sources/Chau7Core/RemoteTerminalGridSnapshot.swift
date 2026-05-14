import Foundation

public enum RemoteTerminalGridSnapshotError: Error, Sendable {
    case invalidMagic
    case unsupportedVersion(UInt8)
    case invalidLength
}

public enum RemoteTerminalGridSnapshotLayout {
    /// Wire-format magic. "CHG2" = grapheme-cluster-aware format.
    /// ASCII bytes are statically known; no runtime parse required.
    public static let magic = Data([0x43, 0x48, 0x47, 0x32])
    public static let version: UInt8 = 2
    /// Header is the same 29 bytes as v1, plus an extra UInt32 for clusters length.
    public static let headerSize = 33
    /// Must match `MemoryLayout<RustCellData>.stride`:
    ///   UInt32 (cluster_offset) + 6×UInt8 (colors) + UInt16 (cluster_len)
    ///   + 4×UInt8 (width, continuation, flags, underline_style) + UInt16 (link_id)
    ///   = 18 bytes → padded to 20 by 4-byte alignment of the leading UInt32.
    public static let cellStride = 20
}

public struct RemoteTerminalGridSnapshot: Equatable, Sendable {
    public let cols: UInt16
    public let rows: UInt16
    public let cursorCol: UInt16
    public let cursorRow: UInt16
    public let cursorVisible: Bool
    public let scrollbackRows: UInt32
    public let displayOffset: UInt32
    public let cells: Data
    /// UTF-8 grapheme cluster bytes referenced by `cells[i].cluster_offset`.
    public let clusters: Data

    public init(
        cols: UInt16,
        rows: UInt16,
        cursorCol: UInt16,
        cursorRow: UInt16,
        cursorVisible: Bool,
        scrollbackRows: UInt32,
        displayOffset: UInt32,
        cells: Data,
        clusters: Data
    ) {
        self.cols = cols
        self.rows = rows
        self.cursorCol = cursorCol
        self.cursorRow = cursorRow
        self.cursorVisible = cursorVisible
        self.scrollbackRows = scrollbackRows
        self.displayOffset = displayOffset
        self.cells = cells
        self.clusters = clusters
    }

    public var cellCount: Int {
        Int(cols) * Int(rows)
    }

    public var isValid: Bool {
        cells.count == cellCount * RemoteTerminalGridSnapshotLayout.cellStride
    }

    public func encode() -> Data? {
        guard isValid else { return nil }
        var data = Data(capacity: RemoteTerminalGridSnapshotLayout.headerSize + cells.count + clusters.count)
        data.append(RemoteTerminalGridSnapshotLayout.magic)
        data.append(RemoteTerminalGridSnapshotLayout.version)
        data.appendUInt16LE(cols)
        data.appendUInt16LE(rows)
        data.appendUInt16LE(cursorCol)
        data.appendUInt16LE(cursorRow)
        data.append(cursorVisible ? 1 : 0)
        data.append(contentsOf: [0, 0, 0])
        data.appendUInt32LE(scrollbackRows)
        data.appendUInt32LE(displayOffset)
        data.appendUInt32LE(UInt32(cells.count))
        data.appendUInt32LE(UInt32(clusters.count))
        data.append(cells)
        data.append(clusters)
        return data
    }

    public static func decode(from data: Data) throws -> RemoteTerminalGridSnapshot {
        guard data.count >= RemoteTerminalGridSnapshotLayout.headerSize else {
            throw RemoteTerminalGridSnapshotError.invalidLength
        }
        let magic = data.prefix(4)
        guard magic == RemoteTerminalGridSnapshotLayout.magic else {
            throw RemoteTerminalGridSnapshotError.invalidMagic
        }
        let version = data[4]
        guard version == RemoteTerminalGridSnapshotLayout.version else {
            throw RemoteTerminalGridSnapshotError.unsupportedVersion(version)
        }

        let cols = try data.readUInt16LE(at: 5)
        let rows = try data.readUInt16LE(at: 7)
        let cursorCol = try data.readUInt16LE(at: 9)
        let cursorRow = try data.readUInt16LE(at: 11)
        let cursorVisible = data[13] != 0
        let scrollbackRows = try data.readUInt32LE(at: 17)
        let displayOffset = try data.readUInt32LE(at: 21)
        let cellsByteCount = try Int(data.readUInt32LE(at: 25))
        let clustersByteCount = try Int(data.readUInt32LE(at: 29))
        let expectedCellsBytes = Int(cols) * Int(rows) * RemoteTerminalGridSnapshotLayout.cellStride
        guard cellsByteCount == expectedCellsBytes else {
            throw RemoteTerminalGridSnapshotError.invalidLength
        }
        let cellsStart = RemoteTerminalGridSnapshotLayout.headerSize
        let cellsEnd = cellsStart + cellsByteCount
        let clustersEnd = cellsEnd + clustersByteCount
        guard data.count >= clustersEnd else {
            throw RemoteTerminalGridSnapshotError.invalidLength
        }
        let cells = data.subdata(in: cellsStart ..< cellsEnd)
        let clusters = data.subdata(in: cellsEnd ..< clustersEnd)
        return RemoteTerminalGridSnapshot(
            cols: cols,
            rows: rows,
            cursorCol: cursorCol,
            cursorRow: cursorRow,
            cursorVisible: cursorVisible,
            scrollbackRows: scrollbackRows,
            displayOffset: displayOffset,
            cells: cells,
            clusters: clusters
        )
    }
}

// `appendUInt16LE` / `readUInt16LE` live in `DataLittleEndian.swift` now.
