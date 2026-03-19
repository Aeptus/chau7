import Chau7Core
import Foundation
import Observation

@MainActor
@Observable
final class RemoteTerminalRendererStore {
    private static let maxReplayBytesPerTab = 400_000

    private(set) var renderState: RemoteTerminalRenderState?
    private(set) var activeTabID: UInt32 = 0
    private(set) var isAvailable = true

    private var playbacks: [UInt32: RemoteRustTerminalPlayback] = [:]
    private var gridSnapshotByTabID: [UInt32: RemoteTerminalRenderState] = [:]
    private var replayByTabID: [UInt32: Data] = [:]
    private var pendingReplayByTabID: [UInt32: [Data]] = [:]
    private var viewportCols = 0
    private var viewportRows = 0
    private var refreshTask: Task<Void, Never>?

    func reset() {
        refreshTask?.cancel()
        refreshTask = nil
        playbacks.removeAll()
        gridSnapshotByTabID.removeAll()
        replayByTabID.removeAll()
        pendingReplayByTabID.removeAll()
        renderState = nil
        activeTabID = 0
        isAvailable = true
    }

    func retainVisibleTabs(_ visibleTabIDs: Set<UInt32>) {
        playbacks = playbacks.filter { visibleTabIDs.contains($0.key) }
        gridSnapshotByTabID = gridSnapshotByTabID.filter { visibleTabIDs.contains($0.key) }
        replayByTabID = replayByTabID.filter { visibleTabIDs.contains($0.key) }
        pendingReplayByTabID = pendingReplayByTabID.filter { visibleTabIDs.contains($0.key) }
        if !visibleTabIDs.contains(activeTabID) {
            refreshTask?.cancel()
            refreshTask = nil
            activeTabID = 0
            renderState = nil
        }
    }

    func setViewport(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        let changed = cols != viewportCols || rows != viewportRows
        viewportCols = cols
        viewportRows = rows

        guard activeTabID != 0 else { return }
        if changed, let playback = playbacks[activeTabID] {
            playback.resize(cols: cols, rows: rows)
        }
        ensurePlayback(for: activeTabID, forceRebuild: false)
        refreshActiveState()
    }

    func setActiveTab(_ tabID: UInt32, fallbackText: String) {
        activeTabID = tabID
        ensurePlayback(for: tabID, forceRebuild: false)
        refreshActiveState()
    }

    func updateActiveFallbackText(_ text: String) {
        _ = text
    }

    func replaceSnapshot(_ data: Data, for tabID: UInt32) {
        guard tabID == activeTabID else { return }
        refreshActiveState()
    }

    func replaceGridSnapshot(_ state: RemoteTerminalRenderState, for tabID: UInt32) {
        gridSnapshotByTabID[tabID] = state
        guard tabID == activeTabID else { return }
        renderState = preferredRenderState(for: tabID)
    }

    func appendOutput(_ data: Data, for tabID: UInt32) {
        let chunk = RemoteOutputTuning.capIncomingFrame(data)
        guard !chunk.isEmpty else { return }

        appendReplayChunk(chunk, to: tabID)

        if let playback = playbacks[tabID] {
            playback.inject(chunk)
            if tabID == activeTabID {
                scheduleRefreshActiveState()
            }
            return
        }

        pendingReplayByTabID[tabID, default: []].append(chunk)
        guard tabID == activeTabID else { return }
        ensurePlayback(for: tabID, forceRebuild: false)
        refreshActiveState()
    }

    func scrollActive(to displayOffset: Int) {
        guard activeTabID != 0,
              let playback = playbacks[activeTabID],
              let state = renderState else { return }
        playback.scrollTo(displayOffset: displayOffset, scrollbackRows: state.scrollbackRows)
        refreshActiveState()
    }

    private func ensurePlayback(for tabID: UInt32, forceRebuild: Bool) {
        guard tabID != 0, viewportCols > 0, viewportRows > 0 else { return }

        if forceRebuild {
            playbacks[tabID] = nil
        }

        if let playback = playbacks[tabID] {
            playback.resize(cols: viewportCols, rows: viewportRows)
            return
        }

        let initialReplay = replayByTabID[tabID] ?? Data()
        let pendingChunks = pendingReplayByTabID[tabID] ?? []
        guard !initialReplay.isEmpty || !pendingChunks.isEmpty else { return }

        guard let playback = RemoteRustTerminalPlayback(cols: viewportCols, rows: viewportRows) else {
            isAvailable = false
            renderState = nil
            return
        }

        isAvailable = true
        if !initialReplay.isEmpty {
            playback.inject(initialReplay)
        }
        for chunk in pendingChunks {
            playback.inject(chunk)
        }
        pendingReplayByTabID.removeValue(forKey: tabID)
        playbacks[tabID] = playback
    }

    private func refreshActiveState() {
        guard activeTabID != 0 else {
            renderState = nil
            return
        }
        ensurePlayback(for: activeTabID, forceRebuild: false)
        renderState = preferredRenderState(for: activeTabID)
    }

    private func scheduleRefreshActiveState() {
        guard refreshTask == nil else { return }
        refreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: RemoteOutputTuning.flushInterval)
            guard let self, !Task.isCancelled else { return }
            self.refreshTask = nil
            self.refreshActiveState()
        }
    }

    private func preferredRenderState(for tabID: UInt32) -> RemoteTerminalRenderState? {
        if let playbackSnapshot = playbacks[tabID]?.snapshot() {
            return playbackSnapshot
        }
        if let directSnapshot = gridSnapshotByTabID[tabID],
           directSnapshot.cols == viewportCols,
           directSnapshot.rows == viewportRows {
            return directSnapshot
        }
        return nil
    }

    private func appendReplayChunk(_ chunk: Data, to tabID: UInt32) {
        if var replay = replayByTabID[tabID] {
            replay.append(chunk)
            if replay.count > Self.maxReplayBytesPerTab {
                replay.removeFirst(replay.count - Self.maxReplayBytesPerTab)
            }
            replayByTabID[tabID] = replay
        } else if chunk.count > Self.maxReplayBytesPerTab {
            replayByTabID[tabID] = Data(chunk.suffix(Self.maxReplayBytesPerTab))
        } else {
            replayByTabID[tabID] = chunk
        }
    }
}
