// MARK: - Triple Buffering with Dirty Region Tracking

// Eliminates synchronization between producer and consumer threads
// while tracking dirty regions to minimize GPU uploads.

import Foundation
import Atomics

/// Triple-buffered terminal state with dirty region tracking.
/// - Buffer 0: Being updated by PTY/parser (update buffer)
/// - Buffer 1: Ready to render (render buffer)
/// - Buffer 2: Currently being displayed (display buffer)
///
/// Atomic buffer swaps ensure lock-free operation.
final class TripleBufferedTerminal {

    struct CommitStatistics {
        let dirtyRows: Int
        let dirtyCells: Int
        let bytesCopied: Int
        let fullRefresh: Bool
        let durationMs: Double
    }

    // MARK: - Types

    /// Single terminal buffer containing all cell data.
    ///
    /// `clusters` holds packed UTF-8 grapheme cluster bytes referenced by cells
    /// via `(clusterStart, clusterLen)`. The bridge rewrites both `cells` and
    /// `clusters` each frame; the renderer reads from them in lockstep.
    final class TerminalBuffer {
        let cells: UnsafeMutableBufferPointer<TerminalCell>
        var clusters: ContiguousArray<UInt8>
        let rows: Int
        let cols: Int

        /// Dirty rows that need re-rendering
        var dirtyRows: IndexSet = []

        /// Whether entire buffer needs refresh
        var fullRefreshNeeded = true

        init(rows: Int, cols: Int) {
            self.rows = rows
            self.cols = cols

            let count = rows * cols
            let ptr = UnsafeMutablePointer<TerminalCell>.allocate(capacity: count)
            ptr.initialize(repeating: TerminalCell(), count: count)
            self.cells = UnsafeMutableBufferPointer(start: ptr, count: count)
            // Reserve enough for ASCII-dense terminals (~1 byte/cell). Vec doubles
            // when emoji push past the reservation.
            self.clusters = ContiguousArray<UInt8>()
            clusters.reserveCapacity(count)
        }

        deinit {
            cells.baseAddress?.deinitialize(count: cells.count)
            cells.baseAddress?.deallocate()
        }

        /// Reset the cluster buffer for a new frame. Called by the bridge before
        /// writing cells; clears bytes but keeps the allocation.
        func resetClusters() {
            clusters.removeAll(keepingCapacity: true)
        }

        /// Append a UTF-8 cluster, returning the start offset.
        @inlinable
        func appendCluster(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
            let offset = UInt32(clusters.count)
            clusters.append(contentsOf: bytes)
            return offset
        }

        /// Returns the UTF-8 cluster bytes for a cell as a copied `Data` — safe to
        /// retain past the call. Use when the renderer needs to hash a cluster or
        /// build a `String` for shaping.
        func clusterData(at offset: UInt32, length: UInt16) -> Data {
            guard length > 0 else { return Data() }
            let start = Int(offset)
            let end = start + Int(length)
            guard end <= clusters.count else { return Data() }
            return clusters.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return Data() }
                return Data(bytes: base.advanced(by: start), count: Int(length))
            }
        }

        /// Build a Swift `String` from a cell's cluster bytes. Returns `""` for blanks.
        func clusterString(at offset: UInt32, length: UInt16) -> String {
            guard length > 0 else { return "" }
            let start = Int(offset)
            let end = start + Int(length)
            guard end <= clusters.count else { return "" }
            return clusters.withUnsafeBufferPointer { buf in
                guard let base = buf.baseAddress else { return "" }
                let slice = UnsafeBufferPointer(start: base.advanced(by: start), count: Int(length))
                return String(decoding: slice, as: UTF8.self)
            }
        }

        /// Marks a row as dirty
        func markDirty(row: Int) {
            guard row >= 0, row < rows else { return }
            dirtyRows.insert(row)
        }

        /// Marks a range of rows as dirty
        func markDirty(rows range: Range<Int>) {
            for row in range {
                markDirty(row: row)
            }
        }

        /// Clears all dirty flags
        func clearDirty() {
            dirtyRows.removeAll()
            fullRefreshNeeded = false
        }

        /// Accesses cell at row/col
        subscript(row: Int, col: Int) -> TerminalCell {
            get { cells[row * cols + col] }
            set {
                let index = row * cols + col
                let currentValue = cells[index]
                guard Self.cellsDiffer(currentValue, newValue) else { return }
                cells[index] = newValue
                markDirty(row: row)
            }
        }

        /// CLUSTER OFFSET INVARIANT
        ///
        /// The bridge rewrites `clusters` from scratch every frame, appending
        /// bytes in column-major scan order. So for two frames with identical
        /// content, identical cells will produce identical offsets. If any
        /// earlier cell on the same scan path changes byte-length (e.g. an
        /// ASCII char becomes an emoji), every downstream cell's offset shifts,
        /// and `clusterStart` differs — which `cellsDiffer` picks up below,
        /// marking those rows dirty so `copyDirtyFrom` re-copies them against
        /// the new wholesale `clusters` array. This is the self-healing
        /// property `copyDirtyFrom` relies on; do not weaken `cellsDiffer` to
        /// ignore `clusterStart` without first replacing the diff with a
        /// content-hash key.
        private static func cellsDiffer(_ lhs: TerminalCell, _ rhs: TerminalCell) -> Bool {
            lhs.clusterStart != rhs.clusterStart ||
                lhs.clusterLen != rhs.clusterLen ||
                lhs.width != rhs.width ||
                lhs.continuation != rhs.continuation ||
                lhs.foregroundColor != rhs.foregroundColor ||
                lhs.backgroundColor != rhs.backgroundColor ||
                lhs.flags != rhs.flags
        }

        /// Copies content from another buffer
        func copyFrom(_ other: TerminalBuffer) {
            guard other.rows == rows, other.cols == cols else { return }
            memcpy(cells.baseAddress!, other.cells.baseAddress!, cells.count * MemoryLayout<TerminalCell>.stride)
            clusters = other.clusters
            dirtyRows = other.dirtyRows
            fullRefreshNeeded = other.fullRefreshNeeded
        }

        /// Copies only dirty rows from another buffer.
        ///
        /// Cluster bytes are replaced wholesale (not per-row). See the CLUSTER
        /// OFFSET INVARIANT on `cellsDiffer`: any byte-length change earlier in
        /// the scan shifts every downstream cell's `clusterStart`, which marks
        /// those cells dirty, so all live offsets in the partially-copied cells
        /// remain valid against the new `clusters` array.
        func copyDirtyFrom(_ other: TerminalBuffer) {
            guard other.rows == rows, other.cols == cols else { return }

            if other.fullRefreshNeeded {
                copyFrom(other)
                return
            }

            for row in other.dirtyRows {
                let startIndex = row * cols
                memcpy(
                    cells.baseAddress!.advanced(by: startIndex),
                    other.cells.baseAddress!.advanced(by: startIndex),
                    cols * MemoryLayout<TerminalCell>.stride
                )
            }
            clusters = other.clusters
            dirtyRows.formUnion(other.dirtyRows)
        }
    }

    // MARK: - Properties

    private var buffers: [TerminalBuffer]

    /// Atomic indices for lock-free buffer management
    private let updateIndex: ManagedAtomic<Int> // Buffer being updated
    private let renderIndex: ManagedAtomic<Int> // Buffer ready to render
    private let displayIndex: ManagedAtomic<Int> // Buffer being displayed

    /// Statistics
    private let swapCount: ManagedAtomic<UInt64>
    private let frameCount: ManagedAtomic<UInt64>

    let rows: Int
    let cols: Int

    // MARK: - Initialization

    init(rows: Int, cols: Int) {
        self.rows = rows
        self.cols = cols

        self.buffers = [
            TerminalBuffer(rows: rows, cols: cols),
            TerminalBuffer(rows: rows, cols: cols),
            TerminalBuffer(rows: rows, cols: cols)
        ]

        self.updateIndex = ManagedAtomic(0)
        self.renderIndex = ManagedAtomic(1)
        self.displayIndex = ManagedAtomic(2)
        self.swapCount = ManagedAtomic(0)
        self.frameCount = ManagedAtomic(0)
    }

    // MARK: - Producer API (PTY/Parser Thread)

    /// Gets the current update buffer for writing.
    /// Call `commitUpdate()` when done writing.
    var updateBuffer: TerminalBuffer {
        buffers[updateIndex.load(ordering: .acquiring)]
    }

    /// Commits the current update buffer and swaps it with the render buffer.
    /// The old render buffer becomes available for the next update.
    @discardableResult
    func commitUpdate() -> CommitStatistics {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let current = updateIndex.load(ordering: .relaxed)
        let render = renderIndex.load(ordering: .relaxed)
        let sourceBuffer = buffers[current]
        let copiedRows = sourceBuffer.fullRefreshNeeded ? rows : sourceBuffer.dirtyRows.count
        let copiedCells = copiedRows * cols
        let copiedBytes = copiedCells * MemoryLayout<TerminalCell>.stride

        // Copy dirty regions to render buffer
        buffers[render].copyDirtyFrom(sourceBuffer)

        // Swap update and render indices
        updateIndex.store(render, ordering: .releasing)
        renderIndex.store(current, ordering: .releasing)

        // Clear dirty flags on the new update buffer. The render buffer keeps
        // the committed dirty rows so the renderer can update incrementally.
        buffers[render].clearDirty()

        swapCount.wrappingIncrement(ordering: .relaxed)
        let durationMs = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000.0
        let stats = CommitStatistics(
            dirtyRows: copiedRows,
            dirtyCells: copiedCells,
            bytesCopied: copiedBytes,
            fullRefresh: sourceBuffer.fullRefreshNeeded,
            durationMs: durationMs
        )
        RenderPipelineProfiler.shared.recordCommit(
            dirtyRows: stats.dirtyRows,
            dirtyCells: stats.dirtyCells,
            bytesCopied: stats.bytesCopied,
            fullRefresh: stats.fullRefresh
        )
        return stats
    }

    // MARK: - Consumer API (Render Thread)

    /// Gets the current render buffer for reading.
    /// This buffer contains the latest committed state.
    var renderBuffer: TerminalBuffer {
        buffers[renderIndex.load(ordering: .acquiring)]
    }

    /// Gets the currently displayed buffer.
    /// Present-only redraws must read from this buffer so they do not regress
    /// to the stale pre-present render surface after a swap.
    var displayBuffer: TerminalBuffer {
        buffers[displayIndex.load(ordering: .acquiring)]
    }

    /// Swaps render buffer to display after GPU submission.
    func presentFrame() {
        let render = renderIndex.load(ordering: .relaxed)
        let display = displayIndex.load(ordering: .relaxed)

        // Swap render and display indices
        renderIndex.store(display, ordering: .releasing)
        displayIndex.store(render, ordering: .releasing)
        buffers[display].clearDirty()

        frameCount.wrappingIncrement(ordering: .relaxed)
    }

    /// Gets dirty rows that need re-rendering
    var dirtyRows: IndexSet {
        renderBuffer.dirtyRows
    }

    /// Whether a full refresh is needed
    var needsFullRefresh: Bool {
        renderBuffer.fullRefreshNeeded
    }

    // MARK: - Convenience Methods

    /// Updates a cell in the update buffer
    func setCell(row: Int, col: Int, _ cell: TerminalCell) {
        updateBuffer[row, col] = cell
    }

    /// Gets a cell from the render buffer
    func getCell(row: Int, col: Int) -> TerminalCell {
        renderBuffer[row, col]
    }

    /// Marks a row as dirty in the update buffer
    func markDirty(row: Int) {
        updateBuffer.markDirty(row: row)
    }

    /// Marks all rows as dirty (full refresh)
    func markFullRefresh() {
        updateBuffer.fullRefreshNeeded = true
    }

    /// Clears all buffers to default state
    func clear() {
        for buffer in buffers {
            let defaultCell = TerminalCell()
            for i in 0 ..< buffer.cells.count {
                buffer.cells[i] = defaultCell
            }
            buffer.resetClusters()
            buffer.fullRefreshNeeded = true
        }
    }

    // MARK: - Statistics

    struct Statistics {
        let bufferSwaps: UInt64
        let framesPresented: UInt64
        let dirtyRowCount: Int
        let needsFullRefresh: Bool
    }

    var statistics: Statistics {
        Statistics(
            bufferSwaps: swapCount.load(ordering: .relaxed),
            framesPresented: frameCount.load(ordering: .relaxed),
            dirtyRowCount: dirtyRows.count,
            needsFullRefresh: needsFullRefresh
        )
    }
}

// MARK: - Dirty Region Tracker

/// Tracks dirty regions at sub-row granularity for minimal GPU uploads.
struct DirtyRegionTracker {
    /// Minimum unit of dirtiness (in cells)
    let cellsPerChunk: Int

    /// Dirty chunks per row
    private var dirtyChunks: [[Bool]]

    let rows: Int
    let cols: Int
    let chunksPerRow: Int

    init(rows: Int, cols: Int, cellsPerChunk: Int = 16) {
        self.rows = rows
        self.cols = cols
        self.cellsPerChunk = cellsPerChunk
        self.chunksPerRow = (cols + cellsPerChunk - 1) / cellsPerChunk

        self.dirtyChunks = Array(repeating: Array(repeating: false, count: chunksPerRow), count: rows)
    }

    /// Marks a cell as dirty
    mutating func markDirty(row: Int, col: Int) {
        guard row >= 0, row < rows, col >= 0, col < cols else { return }
        let chunk = col / cellsPerChunk
        dirtyChunks[row][chunk] = true
    }

    /// Marks a range of cells as dirty
    mutating func markDirty(row: Int, cols range: Range<Int>) {
        guard row >= 0, row < rows else { return }
        let startChunk = max(0, range.lowerBound / cellsPerChunk)
        let endChunk = min(chunksPerRow - 1, (range.upperBound - 1) / cellsPerChunk)
        for chunk in startChunk ... endChunk {
            dirtyChunks[row][chunk] = true
        }
    }

    /// Marks an entire row as dirty
    mutating func markDirtyRow(_ row: Int) {
        guard row >= 0, row < rows else { return }
        for chunk in 0 ..< chunksPerRow {
            dirtyChunks[row][chunk] = true
        }
    }

    /// Gets dirty ranges for a row
    func dirtyRanges(forRow row: Int) -> [Range<Int>] {
        guard row >= 0, row < rows else { return [] }

        var ranges: [Range<Int>] = []
        var rangeStart: Int?

        for chunk in 0 ..< chunksPerRow {
            if dirtyChunks[row][chunk] {
                if rangeStart == nil {
                    rangeStart = chunk * cellsPerChunk
                }
            } else if let start = rangeStart {
                ranges.append(start ..< (chunk * cellsPerChunk))
                rangeStart = nil
            }
        }

        if let start = rangeStart {
            ranges.append(start ..< cols)
        }

        return ranges
    }

    /// Returns all dirty row indices
    var dirtyRowIndices: [Int] {
        (0 ..< rows).filter { row in
            dirtyChunks[row].contains(true)
        }
    }

    /// Clears all dirty flags
    mutating func clear() {
        for row in 0 ..< rows {
            for chunk in 0 ..< chunksPerRow {
                dirtyChunks[row][chunk] = false
            }
        }
    }

    /// Total number of dirty chunks
    var dirtyChunkCount: Int {
        dirtyChunks.reduce(0) { $0 + $1.filter { $0 }.count }
    }
}
