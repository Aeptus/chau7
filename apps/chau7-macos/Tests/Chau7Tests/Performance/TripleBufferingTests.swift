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

        update.resetClusters()
        tb.setCell(row: 0, col: 0, cell("a", into: update))
        tb.setCell(row: 0, col: 1, cell("b", into: update))
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
        firstUpdate.resetClusters()
        tb.setCell(row: 0, col: 0, cell("❤️", into: firstUpdate))
        tb.commitUpdate()

        let rendered = tb.getCell(row: 0, col: 0)
        // Simulate the next frame's bridge pass on the new update buffer.
        let secondUpdate = tb.updateBuffer
        secondUpdate.resetClusters()
        _ = cell("XXXX", into: secondUpdate)

        XCTAssertEqual(
            tb.renderBuffer.clusterString(at: rendered.clusterStart, length: rendered.clusterLen),
            "❤️",
            "Render buffer must own its cluster bytes; the update buffer reset must not clobber them"
        )
    }

    func testSteadyStateSyncDoesNotGrowClusterCapacity() {
        let tb = TripleBufferedTerminal(rows: 2, cols: 4)
        for _ in 0 ..< 50 {
            let update = tb.updateBuffer
            update.resetClusters()
            for col in 0 ..< 4 {
                tb.setCell(row: 0, col: col, cell("x", into: update))
            }
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
        update.clearDirty()
        update.resetClusters()
        tb.setCell(row: 1, col: 0, cell("z", into: update))

        XCTAssertEqual(update.dirtyRows, IndexSet(integer: 1), "setCell must mark only the changed row dirty")
        tb.commitUpdate()
        XCTAssertEqual(tb.dirtyRows, IndexSet(integer: 1), "Render buffer keeps committed dirty rows for incremental upload")

        tb.presentFrame()
        XCTAssertTrue(tb.displayBuffer.dirtyRows.contains(1), "Presented buffer is the former render buffer")
    }

    /// Documents the 3-frame-stale diff baseline: the buffer serving as the
    /// update buffer was last fully written two commits ago and only received
    /// the previous frame's dirty rows via copyDirtyFrom — the intervening
    /// frame's rows were applied to a DIFFERENT buffer. `cellsDiffer`
    /// therefore reports a superset of truly-changed rows (safe: over-dirty,
    /// never under-dirty), which inflates dirty-row metrics on mostly-static
    /// screens. If a damage-generation ring ever fixes this, flip the
    /// expectation below.
    func testDiffBaselineIsStaleByDesignAndOverReportsDirtyRows() {
        let tb = TripleBufferedTerminal(rows: 2, cols: 1)

        func sync(_ top: String, _ bottom: String) {
            let update = tb.updateBuffer
            update.resetClusters()
            tb.setCell(row: 0, col: 0, cell(top, into: update))
            tb.setCell(row: 1, col: 0, cell(bottom, into: update))
            tb.commitUpdate()
            tb.presentFrame()
        }

        sync("a", "b")
        sync("a", "c") // row 1 changes
        // Third frame: identical to the second. A perfect diff would report
        // zero dirty rows; the stale baseline (buffer last saw frame 1)
        // still reports row 1 as dirty.
        let update = tb.updateBuffer
        update.resetClusters()
        tb.setCell(row: 0, col: 0, cell("a", into: update))
        tb.setCell(row: 1, col: 0, cell("c", into: update))

        XCTAssertTrue(
            update.dirtyRows.contains(1),
            "Stale baseline over-reports: documents current behavior — see comment"
        )
    }

    func testClusterOffsetSelfHealingWhenEarlierCellChangesByteLength() {
        // An early cell growing from ASCII to emoji shifts every downstream
        // cluster offset; cellsDiffer must catch the shifted offsets and mark
        // those rows dirty (the CLUSTER OFFSET INVARIANT).
        let tb = TripleBufferedTerminal(rows: 2, cols: 1)

        func sync(_ top: String, _ bottom: String) {
            let update = tb.updateBuffer
            update.resetClusters()
            tb.setCell(row: 0, col: 0, cell(top, into: update))
            tb.setCell(row: 1, col: 0, cell(bottom, into: update))
            tb.commitUpdate()
            tb.presentFrame()
        }

        sync("a", "b")
        sync("💥", "b") // row 0 grows; row 1's offset shifts by 3 bytes

        let bottom = tb.displayBuffer
        let bottomCell = bottom[1, 0]
        XCTAssertEqual(
            bottom.clusterString(at: bottomCell.clusterStart, length: bottomCell.clusterLen),
            "b",
            "Shifted offsets must re-copy downstream rows against the new cluster bytes"
        )
    }
}
