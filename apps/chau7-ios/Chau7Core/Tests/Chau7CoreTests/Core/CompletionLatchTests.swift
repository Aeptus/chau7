import Foundation
import XCTest
@testable import Chau7Core

/// Minimal lock-guarded counter for the concurrency assertions below, so the
/// tests do not need a separate atomics import.
private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Int

    init(_ initial: Int) {
        self.storage = initial
    }

    func increment() {
        lock.lock()
        storage += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

final class CompletionLatchTests: XCTestCase {
    func testStartsOpen() {
        XCTAssertTrue(CompletionLatch().shouldProceed())
    }

    func testLatchingStopsLaterAttempts() {
        let latch = CompletionLatch()
        XCTAssertTrue(latch.shouldProceed())
        latch.latch()
        XCTAssertFalse(latch.shouldProceed())
        XCTAssertFalse(latch.shouldProceed())
    }

    /// The contract callers depend on: an attempt that reports no outcome must
    /// leave the latch open so a later scheduled retry can still try. This is
    /// what makes `.skipped` non-terminal in the transcript-repair chain.
    func testNotLatchingKeepsProceeding() {
        let latch = CompletionLatch()
        XCTAssertTrue(latch.shouldProceed())
        XCTAssertTrue(latch.shouldProceed())
        XCTAssertTrue(latch.shouldProceed())
    }

    func testLatchIsIdempotent() {
        let latch = CompletionLatch()
        latch.latch()
        latch.latch()
        XCTAssertFalse(latch.shouldProceed())
    }

    func testLatchIfOpenReportsOnlyTheFirstWinner() {
        let latch = CompletionLatch()
        XCTAssertTrue(latch.latchIfOpen())
        XCTAssertFalse(latch.latchIfOpen())
        XCTAssertFalse(latch.shouldProceed())
    }

    /// The latch is shared by closures on a serial queue today, but its
    /// contract is thread-safe regardless of how callers are scheduled.
    func testConcurrentLatchingYieldsExactlyOneWinner() {
        let latch = CompletionLatch()
        let winners = LockedCounter(0)

        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if latch.latchIfOpen() {
                winners.increment()
            }
        }

        XCTAssertEqual(winners.value, 1)
        XCTAssertFalse(latch.shouldProceed())
    }

    func testConcurrentProceedReadsAreSafeWhileLatching() {
        let latch = CompletionLatch()
        let sawOpen = LockedCounter(0)

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if latch.shouldProceed() {
                sawOpen.increment()
            }
            if index == 100 {
                latch.latch()
            }
        }

        // Whether a given iteration observed the open state is a scheduling
        // detail; the invariants are that no read was torn and that the latch
        // ends closed.
        XCTAssertGreaterThan(sawOpen.value, 0)
        XCTAssertFalse(latch.shouldProceed())
    }
}
