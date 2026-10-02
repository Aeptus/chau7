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
    /// Rows already folded to the phone's width by the engine, when a fold is
    /// actually needed. nil means "paint the grid as-is" (1:1) or that the engine
    /// could not fold, in which case the canvas falls back to folding in Swift.
    let display: RemoteTerminalDisplayState?
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
    /// Source (Mac PTY) dimensions per tab. Normal output ingests at source
    /// width and folds for display; alternate-screen TUIs use both dimensions
    /// exactly and pan the canvas at 1:1.
    private var sourceColsByTabID: [UInt32: Int] = [:]
    private var sourceRowsByTabID: [UInt32: Int] = [:]
    private var alternateScreenByTabID: [UInt32: Bool] = [:]
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
        sourceRowsByTabID.removeAll()
        alternateScreenByTabID.removeAll()
        self.colorScheme = colorScheme
        isAvailable = true
        unpresentedTraceByTabID.removeAll()
    }

    func retainVisibleTabs(_ visibleTabIDs: Set<UInt32>) {
        playbacks = playbacks.filter { visibleTabIDs.contains($0.key) }
        replayByTabID = replayByTabID.filter { visibleTabIDs.contains($0.key) }
        sourceColsByTabID = sourceColsByTabID.filter { visibleTabIDs.contains($0.key) }
        sourceRowsByTabID = sourceRowsByTabID.filter { visibleTabIDs.contains($0.key) }
        alternateScreenByTabID = alternateScreenByTabID.filter { visibleTabIDs.contains($0.key) }
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

    /// Records the Mac's PTY dimensions and presentation mode for a tab.
    func setTerminalSize(cols: Int, rows: Int, alternateScreenActive: Bool, for tabID: UInt32) {
        let sanitizedCols = max(0, cols)
        let sanitizedRows = max(0, rows)
        let modeChanged = alternateScreenByTabID[tabID] != alternateScreenActive
        guard sanitizedCols != sourceColsByTabID[tabID]
                || sanitizedRows != sourceRowsByTabID[tabID]
                || modeChanged else { return }
        sourceColsByTabID[tabID] = sanitizedCols
        sourceRowsByTabID[tabID] = sanitizedRows
        alternateScreenByTabID[tabID] = alternateScreenActive
        resizeEngines()
    }

    /// Normal output uses the source width and phone-driven height. Alternate
    /// screen TUIs use the exact source grid so cursor-positioned rows stay put.
    private func resizeEngines() {
        guard viewportCols > 0, viewportRows > 0 else { return }
        for (tabID, playback) in playbacks {
            let size = engineSize(for: tabID)
            playback.resize(cols: size.cols, rows: size.rows)
        }
    }

    private func engineSize(for tabID: UInt32) -> (cols: Int, rows: Int) {
        if alternateScreenByTabID[tabID] == true,
           let cols = sourceColsByTabID[tabID], cols > 0,
           let rows = sourceRowsByTabID[tabID], rows > 0 {
            return (cols, rows)
        }
        return RemoteTerminalWrapGeometry.engineSize(
            sourceCols: sourceColsByTabID[tabID] ?? 0,
            displayCols: viewportCols,
            displayRows: viewportRows
        )
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
                display: nil,
                isAvailable: isAvailable,
                frameTrace: frameTrace
            )
        }
        let playback = ensurePlayback(for: tabID)
        // Fold in the engine whenever it is wider than the phone, so the canvas
        // paints rows that are already the right width. `viewportCols` is the
        // phone's own width (the engine is sized to max(source, display)), which
        // makes it exactly the fold target.
        let display = playback.flatMap { playback in
            alternateScreenByTabID[tabID] != true
                && viewportCols > 0 && viewportCols < playback.cols
                ? playback.displayRows(displayCols: viewportCols)
                : nil
        }
        return RemoteTerminalEngineSnapshot(
            state: playback?.snapshot(),
            display: display,
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
        let size = engineSize(for: tabID)
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
    /// Engine-folded rows for the active tab, when a fold is needed.
    private(set) var displayState: RemoteTerminalDisplayState?
    private(set) var activeTabID: UInt32 = 0
    private(set) var isActiveAlternateScreen = false
    private(set) var isAvailable = true
    private(set) var colorScheme: TerminalColorScheme = AppSettings.currentColorScheme

    @ObservationIgnored private let engine: RemoteTerminalRenderEngine
    @ObservationIgnored private var gridSnapshotByTabID: [UInt32: RemoteTerminalRenderState] = [:]
    @ObservationIgnored private var alternateScreenByTabID: [UInt32: Bool] = [:]
    @ObservationIgnored private var mutationTail: Task<Void, Never>?
    @ObservationIgnored private var scrollRequests = RemoteTerminalScrollRequests()
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
        scrollRequests.discard()
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
        alternateScreenByTabID.removeAll()
        renderState = nil
        displayState = nil
        isActiveAlternateScreen = false
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
        alternateScreenByTabID = alternateScreenByTabID.filter { visibleTabIDs.contains($0.key) }
        enqueueMutation(publishFor: nil) { engine in
            await engine.retainVisibleTabs(visibleTabIDs)
        }
        if !visibleTabIDs.contains(activeTabID) {
            scrollRequests.discard()
            activeTabID = 0
            activeTabChangedAt = Date()
            renderState = nil
            publishedTrace = nil
            isActiveAlternateScreen = false
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

    /// Announces the Mac PTY grid and whether its alternate screen is active.
    /// Older hosts omit the mode; those sessions keep the existing reflow path.
    func setTerminalSize(cols: Int, rows: Int, alternateScreenActive: Bool?, for tabID: UInt32) {
        let isAlternate = alternateScreenActive ?? false
        if alternateScreenByTabID[tabID] != isAlternate {
            alternateScreenByTabID[tabID] = isAlternate
            // A grid from the previous mode must not be shown while waiting for
            // the first authoritative checkpoint in the newly entered TUI.
            gridSnapshotByTabID[tabID] = nil
            if tabID == activeTabID {
                isActiveAlternateScreen = isAlternate
            }
        }
        enqueueMutation(publishFor: tabID) { engine in
            await engine.setTerminalSize(
                cols: cols,
                rows: rows,
                alternateScreenActive: isAlternate,
                for: tabID
            )
        }
    }

    func setActiveTab(_ tabID: UInt32) {
        if tabID != activeTabID {
            scrollRequests.discard()
            activeTabChangedAt = Date()
        }
        activeTabID = tabID
        isActiveAlternateScreen = alternateScreenByTabID[tabID] ?? false
        publishedTrace = nil
        markRenderDirty()
    }

    func isAlternateScreenActive(for tabID: UInt32) -> Bool {
        alternateScreenByTabID[tabID] ?? false
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

    /// Keep only the newest gesture destination until the next display refresh.
    /// Output stays ordered on the mutation chain; scroll callbacks cannot grow it.
    func scrollActive(toNormalized fraction: Double) {
        guard activeTabID != 0, renderState != nil else { return }
        scrollRequests.request(tabID: activeTabID, fraction: fraction)
        markRenderDirty()
    }

    private func enqueueMutation(
        publishFor tabID: UInt32?,
        publishAfterMutation: Bool = true,
        _ operation: @escaping @Sendable (RemoteTerminalRenderEngine) async -> Void
    ) {
        let currentGeneration = generation
        let predecessor = mutationTail
        mutationTail = Task { @MainActor [weak self, engine] in
            _ = await predecessor?.result
            guard let self, self.generation == currentGeneration, !Task.isCancelled else { return }
            await operation(engine)
            guard self.generation == currentGeneration else { return }
            if publishAfterMutation && (tabID == nil || tabID == self.activeTabID) {
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
        if let request = scrollRequests.take(for: activeTabID) {
            // This refresh already owns publication after the ordered mutation.
            enqueueMutation(publishFor: request.tabID, publishAfterMutation: false) { engine in
                await engine.scrollNormalized(tabID: request.tabID, fraction: request.fraction)
            }
        }
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
                let gridSnapshot = self.gridSnapshotByTabID[tabID]
                self.renderState = self.isActiveAlternateScreen
                    ? (gridSnapshot ?? snapshot.state)
                    : (snapshot.state ?? gridSnapshot)
                // A nil display state means the grid is already phone-width, or
                // the engine could not fold; the canvas then paints the grid
                // directly rather than falling back to its own fold.
                self.displayState = self.isActiveAlternateScreen ? nil : snapshot.display
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
