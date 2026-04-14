import Foundation
import Chau7Core

final class RenderPipelineProfiler {
    static let shared = RenderPipelineProfiler()

    struct Snapshot {
        let asOf: Date
        let activeLiveViewIDs: [UInt64]
        let livePollCount: Int
        let changedPollCount: Int
        let drawCount: Int
        let syncCallCount: Int
        let syncBytes: Int64
        let mismatchedSyncCount: Int
        let commitCount: Int
        let commitBytes: Int64
        let fullRefreshCommits: Int
        let maxDirtyRows: Int
        let maxDirtyCells: Int
        let maxFrameCells: Int
        let maxInstanceBufferBytes: Int
        let saturatedInstanceFrames: Int
        let glyphLookups: Int
        let glyphMisses: Int
        let maxGlyphCacheSize: Int
        let maxLigatureCacheSize: Int

        static let empty = Snapshot(
            asOf: .distantPast,
            activeLiveViewIDs: [],
            livePollCount: 0,
            changedPollCount: 0,
            drawCount: 0,
            syncCallCount: 0,
            syncBytes: 0,
            mismatchedSyncCount: 0,
            commitCount: 0,
            commitBytes: 0,
            fullRefreshCommits: 0,
            maxDirtyRows: 0,
            maxDirtyCells: 0,
            maxFrameCells: 0,
            maxInstanceBufferBytes: 0,
            saturatedInstanceFrames: 0,
            glyphLookups: 0,
            glyphMisses: 0,
            maxGlyphCacheSize: 0,
            maxLigatureCacheSize: 0
        )
    }

    private struct Totals {
        var livePollCount = 0
        var changedPollCount = 0
        var drawCount = 0
        var syncCallCount = 0
        var syncBytes: Int64 = 0
        var mismatchedSyncCount = 0
        var commitCount = 0
        var commitBytes: Int64 = 0
        var fullRefreshCommits = 0
        var maxDirtyRows = 0
        var maxDirtyCells = 0
        var maxFrameCells = 0
        var maxInstanceBufferBytes = 0
        var saturatedInstanceFrames = 0
        var glyphLookups = 0
        var glyphMisses = 0
        var maxGlyphCacheSize = 0
        var maxLigatureCacheSize = 0
    }

    private struct LiveViewState {
        var mode: String
        var reason: String
        var updatedAt: Date
    }

    private let lock = NSLock()
    private var totals = Totals()
    private var liveViews: [UInt64: LiveViewState] = [:]
    private var lastFlushAt = Date()
    private let flushInterval: TimeInterval

    init(flushInterval: TimeInterval = 30) {
        self.flushInterval = flushInterval
    }

    func updateRenderLoopState(viewID: UInt64, active: Bool, mode: String, reason: String) {
        guard WakeupControl.isEnabled(.instrumentationEnabled) else { return }
        recordMutation { now in
            if active {
                liveViews[viewID] = LiveViewState(mode: mode, reason: reason, updatedAt: now)
            } else {
                liveViews.removeValue(forKey: viewID)
            }
        }
    }

    func recordPoll(viewID: UInt64, changed: Bool, live: Bool) {
        guard WakeupControl.isEnabled(.instrumentationEnabled) else { return }
        recordMutation { _ in
            if live {
                totals.livePollCount += 1
            }
            if changed {
                totals.changedPollCount += 1
            }
            _ = viewID
        }
    }

    func recordDraw(viewID: UInt64, cellCount: Int) {
        guard WakeupControl.isEnabled(.instrumentationEnabled) else { return }
        recordMutation { _ in
            totals.drawCount += 1
            totals.maxFrameCells = max(totals.maxFrameCells, cellCount)
            _ = viewID
        }
    }

    func recordSync(rows: Int, cols: Int, syncedRows: Int, syncedCols: Int, mismatched: Bool, bytesWritten: Int) {
        guard WakeupControl.isEnabled(.instrumentationEnabled) else { return }
        recordMutation { _ in
            totals.syncCallCount += 1
            totals.syncBytes += Int64(bytesWritten)
            if mismatched {
                totals.mismatchedSyncCount += 1
            }
            totals.maxFrameCells = max(totals.maxFrameCells, syncedRows * syncedCols)
            _ = rows
            _ = cols
        }
    }

    func recordCommit(dirtyRows: Int, dirtyCells: Int, bytesCopied: Int, fullRefresh: Bool) {
        guard WakeupControl.isEnabled(.instrumentationEnabled) else { return }
        recordMutation { _ in
            totals.commitCount += 1
            totals.commitBytes += Int64(bytesCopied)
            totals.maxDirtyRows = max(totals.maxDirtyRows, dirtyRows)
            totals.maxDirtyCells = max(totals.maxDirtyCells, dirtyCells)
            if fullRefresh {
                totals.fullRefreshCommits += 1
            }
        }
    }

    func recordInstanceBuffer(
        cells: Int,
        bufferBytes: Int,
        saturated: Bool,
        glyphLookups: Int,
        glyphMisses: Int,
        glyphCacheSize: Int,
        ligatureCacheSize: Int
    ) {
        guard WakeupControl.isEnabled(.instrumentationEnabled) else { return }
        recordMutation { _ in
            totals.maxFrameCells = max(totals.maxFrameCells, cells)
            totals.maxInstanceBufferBytes = max(totals.maxInstanceBufferBytes, bufferBytes)
            totals.glyphLookups += glyphLookups
            totals.glyphMisses += glyphMisses
            totals.maxGlyphCacheSize = max(totals.maxGlyphCacheSize, glyphCacheSize)
            totals.maxLigatureCacheSize = max(totals.maxLigatureCacheSize, ligatureCacheSize)
            if saturated {
                totals.saturatedInstanceFrames += 1
            }
        }
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return Snapshot(
            asOf: Date(),
            activeLiveViewIDs: liveViews.keys.sorted(),
            livePollCount: totals.livePollCount,
            changedPollCount: totals.changedPollCount,
            drawCount: totals.drawCount,
            syncCallCount: totals.syncCallCount,
            syncBytes: totals.syncBytes,
            mismatchedSyncCount: totals.mismatchedSyncCount,
            commitCount: totals.commitCount,
            commitBytes: totals.commitBytes,
            fullRefreshCommits: totals.fullRefreshCommits,
            maxDirtyRows: totals.maxDirtyRows,
            maxDirtyCells: totals.maxDirtyCells,
            maxFrameCells: totals.maxFrameCells,
            maxInstanceBufferBytes: totals.maxInstanceBufferBytes,
            saturatedInstanceFrames: totals.saturatedInstanceFrames,
            glyphLookups: totals.glyphLookups,
            glyphMisses: totals.glyphMisses,
            maxGlyphCacheSize: totals.maxGlyphCacheSize,
            maxLigatureCacheSize: totals.maxLigatureCacheSize
        )
    }

    func resetForTesting() {
        lock.lock()
        totals = Totals()
        liveViews.removeAll()
        lastFlushAt = Date()
        lock.unlock()
    }

    private func recordMutation(_ mutation: (_ now: Date) -> Void) {
        let now = Date()
        var snapshot: Snapshot?

        lock.lock()
        mutation(now)
        if now.timeIntervalSince(lastFlushAt) >= flushInterval {
            snapshot = Snapshot(
                asOf: now,
                activeLiveViewIDs: liveViews.keys.sorted(),
                livePollCount: totals.livePollCount,
                changedPollCount: totals.changedPollCount,
                drawCount: totals.drawCount,
                syncCallCount: totals.syncCallCount,
                syncBytes: totals.syncBytes,
                mismatchedSyncCount: totals.mismatchedSyncCount,
                commitCount: totals.commitCount,
                commitBytes: totals.commitBytes,
                fullRefreshCommits: totals.fullRefreshCommits,
                maxDirtyRows: totals.maxDirtyRows,
                maxDirtyCells: totals.maxDirtyCells,
                maxFrameCells: totals.maxFrameCells,
                maxInstanceBufferBytes: totals.maxInstanceBufferBytes,
                saturatedInstanceFrames: totals.saturatedInstanceFrames,
                glyphLookups: totals.glyphLookups,
                glyphMisses: totals.glyphMisses,
                maxGlyphCacheSize: totals.maxGlyphCacheSize,
                maxLigatureCacheSize: totals.maxLigatureCacheSize
            )
            totals = Totals()
            lastFlushAt = now
        }
        lock.unlock()

        guard let snapshot else { return }
        let missRate: Double
        if snapshot.glyphLookups > 0 {
            missRate = (Double(snapshot.glyphMisses) / Double(snapshot.glyphLookups)) * 100
        } else {
            missRate = 0
        }
        let syncMiB = Double(snapshot.syncBytes) / 1_048_576
        let commitMiB = Double(snapshot.commitBytes) / 1_048_576
        Log.info(
            String(
                format: "Render pipeline (30s): liveViews=%d ids=%@ polls=%d changed=%d draws=%d syncCalls=%d sync=%.1fMiB mismatches=%d commits=%d commit=%.1fMiB fullRefresh=%d maxDirtyRows=%d maxDirtyCells=%d maxFrameCells=%d maxInstanceBuffer=%.1fMiB saturatedFrames=%d glyphCache=%d ligatureCache=%d glyphLookups=%d missRate=%.1f%%",
                snapshot.activeLiveViewIDs.count,
                snapshot.activeLiveViewIDs.map(String.init).joined(separator: ","),
                snapshot.livePollCount,
                snapshot.changedPollCount,
                snapshot.drawCount,
                snapshot.syncCallCount,
                syncMiB,
                snapshot.mismatchedSyncCount,
                snapshot.commitCount,
                commitMiB,
                snapshot.fullRefreshCommits,
                snapshot.maxDirtyRows,
                snapshot.maxDirtyCells,
                snapshot.maxFrameCells,
                Double(snapshot.maxInstanceBufferBytes) / 1_048_576,
                snapshot.saturatedInstanceFrames,
                snapshot.maxGlyphCacheSize,
                snapshot.maxLigatureCacheSize,
                snapshot.glyphLookups,
                missRate
            )
        )
    }
}
