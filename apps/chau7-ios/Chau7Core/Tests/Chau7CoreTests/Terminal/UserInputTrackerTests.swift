import XCTest
@testable import Chau7Core

final class UserInputTrackerTests: XCTestCase {
    func testVisibleRowsCanFilterBySource() {
        let tracker = UserInputTracker(maxEntries: 10)
        tracker.record(row: 5, source: .user, timestamp: .distantPast)
        tracker.record(row: 8, source: .agent, timestamp: .distantPast)
        tracker.record(row: 9, source: .system, timestamp: .distantPast)

        XCTAssertEqual(tracker.visibleRows(top: 0, bottom: 10), [5, 8, 9])
        XCTAssertEqual(tracker.visibleRows(top: 0, bottom: 10, source: .agent), [8])
        XCTAssertEqual(tracker.visibleRows(top: 0, bottom: 10, source: .system), [9])
    }

    func testTrackerPrunesOldestRowsWhenOverCapacity() {
        let tracker = UserInputTracker(maxEntries: 2)
        tracker.record(row: 1, source: .user, timestamp: .distantPast)
        tracker.record(row: 2, source: .agent, timestamp: .distantPast)
        tracker.record(row: 3, source: .system, timestamp: .distantPast)

        XCTAssertEqual(tracker.sortedRecords().map(\.row), [2, 3])
    }
}
