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
}
