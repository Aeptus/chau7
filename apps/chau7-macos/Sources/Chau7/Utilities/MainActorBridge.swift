import Foundation
import Chau7Core

/// Brief synchronous access to UI-owned state from a background service.
/// Waiting and I/O stay on the caller's queue, outside this closure.
enum MainActorBridge {
    static func sync<T>(_ block: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(block)
        }
        return DispatchQueue.main.sync {
            MainActor.assumeIsolated(block)
        }
    }

    private static let readAdmission = DispatchSemaphore(value: 32)
    static let readTimeout: TimeInterval = 1
    static let unresponsiveJSON = #"{"error":"main_thread_unresponsive","retryable":true,"timeout_ms":1000}"#

    /// Read-only requests may time out; an expired queued closure is never executed.
    /// Admission remains held until main drains the closure, bounding backlog during a stall.
    static func read<T>(timeout: TimeInterval = readTimeout, _ block: @escaping @MainActor () -> T) -> T? {
        if Thread.isMainThread { return MainActor.assumeIsolated(block) }
        guard readAdmission.wait(timeout: .now()) == .success else { return nil }
        let latch = DeadlineResultLatch<T>(timeout: timeout)
        DispatchQueue.main.async {
            defer { readAdmission.signal() }
            guard latch.begin() else { return }
            latch.complete(MainActor.assumeIsolated(block))
        }
        return latch.wait()
    }

    /// Fire-and-forget: runs `block` inline when already on main, otherwise
    /// hops with `main.async`. For Void side effects in property observers that
    /// usually fire on main but can fire elsewhere (e.g. from `deinit` when the
    /// last reference drops off-main) — bare `assumeIsolated` would trap there.
    static func run(_ block: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(block)
        } else {
            DispatchQueue.main.async {
                MainActor.assumeIsolated(block)
            }
        }
    }
}
