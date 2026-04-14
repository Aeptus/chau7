import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class RenderPipelineProfilerTests: XCTestCase {

    func testSnapshotAggregatesRenderPipelineMetrics() {
        let profiler = RenderPipelineProfiler(flushInterval: 300)

        profiler.updateRenderLoopState(viewID: 7, active: true, mode: "display_link", reason: "test")
        profiler.recordPoll(viewID: 7, changed: true, live: true)
        profiler.recordPoll(viewID: 7, changed: false, live: true)
        profiler.recordDraw(viewID: 7, cellCount: 120)
        profiler.recordSync(rows: 24, cols: 80, syncedRows: 24, syncedCols: 80, mismatched: true, bytesWritten: 4096)
        profiler.recordCommit(dirtyRows: 12, dirtyCells: 960, bytesCopied: 2048, fullRefresh: true)
        profiler.recordInstanceBuffer(
            cells: 120,
            bufferBytes: 16_384,
            saturated: true,
            glyphLookups: 300,
            glyphMisses: 12,
            glyphCacheSize: 144,
            ligatureCacheSize: 9
        )

        let snapshot = profiler.snapshot()
        XCTAssertEqual(snapshot.activeLiveViewIDs, [UInt64(7)])
        XCTAssertEqual(snapshot.livePollCount, 2)
        XCTAssertEqual(snapshot.changedPollCount, 1)
        XCTAssertEqual(snapshot.drawCount, 1)
        XCTAssertEqual(snapshot.syncCallCount, 1)
        XCTAssertEqual(snapshot.syncBytes, 4096)
        XCTAssertEqual(snapshot.mismatchedSyncCount, 1)
        XCTAssertEqual(snapshot.commitCount, 1)
        XCTAssertEqual(snapshot.commitBytes, 2048)
        XCTAssertEqual(snapshot.fullRefreshCommits, 1)
        XCTAssertEqual(snapshot.maxDirtyRows, 12)
        XCTAssertEqual(snapshot.maxDirtyCells, 960)
        XCTAssertEqual(snapshot.maxFrameCells, 1920)
        XCTAssertEqual(snapshot.maxInstanceBufferBytes, 16_384)
        XCTAssertEqual(snapshot.saturatedInstanceFrames, 1)
        XCTAssertEqual(snapshot.glyphLookups, 300)
        XCTAssertEqual(snapshot.glyphMisses, 12)
        XCTAssertEqual(snapshot.maxGlyphCacheSize, 144)
        XCTAssertEqual(snapshot.maxLigatureCacheSize, 9)
    }

    func testResetClearsState() {
        let profiler = RenderPipelineProfiler(flushInterval: 300)

        profiler.updateRenderLoopState(viewID: 3, active: true, mode: "display_link", reason: "test")
        profiler.recordPoll(viewID: 3, changed: true, live: true)
        profiler.resetForTesting()

        let snapshot = profiler.snapshot()
        XCTAssertEqual(snapshot.activeLiveViewIDs, [])
        XCTAssertEqual(snapshot.livePollCount, 0)
        XCTAssertEqual(snapshot.drawCount, 0)
        XCTAssertEqual(snapshot.syncCallCount, 0)
        XCTAssertEqual(snapshot.commitCount, 0)
        XCTAssertEqual(snapshot.glyphLookups, 0)
    }
}
#endif
