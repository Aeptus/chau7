import XCTest
import Chau7Core
@testable import Chau7

final class RemoteGridSnapshotWorkerTests: XCTestCase {
    func testEncodingRunsOffMainAndReturnsOwnedWireBytes() async {
        let worker = RemoteGridSnapshotWorker()
        let done = expectation(description: "background encoding")
        let update = makeUpdate(full: true, generation: 1)
        worker.encode(update, scope: "first-client/tab") { result in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertNotNil(result.payload)
            XCTAssertEqual(result.generation, 1)
            XCTAssertLessThanOrEqual(result.retainedBytes, RemoteGridSnapshotCache.defaultMaximumBytes)
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: 5)
    }

    func testNewScopeCannotUsePreviousTabOrClientRows() async {
        let worker = RemoteGridSnapshotWorker()
        let first = expectation(description: "first tab")
        worker.encode(makeUpdate(full: true, generation: 1), scope: "first") { result in
            XCTAssertNotNil(result.payload)
            first.fulfill()
        }
        await fulfillment(of: [first], timeout: 5)
        let second = expectation(description: "second tab")
        worker.encode(makeUpdate(full: false, generation: 2), scope: "second") { result in
            XCTAssertNil(result.payload)
            XCTAssertEqual(result.generation, 0)
            second.fulfill()
        }
        await fulfillment(of: [second], timeout: 5)
    }

    private func makeUpdate(full: Bool, generation: UInt64) -> RemoteGridUpdate {
        RemoteGridUpdate(
            baseGeneration: 1, generation: generation, fullRefresh: full, rowIndices: full ? [0] : [],
            snapshot: RemoteTerminalGridSnapshot(
                cols: 1, rows: 1, cursorCol: 0, cursorRow: 0, cursorVisible: true,
                scrollbackRows: 0, displayOffset: 0,
                cells: full ? Data(repeating: 0, count: 20) : Data(), clusters: Data()
            )
        )
    }
}
