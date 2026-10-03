import XCTest
import Chau7Core

final class LockedCacheTests: XCTestCase {
    func testConcurrentRequestsCreateExactlyOneCompleteValue() {
        let cache = LockedCache<String, Int>()
        var creations = 0
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            XCTAssertEqual(cache.value(for: "device-a") { creations += 1
                return creations
            }, 1)
        }
        XCTAssertEqual(creations, 1)
    }

    func testDistinctDeviceKeysDoNotShareResources() {
        let cache = LockedCache<String, Int>()
        XCTAssertEqual(cache.value(for: "device-a") { 1 }, 1)
        XCTAssertEqual(cache.value(for: "device-b") { 2 }, 2)
        XCTAssertEqual(cache.value(for: "device-a") { 3 }, 1)
    }

    func testFailedFactoryDoesNotPublishPartialResources() throws {
        enum Failure: Error { case compilation }
        let cache = LockedCache<String, Int>()
        XCTAssertThrowsError(try cache.value(for: "device") { throw Failure.compilation })
        XCTAssertEqual(cache.value(for: "device") { 42 }, 42)
    }
}
