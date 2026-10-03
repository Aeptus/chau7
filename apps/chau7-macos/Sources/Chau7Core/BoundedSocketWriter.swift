import Darwin
import Foundation

/// Owns a duplicated socket descriptor and serializes complete frames. Admission
/// never waits for the peer. A slow/broken peer aborts this connection, waking its
/// reader; graceful finish drains accepted frames before closing the duplicate.
public final class BoundedSocketWriter: @unchecked Sendable {
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var accepting = true
    private var writable = true
    private var closeScheduled = false
    private var pendingBytes = 0
    private var pendingFrames = 0
    private var descriptor: Int32
    private let timeout: TimeInterval
    private let maxPendingBytes: Int
    private let maxPendingFrames: Int

    public convenience init?(socket: Int32, timeout: TimeInterval = TimeInterval(MCPConnectionLifetimePolicy.sendTimeoutSeconds), maxPendingBytes: Int = 16 * 1024 * 1024, maxPendingFrames: Int = 64) {
        self.init(
            socket: socket,
            timeout: timeout,
            maxPendingBytes: maxPendingBytes,
            maxPendingFrames: maxPendingFrames,
            queue: DispatchQueue(label: "com.chau7.socket.writer", qos: .utility)
        )
    }

    /// Internal serial-owner seam for deterministic queue-delay regressions.
    init?(socket: Int32, timeout: TimeInterval, maxPendingBytes: Int, maxPendingFrames: Int, queue: DispatchQueue) {
        self.queue = queue
        let duplicate = dup(socket)
        guard duplicate >= 0 else { return nil }
        self.descriptor = duplicate
        self.timeout = timeout
        self.maxPendingBytes = maxPendingBytes
        self.maxPendingFrames = maxPendingFrames
        var enabled: Int32 = 1
        guard setsockopt(duplicate, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(duplicate)
            self.descriptor = -1
            return nil
        }
    }

    deinit {
        // No queued block can outlive its retained owner.
        if descriptor >= 0 { Darwin.close(descriptor) }
    }

    public var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return accepting
    }

    @discardableResult
    public func enqueue(_ frame: Data) -> Bool {
        lock.lock()
        guard accepting else { lock.unlock()
            return false
        }
        guard frame.count <= 8 * 1024 * 1024,
              pendingFrames < maxPendingFrames,
              frame.count <= maxPendingBytes - pendingBytes else {
            lock.unlock()
            close()
            return false
        }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        pendingBytes += frame.count
        pendingFrames += 1
        // Enqueue while holding the admission lock so finish cannot overtake an
        // accepted frame. No socket I/O or client callback holds this lock.
        queue.async { [self] in
            if !sendAll(frame, until: deadline) { close() }
            lock.lock()
            pendingBytes -= frame.count
            pendingFrames -= 1
            lock.unlock()
        }
        lock.unlock()
        return true
    }

    /// Reject new frames and drain those already accepted.
    public func finish() {
        scheduleClose(abort: false)
    }

    /// Cancel queued writes without blocking the caller.
    public func close() {
        scheduleClose(abort: true)
    }

    private func scheduleClose(abort: Bool) {
        lock.lock()
        accepting = false
        if abort { writable = false }
        guard !closeScheduled else { lock.unlock()
            return
        }
        closeScheduled = true
        queue.async { [self] in
            guard descriptor >= 0 else { return }
            shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            descriptor = -1
        }
        lock.unlock()
    }

    private func canWrite() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return writable
    }

    private func sendAll(_ frame: Data, until deadline: TimeInterval) -> Bool {
        return frame.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return bytes.isEmpty }
            var offset = 0
            while offset < bytes.count, canWrite(), ProcessInfo.processInfo.systemUptime < deadline {
                // Darwin Unix sockets can still block a large send despite
                // MSG_DONTWAIT. Bound the kernel wait too, without changing the
                // shared descriptor's flags and making the reader nonblocking.
                let remainingSeconds = deadline - ProcessInfo.processInfo.systemUptime
                var sendTimeout = timeval(tv_sec: 0, tv_usec: Int32(max(1, min(100_000, remainingSeconds * 1_000_000))))
                guard setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else { return false }
                let count = send(descriptor, address.advanced(by: offset), bytes.count - offset, MSG_DONTWAIT)
                if count > 0 { offset += count
                    continue
                }
                if count < 0, errno == EINTR { continue }
                guard count < 0, errno == EAGAIN || errno == EWOULDBLOCK else { return false }
                var socket = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                let remaining = (deadline - ProcessInfo.processInfo.systemUptime) * 1000
                _ = poll(&socket, 1, Int32(max(1, min(100, remaining))))
            }
            return offset == bytes.count
        }
    }
}
