import Foundation

// MARK: - Bounded Collection Types (Code Optimization)
// Replaces repeated trimToLast() pattern with self-managing collections

/// A fixed-capacity array that automatically removes oldest elements when full
/// Optimized for append-heavy workloads like log buffers
struct BoundedArray<T> {
    private var storage: [T]
    let maxCount: Int

    init(maxCount: Int) {
        self.maxCount = maxCount
        self.storage = []
        self.storage.reserveCapacity(maxCount)
    }

    /// Appends an element, removing the oldest if at capacity
    mutating func append(_ item: T) {
        if storage.count >= maxCount {
            storage.removeFirst()
        }
        storage.append(item)
    }

    /// Appends multiple elements efficiently
    mutating func append(contentsOf items: [T]) {
        for item in items {
            append(item)
        }
    }

    /// Removes all elements
    mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
    }

    /// The underlying array
    var items: [T] { storage }

    /// Number of elements
    var count: Int { storage.count }

    /// Whether the collection is empty
    var isEmpty: Bool { storage.isEmpty }

    /// First element
    var first: T? { storage.first }

    /// Last element
    var last: T? { storage.last }

    /// Access by index
    subscript(index: Int) -> T {
        storage[index]
    }
}

// MARK: - Sequence Conformance

extension BoundedArray: Sequence {
    func makeIterator() -> IndexingIterator<[T]> {
        storage.makeIterator()
    }
}

// MARK: - Collection Conformance

extension BoundedArray: Collection {
    var startIndex: Int { storage.startIndex }
    var endIndex: Int { storage.endIndex }

    func index(after i: Int) -> Int {
        storage.index(after: i)
    }
}

// MARK: - Bounded Set

/// A fixed-capacity set that automatically removes oldest elements when full
struct BoundedSet<T: Hashable> {
    private var storage: Set<T>
    private var insertionOrder: [T]
    let maxCount: Int

    init(maxCount: Int) {
        self.maxCount = maxCount
        self.storage = Set(minimumCapacity: maxCount)
        self.insertionOrder = []
        self.insertionOrder.reserveCapacity(maxCount)
    }

    /// Inserts an element, removing the oldest if at capacity
    mutating func insert(_ item: T) {
        if storage.contains(item) {
            // Already present - move to end of insertion order
            if let index = insertionOrder.firstIndex(of: item) {
                insertionOrder.remove(at: index)
            }
            insertionOrder.append(item)
            return
        }

        // Evict oldest if at capacity
        while storage.count >= maxCount, let oldest = insertionOrder.first {
            storage.remove(oldest)
            insertionOrder.removeFirst()
        }

        storage.insert(item)
        insertionOrder.append(item)
    }

    /// Removes an element
    mutating func remove(_ item: T) {
        storage.remove(item)
        if let index = insertionOrder.firstIndex(of: item) {
            insertionOrder.remove(at: index)
        }
    }

    /// Checks membership
    func contains(_ item: T) -> Bool {
        storage.contains(item)
    }

    /// Removes all elements
    mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        insertionOrder.removeAll(keepingCapacity: keepingCapacity)
    }

    /// Number of elements
    var count: Int { storage.count }

    /// Whether the collection is empty
    var isEmpty: Bool { storage.isEmpty }

    /// The underlying set
    var items: Set<T> { storage }
}

// MARK: - Sequence Conformance for BoundedSet

extension BoundedSet: Sequence {
    func makeIterator() -> Set<T>.Iterator {
        storage.makeIterator()
    }
}
