import Compression
import Foundation
import Chau7Core

/// Manages per-tab scrollback memory by resizing the Rust ring buffer and
/// flushing/reloading scrollback to disk as tabs transition through
/// TabRenderPhases.
///
/// Memory model per phase:
///   .active/.passiveVisible/.warm → configured user scrollback in RAM
///   .hidden                       → flushed to disk, then viewport floor in RAM
///
/// On demotion to .hidden: capture the full buffer as ANSI text (CRLF + SGR,
/// safe to re-inject through the VTE parser), encode it into a verified cache
/// payload at ~/Library/Application Support/Chau7/ScrollbackCache/<tabID>.gz,
/// then set scrollback size to a viewport floor to free most of the ring
/// buffer.
///
/// On promotion from .hidden: set scrollback size to the configured user cap,
/// read the disk file, decompress, and replay through the Rust terminal via the
/// replay_buffer FFI. Whether a reload happens is decided by the flush-time
/// record for the tab, never by the promotion-time TUI flag (see
/// `handlePhaseTransition`).
final class ScrollbackMemoryManager {
    typealias CacheWriter = (Data, URL) throws -> Void

    static let shared = ScrollbackMemoryManager()

    /// Hard floor so `.hidden` tabs keep enough ring capacity to preserve the
    /// visible grid while freeing the bulk of scrollback after a disk flush.
    private static let viewportFloor = ScrollbackRetentionPolicy.defaultHiddenViewportFloor

    private let ioQueue = DispatchQueue(
        label: "com.chau7.scrollback-memory",
        qos: .utility,
        attributes: [.concurrent]
    )
    /// Per-tab queues preserve tab-local ordering; targeting this shared serial
    /// queue also prevents simultaneous full-buffer captures and compression
    /// across many tabs from multiplying peak memory and disk pressure.
    private let operationTargetQueue = DispatchQueue(
        label: "com.chau7.scrollback-memory.operations",
        qos: .utility
    )

    private let stateLock = NSLock()
    private var perTabQueues: [UUID: DispatchQueue] = [:]
    /// Tabs whose scrollback ring was flushed to disk + shrunk, keyed by what
    /// actually happened at flush time. Reload decisions consult this record —
    /// never the promotion-time TUI flag, which can flip between demotion and
    /// promotion (agents start and stop) and would otherwise either replay into
    /// a live TUI or strand a shrunk ring with an orphaned cache. Guarded by
    /// `stateLock`.
    private var flushState: [UUID: ScrollbackFlushRecord] = [:]
    private let cacheDirectoryURL: URL
    private let cacheWriter: CacheWriter

    init(
        cacheDirectory: URL = ScrollbackMemoryManager.defaultCacheDirectory(),
        cacheWriter: @escaping CacheWriter = ScrollbackMemoryManager.writeCachePayloadDurably
    ) {
        self.cacheDirectoryURL = cacheDirectory
        self.cacheWriter = cacheWriter
        ensureCacheDirectoryExists()
    }

    // MARK: - Public API

    func linesCap(for phase: TabRenderPhase) -> Int {
        linesCap(for: phase, configuredScrollbackLines: FeatureSettings.shared.scrollbackLines)
    }

    func linesCap(for phase: TabRenderPhase, configuredScrollbackLines: Int) -> Int {
        ScrollbackRetentionPolicy.ringCapacity(
            for: phase,
            configuredLines: configuredScrollbackLines,
            hiddenViewportFloor: Self.viewportFloor
        )
    }

    /// Apply a user-configured scrollback setting while respecting the tab's
    /// current render phase. This keeps settings updates from bypassing hidden
    /// tab reclamation or racing phase transitions on a different queue.
    func applyConfiguredScrollbackLines(
        viewId: String,
        tabID: UUID?,
        rustFFI: (any ScrollbackMemoryRustFFI)?,
        phase: TabRenderPhase,
        configuredScrollbackLines: Int
    ) {
        guard let rustFFI else { return }

        let cap = linesCap(for: phase, configuredScrollbackLines: configuredScrollbackLines)
        let apply = {
            rustFFI.setScrollbackSize(UInt32(cap))
            Log.trace("ScrollbackMemoryManager[\(viewId)]: applied configured scrollback cap=\(cap) phase=\(phase)")
        }

        guard let tabID else {
            Log.warn("ScrollbackMemoryManager[\(viewId)]: applying scrollback without tabID; using unsynchronized phase cap")
            apply()
            return
        }

        perTabQueue(for: tabID).async(execute: apply)
    }

    /// Entry point called from RustTerminalView.applyRenderPhase.
    /// Schedules flush/reload/cap-change on a per-tab serial queue so
    /// transitions for the same tab never overlap.
    ///
    /// `hostsTUIApp` short-circuits the destructive flush path: `replayBuffer`
    /// issues `ESC[2J ESC[H` + repours the captured text, which destroys a
    /// running TUI's invariants (boxes/spinners/menus), and shrinking the ring
    /// discards history. So TUI tabs are never flushed, and a cache flushed
    /// earlier is never replayed while a TUI is live — it is kept on disk and
    /// restored on a later non-TUI promotion instead.
    func handlePhaseTransition(
        viewId: String,
        tabID: UUID?,
        rustFFI: (any ScrollbackMemoryRustFFI)?,
        from oldPhase: TabRenderPhase,
        to newPhase: TabRenderPhase,
        hostsTUIApp: Bool = false,
        currentBytesReceived: UInt64? = nil
    ) {
        guard oldPhase != newPhase else { return }
        guard let rustFFI, let tabID else { return }

        let newCap = linesCap(for: newPhase)

        let queue = perTabQueue(for: tabID)
        queue.async { [weak self] in
            guard let self else { return }
            if ScrollbackRetentionPolicy.shouldFlushToDisk(from: oldPhase, to: newPhase) {
                if hostsTUIApp {
                    Log.info("ScrollbackMemoryManager[\(viewId)]: preserving scrollback for TUI tab \(oldPhase) -> \(newPhase)")
                    return
                }
                if flushRecord(for: tabID) != nil {
                    rustFFI.setScrollbackSize(UInt32(Self.viewportFloor))
                    Log.info("ScrollbackMemoryManager[\(viewId)]: reused existing flush cache for hidden transition")
                    return
                }
                if flush(tabID: tabID, viewId: viewId, rustFFI: rustFFI) {
                    // Free the ring buffer only after the buffer has either
                    // been persisted and verified, or proven empty.
                    rustFFI.setScrollbackSize(UInt32(Self.viewportFloor))
                    setFlushRecord(
                        ScrollbackFlushRecord(
                            kind: .hiddenFlush,
                            contentKind: .ansi,
                            bytesReceivedAtFlush: currentBytesReceived,
                            flushedAt: Date()
                        ),
                        for: tabID
                    )
                } else {
                    Log.warn("ScrollbackMemoryManager[\(viewId)]: preserving in-memory scrollback because hidden flush did not complete")
                }
            } else if ScrollbackRetentionPolicy.shouldReloadFromDisk(from: oldPhase, to: newPhase) {
                let record = flushRecord(for: tabID)
                let hasCache = FileManager.default.fileExists(atPath: cacheURL(for: tabID).path)
                if record == nil, !hasCache {
                    // Nothing was ever flushed. A TUI tab's ring was never
                    // shrunk either, so leave it untouched (matches the
                    // demotion-side short-circuit).
                    if !hostsTUIApp {
                        rustFFI.setScrollbackSize(UInt32(newCap))
                    }
                    return
                }
                if hostsTUIApp {
                    // A flush happened earlier but a TUI is live now. Growing
                    // the ring is safe (no cell writes); replaying is not.
                    // Keep the cache + record so a later non-TUI promotion
                    // restores the history instead of losing it.
                    rustFFI.setScrollbackSize(UInt32(newCap))
                    Log.info("ScrollbackMemoryManager[\(viewId)]: deferred scrollback reload for live TUI (cache retained)")
                    return
                }
                clearFlushRecord(for: tabID)
                reload(
                    tabID: tabID,
                    viewId: viewId,
                    rustFFI: rustFFI,
                    newCap: newCap,
                    record: record,
                    currentBytesReceived: currentBytesReceived
                )
            } else {
                // Warm↔active style transitions: if an idle flush shrunk this
                // ring earlier, promotion to a live phase restores the history
                // from disk instead of just raising the empty cap.
                if newPhase.allowsLivePresentation, let record = flushRecord(for: tabID) {
                    if hostsTUIApp {
                        rustFFI.setScrollbackSize(UInt32(newCap))
                        Log.info("ScrollbackMemoryManager[\(viewId)]: deferred idle-flush reload for live TUI (cache retained)")
                    } else {
                        clearFlushRecord(for: tabID)
                        reload(
                            tabID: tabID,
                            viewId: viewId,
                            rustFFI: rustFFI,
                            newCap: newCap,
                            record: record,
                            currentBytesReceived: currentBytesReceived
                        )
                    }
                    return
                }
                rustFFI.setScrollbackSize(UInt32(newCap))
                Log.trace("ScrollbackMemoryManager[\(viewId)]: \(oldPhase) -> \(newPhase) cap=\(newCap)")
            }
        }
    }

    // MARK: - Idle flush (phase-independent, opt-in)

    /// Flush a `.warm` (deselected) idle tab's scrollback ring to disk and shrink
    /// it to the viewport floor — WITHOUT changing the tab's render phase. The
    /// view stays `.warm` and keeps rendering normally; only the history ring is
    /// freed. Reloaded on reselection by `idleReloadIfNeeded`.
    ///
    /// Like the `.hidden` flush this captures *ANSI* (SGR preserved), so the
    /// reloaded scrollback keeps its colors. TUI tabs are skipped entirely — the
    /// caller must pass `hostsTUIApp` for any alternate-screen / AI-TUI session;
    /// flattening + repouring a live TUI surface would corrupt it.
    func idleFlush(
        viewId: String,
        tabID: UUID,
        rustFFI: any ScrollbackMemoryRustFFI,
        hostsTUIApp: Bool,
        bytesReceivedAtFlush: UInt64? = nil
    ) {
        guard !hostsTUIApp else {
            Log.trace("ScrollbackMemoryManager[\(viewId)]: idleFlush skipped (TUI tab)")
            return
        }
        let queue = perTabQueue(for: tabID)
        queue.async { [weak self] in
            guard let self else { return }
            guard flushRecord(for: tabID) == nil else {
                Log.trace("ScrollbackMemoryManager[\(viewId)]: idleFlush coalesced (already flushed)")
                return
            }
            let text = TerminalWorkProfiler.shared.measure(
                .fullBufferCapture,
                context: TerminalWorkContext(
                    renderPhase: TabRenderPhase.warm.rawValue,
                    visibility: "drainOnly",
                    caller: "idleScrollbackFlush"
                ),
                bytes: { $0?.utf8.count ?? 0 }
            ) {
                rustFFI.captureFullBufferAnsiText()
            }
            guard let text else {
                Log.warn("ScrollbackMemoryManager[\(viewId)]: idleFlush - no buffer captured")
                return
            }
            guard persist(text: text, contentKind: .ansi, tabID: tabID, viewId: viewId) else {
                Log.warn("ScrollbackMemoryManager[\(viewId)]: idleFlush - persist failed; ring untouched")
                return
            }
            rustFFI.setScrollbackSize(UInt32(Self.viewportFloor))
            setFlushRecord(
                ScrollbackFlushRecord(
                    kind: .idleFlush,
                    contentKind: .ansi,
                    bytesReceivedAtFlush: bytesReceivedAtFlush,
                    flushedAt: Date()
                ),
                for: tabID
            )
            Log.info("ScrollbackMemoryManager[\(viewId)]: idle-flushed tab \(tabID) (ring → floor \(Self.viewportFloor))")
        }
    }

    /// Restore an idle-flushed tab's scrollback on reselection: replay the cached
    /// ANSI buffer and grow the ring back to the configured capacity. No-op for
    /// tabs that weren't idle-flushed. Serialized on the same per-tab queue as
    /// `idleFlush` so a pending flush always completes first.
    func idleReloadIfNeeded(
        viewId: String,
        tabID: UUID,
        rustFFI: any ScrollbackMemoryRustFFI,
        configuredLines: Int,
        currentBytesReceived: UInt64? = nil
    ) {
        let queue = perTabQueue(for: tabID)
        queue.async { [weak self] in
            guard let self else { return }
            guard let record = flushRecord(for: tabID) else { return }
            clearFlushRecord(for: tabID)
            reload(
                tabID: tabID,
                viewId: viewId,
                rustFFI: rustFFI,
                newCap: configuredLines,
                record: record,
                currentBytesReceived: currentBytesReceived
            )
        }
    }

    /// TUI warm-tab compaction: capture-if-safe, shrink-always, replay-never
    /// while protected. Zero writes to the live TUI by construction — both
    /// branches only read the grid or truncate history storage; the failure
    /// mode is "less scrollback", never "corrupted TUI".
    func tuiIdleCompact(
        viewId: String,
        tabID: UUID,
        rustFFI: any ScrollbackMemoryRustFFI,
        isOnAlternateScreen: Bool,
        bytesReceivedAtFlush: UInt64?,
        tierLines: Int = ScrollbackRetentionPolicy.tuiWarmTierLines
    ) {
        let queue = perTabQueue(for: tabID)
        queue.async { [weak self] in
            guard let self else { return }
            guard flushRecord(for: tabID) == nil else {
                Log.trace("ScrollbackMemoryManager[\(viewId)]: tuiCompact coalesced (already flushed)")
                return
            }
            if isOnAlternateScreen {
                // The primary grid (owner of all scrollback) is unreachable
                // for capture while the alt screen is active — text exports
                // read the active grid. Shrink-only: set_scrollback_size
                // targets the primary grid's history via the alt-screen-aware
                // Rust path; the visible TUI surface is untouched by
                // construction. History beyond the tier is discarded.
                rustFFI.setScrollbackSize(UInt32(tierLines))
                Log.info("ScrollbackMemoryManager[\(viewId)]: tuiCompact shrink-only (alt screen) → \(tierLines) lines; deeper history discarded")
                return
            }
            // Primary-screen TUI (e.g. Claude Code): the ANSI capture is a
            // read-only export — it cannot perturb the live surface. Persist,
            // then shrink. The record makes the full history replayable the
            // moment the session's TUI protection clears (agent exited), via
            // the normal promotion path.
            let text = TerminalWorkProfiler.shared.measure(
                .fullBufferCapture,
                context: TerminalWorkContext(
                    renderPhase: TabRenderPhase.warm.rawValue,
                    visibility: "drainOnly",
                    caller: "tuiIdleCompact"
                ),
                bytes: { $0?.utf8.count ?? 0 }
            ) {
                rustFFI.captureFullBufferAnsiText()
            }
            guard let text else {
                Log.warn("ScrollbackMemoryManager[\(viewId)]: tuiCompact - no buffer captured; ring untouched")
                return
            }
            guard persist(text: text, contentKind: .ansi, tabID: tabID, viewId: viewId) else {
                Log.warn("ScrollbackMemoryManager[\(viewId)]: tuiCompact - persist failed; ring untouched")
                return
            }
            rustFFI.setScrollbackSize(UInt32(tierLines))
            setFlushRecord(
                ScrollbackFlushRecord(
                    kind: .tuiCompact,
                    contentKind: .ansi,
                    bytesReceivedAtFlush: bytesReceivedAtFlush,
                    flushedAt: Date()
                ),
                for: tabID
            )
            Log.info("ScrollbackMemoryManager[\(viewId)]: tuiCompact persisted history and shrunk ring → \(tierLines) lines")
        }
    }

    /// Deletes cache files whose tab is not in the live/saved set — tabs
    /// closed while hidden (or lost to a crash) used to leave their `.gz`
    /// files behind forever. Call once at startup after restore resolves the
    /// surviving tab IDs.
    func sweepOrphanedCaches(keeping validTabIDs: Set<UUID>) {
        ioQueue.async { [cacheDirectoryURL] in
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: cacheDirectoryURL,
                includingPropertiesForKeys: nil
            ) else { return }
            var removed = 0
            for file in files where file.pathExtension == "gz" {
                let stem = file.deletingPathExtension().lastPathComponent
                guard let id = UUID(uuidString: stem), !validTabIDs.contains(id) else { continue }
                try? FileManager.default.removeItem(at: file)
                removed += 1
            }
            if removed > 0 {
                Log.info("ScrollbackMemoryManager: swept \(removed) orphaned cache file(s)")
            }
        }
    }

    /// Remove the on-disk cache for a tab (called when the tab is closed
    /// permanently so we don't leak cache files).
    func purgeCache(for tabID: UUID) {
        let url = cacheURL(for: tabID)
        ioQueue.async {
            try? FileManager.default.removeItem(at: url)
        }
        stateLock.lock()
        perTabQueues[tabID] = nil
        flushState[tabID] = nil
        budgetCandidates[tabID] = nil
        stateLock.unlock()
    }

    // MARK: - Scrollback budget backstop

    /// Warm tabs eligible for immediate idle flush when the aggregate ring
    /// estimate exceeds the budget. Registered by RustTerminalView on `.warm`,
    /// unregistered on any other phase. Guarded by `stateLock`.
    private var budgetCandidates: [UUID: ScrollbackBudgetFlushCandidate] = [:]

    func registerBudgetFlushCandidate(tabID: UUID, candidate: ScrollbackBudgetFlushCandidate) {
        stateLock.lock()
        budgetCandidates[tabID] = candidate
        stateLock.unlock()
    }

    func unregisterBudgetFlushCandidate(tabID: UUID) {
        stateLock.lock()
        budgetCandidates[tabID] = nil
        stateLock.unlock()
    }

    /// Piggybacks on MemoryPressureResponder's existing 30s footprint timer
    /// (no new wakeup source): when warm tabs' summed ring estimates exceed
    /// the budget, flush the largest ones immediately instead of waiting out
    /// their idle timers. This is what bounds aggregate scrollback memory
    /// deterministically rather than hoping the timers line up.
    func enforceScrollbackBudget(
        budgetBytes: Int = ScrollbackRetentionPolicy.scrollbackBudgetBytes(
            overrideMB: UserDefaults.standard.object(forKey: "terminal.scrollbackBudgetMB") as? Int
        ),
        perTabBudgetBytes: Int = ScrollbackRetentionPolicy.perTabScrollbackBudgetBytes(
            overrideMB: UserDefaults.standard.object(forKey: "terminal.perTabScrollbackBudgetMB") as? Int
        )
    ) {
        stateLock.lock()
        let candidates = budgetCandidates
        stateLock.unlock()
        guard !candidates.isEmpty else { return }

        let sized = candidates.map { (tabID: $0.key, candidate: $0.value, bytes: $0.value.estimatedRingBytes()) }
        var total = sized.reduce(0) { $0 + $1.bytes }
        var requested = Set<UUID>()

        // A single warm tab may otherwise consume most of the aggregate cap.
        // Its callback persists the complete ANSI buffer before shrinking, so
        // this limit is lossless and selected/live tabs remain protected.
        for entry in sized.sorted(by: { $0.bytes > $1.bytes })
            where TerminalMemoryBudgetPolicy.exceedsBudget(
                bytes: entry.bytes,
                budgetBytes: perTabBudgetBytes
            ) {
            entry.candidate.requestFlush()
            requested.insert(entry.tabID)
            total -= entry.bytes
        }

        guard total > budgetBytes else { return }

        Log.info("ScrollbackMemoryManager: scrollback budget exceeded (\(total / (1024 * 1024))MB > \(budgetBytes / (1024 * 1024))MB) — flushing largest warm tabs")
        for entry in sized.sorted(by: { $0.bytes > $1.bytes }) {
            guard total > budgetBytes else { break }
            guard !requested.contains(entry.tabID) else { continue }
            entry.candidate.requestFlush()
            total -= entry.bytes
        }
    }

    // MARK: - Flush records

    private func flushRecord(for tabID: UUID) -> ScrollbackFlushRecord? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return flushState[tabID]
    }

    private func setFlushRecord(_ record: ScrollbackFlushRecord, for tabID: UUID) {
        stateLock.lock()
        flushState[tabID] = record
        stateLock.unlock()
    }

    private func clearFlushRecord(for tabID: UUID) {
        stateLock.lock()
        flushState[tabID] = nil
        stateLock.unlock()
    }

    // MARK: - Flush (demote → .hidden)

    private func flush(tabID: UUID, viewId: String, rustFFI: any ScrollbackMemoryRustFFI) -> Bool {
        let text = TerminalWorkProfiler.shared.measure(
            .fullBufferCapture,
            context: TerminalWorkContext(
                renderPhase: TabRenderPhase.hidden.rawValue,
                visibility: "drainOnly",
                caller: "hiddenPhaseFlush"
            ),
            bytes: { $0?.utf8.count ?? 0 }
        ) {
            // ANSI capture, not plain text: this payload is re-injected through
            // the VTE parser on reload, where the plain capture's bare LFs
            // staircase every line and its missing SGR drops all colors.
            rustFFI.captureFullBufferAnsiText()
        }
        guard let text else {
            Log.warn("ScrollbackMemoryManager[\(viewId)]: flush - no buffer text captured")
            return false
        }
        return persist(text: text, contentKind: .ansi, tabID: tabID, viewId: viewId)
    }

    /// Encode → durably write → read back → verify a captured buffer into the
    /// tab's cache file. Shared by the `.hidden` flush and the idle flush.
    /// Returns true only once the bytes are persisted and verified (or the
    /// buffer was empty, in which case any stale cache is removed).
    ///
    /// Verification decodes the on-disk bytes against the size + CRC32 embedded
    /// in the payload — never a full byte comparison against the original, so
    /// the raw capture is not pinned across the verify step. This path runs on
    /// the reclamation side; its transient footprint matters.
    private func persist(
        text: String,
        contentKind: ScrollbackCacheContentKind,
        tabID: UUID,
        viewId: String
    ) -> Bool {
        let data = Data(text.utf8)
        let url = cacheURL(for: tabID)
        guard !data.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return true
        }

        let expectedCount = data.count
        let expectedCRC = CRC32.checksum(data)
        let payload = Self.encodedCachePayload(for: data, contentKind: contentKind, crc32: expectedCRC)
        do {
            try cacheWriter(payload, url)
            let persisted = try Data(contentsOf: url)
            guard let decoded = Self.decodedCachePayload(persisted),
                  decoded.data.count == expectedCount,
                  decoded.embeddedCRC32 == expectedCRC else {
                throw ScrollbackCacheError.verificationFailed
            }
            Log.info("ScrollbackMemoryManager[\(viewId)]: flushed \(expectedCount)B raw / \(payload.count)B cache to \(url.lastPathComponent)")
            return true
        } catch {
            let failureKind = if error is ScrollbackCacheError {
                ScrollbackCacheFailureKind.corruptData
            } else {
                ScrollbackCacheFailureClassifier.classify(error)
            }
            Log.warn(
                "ScrollbackMemoryManager[\(viewId)]: flush write failed class=\(failureKind.rawValue): \(error)"
            )
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    // MARK: - Reload (promote from .hidden)

    private func reload(
        tabID: UUID,
        viewId: String,
        rustFFI: any ScrollbackMemoryRustFFI,
        newCap: Int,
        record: ScrollbackFlushRecord? = nil,
        currentBytesReceived: UInt64? = nil
    ) {
        let effectiveCap = max(newCap, Self.viewportFloor)
        rustFFI.setScrollbackSize(UInt32(effectiveCap))

        let url = cacheURL(for: tabID)
        // Distinguish "no cache" (expected for never-flushed tabs) from a
        // failed read (scrollback silently lost on I/O error).
        guard FileManager.default.fileExists(atPath: url.path) else {
            Log.trace("ScrollbackMemoryManager[\(viewId)]: reload - no cache file")
            return
        }
        guard let compressed = try? Data(contentsOf: url) else {
            Log.warn("ScrollbackMemoryManager[\(viewId)]: reload - cache file exists but could not be read; scrollback lost for tab \(tabID)")
            return
        }

        guard let decoded = Self.decodedCachePayload(compressed) else {
            Log.warn("ScrollbackMemoryManager[\(viewId)]: reload - cache decode failed")
            try? FileManager.default.removeItem(at: url)
            return
        }

        var replayData = Self.replayData(for: decoded)
        // Post-flush-output seam: output that arrived after the flush lives
        // only in the shrunk in-memory ring, and `replayBuffer` clears that
        // ring. Capture it first and replay cache + reset + current so no
        // output is ever dropped. The cost is a small duplicated seam (the
        // ring was at the viewport floor) — cosmetic, and strictly better
        // than loss. Byte counters unavailable → assume output arrived.
        let outputArrivedAfterFlush: Bool
        if let flushedBytes = record?.bytesReceivedAtFlush, let currentBytesReceived {
            outputArrivedAfterFlush = currentBytesReceived != flushedBytes
        } else {
            outputArrivedAfterFlush = record?.bytesReceivedAtFlush != nil || currentBytesReceived != nil
        }
        if outputArrivedAfterFlush,
           let currentTail = rustFFI.captureFullBufferAnsiText(),
           !currentTail.isEmpty {
            replayData.append(Data("\u{1B}[0m".utf8))
            replayData.append(Data(currentTail.utf8))
        }
        // Responsiveness instrument: sustained >50ms replays here mean the
        // reload should move off the promotion path (defer-until-scroll).
        TerminalWorkProfiler.shared.measure(
            .replayBuffer,
            context: TerminalWorkContext(
                renderPhase: "reload",
                visibility: "background",
                caller: "scrollbackReload"
            ),
            bytes: { _ in replayData.count }
        ) {
            rustFFI.replayBuffer(replayData)
        }
        try? FileManager.default.removeItem(at: url)
        Log.info("ScrollbackMemoryManager[\(viewId)]: reloaded \(decoded.data.count)B from \(url.lastPathComponent)")
    }

    /// ANSI payloads are CRLF-correct at the source and replay verbatim. Legacy
    /// plain-text payloads carry bare LFs; injected without a PTY those keep the
    /// previous line's column and staircase every restored line, so they must be
    /// normalized first.
    static func replayData(for decoded: DecodedScrollbackCache) -> Data {
        switch decoded.contentKind {
        case .ansi:
            return decoded.data
        case .plainText:
            guard let text = String(data: decoded.data, encoding: .utf8) else {
                return decoded.data
            }
            return Data(RestoreScrollbackNormalizer.normalizeLineEndingsForParserInjection(text).utf8)
        }
    }

    // MARK: - Cache payload codec

    /// v2 payload layout, after the ASCII header line:
    ///   contentKind: UInt8, uncompressedSize: UInt64 LE, crc32: UInt32 LE,
    ///   then the (zlib or raw) stream. The embedded size makes decompression
    ///   exact-size instead of guess-and-grow — the v1 heuristic capped out at
    ///   40× expansion, and terminal scrollback routinely compresses 50-200×,
    ///   so precisely the biggest buffers always failed verification, lost
    ///   their cache, and kept their ring resident.
    private static let zlibCacheHeaderV2 = Data("CHAU7_SCROLLBACK_ZLIB_V2\n".utf8)
    private static let rawCacheHeaderV2 = Data("CHAU7_SCROLLBACK_RAW_V2\n".utf8)
    private static let zlibCacheHeaderV1 = Data("CHAU7_SCROLLBACK_ZLIB_V1\n".utf8)
    private static let rawCacheHeaderV1 = Data("CHAU7_SCROLLBACK_RAW_V1\n".utf8)
    private static let cacheMetaLength = 1 + 8 + 4
    /// Sanity ceiling for the embedded size and for legacy guess-and-grow
    /// decompression. A 100k-line ring stays far below this.
    private static let maxUncompressedCacheBytes = 512 * 1024 * 1024

    private enum ScrollbackCacheError: Error {
        case verificationFailed
    }

    static func encodedCachePayload(
        for data: Data,
        contentKind: ScrollbackCacheContentKind,
        crc32: UInt32
    ) -> Data {
        var meta = Data(capacity: cacheMetaLength)
        meta.append(contentKind.rawValue)
        appendUInt64LE(UInt64(data.count), to: &meta)
        appendUInt32LE(crc32, to: &meta)

        if let compressed = compress(data) {
            var payload = zlibCacheHeaderV2
            payload.append(meta)
            payload.append(compressed)
            return payload
        }

        var payload = rawCacheHeaderV2
        payload.append(meta)
        payload.append(data)
        return payload
    }

    static func decodedCachePayload(_ payload: Data) -> DecodedScrollbackCache? {
        if payload.starts(with: zlibCacheHeaderV2) {
            return decodeV2(payload.dropFirst(zlibCacheHeaderV2.count), compressed: true)
        }
        if payload.starts(with: rawCacheHeaderV2) {
            return decodeV2(payload.dropFirst(rawCacheHeaderV2.count), compressed: false)
        }
        // v1 and headerless payloads predate the embedded metadata and were all
        // written from the plain-text capture (bare LFs).
        if payload.starts(with: zlibCacheHeaderV1) {
            guard let data = legacyDecompress(Data(payload.dropFirst(zlibCacheHeaderV1.count))) else {
                return nil
            }
            return DecodedScrollbackCache(data: data, contentKind: .plainText, embeddedCRC32: nil)
        }
        if payload.starts(with: rawCacheHeaderV1) {
            return DecodedScrollbackCache(
                data: Data(payload.dropFirst(rawCacheHeaderV1.count)),
                contentKind: .plainText,
                embeddedCRC32: nil
            )
        }
        if let decompressed = legacyDecompress(payload) {
            return DecodedScrollbackCache(data: decompressed, contentKind: .plainText, embeddedCRC32: nil)
        }
        if String(data: payload, encoding: .utf8) != nil {
            return DecodedScrollbackCache(data: payload, contentKind: .plainText, embeddedCRC32: nil)
        }
        return nil
    }

    private static func decodeV2(_ body: Data, compressed: Bool) -> DecodedScrollbackCache? {
        guard body.count >= cacheMetaLength else { return nil }
        // `body` is a slice; its indices are inherited from the parent payload.
        let meta = Data(body.prefix(cacheMetaLength))
        guard let contentKind = ScrollbackCacheContentKind(rawValue: meta[0]) else { return nil }
        let size = readUInt64LE(meta, at: 1)
        let crc = readUInt32LE(meta, at: 9)
        guard size <= UInt64(maxUncompressedCacheBytes) else { return nil }
        let stream = Data(body.dropFirst(cacheMetaLength))

        let data: Data
        if compressed {
            guard let decompressed = decompress(stream, exactSize: Int(size)) else { return nil }
            data = decompressed
        } else {
            guard stream.count == Int(size) else { return nil }
            data = stream
        }
        guard CRC32.checksum(data) == crc else { return nil }
        return DecodedScrollbackCache(data: data, contentKind: contentKind, embeddedCRC32: crc)
    }

    private static func compress(_ data: Data) -> Data? {
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data in
            let srcBase = src.baseAddress!.assumingMemoryBound(to: UInt8.self)
            // Account for ZLIB worst-case expansion on incompressible data:
            // input + input/10 + 256 bytes of overhead.
            let dstCapacity = data.count + data.count / 10 + 256
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
            defer { dst.deallocate() }
            let written = compression_encode_buffer(
                dst, dstCapacity,
                srcBase, data.count,
                nil,
                COMPRESSION_ZLIB
            )
            if written == 0 {
                return Data()
            }
            return Data(bytes: dst, count: written)
        }
        .nilIfEmpty
    }

    /// Exact-size decompression for v2 payloads: allocate precisely the
    /// embedded uncompressed size, one pass, no growth heuristic.
    private static func decompress(_ data: Data, exactSize: Int) -> Data? {
        guard exactSize > 0 else { return nil }
        return data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: exactSize)
            defer { dst.deallocate() }
            let written = compression_decode_buffer(
                dst, exactSize,
                srcBase, data.count,
                nil,
                COMPRESSION_ZLIB
            )
            guard written == exactSize else { return nil }
            return Data(bytes: dst, count: written)
        }
    }

    /// Guess-and-grow decompression for v1/headerless payloads, which carry no
    /// size metadata. Grows until `maxUncompressedCacheBytes` instead of the
    /// old three-doublings cap so existing high-ratio caches stay restorable.
    private static func legacyDecompress(_ data: Data) -> Data? {
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            var dstCapacity = max(data.count * 10, 4096)
            while true {
                let dst = UnsafeMutablePointer<UInt8>.allocate(capacity: dstCapacity)
                defer { dst.deallocate() }
                let written = compression_decode_buffer(
                    dst, dstCapacity,
                    srcBase, data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
                if written > 0, written < dstCapacity {
                    return Data(bytes: dst, count: written)
                }
                guard dstCapacity < maxUncompressedCacheBytes else { return nil }
                dstCapacity = min(dstCapacity * 2, maxUncompressedCacheBytes)
            }
        }
    }

    // MARK: - Little-endian meta codec

    private static func appendUInt64LE(_ value: UInt64, to data: inout Data) {
        for shift in stride(from: 0, to: 64, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt64(shift)))
        }
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        for shift in stride(from: 0, to: 32, by: 8) {
            data.append(UInt8(truncatingIfNeeded: value >> UInt32(shift)))
        }
    }

    private static func readUInt64LE(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for i in 0 ..< 8 {
            value |= UInt64(data[offset + i]) << UInt64(i * 8)
        }
        return value
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0 ..< 4 {
            value |= UInt32(data[offset + i]) << UInt32(i * 8)
        }
        return value
    }

    // MARK: - Paths

    private func ensureCacheDirectoryExists() {
        try? FileManager.default.createDirectory(at: cacheDirectoryURL, withIntermediateDirectories: true)
    }

    private func cacheURL(for tabID: UUID) -> URL {
        cacheDirectoryURL.appendingPathComponent("\(tabID.uuidString).gz")
    }

    private static func defaultCacheDirectory() -> URL {
        RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("ScrollbackCache", isDirectory: true)
    }

    private static func writeCachePayloadDurably(_ payload: Data, to url: URL) throws {
        let fileManager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try payload.write(to: tempURL, options: .withoutOverwriting)
            let handle = try FileHandle(forWritingTo: tempURL)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }

            if fileManager.fileExists(atPath: url.path) {
                // Atomic swap — the old remove-then-move left a window where a
                // crash lost both the old and the new cache.
                _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
            } else {
                try fileManager.moveItem(at: tempURL, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: tempURL)
            throw error
        }
    }

    // MARK: - Per-tab queues

    private func perTabQueue(for tabID: UUID) -> DispatchQueue {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let existing = perTabQueues[tabID] {
            return existing
        }
        let queue = DispatchQueue(
            label: "com.chau7.scrollback-memory.tab.\(tabID.uuidString)",
            qos: .utility,
            target: operationTargetQueue
        )
        perTabQueues[tabID] = queue
        return queue
    }

    func drainPendingOperationsForTesting(tabID: UUID) {
        perTabQueue(for: tabID).sync {}
    }
}

/// A warm tab's hooks for the scrollback budget backstop. `estimatedRingBytes`
/// is an O(1) FFI stat (thread-safe); `requestFlush` triggers the tab's
/// immediate idle flush (hops to main internally).
struct ScrollbackBudgetFlushCandidate {
    let viewId: String
    let estimatedRingBytes: () -> Int
    let requestFlush: () -> Void
}

/// What a decoded cache file contains and how it may be replayed.
struct DecodedScrollbackCache {
    let data: Data
    let contentKind: ScrollbackCacheContentKind
    /// CRC32 carried by v2 payloads; nil for v1/headerless legacy caches.
    let embeddedCRC32: UInt32?
}

enum ScrollbackCacheContentKind: UInt8 {
    /// Plain row text with bare LFs (legacy captures) — must be CRLF-normalized
    /// before parser injection.
    case plainText = 0
    /// ANSI export: CRLF line endings + SGR, replayable verbatim.
    case ansi = 1
}

/// What actually happened at flush time, recorded so reload decisions follow
/// the flush-time facts rather than the promotion-time TUI flag.
struct ScrollbackFlushRecord {
    enum Kind {
        case hiddenFlush
        case idleFlush
        /// TUI warm-tab compaction: history persisted (when capture was safe)
        /// and the ring shrunk to the TUI tier — but NEVER replayed while the
        /// session stays protected; the promotion path defers until the
        /// agent exits.
        case tuiCompact
    }

    let kind: Kind
    let contentKind: ScrollbackCacheContentKind
    /// PTY byte counter at flush time; lets reload detect output that arrived
    /// after the flush. Populated once the proactive-reclamation path lands.
    var bytesReceivedAtFlush: UInt64?
    let flushedAt: Date

    init(
        kind: Kind,
        contentKind: ScrollbackCacheContentKind,
        bytesReceivedAtFlush: UInt64? = nil,
        flushedAt: Date
    ) {
        self.kind = kind
        self.contentKind = contentKind
        self.bytesReceivedAtFlush = bytesReceivedAtFlush
        self.flushedAt = flushedAt
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0 ..< 256).map { index -> UInt32 in
        var crc = UInt32(index)
        for _ in 0 ..< 8 {
            crc = (crc & 1) == 1 ? 0xEDB8_8320 ^ (crc >> 1) : crc >> 1
        }
        return crc
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            for byte in buffer {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    var nilIfEmpty: Data? {
        isEmpty ? nil : self
    }
}

/// Minimal protocol abstracting the Rust FFI calls the manager needs. Lets
/// us unit-test the manager without spinning up real terminals.
protocol ScrollbackMemoryRustFFI: AnyObject {
    func setScrollbackSize(_ lines: UInt32)
    func captureFullBufferText() -> String?
    /// ANSI-styled capture (SGR preserved, CRLF line endings). Used by both
    /// flush paths so a flushed-then-reloaded tab keeps its scrollback colors
    /// and column alignment when re-injected through the VTE parser.
    func captureFullBufferAnsiText() -> String?
    func replayBuffer(_ data: Data)
}

extension RustTerminalFFI: ScrollbackMemoryRustFFI {
    func captureFullBufferText() -> String? {
        fullBufferText()
    }

    func captureFullBufferAnsiText() -> String? {
        fullBufferAnsiText()
    }
}
