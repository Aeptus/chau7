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
    /// How far below the cap a replay buffer is trimmed when it overflows, so
    /// the (unavoidable) copy is amortised instead of running every frame.
    private static let replayTrimHeadroomBytes = 100_000

    private var playbacks: [UInt32: RemoteRustTerminalPlayback] = [:]
    private var replayByTabID: [UInt32: Data] = [:]
    private var viewportCols = 0
    private var viewportRows = 0
    /// Source (Mac PTY) width per tab, announced in the tab inventory. The
    /// engine ingests at this width so the TUI is not hard-wrapped at the
    /// phone's narrower viewport; the canvas re-wraps it for display.
    private var sourceColsByTabID: [UInt32: Int] = [:]
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
        sourceColsByTabID.removeAll()
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
        resizeEngines()
    }

    /// Records the Mac's PTY width for a tab and resizes that tab's engine to
    /// ingest at it. Called when the tab inventory arrives or its width changes.
    func setSourceColumns(_ cols: Int, for tabID: UInt32) {
        let sanitized = max(0, cols)
        guard sanitized != sourceColsByTabID[tabID] else { return }
        sourceColsByTabID[tabID] = sanitized
        resizeEngines()
    }

    /// Engine width is the source width when known, never the phone width —
    /// ingesting wide TUI output into a narrow engine is what hard-wrapped and
    /// scrambled it. Rows stay phone-driven so the visible screen height and the
    /// scroll math keep matching the display.
    private func resizeEngines() {
        guard viewportCols > 0, viewportRows > 0 else { return }
        for (tabID, playback) in playbacks {
            let size = RemoteTerminalWrapGeometry.engineSize(
                sourceCols: sourceColsByTabID[tabID] ?? 0,
                displayCols: viewportCols,
                displayRows: viewportRows
            )
            playback.resize(cols: size.cols, rows: size.rows)
        }
    }

    func replaceSnapshot(_ data: Data, for tabID: UInt32) {
        replayByTabID[tabID] = Self.boundedReplay(data)
        playbacks[tabID] = nil
    }

    func appendOutput(_ data: Data, for tabID: UInt32, trace: RemoteTerminalFrameTrace?) {
        let chunk = RemoteOutputTuning.capIncomingFrame(data)
        guard !chunk.isEmpty else { return }
        // Only buffer a replay while there is no live playback to inject into.
        // `ensurePlayback` is the only reader and short-circuits on a live
        // playback, so appending while one exists was pure write amplification:
        // once the buffer hit the cap, every single output frame re-copied all
        // 400 KB (COW append + a full `Data.suffix` re-slice) for a buffer
        // nothing would ever read.
        if playbacks[tabID] == nil {
            appendReplayChunk(chunk, to: tabID)
        }
        playbacks[tabID]?.inject(chunk)
        if var trace {
            trace.engineAppliedAt = Date()
            unpresentedTraceByTabID[tabID] = trace
        }
    }

    func scrollNormalized(tabID: UInt32, fraction: Double) {
        guard let playback = ensurePlayback(for: tabID) else { return }
        playback.scrollToNormalized(fraction)
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
        let size = RemoteTerminalWrapGeometry.engineSize(
            sourceCols: sourceColsByTabID[tabID] ?? 0,
            displayCols: viewportCols,
            displayRows: viewportRows
        )
        guard let playback = RemoteRustTerminalPlayback(
            cols: size.cols,
            rows: size.rows,
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
        // Mutate in place through the subscript. `if var replay = …; replay.append(…)
        // replayByTabID[tabID] = …` holds a second reference to the buffer, so the
        // append copies the whole thing, and the re-slice below copies it again.
        replayByTabID[tabID, default: Data()].append(chunk)
        guard let replay = replayByTabID[tabID], replay.count > Self.maxReplayBytesPerTab else { return }
        // Trim to a low watermark instead of exactly to the cap, so the copy is
        // amortised over many frames instead of running on every frame once the
        // buffer is full.
        let keep = Self.maxReplayBytesPerTab - Self.replayTrimHeadroomBytes
        var tail = Data(replay.suffix(keep))
        // Resync to a UTF-8 scalar boundary so the replay cannot start with a
        // replacement character after a mid-sequence cut.
        while let first = tail.first, first & 0xC0 == 0x80 {
            tail = tail.dropFirst()
        }
        replayByTabID[tabID] = tail
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
        // A remote inventory may temporarily adopt the Mac's custom palette.
        // Disconnecting must return to the iPhone preference so a later
        // connection (or the text fallback) never inherits stale remote state.
        let scheme = AppSettings.currentColorScheme
        colorScheme = scheme
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

    /// Announces the Mac PTY width for a tab so its engine ingests at that
    /// width. Pass 0 when the inventory carries none (older Macs), which falls
    /// the engine back to sizing to the phone viewport.
    func setSourceColumns(_ cols: Int, for tabID: UInt32) {
        enqueueMutation(publishFor: tabID) { engine in
            await engine.setSourceColumns(cols, for: tabID)
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

    /// Scrolls the active tab to a *fraction* of its scrollback.
    ///
    /// The fraction is computed by `RemoteTerminalScrollPolicy.displayOffset`
    /// from the same numbers the scroll view used, and applied against the
    /// engine's live `history_size` when the mutation actually runs. Passing an
    /// absolute row count captured from the last published `renderState` was
    /// wrong: the captured struct was also a value copy held across an `await`,
    /// so by the time the mutation ran the Rust history had already grown and
    /// the viewport landed further back than the user asked for — by an error
    /// that grew the longer the session ran.
    func scrollActive(toNormalized fraction: Double) {
        guard activeTabID != 0, renderState != nil else { return }
        let tabID = activeTabID
        let clamped = min(max(fraction, 0), 1)
        enqueueMutation(publishFor: tabID) { engine in
            await engine.scrollNormalized(tabID: tabID, fraction: clamped)
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
