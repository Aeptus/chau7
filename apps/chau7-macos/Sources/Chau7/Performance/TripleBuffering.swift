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
public final class TripleBufferedTerminal {

    // MARK: - Types

    /// Single terminal buffer containing all cell data
    public final class TerminalBuffer {
        let cells: UnsafeMutableBufferPointer<TerminalCell>
        let rows: Int
        let cols: Int

        /// Dirty rows that need re-rendering
        var dirtyRows: IndexSet = []

        /// Whether entire buffer needs refresh
        var fullRefreshNeeded: Bool = true

        init(rows: Int, cols: Int) {
            self.rows = rows
            self.cols = cols

            let count = rows * cols
            let ptr = UnsafeMutablePointer<TerminalCell>.allocate(capacity: count)
            ptr.initialize(repeating: TerminalCell(), count: count)
            self.cells = UnsafeMutableBufferPointer(start: ptr, count: count)
        }

        deinit {
            cells.baseAddress?.deinitialize(count: cells.count)
            cells.baseAddress?.deallocate()
        }

        /// Marks a row as dirty
        func markDirty(row: Int) {
            guard row >= 0 && row < rows else { return }
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
                cells[row * cols + col] = newValue
                markDirty(row: row)
            }
        }

        /// Copies content from another buffer
        func copyFrom(_ other: TerminalBuffer) {
            guard other.rows == rows && other.cols == cols else { return }
            memcpy(cells.baseAddress!, other.cells.baseAddress!, cells.count * MemoryLayout<TerminalCell>.stride)
            dirtyRows = other.dirtyRows
            fullRefreshNeeded = other.fullRefreshNeeded
        }

        /// Copies only dirty rows from another buffer
        func copyDirtyFrom(_ other: TerminalBuffer) {
            guard other.rows == rows && other.cols == cols else { return }

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
            dirtyRows.formUnion(other.dirtyRows)
        }
    }

    // MARK: - Properties

    private var buffers: [TerminalBuffer]

    /// Atomic indices for lock-free buffer management
    private let updateIndex: ManagedAtomic<Int>   // Buffer being updated
    private let renderIndex: ManagedAtomic<Int>   // Buffer ready to render
    private let displayIndex: ManagedAtomic<Int>  // Buffer being displayed

    /// Statistics
    private let swapCount: ManagedAtomic<UInt64>
    private let frameCount: ManagedAtomic<UInt64>

    public let rows: Int
    public let cols: Int

    // MARK: - Initialization

    public init(rows: Int, cols: Int) {
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
    public var updateBuffer: TerminalBuffer {
        buffers[updateIndex.load(ordering: .acquiring)]
    }

    /// Commits the current update buffer and swaps it with the render buffer.
    /// The old render buffer becomes available for the next update.
    public func commitUpdate() {
        let current = updateIndex.load(ordering: .relaxed)
        let render = renderIndex.load(ordering: .relaxed)

        // Copy dirty regions to render buffer
        buffers[render].copyDirtyFrom(buffers[current])

        // Swap update and render indices
        updateIndex.store(render, ordering: .releasing)
        renderIndex.store(current, ordering: .releasing)

        // Clear dirty flags on old update buffer (now render buffer)
        buffers[current].clearDirty()

        swapCount.wrappingIncrement(ordering: .relaxed)
    }

    // MARK: - Consumer API (Render Thread)

    /// Gets the current render buffer for reading.
    /// This buffer contains the latest committed state.
    public var renderBuffer: TerminalBuffer {
        buffers[renderIndex.load(ordering: .acquiring)]
    }

    /// Swaps render buffer to display after GPU submission.
    public func presentFrame() {
        let render = renderIndex.load(ordering: .relaxed)
        let display = displayIndex.load(ordering: .relaxed)

        // Swap render and display indices
        renderIndex.store(display, ordering: .releasing)
        displayIndex.store(render, ordering: .releasing)

        frameCount.wrappingIncrement(ordering: .relaxed)
    }

    /// Gets dirty rows that need re-rendering
    public var dirtyRows: IndexSet {
        renderBuffer.dirtyRows
    }

    /// Whether a full refresh is needed
    public var needsFullRefresh: Bool {
        renderBuffer.fullRefreshNeeded
    }

    // MARK: - Convenience Methods

    /// Updates a cell in the update buffer
    public func setCell(row: Int, col: Int, _ cell: TerminalCell) {
        updateBuffer[row, col] = cell
    }

    /// Gets a cell from the render buffer
    public func getCell(row: Int, col: Int) -> TerminalCell {
        renderBuffer[row, col]
    }

    /// Marks a row as dirty in the update buffer
    public func markDirty(row: Int) {
        updateBuffer.markDirty(row: row)
    }

    /// Marks all rows as dirty (full refresh)
    public func markFullRefresh() {
        updateBuffer.fullRefreshNeeded = true
    }

    /// Clears all buffers to default state
    public func clear() {
        for buffer in buffers {
            let defaultCell = TerminalCell()
            for i in 0..<buffer.cells.count {
                buffer.cells[i] = defaultCell
            }
            buffer.fullRefreshNeeded = true
        }
    }

    // MARK: - Statistics

    public struct Statistics {
        public let bufferSwaps: UInt64
        public let framesPresented: UInt64
        public let dirtyRowCount: Int
        public let needsFullRefresh: Bool
    }

    public var statistics: Statistics {
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
public struct DirtyRegionTracker {
    /// Minimum unit of dirtiness (in cells)
    public let cellsPerChunk: Int

    /// Dirty chunks per row
    private var dirtyChunks: [[Bool]]

    public let rows: Int
    public let cols: Int
    public let chunksPerRow: Int

    public init(rows: Int, cols: Int, cellsPerChunk: Int = 16) {
        self.rows = rows
        self.cols = cols
        self.cellsPerChunk = cellsPerChunk
        self.chunksPerRow = (cols + cellsPerChunk - 1) / cellsPerChunk

        self.dirtyChunks = Array(repeating: Array(repeating: false, count: chunksPerRow), count: rows)
    }

    /// Marks a cell as dirty
    public mutating func markDirty(row: Int, col: Int) {
        guard row >= 0 && row < rows && col >= 0 && col < cols else { return }
        let chunk = col / cellsPerChunk
        dirtyChunks[row][chunk] = true
    }

    /// Marks a range of cells as dirty
    public mutating func markDirty(row: Int, cols range: Range<Int>) {
        guard row >= 0 && row < rows else { return }
        let startChunk = max(0, range.lowerBound / cellsPerChunk)
        let endChunk = min(chunksPerRow - 1, (range.upperBound - 1) / cellsPerChunk)
        for chunk in startChunk...endChunk {
            dirtyChunks[row][chunk] = true
        }
    }

    /// Marks an entire row as dirty
    public mutating func markDirtyRow(_ row: Int) {
        guard row >= 0 && row < rows else { return }
        for chunk in 0..<chunksPerRow {
            dirtyChunks[row][chunk] = true
        }
    }

    /// Gets dirty ranges for a row
    public func dirtyRanges(forRow row: Int) -> [Range<Int>] {
        guard row >= 0 && row < rows else { return [] }

        var ranges: [Range<Int>] = []
        var rangeStart: Int? = nil

        for chunk in 0..<chunksPerRow {
            if dirtyChunks[row][chunk] {
                if rangeStart == nil {
                    rangeStart = chunk * cellsPerChunk
                }
            } else if let start = rangeStart {
                ranges.append(start..<(chunk * cellsPerChunk))
                rangeStart = nil
            }
        }

        if let start = rangeStart {
            ranges.append(start..<cols)
        }

        return ranges
    }

    /// Returns all dirty row indices
    public var dirtyRowIndices: [Int] {
        (0..<rows).filter { row in
            dirtyChunks[row].contains(true)
        }
    }

    /// Clears all dirty flags
    public mutating func clear() {
        for row in 0..<rows {
            for chunk in 0..<chunksPerRow {
                dirtyChunks[row][chunk] = false
            }
        }
    }

    /// Total number of dirty chunks
    public var dirtyChunkCount: Int {
        dirtyChunks.reduce(0) { $0 + $1.filter { $0 }.count }
    }
}
