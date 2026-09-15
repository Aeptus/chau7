// Owns the iPhone's remote Rust terminal pipeline.
//
// Stateful Rust handles live exclusively inside `RemoteTerminalRenderEngine`,
// whose actor serialization preserves PTY byte order off the main actor. The
// observable store publishes an immutable grid no more than once per display
// refresh, keeping SwiftUI out of the byte-ingestion critical path.
import Chau7Core
import Foundation
import Observation
import UIKit

private struct RemoteTerminalEngineSnapshot: Sendable {
    let state: RemoteTerminalRenderState?
    let isAvailable: Bool
    let frameTrace: RemoteTerminalFrameTrace?
}

private actor RemoteTerminalRenderEngine {
    private static let maxReplayBytesPerTab = 400_000

    private var playbacks: [UInt32: RemoteRustTerminalPlayback] = [:]
    private var replayByTabID: [UInt32: Data] = [:]
    private var viewportCols = 0
    private var viewportRows = 0
    private var colorScheme: TerminalColorScheme
    private var isAvailable = true
    private var unpresentedTraceByTabID: [UInt32: RemoteTerminalFrameTrace] = [:]

    init(colorScheme: TerminalColorScheme) {
        self.colorScheme = colorScheme
    }

    func reset(colorScheme: TerminalColorScheme) {
        playbacks.removeAll()
        replayByTabID.removeAll()
        viewportCols = 0
        viewportRows = 0
        self.colorScheme = colorScheme
        isAvailable = true
        unpresentedTraceByTabID.removeAll()
    }

    func retainVisibleTabs(_ visibleTabIDs: Set<UInt32>) {
        playbacks = playbacks.filter { visibleTabIDs.contains($0.key) }
        replayByTabID = replayByTabID.filter { visibleTabIDs.contains($0.key) }
        unpresentedTraceByTabID = unpresentedTraceByTabID.filter { visibleTabIDs.contains($0.key) }
    }

    func applyColorScheme(_ scheme: TerminalColorScheme) {
        colorScheme = scheme
        for playback in playbacks.values {
            playback.applyColorScheme(scheme)
        }
    }

    func setViewport(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        guard cols != viewportCols || rows != viewportRows else { return }
        viewportCols = cols
        viewportRows = rows
        for playback in playbacks.values {
            playback.resize(cols: cols, rows: rows)
        }
    }

    func replaceSnapshot(_ data: Data, for tabID: UInt32) {
        replayByTabID[tabID] = Self.boundedReplay(data)
        playbacks[tabID] = nil
    }

    func appendOutput(_ data: Data, for tabID: UInt32, trace: RemoteTerminalFrameTrace?) {
        let chunk = RemoteOutputTuning.capIncomingFrame(data)
        guard !chunk.isEmpty else { return }
        appendReplayChunk(chunk, to: tabID)
        playbacks[tabID]?.inject(chunk)
        if var trace {
            trace.engineAppliedAt = Date()
            unpresentedTraceByTabID[tabID] = trace
        }
    }

    func scroll(tabID: UInt32, to displayOffset: Int, scrollbackRows: Int) {
        guard let playback = ensurePlayback(for: tabID) else { return }
        playback.scrollTo(displayOffset: displayOffset, scrollbackRows: scrollbackRows)
    }

    func snapshot(for tabID: UInt32) -> RemoteTerminalEngineSnapshot {
        let frameTrace = unpresentedTraceByTabID.removeValue(forKey: tabID)
        guard tabID != 0 else {
            return RemoteTerminalEngineSnapshot(
                state: nil,
                isAvailable: isAvailable,
                frameTrace: frameTrace
            )
        }
        return RemoteTerminalEngineSnapshot(
            state: ensurePlayback(for: tabID)?.snapshot(),
            isAvailable: isAvailable,
            frameTrace: frameTrace
        )
    }

    private func ensurePlayback(for tabID: UInt32) -> RemoteRustTerminalPlayback? {
        guard viewportCols > 0, viewportRows > 0 else { return nil }
        if let playback = playbacks[tabID] {
            return playback
        }
        guard let replay = replayByTabID[tabID], !replay.isEmpty else { return nil }
        guard let playback = RemoteRustTerminalPlayback(
            cols: viewportCols,
            rows: viewportRows,
            colorScheme: colorScheme
        ) else {
            isAvailable = false
            return nil
        }
        playback.inject(replay)
        playbacks[tabID] = playback
        isAvailable = true
        return playback
    }

    private func appendReplayChunk(_ chunk: Data, to tabID: UInt32) {
        if var replay = replayByTabID[tabID] {
            replay.append(chunk)
            replayByTabID[tabID] = Self.boundedReplay(replay)
        } else {
            replayByTabID[tabID] = Self.boundedReplay(chunk)
        }
    }

    private static func boundedReplay(_ data: Data) -> Data {
        data.count > maxReplayBytesPerTab
            ? Data(data.suffix(maxReplayBytesPerTab))
            : data
    }
}

@MainActor
private final class RemoteDisplayLinkPacer: NSObject {
    private var displayLink: CADisplayLink?
    var onFrame: (() -> Void)?

    func requestFrame() {
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
            link.add(to: .main, forMode: .common)
            link.isPaused = true
            displayLink = link
        }
        displayLink?.isPaused = false
    }

    @objc private func displayLinkFired() {
        displayLink?.isPaused = true
        onFrame?()
    }

    deinit {
        displayLink?.invalidate()
    }
}

@MainActor
@Observable
final class RemoteTerminalRendererStore {
    private(set) var renderState: RemoteTerminalRenderState?
    private(set) var activeTabID: UInt32 = 0
    private(set) var isAvailable = true
    private(set) var colorScheme: TerminalColorScheme = AppSettings.currentColorScheme

    @ObservationIgnored private let engine: RemoteTerminalRenderEngine
    @ObservationIgnored private var gridSnapshotByTabID: [UInt32: RemoteTerminalRenderState] = [:]
    @ObservationIgnored private var mutationTail: Task<Void, Never>?
    @ObservationIgnored private var renderRequestInFlight = false
    @ObservationIgnored private var renderDirty = false
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var activeTabChangedAt = Date.distantPast
    @ObservationIgnored private(set) var publishedTrace: RemoteTerminalFrameTrace?
    @ObservationIgnored private lazy var displayPacer: RemoteDisplayLinkPacer = {
        let pacer = RemoteDisplayLinkPacer()
        pacer.onFrame = { [weak self] in
            self?.publishAtDisplayRefresh()
        }
        return pacer
    }()

    @ObservationIgnored private var pendingPresentationTrace: RemoteTerminalFrameTrace?
    @ObservationIgnored private lazy var presentationPacer: RemoteDisplayLinkPacer = {
        let pacer = RemoteDisplayLinkPacer()
        pacer.onFrame = { [weak self] in
            self?.acknowledgeNextVSync()
        }
        return pacer
    }()

    @ObservationIgnored var onFramePublished: ((Double) -> Void)?
    @ObservationIgnored var onFramePresented: ((RemoteTerminalFrameTrace) -> Void)?

    init() {
        let scheme = AppSettings.currentColorScheme
        colorScheme = scheme
        engine = RemoteTerminalRenderEngine(colorScheme: scheme)
    }

    func reset() {
        generation &+= 1
        let currentGeneration = generation
        let predecessor = mutationTail
        let scheme = colorScheme
        mutationTail = Task { @MainActor [weak self, engine] in
            _ = await predecessor?.result
            await engine.reset(colorScheme: scheme)
            guard let self, self.generation == currentGeneration else { return }
            self.markRenderDirty()
        }
        gridSnapshotByTabID.removeAll()
        renderState = nil
        publishedTrace = nil
        pendingPresentationTrace = nil
        activeTabID = 0
        activeTabChangedAt = Date()
        isAvailable = true
        renderDirty = false
        renderRequestInFlight = false
    }

    func retainVisibleTabs(_ visibleTabIDs: Set<UInt32>) {
        gridSnapshotByTabID = gridSnapshotByTabID.filter { visibleTabIDs.contains($0.key) }
        enqueueMutation(publishFor: nil) { engine in
            await engine.retainVisibleTabs(visibleTabIDs)
        }
        if !visibleTabIDs.contains(activeTabID) {
            activeTabID = 0
            activeTabChangedAt = Date()
            renderState = nil
            publishedTrace = nil
        }
    }

    func applyColorScheme(_ scheme: TerminalColorScheme) {
        guard scheme.signature != colorScheme.signature else { return }
        colorScheme = scheme
        enqueueMutation(publishFor: activeTabID) { engine in
            await engine.applyColorScheme(scheme)
        }
    }

    func setViewport(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        enqueueMutation(publishFor: activeTabID) { engine in
            await engine.setViewport(cols: cols, rows: rows)
        }
    }

    func setActiveTab(_ tabID: UInt32) {
        if tabID != activeTabID {
            activeTabChangedAt = Date()
        }
        activeTabID = tabID
        publishedTrace = nil
        markRenderDirty()
    }

    /// Initial and recovery snapshots are keyframes. Incremental PTY bytes
    /// mutate the same actor-owned playback afterward.
    func replaceSnapshot(_ data: Data, for tabID: UInt32) {
        enqueueMutation(publishFor: tabID) { engine in
            await engine.replaceSnapshot(data, for: tabID)
        }
    }

    func replaceGridSnapshot(_ state: RemoteTerminalRenderState, for tabID: UInt32) {
        gridSnapshotByTabID[tabID] = state
        if tabID == activeTabID {
            markRenderDirty()
        }
    }

    func appendOutput(_ data: Data, for tabID: UInt32, trace: RemoteTerminalFrameTrace? = nil) {
        guard !data.isEmpty else { return }
        let visibleTrace = tabID == activeTabID ? trace : nil
        enqueueMutation(publishFor: tabID) { engine in
            await engine.appendOutput(data, for: tabID, trace: visibleTrace)
        }
    }

    /// Called after Core Graphics has rasterized the exact published frame.
    /// The following display-link callback is the nearest public proxy for the
    /// compositor presenting that rasterized frame on screen.
    func recordCanvasDrawn(_ trace: RemoteTerminalFrameTrace) {
        pendingPresentationTrace = trace
        presentationPacer.requestFrame()
    }

    func scrollActive(to displayOffset: Int) {
        guard activeTabID != 0, let state = renderState else { return }
        let tabID = activeTabID
        enqueueMutation(publishFor: tabID) { engine in
            await engine.scroll(tabID: tabID, to: displayOffset, scrollbackRows: state.scrollbackRows)
        }
    }

    private func enqueueMutation(
        publishFor tabID: UInt32?,
        _ operation: @escaping @Sendable (RemoteTerminalRenderEngine) async -> Void
    ) {
        let currentGeneration = generation
        let predecessor = mutationTail
        mutationTail = Task { @MainActor [weak self, engine] in
            _ = await predecessor?.result
            guard let self, self.generation == currentGeneration, !Task.isCancelled else { return }
            await operation(engine)
            guard self.generation == currentGeneration else { return }
            if tabID == nil || tabID == self.activeTabID {
                self.markRenderDirty()
            }
        }
    }

    private func markRenderDirty() {
        renderDirty = true
        displayPacer.requestFrame()
    }

    private func publishAtDisplayRefresh() {
        guard renderDirty, !renderRequestInFlight else { return }
        renderDirty = false
        renderRequestInFlight = true
        let tabID = activeTabID
        let currentGeneration = generation
        let predecessor = mutationTail
        let startedAt = ContinuousClock.now

        Task { @MainActor [weak self, engine] in
            _ = await predecessor?.result
            let snapshot = await engine.snapshot(for: tabID)
            guard let self, self.generation == currentGeneration else { return }
            self.renderRequestInFlight = false
            self.isAvailable = snapshot.isAvailable
            if tabID == self.activeTabID {
                if var frameTrace = snapshot.frameTrace,
                   frameTrace.iosAppliedAt >= self.activeTabChangedAt
                {
                    frameTrace.statePublishedAt = Date()
                    self.publishedTrace = frameTrace
                } else {
                    self.publishedTrace = nil
                }
                self.renderState = snapshot.state ?? self.gridSnapshotByTabID[tabID]
            }
            let elapsed = startedAt.duration(to: .now)
            let milliseconds = Double(elapsed.components.seconds) * 1000
                + Double(elapsed.components.attoseconds) / 1_000_000_000_000_000
            self.onFramePublished?(milliseconds)
            if self.renderDirty {
                self.displayPacer.requestFrame()
            }
        }
    }

    private func acknowledgeNextVSync() {
        guard var trace = pendingPresentationTrace else { return }
        pendingPresentationTrace = nil
        trace.nextVSyncAt = Date()
        onFramePresented?(trace)
    }
}
