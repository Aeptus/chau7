import Foundation
import XCTest
@testable import Chau7

final class RepositoryStatsCacheTests: XCTestCase {
    func testRepeatedRequestsInsideTTLUseCachedSnapshot() {
        let calls = StatsLockedCounter()
        let clock = StatsTestClock()
        let model = RepositoryModel(
            rootPath: "/repos/main",
            statsTTL: 30,
            statsLoader: { _ in
                calls.increment()
                return .empty
            },
            now: clock.read
        )

        model.refreshStatsIfNeeded()
        XCTAssertTrue(waitUntil { model.stats != nil })

        model.refreshStatsIfNeeded()
        model.refreshStatsIfNeeded()

        XCTAssertEqual(calls.value, 1)
    }

    func testRequestsCoalesceWhileRefreshIsInFlight() {
        let calls = StatsLockedCounter()
        let loadStarted = expectation(description: "stats load started")
        let releaseLoad = DispatchSemaphore(value: 0)
        let model = RepositoryModel(
            rootPath: "/repos/main",
            statsLoader: { _ in
                calls.increment()
                loadStarted.fulfill()
                _ = releaseLoad.wait(timeout: .now() + 1)
                return .empty
            }
        )

        model.refreshStatsIfNeeded()
        wait(for: [loadStarted], timeout: 1)
        model.refreshStatsIfNeeded()
        model.refreshStatsIfNeeded(force: true)
        releaseLoad.signal()

        XCTAssertTrue(waitUntil { model.stats != nil })
        XCTAssertEqual(calls.value, 1)
    }

    func testExpiredAndDirtySnapshotsRefreshOnDemand() {
        let calls = StatsLockedCounter()
        let clock = StatsTestClock()
        let model = RepositoryModel(
            rootPath: "/repos/main",
            statsTTL: 30,
            statsLoader: { _ in
                calls.increment()
                return .empty
            },
            now: clock.read
        )

        model.refreshStatsIfNeeded()
        XCTAssertTrue(waitUntil { calls.value == 1 && model.stats != nil })

        clock.advance(by: 31)
        model.refreshStatsIfNeeded()
        XCTAssertTrue(waitUntil { calls.value == 2 })

        model.invalidateStats()
        model.refreshStatsIfNeeded()
        XCTAssertTrue(waitUntil { calls.value == 3 })
    }

    func testStaleSnapshotSurvivesInFlightAndFailedRefresh() {
        let calls = StatsLockedCounter()
        let secondLoadStarted = expectation(description: "second stats load started")
        let releaseSecondLoad = DispatchSemaphore(value: 0)
        let model = RepositoryModel(
            rootPath: "/repos/main",
            statsLoader: { _ in
                calls.increment()
                guard calls.value > 1 else { return .empty }
                secondLoadStarted.fulfill()
                _ = releaseSecondLoad.wait(timeout: .now() + 1)
                return nil
            }
        )

        model.refreshStatsIfNeeded()
        XCTAssertTrue(waitUntil { model.stats != nil })

        model.refreshStatsIfNeeded(force: true)
        wait(for: [secondLoadStarted], timeout: 1)
        XCTAssertNotNil(model.stats, "last-known data must remain visible during refresh")

        releaseSecondLoad.signal()
        XCTAssertTrue(waitUntil { calls.value == 2 })
        XCTAssertNotNil(model.stats, "a failed refresh must preserve last-known data")
    }

    func testInvalidationDuringRefreshIsNotLostByCompletion() {
        let calls = StatsLockedCounter()
        let secondLoadStarted = expectation(description: "second stats load started")
        let releaseSecondLoad = DispatchSemaphore(value: 0)
        let model = RepositoryModel(
            rootPath: "/repos/main",
            statsLoader: { _ in
                calls.increment()
                if calls.value == 2 {
                    secondLoadStarted.fulfill()
                    _ = releaseSecondLoad.wait(timeout: .now() + 1)
                }
                return .empty
            }
        )

        model.refreshStatsIfNeeded()
        XCTAssertTrue(waitUntil { model.stats != nil })

        model.refreshStatsIfNeeded(force: true)
        wait(for: [secondLoadStarted], timeout: 1)
        model.invalidateStats()
        releaseSecondLoad.signal()

        XCTAssertTrue(waitUntil {
            model.refreshStatsIfNeeded()
            return calls.value == 3
        }, "a newer invalidation must survive an older refresh completion")
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        return condition()
    }
}

private final class StatsLockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

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

private final class StatsTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_750_000_000)

    func read() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(interval)
        lock.unlock()
    }
}
