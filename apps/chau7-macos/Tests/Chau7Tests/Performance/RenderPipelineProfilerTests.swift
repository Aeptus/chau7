import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

final class RenderPipelineProfilerTests: XCTestCase {

    func testSnapshotAggregatesRenderPipelineMetrics() {
        let profiler = RenderPipelineProfiler(flushInterval: 300)

        profiler.updateRenderLoopState(
            viewID: 7,
            active: true,
            tabID: "tab-1",
            sessionID: "session-1",
            mode: "display_link",
            reasons: "selected,visibleWindow"
        )
        profiler.recordPoll(viewID: 7, changed: true)
        profiler.recordPoll(viewID: 7, changed: false)
        profiler.recordDraw(viewID: 7, cellCount: 120)
        profiler.recordSync(viewID: 7, rows: 24, cols: 80, syncedRows: 24, syncedCols: 80, mismatched: true, bytesWritten: 4096)
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
        XCTAssertEqual(
            snapshot.liveViews,
            [RenderPipelineProfiler.LiveViewSnapshot(
                viewID: 7,
                tabID: "tab-1",
                sessionID: "session-1",
                isActive: true,
                mode: "display_link",
                reasons: "selected,visibleWindow",
                pollCount: 2,
                changedPollCount: 1,
                drawCount: 1,
                syncCallCount: 1,
                syncBytes: 4096
            )]
        )
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

        profiler.updateRenderLoopState(
            viewID: 3,
            active: true,
            tabID: "tab-3",
            sessionID: nil,
            mode: "display_link",
            reasons: "selected"
        )
        profiler.recordPoll(viewID: 3, changed: true)
        profiler.resetForTesting()

        let snapshot = profiler.snapshot()
        XCTAssertEqual(snapshot.activeLiveViewIDs, [])
        XCTAssertEqual(snapshot.liveViews, [])
        XCTAssertEqual(snapshot.livePollCount, 0)
        XCTAssertEqual(snapshot.drawCount, 0)
        XCTAssertEqual(snapshot.syncCallCount, 0)
        XCTAssertEqual(snapshot.commitCount, 0)
        XCTAssertEqual(snapshot.glyphLookups, 0)
    }

    func testDeactivatedViewRemainsInSnapshotUntilFlush() {
        let profiler = RenderPipelineProfiler(flushInterval: 300)

        profiler.updateRenderLoopState(
            viewID: 11,
            active: true,
            tabID: "tab-11",
            sessionID: "session-11",
            mode: "timer",
            reasons: "selected-passive"
        )
        profiler.recordPoll(viewID: 11, changed: true)
        profiler.recordSync(viewID: 11, rows: 24, cols: 80, syncedRows: 12, syncedCols: 80, mismatched: false, bytesWritten: 2048)
        profiler.updateRenderLoopState(
            viewID: 11,
            active: false,
            tabID: "tab-11",
            sessionID: "session-11",
            mode: "timer",
            reasons: "selected-passive"
        )

        let snapshot = profiler.snapshot()
        XCTAssertEqual(snapshot.activeLiveViewIDs, [])
        XCTAssertEqual(snapshot.liveViews.count, 1)
        XCTAssertEqual(snapshot.liveViews[0].viewID, 11)
        XCTAssertFalse(snapshot.liveViews[0].isActive)
        XCTAssertEqual(snapshot.liveViews[0].pollCount, 1)
        XCTAssertEqual(snapshot.liveViews[0].syncCallCount, 1)
        XCTAssertEqual(snapshot.liveViews[0].syncBytes, 2048)
    }
}
#endif
