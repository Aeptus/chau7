import Foundation

/// An atomic cache entry is published only after its factory succeeds.
/// Factories run under the lock; they must not reenter this cache.
public final class LockedCache<Key: Hashable & Sendable, Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Key: Value] = [:]

    public init() {}

    public func value(for key: Key, create: () throws -> Value) rethrows -> Value {
        lock.lock()
        defer { lock.unlock() }
        if let value = values[key] { return value }
        let value = try create()
        values[key] = value
        return value
    }
}
