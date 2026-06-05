import Foundation

final class TerminalTranscriptCapture: MemoryReclaimable {
    private let lock = NSLock()
    private let maxBytes: Int
    private var buffer = Data()
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
        let before = buffer.count
        guard before > 0 else { return 0 }
        switch level {
        case .warning:
            let keep = before / 2
            let removed = before - keep
            buffer = Data(buffer.suffix(keep))
            boundaryOffset = max(0, boundaryOffset - removed)
            return removed
        case .critical:
            buffer = Data() // release storage, not just contents
            boundaryOffset = 0
            return before
        }
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }

        lock.lock()
        defer { lock.unlock() }

        buffer.append(data)
        trimIfNeededLocked()
    }

    func markCommandBoundary() {
        lock.lock()
        boundaryOffset = buffer.count
        lock.unlock()
    }

    func dataSinceBoundary() -> Data {
        lock.lock()
        defer { lock.unlock() }

        guard boundaryOffset < buffer.count else { return Data() }
        let start = buffer.index(buffer.startIndex, offsetBy: boundaryOffset)
        return Data(buffer[start...])
    }

    func tailData(maxBytes requestedMaxBytes: Int) -> Data {
        lock.lock()
        defer { lock.unlock() }

        let keep = max(1, min(requestedMaxBytes, buffer.count))
        return Data(buffer.suffix(keep))
    }

    func reset() {
        lock.lock()
        buffer.removeAll(keepingCapacity: true)
        boundaryOffset = 0
        lock.unlock()
    }

    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return buffer.isEmpty
    }

    private func trimIfNeededLocked() {
        guard buffer.count > maxBytes else { return }

        let overflow = buffer.count - maxBytes
        buffer = Data(buffer.suffix(maxBytes))
        boundaryOffset = max(0, boundaryOffset - overflow)
    }

    private static func defaultMaxBytes() -> Int {
        if let raw = EnvVars.get(EnvVars.ptyLogMaxBytes),
           let value = Int(raw), value > 0 {
            return value
        }
        return 10 * 1024 * 1024
    }
}
