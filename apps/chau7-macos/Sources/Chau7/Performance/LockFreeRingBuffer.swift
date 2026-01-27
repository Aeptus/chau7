// MARK: - Lock-Free Ring Buffer for PTY Data
// High-performance SPSC (Single Producer Single Consumer) ring buffer
// using Swift Atomics for zero-contention data transfer between PTY and renderer.

import Foundation
import Atomics

/// A lock-free ring buffer for high-throughput, low-latency data transfer.
/// Uses atomic operations instead of locks for ~10-50ns per operation vs ~1-10µs with locks.
///
/// Thread Safety:
/// - Single producer (PTY read thread) calls `write()`
/// - Single consumer (render thread) calls `read()`
/// - Multiple consumers require external synchronization
public final class LockFreeRingBuffer<T> {
    private let buffer: UnsafeMutableBufferPointer<T>
    private let capacity: Int
    private let mask: Int  // For fast modulo via bitwise AND

    // Cache-line padded atomics to prevent false sharing
    private let head: ManagedAtomic<Int>  // Write position (producer)
    private let tail: ManagedAtomic<Int>  // Read position (consumer)

    // Statistics for debugging
    private let writeCount: ManagedAtomic<UInt64>
    private let readCount: ManagedAtomic<UInt64>
    private let dropCount: ManagedAtomic<UInt64>

    /// Creates a ring buffer with the specified capacity.
    /// - Parameter capacity: Must be a power of 2 for optimal performance.
    ///                       Will be rounded up to next power of 2 if not.
    public init(capacity requestedCapacity: Int) {
        // Round up to power of 2 for fast modulo
        let actualCapacity = Self.nextPowerOf2(max(16, requestedCapacity))
        self.capacity = actualCapacity
        self.mask = actualCapacity - 1

        // Allocate raw memory for the buffer
        let ptr = UnsafeMutablePointer<T>.allocate(capacity: actualCapacity)
        self.buffer = UnsafeMutableBufferPointer(start: ptr, count: actualCapacity)

        self.head = ManagedAtomic(0)
        self.tail = ManagedAtomic(0)
        self.writeCount = ManagedAtomic(0)
        self.readCount = ManagedAtomic(0)
        self.dropCount = ManagedAtomic(0)
    }

    deinit {
        buffer.baseAddress?.deallocate()
    }

    // MARK: - Producer API (PTY thread)

    /// Writes a value to the buffer. Returns false if buffer is full.
    /// - Complexity: O(1), lock-free
    public func write(_ value: T) -> Bool {
        let currentHead = head.load(ordering: .relaxed)
        let nextHead = (currentHead + 1) & mask

        // Check if full (would catch up to tail)
        if nextHead == tail.load(ordering: .acquiring) {
            dropCount.wrappingIncrement(ordering: .relaxed)
            return false
        }

        buffer[currentHead] = value
        head.store(nextHead, ordering: .releasing)
        writeCount.wrappingIncrement(ordering: .relaxed)
        return true
    }

    /// Writes multiple values to the buffer.
    /// - Returns: Number of values successfully written
    public func write(contentsOf values: UnsafeBufferPointer<T>) -> Int {
        var written = 0
        for i in 0..<values.count {
            if write(values[i]) {
                written += 1
            } else {
                break
            }
        }
        return written
    }

    /// Writes multiple values from an array slice.
    public func write(contentsOf slice: ArraySlice<T>) -> Int {
        slice.withUnsafeBufferPointer { ptr in
            write(contentsOf: ptr)
        }
    }

    // MARK: - Consumer API (Render thread)

    /// Reads a value from the buffer. Returns nil if buffer is empty.
    /// - Complexity: O(1), lock-free
    public func read() -> T? {
        let currentTail = tail.load(ordering: .relaxed)

        // Check if empty
        if currentTail == head.load(ordering: .acquiring) {
            return nil
        }

        let value = buffer[currentTail]
        tail.store((currentTail + 1) & mask, ordering: .releasing)
        readCount.wrappingIncrement(ordering: .relaxed)
        return value
    }

    /// Reads up to `maxCount` values into the destination buffer.
    /// - Returns: Number of values read
    public func read(into destination: UnsafeMutableBufferPointer<T>, maxCount: Int) -> Int {
        var count = 0
        let limit = min(maxCount, destination.count)

        while count < limit, let value = read() {
            destination[count] = value
            count += 1
        }
        return count
    }

    /// Reads all available values into an array.
    public func readAll() -> [T] {
        var result: [T] = []
        result.reserveCapacity(availableToRead)
        while let value = read() {
            result.append(value)
        }
        return result
    }

    // MARK: - Status

    /// Number of items available to read.
    public var availableToRead: Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        return (h - t + capacity) & mask
    }

    /// Number of slots available to write.
    public var availableToWrite: Int {
        capacity - 1 - availableToRead  // -1 to distinguish full from empty
    }

    /// Whether the buffer is empty.
    public var isEmpty: Bool {
        head.load(ordering: .acquiring) == tail.load(ordering: .relaxed)
    }

    /// Whether the buffer is full.
    public var isFull: Bool {
        availableToWrite == 0
    }

    /// Total capacity of the buffer.
    public var bufferCapacity: Int { capacity }

    // MARK: - Statistics

    /// Statistics for monitoring buffer performance.
    public struct Statistics {
        public let totalWrites: UInt64
        public let totalReads: UInt64
        public let totalDrops: UInt64
        public let currentSize: Int
        public let capacity: Int

        public var dropRate: Double {
            guard totalWrites > 0 else { return 0 }
            return Double(totalDrops) / Double(totalWrites + totalDrops)
        }
    }

    public var statistics: Statistics {
        Statistics(
            totalWrites: writeCount.load(ordering: .relaxed),
            totalReads: readCount.load(ordering: .relaxed),
            totalDrops: dropCount.load(ordering: .relaxed),
            currentSize: availableToRead,
            capacity: capacity
        )
    }

    // MARK: - Helpers

    private static func nextPowerOf2(_ n: Int) -> Int {
        var v = n - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v |= v >> 32
        return v + 1
    }
}

// MARK: - Byte Buffer Specialization

/// Optimized ring buffer for raw byte data from PTY.
public final class LockFreeByteBuffer {
    private let storage: UnsafeMutableRawPointer
    private let capacity: Int
    private let mask: Int

    private let head: ManagedAtomic<Int>
    private let tail: ManagedAtomic<Int>

    public init(capacity requestedCapacity: Int) {
        let actualCapacity = Self.nextPowerOf2(max(4096, requestedCapacity))
        self.capacity = actualCapacity
        self.mask = actualCapacity - 1

        // Page-aligned allocation for better cache behavior
        self.storage = UnsafeMutableRawPointer.allocate(
            byteCount: actualCapacity,
            alignment: 4096  // Page size
        )

        self.head = ManagedAtomic(0)
        self.tail = ManagedAtomic(0)
    }

    deinit {
        storage.deallocate()
    }

    /// Writes bytes directly from PTY read buffer.
    /// Uses memcpy for bulk transfer when possible.
    public func write(from source: UnsafeRawPointer, count: Int) -> Int {
        let currentHead = head.load(ordering: .relaxed)
        let currentTail = tail.load(ordering: .acquiring)

        let available = (currentTail - currentHead - 1 + capacity) & mask
        let toWrite = min(count, available)

        guard toWrite > 0 else { return 0 }

        let firstChunk = min(toWrite, capacity - currentHead)
        let secondChunk = toWrite - firstChunk

        // Copy first chunk (up to end of buffer)
        memcpy(storage.advanced(by: currentHead), source, firstChunk)

        // Copy second chunk (wrap around to beginning)
        if secondChunk > 0 {
            memcpy(storage, source.advanced(by: firstChunk), secondChunk)
        }

        head.store((currentHead + toWrite) & mask, ordering: .releasing)
        return toWrite
    }

    /// Reads bytes directly into destination buffer.
    public func read(into destination: UnsafeMutableRawPointer, maxCount: Int) -> Int {
        let currentTail = tail.load(ordering: .relaxed)
        let currentHead = head.load(ordering: .acquiring)

        let available = (currentHead - currentTail + capacity) & mask
        let toRead = min(maxCount, available)

        guard toRead > 0 else { return 0 }

        let firstChunk = min(toRead, capacity - currentTail)
        let secondChunk = toRead - firstChunk

        // Copy first chunk
        memcpy(destination, storage.advanced(by: currentTail), firstChunk)

        // Copy second chunk (wrap around)
        if secondChunk > 0 {
            memcpy(destination.advanced(by: firstChunk), storage, secondChunk)
        }

        tail.store((currentTail + toRead) & mask, ordering: .releasing)
        return toRead
    }

    /// Provides direct read access without copying (for SIMD processing).
    /// The returned pointer is valid until the next read operation.
    public func peekContiguous() -> (pointer: UnsafeRawPointer, count: Int)? {
        let currentTail = tail.load(ordering: .relaxed)
        let currentHead = head.load(ordering: .acquiring)

        guard currentTail != currentHead else { return nil }

        // Return contiguous chunk from tail to either head or end of buffer
        let contiguous: Int = currentHead > currentTail
            ? currentHead - currentTail
            : capacity - currentTail

        let pointer: UnsafeRawPointer = UnsafeRawPointer(storage.advanced(by: currentTail))
        return (pointer: pointer, count: contiguous)
    }

    /// Advances read position after peek.
    public func advanceRead(by count: Int) {
        let currentTail = tail.load(ordering: .relaxed)
        tail.store((currentTail + count) & mask, ordering: .releasing)
    }

    /// Writes bytes from an UnsafeBufferPointer.
    public func write(from buffer: UnsafeBufferPointer<UInt8>) -> Int {
        guard let baseAddress = buffer.baseAddress else { return 0 }
        return write(from: baseAddress, count: buffer.count)
    }

    // MARK: - Properties

    /// Total capacity of the buffer in bytes.
    public var bufferCapacity: Int {
        capacity
    }

    /// Number of bytes available to read.
    public var count: Int {
        let h = head.load(ordering: .acquiring)
        let t = tail.load(ordering: .relaxed)
        return (h - t + capacity) & mask
    }

    /// Number of bytes that can be written.
    public var availableSpace: Int {
        let currentHead = head.load(ordering: .relaxed)
        let currentTail = tail.load(ordering: .acquiring)
        return (currentTail - currentHead - 1 + capacity) & mask
    }

    public var availableToRead: Int {
        count
    }

    public var isEmpty: Bool {
        head.load(ordering: .acquiring) == tail.load(ordering: .relaxed)
    }

    private static func nextPowerOf2(_ n: Int) -> Int {
        var v = n - 1
        v |= v >> 1
        v |= v >> 2
        v |= v >> 4
        v |= v >> 8
        v |= v >> 16
        v |= v >> 32
        return v + 1
    }
}
