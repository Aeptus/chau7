import XCTest
@testable import Chau7
@testable import Chau7Core

final class PersistentHistoryStoreQueueTests: XCTestCase {
    func testClearAllSerializesWithQueuedAsyncInserts() {
        let store = PersistentHistoryStore(path: ":memory:")
        store.maxRecords = 100

        for i in 0 ..< 10 {
            store.insert(HistoryRecord(
                command: "queued-\(i)",
                timestamp: Date().addingTimeInterval(Double(i))
            ))
        }

        store.clearAll()
        store.waitForPendingWrites()

        XCTAssertEqual(store.totalCount(), 0)
        XCTAssertTrue(store.recent(limit: 10).isEmpty)
    }

    func testClearOlderThanKeepsCachedCountInSyncSoTrimCannotOverDelete() {
        // Regression: clearOlderThan deleted rows without decrementing the
        // cached count, so a later trimIfNeeded computed a phantom excess and
        // deleted valid (even brand-new) records.
        let store = PersistentHistoryStore(path: ":memory:")
        store.maxRecords = 10

        for i in 0 ..< 10 {
            store.insertSync(HistoryRecord(
                command: "old-\(i)",
                timestamp: Date().addingTimeInterval(-30 * 86400)
            ))
        }
        XCTAssertEqual(store.totalCount(), 10)

        store.clearOlderThan(days: 7)
        XCTAssertEqual(store.totalCount(), 0)

        // Under the stale cached count (10), this insert pushed the phantom
        // total to 11 > maxRecords and trim deleted the new record itself.
        store.insertSync(HistoryRecord(command: "fresh", timestamp: Date()))

        XCTAssertEqual(store.totalCount(), 1)
        XCTAssertEqual(store.recent(limit: 10).first?.command, "fresh")
    }

    func testClearOlderThanKeepsNewerRecords() {
        let store = PersistentHistoryStore(path: ":memory:")
        store.maxRecords = 100

        store.insertSync(HistoryRecord(command: "ancient", timestamp: Date().addingTimeInterval(-30 * 86400)))
        store.insertSync(HistoryRecord(command: "recent", timestamp: Date()))

        store.clearOlderThan(days: 7)

        let remaining = store.recent(limit: 10)
        XCTAssertEqual(remaining.map(\.command), ["recent"])
    }

    func testImportJSONTrimsOnceAtEndAndCountsStayConsistent() throws {
        let store = PersistentHistoryStore(path: ":memory:")
        store.maxRecords = 5

        let records = (0 ..< 8).map { i in
            HistoryRecord(command: "import-\(i)", timestamp: Date().addingTimeInterval(Double(i)))
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(records)

        XCTAssertEqual(store.importJSON(data), 8)
        XCTAssertEqual(store.totalCount(), 5)
        // The oldest three were trimmed; the newest five survive.
        XCTAssertEqual(store.recent(limit: 10).map(\.command).sorted(),
                       ["import-3", "import-4", "import-5", "import-6", "import-7"])
    }
}
