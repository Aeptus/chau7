import Foundation

final class TerminalTranscriptCapture {
    private let lock = NSLock()
    private let maxBytes: Int
    private var buffer = Data()
    private var boundaryOffset = 0

    init(maxBytes: Int = TerminalTranscriptCapture.defaultMaxBytes()) {
        self.maxBytes = max(1, maxBytes)
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
