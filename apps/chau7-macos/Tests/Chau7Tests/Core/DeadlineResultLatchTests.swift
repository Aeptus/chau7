import XCTest
import Chau7Core

final class DeadlineResultLatchTests: XCTestCase {
    func testCompletedValueAndOptionalNilAreDistinctFromTimeout() {
        let latch = DeadlineResultLatch<Int>(timeout: 1)
        XCTAssertTrue(latch.begin())
        XCTAssertFalse(latch.begin())
        latch.complete(42)
        XCTAssertEqual(latch.wait(), 42)
        let optional = DeadlineResultLatch<Int?>(timeout: 1)
        XCTAssertTrue(optional.begin())
        optional.complete(nil)
        let result = optional.wait()
        XCTAssertNotNil(result as Any?)
        XCTAssertNil(result!)
    }

    func testTimedOutQueuedWorkCannotBegin() {
        let latch = DeadlineResultLatch<Int>(timeout: 0.01)
        let start = Date()
        XCTAssertNil(latch.wait())
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertFalse(latch.begin())
        latch.complete(42)
        XCTAssertNil(latch.wait())
    }

    func testRunningWorkCannotPublishAfterCallerExpires() {
        let latch = DeadlineResultLatch<Int>(timeout: 0.01)
        XCTAssertTrue(latch.begin())
        XCTAssertNil(latch.wait())
        latch.complete(42)
        XCTAssertNil(latch.wait())
    }
}
