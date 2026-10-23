import Foundation

/// One-way latch used to stop a chain of scheduled retries once an earlier
/// attempt has already produced a final answer.
///
/// This exists to replace the `NSLock` + captured `var` idiom that Swift's
/// concurrency checking rejects: a mutable local captured by several
/// `@Sendable` closures is diagnosed at compile time, and the usual workaround
/// — sprinkling `lock`/`unlock` around each access — papers over the check
/// rather than satisfying it, because the flag is shared state regardless of
/// how carefully it is locked.
///
/// Semantics match the pattern it replaces: `shouldProceed()` returns `true`
/// until `latch()` is called, and `false` from then on. It is deliberately
/// **not** a one-shot claim — callers that need "only one caller may proceed"
/// want an atomic compare-and-set, which is a different contract. Here an
/// attempt that reports no outcome leaves the latch open so a later retry can
/// still run.
///
/// Thread-safe: every access is a single acquisition.
public final class CompletionLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var latched = false

    public init() {}

    /// `true` while the latch is still open.
    public func shouldProceed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !latched
    }

    /// Closes the latch. Subsequent `shouldProceed()` calls return `false`.
    public func latch() {
        lock.lock()
        defer { lock.unlock() }
        latched = true
    }

    /// Closes the latch only if it is still open, reporting whether this call
    /// was the one that closed it.
    @discardableResult
    public func latchIfOpen() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !latched else { return false }
        latched = true
        return true
    }
}
