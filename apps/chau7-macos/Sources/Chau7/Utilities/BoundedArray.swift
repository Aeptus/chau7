import Foundation

/// A fixed-capacity set that automatically removes oldest elements when full
struct BoundedSet<T: Hashable> {
    private var storage: Set<T>
    private var insertionOrder: [T]
    let maxCount: Int

    init(maxCount: Int) {
        self.maxCount = maxCount
        self.storage = Set(minimumCapacity: maxCount)
        self.insertionOrder = []
        insertionOrder.reserveCapacity(maxCount)
    }

    mutating func insert(_ item: T) {
        if storage.contains(item) {
            if let index = insertionOrder.firstIndex(of: item) {
                insertionOrder.remove(at: index)
            }
            insertionOrder.append(item)
            return
        }
        while storage.count >= maxCount, let oldest = insertionOrder.first {
            storage.remove(oldest)
            insertionOrder.removeFirst()
        }
        storage.insert(item)
        insertionOrder.append(item)
    }

    mutating func remove(_ item: T) {
        storage.remove(item)
        if let index = insertionOrder.firstIndex(of: item) {
            insertionOrder.remove(at: index)
        }
    }

    func contains(_ item: T) -> Bool {
        storage.contains(item)
    }

    mutating func removeAll(keepingCapacity: Bool = false) {
        storage.removeAll(keepingCapacity: keepingCapacity)
        insertionOrder.removeAll(keepingCapacity: keepingCapacity)
    }

    var count: Int {
        storage.count
    }

    var isEmpty: Bool {
        storage.isEmpty
    }

    var items: Set<T> {
        storage
    }
}

extension BoundedSet: Sequence {
    func makeIterator() -> Set<T>.Iterator {
        storage.makeIterator()
    }
}
