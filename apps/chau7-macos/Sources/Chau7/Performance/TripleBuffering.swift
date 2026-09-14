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
        /// Packed UTF-8 cluster bytes, manually managed. The previous
        /// `ContiguousArray` was assigned across buffers by reference in
        /// `copyFrom`/`copyDirtyFrom` (a COW share), so the very next
        /// `resetClusters()` mutated shared storage and forced a fresh heap
        /// allocation every sync (~10-20 KB alloc/free at ~19 Hz). Owned
        /// storage + memcpy keeps steady-state syncs allocation-free.
        private var clusterStorage: UnsafeMutablePointer<UInt8>
        private(set) var clusterCount = 0
        private(set) var clusterCapacity: Int
        let rows: Int
        let cols: Int

        /// Monotonic Rust grid generation represented by this buffer. Row
        /// generations let a rotating target catch up even when it missed one
        /// or more deltas while another buffer was on screen.
        private(set) var generation: UInt64 = 0
        private var rowGenerations: [UInt64]

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
            self.rowGenerations = Array(repeating: 0, count: rows)
            // Enough for ASCII-dense terminals (~1 byte/cell); grows
            // geometrically when emoji push past it.
            self.clusterCapacity = max(count, 64)
            self.clusterStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: clusterCapacity)
        }

        deinit {
            cells.baseAddress?.deinitialize(count: cells.count)
            cells.baseAddress?.deallocate()
            clusterStorage.deallocate()
        }

        /// Read-only view of the live cluster bytes. Valid until the next
        /// `resetClusters`/`appendCluster`/`copy*From` on THIS buffer — the
        /// renderer reads the render buffer while the bridge writes the
        /// update buffer, so the two never alias.
        var clusters: UnsafeBufferPointer<UInt8> {
            UnsafeBufferPointer(start: clusterStorage, count: clusterCount)
        }

        /// Reset the cluster buffer for a new frame. Called by the bridge before
        /// writing cells; clears the count but keeps the allocation.
        func resetClusters() {
            clusterCount = 0
        }

        /// Prepares the producer buffer for one Rust snapshot. Full snapshots
        /// replace all cluster storage; deltas retain unchanged rows and append
        /// only clusters referenced by changed rows.
        func beginUpdate(generation: UInt64, fullRefresh: Bool) {
            dirtyRows.removeAll()
            self.generation = generation
            fullRefreshNeeded = fullRefresh
            if fullRefresh {
                resetClusters()
                rowGenerations = Array(repeating: 0, count: rows)
            } else {
                compactClustersIfNeeded()
            }
        }

        func finishUpdatedRow(_ row: Int, generation: UInt64) {
            guard row >= 0, row < rows else { return }
            rowGenerations[row] = generation
            dirtyRows.insert(row)
        }

        /// Append a UTF-8 cluster, returning the start offset.
        @inline(__always)
        func appendCluster(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt32 {
            let offset = clusterCount
            guard let base = bytes.baseAddress, !bytes.isEmpty else {
                return UInt32(offset)
            }
            ensureClusterCapacity(clusterCount + bytes.count)
            clusterStorage.advanced(by: offset).update(from: base, count: bytes.count)
            clusterCount += bytes.count
            return UInt32(offset)
        }

        private func ensureClusterCapacity(_ needed: Int) {
            guard needed > clusterCapacity else { return }
            var newCapacity = max(clusterCapacity * 2, 64)
            while newCapacity < needed {
                newCapacity *= 2
            }
            let newStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
            newStorage.update(from: clusterStorage, count: clusterCount)
            clusterStorage.deallocate()
            clusterStorage = newStorage
            clusterCapacity = newCapacity
        }

        /// Incremental row updates leave unreachable historical cluster bytes
        /// behind. Repack live clusters before storage grows beyond its bounded
        /// working set; cell offsets are rewritten atomically on the producer
        /// buffer and the allocation shrinks with the live content.
        private func compactClustersIfNeeded() {
            let softLimit = 1 * 1_024 * 1_024
            let hardCapacity = 4 * 1_024 * 1_024
            let liveBytes = cells.reduce(into: 0) { total, cell in
                total += Int(cell.clusterLen)
            }
            guard clusterCount > max(softLimit, liveBytes * 3)
                    || clusterCapacity > max(hardCapacity, liveBytes * 4) else {
                return
            }

            let newCapacity = max(64, liveBytes + max(liveBytes / 2, 64))
            let newStorage = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
            var nextOffset = 0
            for index in cells.indices {
                var cell = cells[index]
                let length = Int(cell.clusterLen)
                guard length > 0 else { continue }
                let oldOffset = Int(cell.clusterStart)
                guard oldOffset >= 0, oldOffset + length <= clusterCount else {
                    cell.clusterStart = 0
                    cell.clusterLen = 0
                    cells[index] = cell
                    continue
                }
                newStorage.advanced(by: nextOffset).update(
                    from: clusterStorage.advanced(by: oldOffset),
                    count: length
                )
                cell.clusterStart = UInt32(nextOffset)
                cells[index] = cell
                nextOffset += length
            }
            clusterStorage.deallocate()
            clusterStorage = newStorage
            clusterCount = nextOffset
            clusterCapacity = newCapacity
        }

        /// Replace this buffer's cluster bytes with a copy of another buffer's.
        fileprivate func copyClustersFrom(_ other: TerminalBuffer) {
            ensureClusterCapacity(other.clusterCount)
            clusterStorage.update(from: other.clusterStorage, count: other.clusterCount)
            clusterCount = other.clusterCount
        }

        /// Returns the UTF-8 cluster bytes for a cell as a copied `Data` — safe to
        /// retain past the call. Use when the renderer needs to hash a cluster or
        /// build a `String` for shaping.
        func clusterData(at offset: UInt32, length: UInt16) -> Data {
            guard length > 0 else { return Data() }
            let start = Int(offset)
            let end = start + Int(length)
            guard end <= clusterCount else { return Data() }
            return Data(bytes: clusterStorage.advanced(by: start), count: Int(length))
        }

        /// Build a Swift `String` from a cell's cluster bytes. Returns `""` for blanks.
        func clusterString(at offset: UInt32, length: UInt16) -> String {
            guard length > 0 else { return "" }
            let start = Int(offset)
            let end = start + Int(length)
            guard end <= clusterCount else { return "" }
            let slice = UnsafeBufferPointer(start: clusterStorage.advanced(by: start), count: Int(length))
            return String(decoding: slice, as: UTF8.self)
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
            copyClustersFrom(other)
            dirtyRows = other.dirtyRows
            fullRefreshNeeded = other.fullRefreshNeeded
            generation = other.generation
            rowGenerations = other.rowGenerations
        }

        /// Copies every row newer than this rotating target. Cluster offsets
        /// are target-local, so each copied grapheme is appended and remapped
        /// rather than borrowing the source buffer's offset.
        func copyDirtyFrom(_ other: TerminalBuffer) -> (rows: Int, fullRefresh: Bool) {
            guard other.rows == rows, other.cols == cols else { return (0, false) }

            if other.fullRefreshNeeded {
                copyFrom(other)
                return (rows, true)
            }

            compactClustersIfNeeded()
            var copiedRows = IndexSet()
            for row in 0 ..< rows where other.rowGenerations[row] > rowGenerations[row] {
                copyRow(row, from: other)
                rowGenerations[row] = other.rowGenerations[row]
                copiedRows.insert(row)
            }
            generation = max(generation, other.generation)
            dirtyRows.formUnion(copiedRows)
            return (copiedRows.count, false)
        }

        private func copyRow(_ row: Int, from other: TerminalBuffer) {
            let startIndex = row * cols
            for col in 0 ..< cols {
                let index = startIndex + col
                var cell = other.cells[index]
                let length = Int(cell.clusterLen)
                if length > 0 {
                    let sourceOffset = Int(cell.clusterStart)
                    if sourceOffset >= 0, sourceOffset + length <= other.clusterCount {
                        let bytes = UnsafeBufferPointer(
                            start: other.clusterStorage.advanced(by: sourceOffset),
                            count: length
                        )
                        cell.clusterStart = appendCluster(bytes)
                    } else {
                        cell.clusterStart = 0
                        cell.clusterLen = 0
                    }
                } else {
                    cell.clusterStart = 0
                }
                cells[index] = cell
            }
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

    var latestGeneration: UInt64 {
        updateBuffer.generation
    }

    /// Estimated resident bytes across the three buffers (cells + cluster
    /// storage capacity). O(1); used by the per-tab memory diagnostics.
    var estimatedFootprintBytes: Int {
        buffers.reduce(0) { total, buffer in
            total
                + buffer.cells.count * MemoryLayout<TerminalCell>.stride
                + buffer.clusterCapacity
        }
    }

    /// Commits the current update buffer and swaps it with the render buffer.
    /// The old render buffer becomes available for the next update.
    @discardableResult
    func commitUpdate() -> CommitStatistics {
        let startedAt = CFAbsoluteTimeGetCurrent()
        let current = updateIndex.load(ordering: .relaxed)
        let render = renderIndex.load(ordering: .relaxed)
        let sourceBuffer = buffers[current]
        let copyResult = buffers[render].copyDirtyFrom(sourceBuffer)
        let copiedRows = copyResult.rows
        let copiedCells = copiedRows * cols
        let copiedBytes = copiedCells * MemoryLayout<TerminalCell>.stride

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
            fullRefresh: copyResult.fullRefresh,
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
            buffer.beginUpdate(generation: 0, fullRefresh: true)
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
