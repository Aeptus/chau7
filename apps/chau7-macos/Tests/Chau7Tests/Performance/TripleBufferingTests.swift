import XCTest
@testable import Chau7

final class TripleBufferingTests: XCTestCase {
    private func cell(_ char: String, into buffer: TripleBufferedTerminal.TerminalBuffer) -> TerminalCell {
        let bytes = Array(char.utf8)
        return bytes.withUnsafeBufferPointer { ptr in
            let start = buffer.appendCluster(ptr)
            return TerminalCell(clusterStart: start, clusterLen: UInt16(bytes.count))
        }
    }

    func testCommitRotatesUpdateAndRenderBuffers() {
        let tb = TripleBufferedTerminal(rows: 1, cols: 2)
        let update = tb.updateBuffer

        update.beginUpdate(generation: 1, fullRefresh: true)
        tb.setCell(row: 0, col: 0, cell("a", into: update))
        tb.setCell(row: 0, col: 1, cell("b", into: update))
        update.finishUpdatedRow(0, generation: 1)
        tb.commitUpdate()

        XCTAssertEqual(tb.renderBuffer.clusterString(at: tb.getCell(row: 0, col: 0).clusterStart, length: tb.getCell(row: 0, col: 0).clusterLen), "a")
        XCTAssertFalse(tb.updateBuffer === tb.renderBuffer, "Commit must swap the update and render roles")
    }

    func testClusterBytesSurviveSourceBufferReset() {
        // Regression for the COW-share bug: after a commit, the render
        // buffer's cluster bytes must remain intact even though the bridge
        // immediately resets and rewrites the (new) update buffer. With the
        // old shared ContiguousArray this was only true because the mutation
        // forced a fresh allocation every frame.
        let tb = TripleBufferedTerminal(rows: 1, cols: 1)

        let firstUpdate = tb.updateBuffer
        firstUpdate.beginUpdate(generation: 1, fullRefresh: true)
        tb.setCell(row: 0, col: 0, cell("❤️", into: firstUpdate))
        firstUpdate.finishUpdatedRow(0, generation: 1)
        tb.commitUpdate()

        let rendered = tb.getCell(row: 0, col: 0)
        // Simulate the next frame's bridge pass on the new update buffer.
        let secondUpdate = tb.updateBuffer
        secondUpdate.beginUpdate(generation: 2, fullRefresh: false)
        _ = cell("XXXX", into: secondUpdate)

        XCTAssertEqual(
            tb.renderBuffer.clusterString(at: rendered.clusterStart, length: rendered.clusterLen),
            "❤️",
            "Render buffer must own its cluster bytes; the update buffer reset must not clobber them"
        )
    }

    func testSteadyStateSyncDoesNotGrowClusterCapacity() {
        let tb = TripleBufferedTerminal(rows: 2, cols: 4)
        for generation in 1 ... 50 {
            let update = tb.updateBuffer
            update.beginUpdate(generation: UInt64(generation), fullRefresh: true)
            for col in 0 ..< 4 {
                tb.setCell(row: 0, col: col, cell("x", into: update))
            }
            update.finishUpdatedRow(0, generation: UInt64(generation))
            update.finishUpdatedRow(1, generation: UInt64(generation))
            tb.commitUpdate()
        }
        for buffer in [tb.updateBuffer, tb.renderBuffer, tb.displayBuffer] {
            XCTAssertEqual(
                buffer.clusterCapacity,
                max(2 * 4, 64),
                "ASCII-density workload must never grow the initial capacity"
            )
        }
    }

    func testDirtyRowsPropagateThroughCommitAndClearOnPresent() {
        let tb = TripleBufferedTerminal(rows: 3, cols: 1)
        let update = tb.updateBuffer
        update.beginUpdate(generation: 1, fullRefresh: false)
        tb.setCell(row: 1, col: 0, cell("z", into: update))
        update.finishUpdatedRow(1, generation: 1)

        XCTAssertEqual(update.dirtyRows, IndexSet(integer: 1), "setCell must mark only the changed row dirty")
        tb.commitUpdate()
        XCTAssertEqual(tb.dirtyRows, IndexSet(integer: 1), "Render buffer keeps committed dirty rows for incremental upload")

        tb.presentFrame()
        XCTAssertTrue(tb.displayBuffer.dirtyRows.contains(1), "Presented buffer is the former render buffer")
    }

    func testRowGenerationsKeepRotatingUpdateBufferCurrent() {
        let tb = TripleBufferedTerminal(rows: 2, cols: 1)

        var update = tb.updateBuffer
        update.beginUpdate(generation: 1, fullRefresh: true)
        tb.setCell(row: 0, col: 0, cell("a", into: update))
        tb.setCell(row: 1, col: 0, cell("b", into: update))
        update.finishUpdatedRow(0, generation: 1)
        update.finishUpdatedRow(1, generation: 1)
        tb.commitUpdate()
        tb.presentFrame()

        update = tb.updateBuffer
        update.beginUpdate(generation: 2, fullRefresh: false)
        tb.setCell(row: 1, col: 0, cell("c", into: update))
        update.finishUpdatedRow(1, generation: 2)
        tb.commitUpdate()
        tb.presentFrame()

        update = tb.updateBuffer
        update.beginUpdate(generation: 2, fullRefresh: false)
        XCTAssertTrue(update.dirtyRows.isEmpty)
        _ = tb.commitUpdate()
        XCTAssertTrue(
            tb.dirtyRows.isEmpty,
            "a target-buffer catch-up copy must not become a false renderer dirty row"
        )
    }

    func testClusterOffsetSelfHealingWhenEarlierCellChangesByteLength() {
        // An early cell growing from ASCII to emoji shifts every downstream
        // cluster offset; cellsDiffer must catch the shifted offsets and mark
        // those rows dirty (the CLUSTER OFFSET INVARIANT).
        let tb = TripleBufferedTerminal(rows: 2, cols: 1)

        func sync(_ top: String, _ bottom: String, generation: UInt64) {
            let update = tb.updateBuffer
            update.beginUpdate(generation: generation, fullRefresh: generation == 1)
            tb.setCell(row: 0, col: 0, cell(top, into: update))
            tb.setCell(row: 1, col: 0, cell(bottom, into: update))
            update.finishUpdatedRow(0, generation: generation)
            update.finishUpdatedRow(1, generation: generation)
            tb.commitUpdate()
            tb.presentFrame()
        }

        sync("a", "b", generation: 1)
        sync("💥", "b", generation: 2)

        let bottom = tb.displayBuffer
        let bottomCell = bottom[1, 0]
        XCTAssertEqual(
            bottom.clusterString(at: bottomCell.clusterStart, length: bottomCell.clusterLen),
            "b",
            "Shifted offsets must re-copy downstream rows against the new cluster bytes"
        )
    }

    func testLaggingRenderBufferCatchesUpRowsItMissed() {
        let tb = TripleBufferedTerminal(rows: 3, cols: 1)

        var update = tb.updateBuffer
        update.beginUpdate(generation: 1, fullRefresh: true)
        for row in 0 ..< 3 {
            tb.setCell(row: row, col: 0, cell("a", into: update))
            update.finishUpdatedRow(row, generation: 1)
        }
        tb.commitUpdate()
        tb.presentFrame()

        update = tb.updateBuffer
        update.beginUpdate(generation: 2, fullRefresh: false)
        tb.setCell(row: 0, col: 0, cell("b", into: update))
        update.finishUpdatedRow(0, generation: 2)
        tb.commitUpdate()
        tb.presentFrame()

        update = tb.updateBuffer
        update.beginUpdate(generation: 3, fullRefresh: false)
        tb.setCell(row: 2, col: 0, cell("c", into: update))
        update.finishUpdatedRow(2, generation: 3)
        let stats = tb.commitUpdate()
        tb.presentFrame()

        XCTAssertEqual(stats.dirtyRows, 2, "rotating target must catch up generation 2 and 3 rows")
        XCTAssertEqual(tb.displayBuffer.clusterString(at: tb.displayBuffer[0, 0].clusterStart, length: tb.displayBuffer[0, 0].clusterLen), "b")
        XCTAssertEqual(tb.displayBuffer.clusterString(at: tb.displayBuffer[2, 0].clusterStart, length: tb.displayBuffer[2, 0].clusterLen), "c")
    }
}
