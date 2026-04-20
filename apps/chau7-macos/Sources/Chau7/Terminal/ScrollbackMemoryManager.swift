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
/// On demotion to .hidden: capture the full buffer text, gzip-compress it,
/// write to ~/Library/Application Support/Chau7/ScrollbackCache/<tabID>.gz,
/// then set scrollback size to a viewport floor to free most of the ring buffer.
///
/// On promotion from .hidden: set scrollback size to the configured user cap,
/// read the disk file, decompress, and replay through the Rust terminal via the
/// replay_buffer FFI.
final class ScrollbackMemoryManager {
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

    private init() {
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

    /// Entry point called from RustTerminalView.applyRenderPhase.
    /// Schedules flush/reload/cap-change on a per-tab serial queue so
    /// transitions for the same tab never overlap.
    func handlePhaseTransition(
        viewId: String,
        tabID: UUID?,
        rustFFI: (any ScrollbackMemoryRustFFI)?,
        from oldPhase: TabRenderPhase,
        to newPhase: TabRenderPhase
    ) {
        guard oldPhase != newPhase else { return }
        guard let rustFFI, let tabID else { return }

        let newCap = linesCap(for: newPhase)

        let queue = perTabQueue(for: tabID)
        queue.async { [weak self] in
            guard let self else { return }
            if ScrollbackRetentionPolicy.shouldFlushToDisk(from: oldPhase, to: newPhase) {
                flush(tabID: tabID, viewId: viewId, rustFFI: rustFFI)
            } else if ScrollbackRetentionPolicy.shouldReloadFromDisk(from: oldPhase, to: newPhase) {
                reload(tabID: tabID, viewId: viewId, rustFFI: rustFFI, newCap: newCap)
            } else {
                rustFFI.setScrollbackSize(UInt32(newCap))
                Log.trace("ScrollbackMemoryManager[\(viewId)]: \(oldPhase) -> \(newPhase) cap=\(newCap)")
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

    private func flush(tabID: UUID, viewId: String, rustFFI: any ScrollbackMemoryRustFFI) {
        guard let text = rustFFI.captureFullBufferText() else {
            Log.warn("ScrollbackMemoryManager[\(viewId)]: flush - no buffer text captured")
            rustFFI.setScrollbackSize(UInt32(Self.viewportFloor))
            return
        }

        let data = Data(text.utf8)
        guard !data.isEmpty else {
            rustFFI.setScrollbackSize(UInt32(Self.viewportFloor))
            return
        }

        let compressed = Self.compress(data)
        let url = cacheURL(for: tabID)
        do {
            try compressed.write(to: url, options: .atomic)
            Log.info("ScrollbackMemoryManager[\(viewId)]: flushed \(data.count)B raw / \(compressed.count)B gz to \(url.lastPathComponent)")
        } catch {
            Log.warn("ScrollbackMemoryManager[\(viewId)]: flush write failed: \(error)")
        }

        // Free the ring buffer. We keep a viewport floor so the currently
        // visible grid doesn't get clipped mid-transition.
        rustFFI.setScrollbackSize(UInt32(Self.viewportFloor))
    }

    // MARK: - Reload (promote from .hidden)

    private func reload(tabID: UUID, viewId: String, rustFFI: any ScrollbackMemoryRustFFI, newCap: Int) {
        let effectiveCap = max(newCap, Self.viewportFloor)
        rustFFI.setScrollbackSize(UInt32(effectiveCap))

        let url = cacheURL(for: tabID)
        guard let compressed = try? Data(contentsOf: url) else {
            Log.trace("ScrollbackMemoryManager[\(viewId)]: reload - no cache file")
            return
        }

        guard let decompressed = Self.decompress(compressed) else {
            Log.warn("ScrollbackMemoryManager[\(viewId)]: reload - decompression failed")
            try? FileManager.default.removeItem(at: url)
            return
        }

        rustFFI.replayBuffer(decompressed)
        try? FileManager.default.removeItem(at: url)
        Log.info("ScrollbackMemoryManager[\(viewId)]: reloaded \(decompressed.count)B from \(url.lastPathComponent)")
    }

    // MARK: - Compression

    private static func compress(_ data: Data) -> Data {
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
                // Fallback: store uncompressed if compressor failed
                return data
            }
            return Data(bytes: dst, count: written)
        }
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
        let dir = Self.cacheDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func cacheURL(for tabID: UUID) -> URL {
        Self.cacheDirectory().appendingPathComponent("\(tabID.uuidString).gz")
    }

    private static func cacheDirectory() -> URL {
        RuntimeIsolation.appSupportDirectory(named: "Chau7")
            .appendingPathComponent("ScrollbackCache", isDirectory: true)
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
}

/// Minimal protocol abstracting the Rust FFI calls the manager needs. Lets
/// us unit-test the manager without spinning up real terminals.
protocol ScrollbackMemoryRustFFI: AnyObject {
    func setScrollbackSize(_ lines: UInt32)
    func captureFullBufferText() -> String?
    func replayBuffer(_ data: Data)
}

extension RustTerminalFFI: ScrollbackMemoryRustFFI {
    func captureFullBufferText() -> String? {
        fullBufferText()
    }
}
