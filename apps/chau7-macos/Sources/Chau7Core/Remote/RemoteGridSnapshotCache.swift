import Foundation

/// Owned bytes only: no backend pointers or UI objects cross the worker boundary.
public struct RemoteGridUpdate: Sendable {
    public let baseGeneration: UInt64
    public let generation: UInt64
    public let fullRefresh: Bool
    public let rowIndices: [UInt16]
    public let snapshot: RemoteTerminalGridSnapshot

    public init(
        baseGeneration: UInt64,
        generation: UInt64,
        fullRefresh: Bool,
        rowIndices: [UInt16],
        snapshot: RemoteTerminalGridSnapshot
    ) {
        self.baseGeneration = baseGeneration
        self.generation = generation
        self.fullRefresh = fullRefresh
        self.rowIndices = rowIndices
        self.snapshot = snapshot
    }
}

/// One viewport, bounded independently of tab count. Dirty rows have their own
/// cluster pools because offsets in each backend delta refer to that delta only.
/// Assembly and encoding run on the remote worker, never on the UI thread.
public struct RemoteGridSnapshotCache {
    private struct Row {
        var cells: Data
        var clusters: Data
    }

    public static let defaultMaximumBytes = 4 * 1024 * 1024
    public private(set) var generation: UInt64 = 0
    public private(set) var retainedBytes = 0
    private let maximumBytes: Int
    private var rows: [Row] = []
    private var previous: RemoteTerminalGridSnapshot?

    public init(maximumBytes: Int = defaultMaximumBytes) {
        self.maximumBytes = max(0, maximumBytes)
    }

    public mutating func reset() {
        rows.removeAll()
        previous = nil
        generation = 0
        retainedBytes = 0
    }

    public mutating func encode(_ update: RemoteGridUpdate) -> Data? {
        let snapshot = update.snapshot
        let stride = RemoteTerminalGridSnapshotLayout.cellStride
        let rowBytes = Int(snapshot.cols) * stride
        guard snapshot.cols > 0, snapshot.rows > 0,
              snapshot.cells.count == update.rowIndices.count * rowBytes,
              Set(update.rowIndices).count == update.rowIndices.count,
              update.rowIndices.allSatisfy({ $0 < snapshot.rows }),
              update.fullRefresh ? update.rowIndices.count == Int(snapshot.rows)
              : (update.baseGeneration == generation && rows.count == Int(snapshot.rows)
                  && previous?.cols == snapshot.cols) else {
            reset()
            return nil
        }

        var nextRows = update.fullRefresh
            ? Array(repeating: Row(cells: Data(), clusters: Data()), count: Int(snapshot.rows)) : rows
        for (packedIndex, rowIndex) in update.rowIndices.enumerated() {
            var cells = snapshot.cells.subdata(in: packedIndex * rowBytes ..< (packedIndex + 1) * rowBytes)
            var clusters = Data()
            for column in 0 ..< Int(snapshot.cols) {
                let cellOffset = column * stride
                guard let offset = try? snapshot.cells.readUInt32LE(at: packedIndex * rowBytes + cellOffset),
                      let length = try? snapshot.cells.readUInt16LE(at: packedIndex * rowBytes + cellOffset + 10),
                      Int(offset) + Int(length) <= snapshot.clusters.count else {
                    reset()
                    return nil
                }
                Self.writeOffset(UInt32(clusters.count), into: &cells, at: cellOffset)
                clusters.append(snapshot.clusters.subdata(in: Int(offset) ..< Int(offset) + Int(length)))
            }
            nextRows[Int(rowIndex)] = Row(cells: cells, clusters: clusters)
        }

        if !update.fullRefresh, update.rowIndices.isEmpty, let previous,
           previous.cursorCol == snapshot.cursorCol, previous.cursorRow == snapshot.cursorRow,
           previous.cursorVisible == snapshot.cursorVisible,
           previous.scrollbackRows == snapshot.scrollbackRows, previous.displayOffset == snapshot.displayOffset {
            generation = update.generation
            return nil
        }

        var cells = Data(capacity: Int(snapshot.rows) * rowBytes)
        var clusters = Data()
        for row in nextRows {
            var rowCells = row.cells
            for column in 0 ..< Int(snapshot.cols) {
                let offset = column * stride
                guard let localOffset = try? rowCells.readUInt32LE(at: offset),
                      UInt64(localOffset) + UInt64(clusters.count) <= UInt32.max else {
                    reset()
                    return nil
                }
                Self.writeOffset(localOffset + UInt32(clusters.count), into: &rowCells, at: offset)
            }
            cells.append(rowCells)
            clusters.append(row.clusters)
        }
        let assembled = RemoteTerminalGridSnapshot(
            cols: snapshot.cols, rows: snapshot.rows, cursorCol: snapshot.cursorCol,
            cursorRow: snapshot.cursorRow, cursorVisible: snapshot.cursorVisible,
            scrollbackRows: snapshot.scrollbackRows, displayOffset: snapshot.displayOffset,
            cells: cells, clusters: clusters
        )
        let payload = assembled.encode()
        let bytes = nextRows.reduce(0) { $0 + $1.cells.count + $1.clusters.count }
            + cells.count + clusters.count
        if bytes <= maximumBytes {
            rows = nextRows
            previous = assembled
            generation = update.generation
            retainedBytes = bytes
        } else {
            // Oversized frames still reach the client. Do not retain their cache;
            // generation zero requests a full frame on the next capture.
            reset()
        }
        return payload
    }

    private static func writeOffset(_ value: UInt32, into data: inout Data, at offset: Int) {
        for byte in 0 ..< 4 {
            data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8))
        }
    }
}
