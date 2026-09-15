import Foundation

final class TerminalTranscriptCapture: MemoryReclaimable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var chunks: [Data?] = []
    private var headIndex = 0
    private var byteCount = 0
    private var boundaryOffset = 0

    init(
        maxBytes: Int = TerminalTranscriptCapture.defaultMaxBytes(),
        memoryPressureCoordinator: MemoryPressureCoordinator = .shared
    ) {
        self.maxBytes = max(1, maxBytes)
        // Per-tab ring (up to ~10MB). The transcript is best-effort backfill data
        // and fully regenerable from live PTY output, so it is safe to release
        // under memory pressure.
        memoryPressureCoordinator.register(self)
    }

    /// Releases the transcript ring under OS memory pressure. Returns bytes freed.
    /// `.warning` drops the older half (keeps recent context for command backfill);
    /// `.critical` releases the ring's storage entirely.
    @discardableResult
    func reclaimMemory(_ level: MemoryPressureLevel) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let before = byteCount
        guard before > 0 else { return 0 }
        switch level {
        case .warning:
            let keep = before / 2
            let removed = before - keep
            trimPrefixLocked(removed)
            return removed
        case .critical:
            chunks.removeAll(keepingCapacity: false)
            headIndex = 0
            byteCount = 0
            boundaryOffset = 0
            return before
        }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        chunks.append(data)
        byteCount += data.count
        trimIfNeededLocked()
    }

    func markCommandBoundary() {
        lock.lock()
        boundaryOffset = byteCount
        lock.unlock()
    }

    func dataSinceBoundary() -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard boundaryOffset < byteCount else { return Data() }
        return dataLocked(skipping: boundaryOffset)
    }

    func tailData(maxBytes requestedMaxBytes: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }

        let keep = max(0, min(requestedMaxBytes, byteCount))
        return dataLocked(skipping: byteCount - keep)
    }

    func reset() {
        lock.lock()
        chunks.removeAll(keepingCapacity: true)
        headIndex = 0
        byteCount = 0
        boundaryOffset = 0
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return byteCount == 0
    }

    private func trimIfNeededLocked() {
        guard byteCount > maxBytes else { return }

        trimPrefixLocked(byteCount - maxBytes)
    }

    private func trimPrefixLocked(_ requestedCount: Int) {
        let removedCount = min(max(0, requestedCount), byteCount)
        var remaining = removedCount

        while remaining > 0, headIndex < chunks.count {
            guard let chunk = chunks[headIndex] else {
                headIndex += 1
                continue
            }
            if remaining >= chunk.count {
                remaining -= chunk.count
                byteCount -= chunk.count
                chunks[headIndex] = nil
                headIndex += 1
            } else {
                chunks[headIndex] = Data(chunk.dropFirst(remaining))
                byteCount -= remaining
                remaining = 0
            }
        }

        boundaryOffset = max(0, boundaryOffset - removedCount)
        compactChunkSlotsIfNeeded()
    }

    private func compactChunkSlotsIfNeeded() {
        guard headIndex > 0,
              headIndex >= 64 || headIndex * 2 >= chunks.count else { return }
        chunks.removeFirst(headIndex)
        headIndex = 0
    }

    private func dataLocked(skipping requestedSkip: Int) -> Data {
        var skip = min(max(0, requestedSkip), byteCount)
        var result = Data()
        result.reserveCapacity(byteCount - skip)

        for index in headIndex ..< chunks.count {
            guard let chunk = chunks[index] else { continue }
            if skip >= chunk.count {
                skip -= chunk.count
                continue
            }
            result.append(contentsOf: chunk.dropFirst(skip))
            skip = 0
        }
        return result
    }

    #if DEBUG
    var allocatedChunkSlotCountForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return chunks.count
    }
    #endif

    private static func defaultMaxBytes() -> Int {
        if let raw = EnvVars.get(EnvVars.ptyLogMaxBytes),
           let value = Int(raw), value > 0 {
            return value
        }
        return 10 * 1024 * 1024
    }
}
