import Foundation

/// One bounded rendezvous. Expired queued work cannot begin or publish a late result.
public final class DeadlineResultLatch<Value>: @unchecked Sendable {
    private enum State { case pending, running, completed, expired }
    private let lock = NSLock()
    private let signal = DispatchSemaphore(value: 0)
    private let deadline: DispatchTime
    private var state = State.pending
    private var result: Value?

    public init(timeout: TimeInterval) {
        let bounded = timeout.isFinite ? max(0, min(timeout, 3600)) : 0
        self.deadline = .now() + bounded
    }

    public func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .pending, DispatchTime.now() < deadline else {
            if state == .pending { state = .expired }
            return false
        }
        state = .running
        return true
    }

    public func complete(_ value: Value) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .running, DispatchTime.now() < deadline else {
            if state == .running { state = .expired }
            signal.signal()
            return
        }
        result = value
        state = .completed
        signal.signal()
    }

    public func wait() -> Value? {
        _ = signal.wait(timeout: deadline)
        lock.lock()
        defer { lock.unlock() }
        guard state == .completed else {
            state = .expired
            return nil
        }
        return result
    }
}
