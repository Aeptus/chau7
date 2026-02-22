import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class TripleBufferingTests: XCTestCase {

    // MARK: - testInitialState

    func testInitialState() {
        let buffer = TripleBufferedTerminal(rows: 24, cols: 80)

        XCTAssertEqual(buffer.rows, 24)
        XCTAssertEqual(buffer.cols, 80)

        // Initial statistics should be zero
        let stats = buffer.statistics
        XCTAssertEqual(stats.bufferSwaps, 0,
            "No swaps should have occurred yet")
        XCTAssertEqual(stats.framesPresented, 0,
            "No frames should have been presented yet")

        // Initial cells should be the default (space character = 0x20)
        let cell = buffer.getCell(row: 0, col: 0)
        XCTAssertEqual(cell.character, 0x20,
            "Default cell character should be space (0x20)")
        XCTAssertEqual(cell.flags, 0,
            "Default cell flags should be 0")
    }

    func testInitialBuffersAreFullRefresh() {
        let buffer = TripleBufferedTerminal(rows: 4, cols: 4)

        // New buffers should need full refresh
        XCTAssertTrue(buffer.needsFullRefresh,
            "Freshly created buffer should need full refresh")
    }

    // MARK: - testCommitAndSwap

    func testCommitAndSwap() {
        let buffer = TripleBufferedTerminal(rows: 4, cols: 4)

        // Write to the update buffer
        let testCell = TerminalCell(
            character: 0x41, // 'A'
            foreground: SIMD4<Float>(1, 0, 0, 1),
            background: SIMD4<Float>(0, 0, 0, 1),
            flags: 1 // bold
        )
        buffer.setCell(row: 0, col: 0, testCell)

        // Commit the update (copies dirty regions to render buffer)
        buffer.commitUpdate()

        // The render buffer should now have our data
        let readCell = buffer.getCell(row: 0, col: 0)
        XCTAssertEqual(readCell.character, 0x41,
            "After commit, render buffer should contain the written character")
        XCTAssertEqual(readCell.flags, 1,
            "After commit, render buffer should contain the written flags")

        // Verify swap count incremented
        XCTAssertEqual(buffer.statistics.bufferSwaps, 1)
    }

    func testCommitMarksDirtyRows() {
        let buffer = TripleBufferedTerminal(rows: 4, cols: 4)

        // Write to row 2
        let testCell = TerminalCell(character: 0x42)
        buffer.setCell(row: 2, col: 0, testCell)

        buffer.commitUpdate()

        // Row 2 should be marked dirty in the render buffer
        let dirty = buffer.dirtyRows
        XCTAssertTrue(dirty.contains(2),
            "Row 2 should be dirty after writing to it")
    }

    // MARK: - testMultipleCommits

    func testMultipleCommits() {
        let buffer = TripleBufferedTerminal(rows: 4, cols: 4)

        // First write
        let cellA = TerminalCell(character: 0x41) // 'A'
        buffer.setCell(row: 0, col: 0, cellA)
        buffer.commitUpdate()

        // Second write to the same cell (overwrites)
        let cellB = TerminalCell(character: 0x42) // 'B'
        buffer.setCell(row: 0, col: 0, cellB)
        buffer.commitUpdate()

        // The render buffer should have the latest value
        let readCell = buffer.getCell(row: 0, col: 0)
        XCTAssertEqual(readCell.character, 0x42,
            "After multiple commits, only the latest value should be visible")
        XCTAssertEqual(buffer.statistics.bufferSwaps, 2,
            "Two commits should result in two swaps")
    }

    func testMultipleCommitsOnlyLatestVisible() {
        let buffer = TripleBufferedTerminal(rows: 4, cols: 4)

        // Write multiple values before committing
        buffer.setCell(row: 0, col: 0, TerminalCell(character: 0x41))
        buffer.setCell(row: 0, col: 0, TerminalCell(character: 0x42))
        buffer.setCell(row: 0, col: 0, TerminalCell(character: 0x43)) // 'C'

        // Single commit
        buffer.commitUpdate()

        let readCell = buffer.getCell(row: 0, col: 0)
        XCTAssertEqual(readCell.character, 0x43,
            "Only the last write before commit should be visible")
    }

    // MARK: - Present Frame

    func testPresentFrame() {
        let buffer = TripleBufferedTerminal(rows: 4, cols: 4)

        buffer.setCell(row: 0, col: 0, TerminalCell(character: 0x41))
        buffer.commitUpdate()
        buffer.presentFrame()

        XCTAssertEqual(buffer.statistics.framesPresented, 1,
            "One frame should have been presented")
    }

    // MARK: - Clear

    func testClear() {
        let buffer = TripleBufferedTerminal(rows: 4, cols: 4)

        // Write some data
        buffer.setCell(row: 0, col: 0, TerminalCell(character: 0x41))
        buffer.commitUpdate()

        // Clear all buffers
        buffer.clear()

        // After clear, all cells should be default
        let cell = buffer.getCell(row: 0, col: 0)
        XCTAssertEqual(cell.character, 0x20,
            "After clear, cells should be reset to default space")
    }

    // MARK: - Mark Full Refresh

    func testMarkFullRefresh() {
        let buffer = TripleBufferedTerminal(rows: 4, cols: 4)

        // After a commit, dirty flags are cleared on the update buffer
        buffer.setCell(row: 0, col: 0, TerminalCell(character: 0x41))
        buffer.commitUpdate()

        buffer.markFullRefresh()
        buffer.commitUpdate()

        XCTAssertTrue(buffer.needsFullRefresh,
            "After markFullRefresh + commit, render buffer should need full refresh")
    }

    // MARK: - DirtyRegionTracker

    func testDirtyRegionTrackerMarkCell() {
        var tracker = DirtyRegionTracker(rows: 10, cols: 80, cellsPerChunk: 16)

        tracker.markDirty(row: 3, col: 10)

        let dirtyRows = tracker.dirtyRowIndices
        XCTAssertEqual(dirtyRows, [3],
            "Only marked row should be dirty")
        XCTAssertEqual(tracker.dirtyChunkCount, 1,
            "Only one chunk should be dirty")
    }

    func testDirtyRegionTrackerClear() {
        var tracker = DirtyRegionTracker(rows: 10, cols: 80, cellsPerChunk: 16)

        tracker.markDirtyRow(0)
        tracker.markDirtyRow(5)
        tracker.clear()

        XCTAssertEqual(tracker.dirtyChunkCount, 0,
            "After clear, no chunks should be dirty")
        XCTAssertTrue(tracker.dirtyRowIndices.isEmpty,
            "After clear, no rows should be dirty")
    }

    func testDirtyRegionTrackerDirtyRanges() {
        var tracker = DirtyRegionTracker(rows: 10, cols: 80, cellsPerChunk: 16)

        // Mark cells in chunks 0 and 2 of row 0
        tracker.markDirty(row: 0, col: 0)  // chunk 0
        tracker.markDirty(row: 0, col: 32) // chunk 2

        let ranges = tracker.dirtyRanges(forRow: 0)
        XCTAssertEqual(ranges.count, 2,
            "Should have two separate dirty ranges")
    }
}
#endif
