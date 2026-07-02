import Foundation

/// Generic in-memory ring buffer with a monotonic sequence cursor space.
///
/// This is the storage engine behind `EventJournal` (per-session runtime
/// events) and `GlobalEventJournal` (spine envelopes). Sequence numbers are
/// allocated at append time under the lock, are dense, start at 1, and
/// survive eviction — a cursor older than the oldest retained entry reads
/// from the oldest available.
///
/// - Thread safety: all mutable state is guarded by `lock`; the
///   `@unchecked Sendable` conformance is load-bearing. Callers must not
///   re-enter the journal from inside the `append` builder closure.
public final class RingJournal<Element: Sendable>: @unchecked Sendable {

    private struct Entry {
        let seq: UInt64
        let element: Element
    }

    private let capacity: Int
    private var buffer: [Entry]
    private var writeIndex = 0
    private var totalAppended: UInt64 = 0
    private var wrapped = false
    private let lock = NSLock()

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
        self.buffer = []
        buffer.reserveCapacity(capacity)
    }

    /// Append a new element built from the allocated sequence number.
    /// The builder runs under the lock, so seq allocation and insertion are
    /// atomic: total order across concurrent producers == seq order.
    @discardableResult
    public func append(_ make: (UInt64) -> Element) -> Element {
        lock.lock()
        defer { lock.unlock() }
        totalAppended += 1
        let element = make(totalAppended)
        let entry = Entry(seq: totalAppended, element: element)
        if buffer.count < capacity {
            buffer.append(entry)
        } else {
            buffer[writeIndex] = entry
            wrapped = true
        }
        writeIndex = (writeIndex + 1) % capacity
        return element
    }

    /// Read elements after the given cursor (exclusive), oldest first.
    ///
    /// Returns the elements with seq > cursor (up to `limit`), the new cursor
    /// (seq of the last returned element, or the input cursor if none), and
    /// whether more elements exist beyond the returned batch. If the cursor
    /// is older than the oldest retained entry, reads start from the oldest
    /// available.
    public func entries(after cursor: UInt64, limit: Int = 100) -> (elements: [Element], cursor: UInt64, hasMore: Bool) {
        lock.lock()
        defer { lock.unlock() }

        guard !buffer.isEmpty else {
            return ([], cursor, false)
        }

        let oldest = oldestSeqLocked
        let newest = totalAppended

        guard cursor < newest else {
            return ([], cursor, false)
        }

        let effectiveStart = max(cursor, oldest - 1) // -1 because we want seq > cursor

        var result: [Element] = []
        var lastSeq = cursor
        let count = buffer.count
        result.reserveCapacity(min(limit, count))

        let startReadIndex = wrapped ? writeIndex : 0
        for i in 0 ..< count {
            let entry = buffer[(startReadIndex + i) % count]
            if entry.seq > effectiveStart {
                result.append(entry.element)
                lastSeq = entry.seq
                if result.count >= limit {
                    let hasMore = (i + 1) < count
                    return (result, lastSeq, hasMore)
                }
            }
        }

        return (result, result.isEmpty ? cursor : lastSeq, false)
    }

    /// All retained elements matching `predicate`, in chronological order.
    /// The predicate runs under the lock; keep it cheap and non-reentrant.
    public func elements(where predicate: (Element) -> Bool) -> [Element] {
        lock.lock()
        defer { lock.unlock() }

        guard !buffer.isEmpty else { return [] }

        let count = buffer.count
        let startReadIndex = wrapped ? writeIndex : 0
        var result: [Element] = []
        result.reserveCapacity(count)
        for i in 0 ..< count {
            let entry = buffer[(startReadIndex + i) % count]
            if predicate(entry.element) {
                result.append(entry.element)
            }
        }
        return result
    }

    /// The sequence number of the most recent element (0 if empty).
    public var latestCursor: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return totalAppended
    }

    /// The oldest available sequence number (0 if empty, 1 if not yet wrapped).
    public var oldestAvailableCursor: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return oldestSeqLocked
    }

    /// Current number of retained elements.
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return buffer.count
    }

    // MARK: - Private

    /// Oldest seq in the buffer. Caller must hold lock.
    private var oldestSeqLocked: UInt64 {
        guard !buffer.isEmpty else { return 0 }
        if wrapped {
            return buffer[writeIndex % capacity].seq
        } else {
            return buffer[0].seq
        }
    }
}
