import Foundation
import Chau7Core

final class RenderPipelineProfiler {
    static let shared = RenderPipelineProfiler()

    struct LiveViewSnapshot: Equatable {
        let viewID: UInt64
        let tabID: String?
        let sessionID: String?
        let isActive: Bool
        let mode: String
        let reasons: String
        let pollCount: Int
        let changedPollCount: Int
        let drawCount: Int
        let syncCallCount: Int
        let syncBytes: Int64
    }

    struct Snapshot {
        let asOf: Date
        let activeLiveViewIDs: [UInt64]
        let liveViews: [LiveViewSnapshot]
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
            liveViews: [],
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
        var tabID: String?
        var sessionID: String?
        var isActive: Bool
        var mode: String
        var reasons: String
        var pollCount: Int
        var changedPollCount: Int
        var drawCount: Int
        var syncCallCount: Int
        var syncBytes: Int64
        var updatedAt: Date
    }

    private let lock = NSLock()
    private var totals = Totals()
    private var liveViews: [UInt64: LiveViewState] = [:]
    private var lastFlushAt: Date
    private let flushInterval: TimeInterval
    private let now: () -> Date
    private let footprintBytes: () -> UInt64
    private let telemetry: PerformanceTelemetryRecording
    private var lastFlushFootprintBytes: UInt64 = 0
    private var peakFootprintBytes: UInt64 = 0

    init(
        flushInterval: TimeInterval = 60,
        now: @escaping () -> Date = Date.init,
        footprintBytes: @escaping () -> UInt64 = RenderPipelineProfiler.currentPhysFootprintBytes,
        telemetry: PerformanceTelemetryRecording = PerformanceTelemetryWriter.shared
    ) {
        self.flushInterval = flushInterval
        self.now = now
        self.footprintBytes = footprintBytes
        self.telemetry = telemetry
        self.lastFlushAt = now()
    }

    /// Reads the process's `phys_footprint` via `task_vm_info`. Returns 0 on
    /// failure. Same Mach call MemoryPressureResponder uses for pressure
    /// thresholds — duplicated here to keep this file dependency-free for
    /// the 30s flush hot path.
    private static func currentPhysFootprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result: kern_return_t = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    func updateRenderLoopState(
        viewID: UInt64,
        active: Bool,
        tabID: String?,
        sessionID: String?,
        mode: String,
        reasons: String
    ) {
        guard WakeupControl.isEnabled(.instrumentationEnabled) else { return }
        recordMutation { now in
            if active {
                let existing = liveViews[viewID]
                liveViews[viewID] = LiveViewState(
                    tabID: tabID,
                    sessionID: sessionID,
                    isActive: active,
                    mode: mode,
                    reasons: reasons,
                    pollCount: existing?.pollCount ?? 0,
                    changedPollCount: existing?.changedPollCount ?? 0,
                    drawCount: existing?.drawCount ?? 0,
                    syncCallCount: existing?.syncCallCount ?? 0,
                    syncBytes: existing?.syncBytes ?? 0,
                    updatedAt: now
                )
            } else {
                guard var existing = liveViews[viewID] else { return }
                existing.isActive = false
                existing.updatedAt = now
                liveViews[viewID] = existing
            }
        }
    }

    func recordPoll(viewID: UInt64, changed: Bool) {
        guard WakeupControl.isEnabled(.instrumentationEnabled) else { return }
        recordMutation { _ in
            totals.livePollCount += 1
            if changed {
                totals.changedPollCount += 1
            }
            if var state = liveViews[viewID] {
                state.pollCount += 1
                if changed {
                    state.changedPollCount += 1
                }
                liveViews[viewID] = state
            }
        }
    }

    func recordDraw(viewID: UInt64, cellCount: Int) {
        guard WakeupControl.isEnabled(.instrumentationEnabled) else { return }
        recordMutation { _ in
            totals.drawCount += 1
            totals.maxFrameCells = max(totals.maxFrameCells, cellCount)
            if var state = liveViews[viewID] {
                state.drawCount += 1
                liveViews[viewID] = state
            }
        }
    }

    func recordSync(viewID: UInt64, rows: Int, cols: Int, syncedRows: Int, syncedCols: Int, mismatched: Bool, bytesWritten: Int) {
        guard WakeupControl.isEnabled(.instrumentationEnabled) else { return }
        recordMutation { _ in
            totals.syncCallCount += 1
            totals.syncBytes += Int64(bytesWritten)
            if mismatched {
                totals.mismatchedSyncCount += 1
            }
            totals.maxFrameCells = max(totals.maxFrameCells, syncedRows * syncedCols)
            if var state = liveViews[viewID] {
                state.syncCallCount += 1
                state.syncBytes += Int64(bytesWritten)
                liveViews[viewID] = state
            }
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
        return buildSnapshot(asOf: now())
    }

    /// Build a `Snapshot` from the current `totals` / `liveViews`. Caller
    /// must hold `lock`. Used by both `snapshot()` and the deferred-flush
    /// path in `recordMutation`.
    private func buildSnapshot(asOf date: Date) -> Snapshot {
        Snapshot(
            asOf: date,
            activeLiveViewIDs: liveViews.compactMap { viewID, state in
                state.isActive ? viewID : nil
            }.sorted(),
            liveViews: liveViewSnapshots(),
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
        lastFlushAt = now()
        lastFlushFootprintBytes = 0
        peakFootprintBytes = 0
        lock.unlock()
    }

    private func recordMutation(_ mutation: (_ now: Date) -> Void) {
        let now = now()
        var snapshot: Snapshot?
        var memorySample: (current: UInt64, delta: Int64, peak: UInt64)?

        lock.lock()
        mutation(now)
        if now.timeIntervalSince(lastFlushAt) >= flushInterval {
            snapshot = buildSnapshot(asOf: now)
            let current = footprintBytes()
            let delta: Int64 = lastFlushFootprintBytes == 0
                ? 0
                : Int64(bitPattern: current) - Int64(bitPattern: lastFlushFootprintBytes)
            peakFootprintBytes = max(peakFootprintBytes, current)
            memorySample = (current, delta, peakFootprintBytes)
            lastFlushFootprintBytes = current
            totals = Totals()
            liveViews = liveViews.reduce(into: [:]) { result, entry in
                let (viewID, state) = entry
                guard state.isActive else { return }
                result[viewID] = LiveViewState(
                    tabID: state.tabID,
                    sessionID: state.sessionID,
                    isActive: true,
                    mode: state.mode,
                    reasons: state.reasons,
                    pollCount: 0,
                    changedPollCount: 0,
                    drawCount: 0,
                    syncCallCount: 0,
                    syncBytes: 0,
                    updatedAt: state.updatedAt
                )
            }
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
        let liveViewMetrics: [[String: Any]] = snapshot.liveViews.map { liveView in
            [
                "view_id": liveView.viewID,
                "active": liveView.isActive,
                "mode": liveView.mode,
                "reasons": liveView.reasons,
                "poll_count": liveView.pollCount,
                "changed_poll_count": liveView.changedPollCount,
                "draw_count": liveView.drawCount,
                "sync_call_count": liveView.syncCallCount,
                "sync_bytes": liveView.syncBytes
            ]
        }
        var fields: [String: Any] = [
            "interval_seconds": flushInterval.isFinite ? flushInterval : 0,
            "active_live_view_count": snapshot.activeLiveViewIDs.count,
            "live_poll_count": snapshot.livePollCount,
            "changed_poll_count": snapshot.changedPollCount,
            "draw_count": snapshot.drawCount,
            "sync_call_count": snapshot.syncCallCount,
            "sync_bytes": snapshot.syncBytes,
            "mismatched_sync_count": snapshot.mismatchedSyncCount,
            "commit_count": snapshot.commitCount,
            "commit_bytes": snapshot.commitBytes,
            "full_refresh_commits": snapshot.fullRefreshCommits,
            "max_dirty_rows": snapshot.maxDirtyRows,
            "max_dirty_cells": snapshot.maxDirtyCells,
            "max_frame_cells": snapshot.maxFrameCells,
            "max_instance_buffer_bytes": snapshot.maxInstanceBufferBytes,
            "saturated_instance_frames": snapshot.saturatedInstanceFrames,
            "max_glyph_cache_size": snapshot.maxGlyphCacheSize,
            "max_ligature_cache_size": snapshot.maxLigatureCacheSize,
            "glyph_lookups": snapshot.glyphLookups,
            "glyph_misses": snapshot.glyphMisses,
            "glyph_miss_rate_percent": missRate,
            "live_views": liveViewMetrics
        ]
        if let memorySample {
            fields["physical_footprint_bytes"] = memorySample.current
            fields["physical_footprint_delta_bytes"] = memorySample.delta
            fields["peak_physical_footprint_bytes"] = memorySample.peak
        }
        telemetry.record(category: "render_pipeline", fields: fields, at: snapshot.asOf)

        if snapshot.mismatchedSyncCount > 0 || snapshot.saturatedInstanceFrames > 0 {
            Log.warn(
                "Render pipeline invariant warning: mismatchedSyncs=\(snapshot.mismatchedSyncCount) " +
                    "saturatedFrames=\(snapshot.saturatedInstanceFrames)"
            )
        }
    }

    private func liveViewSnapshots() -> [LiveViewSnapshot] {
        liveViews
            .map { viewID, state in
                LiveViewSnapshot(
                    viewID: viewID,
                    tabID: state.tabID,
                    sessionID: state.sessionID,
                    isActive: state.isActive,
                    mode: state.mode,
                    reasons: state.reasons,
                    pollCount: state.pollCount,
                    changedPollCount: state.changedPollCount,
                    drawCount: state.drawCount,
                    syncCallCount: state.syncCallCount,
                    syncBytes: state.syncBytes
                )
            }
            .sorted { lhs, rhs in lhs.viewID < rhs.viewID }
    }
}
