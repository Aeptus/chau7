import Foundation

public enum RemoteTerminalGridSnapshotError: Error, Sendable {
    case invalidMagic
    case unsupportedVersion(UInt8)
    case invalidLength
}

public enum RemoteTerminalGridSnapshotLayout {
    public static let magic = "CHG1".data(using: .utf8)!
    public static let version: UInt8 = 1
    public static let headerSize = 29
    public static let cellStride = 12
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

    public init(
        cols: UInt16,
        rows: UInt16,
        cursorCol: UInt16,
        cursorRow: UInt16,
        cursorVisible: Bool,
        scrollbackRows: UInt32,
        displayOffset: UInt32,
        cells: Data
    ) {
        self.cols = cols
        self.rows = rows
        self.cursorCol = cursorCol
        self.cursorRow = cursorRow
        self.cursorVisible = cursorVisible
        self.scrollbackRows = scrollbackRows
        self.displayOffset = displayOffset
        self.cells = cells
    }

    public var cellCount: Int {
        Int(cols) * Int(rows)
    }

    public var isValid: Bool {
        cells.count == cellCount * RemoteTerminalGridSnapshotLayout.cellStride
    }

    public func encode() -> Data? {
        guard isValid else { return nil }
        var data = Data(capacity: RemoteTerminalGridSnapshotLayout.headerSize + cells.count)
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
        data.append(cells)
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
        let expectedCount = Int(cols) * Int(rows) * RemoteTerminalGridSnapshotLayout.cellStride
        guard cellsByteCount == expectedCount else {
            throw RemoteTerminalGridSnapshotError.invalidLength
        }
        let totalLength = RemoteTerminalGridSnapshotLayout.headerSize + cellsByteCount
        guard data.count >= totalLength else {
            throw RemoteTerminalGridSnapshotError.invalidLength
        }
        let cells = data.subdata(in: RemoteTerminalGridSnapshotLayout.headerSize ..< totalLength)
        return RemoteTerminalGridSnapshot(
            cols: cols,
            rows: rows,
            cursorCol: cursorCol,
            cursorRow: cursorRow,
            cursorVisible: cursorVisible,
            scrollbackRows: scrollbackRows,
            displayOffset: displayOffset,
            cells: cells
        )
    }
}

extension Data {
    mutating func appendUInt16LE(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value))
        append(UInt8(truncatingIfNeeded: value >> 8))
    }

    func readUInt16LE(at offset: Int) throws -> UInt16 {
        guard count >= offset + 2 else { throw RemoteFrameError.insufficientData }
        let b0 = UInt16(self[offset])
        let b1 = UInt16(self[offset + 1]) << 8
        return b0 | b1
    }
}
