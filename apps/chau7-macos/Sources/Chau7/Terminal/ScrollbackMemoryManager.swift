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
/// On demotion to .hidden: capture the full buffer text, encode it into a
/// verified cache payload at
/// ~/Library/Application Support/Chau7/ScrollbackCache/<tabID>.gz, then set
/// scrollback size to a viewport floor to free most of the ring buffer.
///
/// On promotion from .hidden: set scrollback size to the configured user cap,
/// read the disk file, decompress, and replay through the Rust terminal via the
/// replay_buffer FFI.
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

    private let stateLock = NSLock()
    private var perTabQueues: [UUID: DispatchQueue] = [:]
    /// Tabs whose scrollback ring was flushed to disk + shrunk by the *idle*
    /// path (not the `.hidden` phase path), so `idleReloadIfNeeded` knows to
    /// restore them on reselection. Guarded by `stateLock`.
    private var idleFlushedTabIDs: Set<UUID> = []
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
    /// `hostsTUIApp` short-circuits the destructive flush/reload paths.
    /// `flush()` captures the grid via `full_buffer_text` which only emits
    /// row-text — no SGR, no cursor positioning, no preserved TUI state. For a
    /// shell tab that's fine; for a tab running Claude/Codex/Aider/etc. it
    /// flattens the live TUI surface to plain text, and on reload `replayBuffer`
    /// then issues `ESC[2J ESC[H` + replays the flattened text, which destroys
    /// the running TUI's invariants (boxes/spinners/menus). Skip both for TUI
    /// tabs: ring still gets resized so memory still tracks, but we never
    /// flatten or repour the TUI surface from a stale snapshot.
    func handlePhaseTransition(
        viewId: String,
        tabID: UUID?,
        rustFFI: (any ScrollbackMemoryRustFFI)?,
        from oldPhase: TabRenderPhase,
        to newPhase: TabRenderPhase,
        hostsTUIApp: Bool = false
    ) {
        guard oldPhase != newPhase else { return }
        guard let rustFFI, let tabID else { return }

        let newCap = linesCap(for: newPhase)

        let queue = perTabQueue(for: tabID)
        queue.async { [weak self] in
            guard let self else { return }
            if ScrollbackRetentionPolicy.shouldFlushToDisk(from: oldPhase, to: newPhase) {
                if hostsTUIApp {
                    rustFFI.setScrollbackSize(UInt32(Self.viewportFloor))
                    Log.info("ScrollbackMemoryManager[\(viewId)]: skipping flush for TUI tab \(oldPhase) -> \(newPhase)")
                    return
                }
                if flush(tabID: tabID, viewId: viewId, rustFFI: rustFFI) {
                    // Free the ring buffer only after the buffer has either
                    // been persisted and verified, or proven empty.
                    rustFFI.setScrollbackSize(UInt32(Self.viewportFloor))
                } else {
                    Log.warn("ScrollbackMemoryManager[\(viewId)]: preserving in-memory scrollback because hidden flush did not complete")
                }
            } else if ScrollbackRetentionPolicy.shouldReloadFromDisk(from: oldPhase, to: newPhase) {
                if hostsTUIApp {
                    rustFFI.setScrollbackSize(UInt32(max(newCap, Self.viewportFloor)))
                    Log.info("ScrollbackMemoryManager[\(viewId)]: skipping reload-replay for TUI tab \(oldPhase) -> \(newPhase)")
                    return
                }
                reload(tabID: tabID, viewId: viewId, rustFFI: rustFFI, newCap: newCap)
            } else {
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
    /// Unlike the `.hidden` flush this captures *ANSI* (SGR preserved), so the
    /// reloaded scrollback keeps its colors. TUI tabs are skipped entirely — the
    /// caller must pass `hostsTUIApp` for any alternate-screen / AI-TUI session;
    /// flattening + repouring a live TUI surface would corrupt it.
    func idleFlush(
        viewId: String,
        tabID: UUID,
        rustFFI: any ScrollbackMemoryRustFFI,
        hostsTUIApp: Bool
    ) {
        guard !hostsTUIApp else {
            Log.trace("ScrollbackMemoryManager[\(viewId)]: idleFlush skipped (TUI tab)")
            return
        }
        let queue = perTabQueue(for: tabID)
        queue.async { [weak self] in
            guard let self else { return }
            guard let text = rustFFI.captureFullBufferAnsiText() else {
                Log.warn("ScrollbackMemoryManager[\(viewId)]: idleFlush - no buffer captured")
                return
            }
            guard persist(text: text, tabID: tabID, viewId: viewId) else {
                Log.warn("ScrollbackMemoryManager[\(viewId)]: idleFlush - persist failed; ring untouched")
                return
            }
            rustFFI.setScrollbackSize(UInt32(Self.viewportFloor))
            stateLock.lock()
            idleFlushedTabIDs.insert(tabID)
            stateLock.unlock()
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
        configuredLines: Int
    ) {
        let queue = perTabQueue(for: tabID)
        queue.async { [weak self] in
            guard let self else { return }
            stateLock.lock()
            let wasFlushed = idleFlushedTabIDs.remove(tabID) != nil
            stateLock.unlock()
            guard wasFlushed else { return }
            reload(tabID: tabID, viewId: viewId, rustFFI: rustFFI, newCap: configuredLines)
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
        stateLock.unlock()
    }

    // MARK: - Flush (demote → .hidden)

    private func flush(tabID: UUID, viewId: String, rustFFI: any ScrollbackMemoryRustFFI) -> Bool {
        guard let text = rustFFI.captureFullBufferText() else {
            Log.warn("ScrollbackMemoryManager[\(viewId)]: flush - no buffer text captured")
            return false
        }
        return persist(text: text, tabID: tabID, viewId: viewId)
    }

    /// Encode → durably write → read back → verify a captured buffer into the
    /// tab's cache file. Shared by the `.hidden` flush and the idle flush.
    /// Returns true only once the bytes are persisted and verified (or the
    /// buffer was empty, in which case any stale cache is removed).
    private func persist(text: String, tabID: UUID, viewId: String) -> Bool {
        let data = Data(text.utf8)
        let url = cacheURL(for: tabID)
        guard !data.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return true
        }

        let payload = Self.encodedCachePayload(for: data)
        do {
            try cacheWriter(payload, url)
            let persisted = try Data(contentsOf: url)
            guard let decoded = Self.decodedCachePayload(persisted), decoded == data else {
                throw ScrollbackCacheError.verificationFailed
            }
            Log.info("ScrollbackMemoryManager[\(viewId)]: flushed \(data.count)B raw / \(payload.count)B cache to \(url.lastPathComponent)")
            return true
        } catch {
            Log.warn("ScrollbackMemoryManager[\(viewId)]: flush write failed: \(error)")
            try? FileManager.default.removeItem(at: url)
            return false
        }
    }

    // MARK: - Reload (promote from .hidden)

    private func reload(tabID: UUID, viewId: String, rustFFI: any ScrollbackMemoryRustFFI, newCap: Int) {
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

        guard let decompressed = Self.decodedCachePayload(compressed) else {
            Log.warn("ScrollbackMemoryManager[\(viewId)]: reload - cache decode failed")
            try? FileManager.default.removeItem(at: url)
            return
        }

        rustFFI.replayBuffer(decompressed)
        try? FileManager.default.removeItem(at: url)
        Log.info("ScrollbackMemoryManager[\(viewId)]: reloaded \(decompressed.count)B from \(url.lastPathComponent)")
    }

    // MARK: - Compression

    private static let zlibCacheHeader = Data("CHAU7_SCROLLBACK_ZLIB_V1\n".utf8)
    private static let rawCacheHeader = Data("CHAU7_SCROLLBACK_RAW_V1\n".utf8)

    private enum ScrollbackCacheError: Error {
        case verificationFailed
    }

    private static func encodedCachePayload(for data: Data) -> Data {
        if let compressed = compress(data) {
            var payload = zlibCacheHeader
            payload.append(compressed)
            return payload
        }

        var payload = rawCacheHeader
        payload.append(data)
        return payload
    }

    private static func decodedCachePayload(_ payload: Data) -> Data? {
        if payload.starts(with: zlibCacheHeader) {
            return decompress(Data(payload.dropFirst(zlibCacheHeader.count)))
        }

        if payload.starts(with: rawCacheHeader) {
            return Data(payload.dropFirst(rawCacheHeader.count))
        }

        // Backward compatibility for caches written before payload headers.
        if let decompressed = decompress(payload) {
            return decompressed
        }

        if String(data: payload, encoding: .utf8) != nil {
            return payload
        }

        return nil
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

    private static func decompress(_ data: Data) -> Data? {
        data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Data? in
            guard let srcBase = src.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }
            // Compressed text is typically 3-5x smaller than original. Start
            // with a 10x buffer; grow if the first pass hits the cap.
            var dstCapacity = max(data.count * 10, 4096)
            for _ in 0 ..< 3 {
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
                dstCapacity *= 2
            }
            return nil
        }
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
                try fileManager.removeItem(at: url)
            }
            try fileManager.moveItem(at: tempURL, to: url)
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
            qos: .utility
        )
        perTabQueues[tabID] = queue
        return queue
    }

    func drainPendingOperationsForTesting(tabID: UUID) {
        perTabQueue(for: tabID).sync {}
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
    /// ANSI-styled capture (SGR preserved). Used by the idle-flush path so a
    /// flushed-then-reloaded tab keeps its scrollback colors, unlike the plain
    /// `.hidden` flush which intentionally flattens to text.
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
