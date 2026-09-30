import XCTest
@testable import Chau7

@MainActor
final class MainActorBridgeTests: XCTestCase {
    func testMainThreadCallReturnsWithoutRedispatching() {
        XCTAssertEqual(MainActorBridge.sync { Thread.isMainThread ? 42 : 0 }, 42)
    }

    func testBackgroundCallRunsOnMainAndReturnsToCaller() async {
        let task = Task.detached {
            let startedOffMain = !Thread.isMainThread
            let ranOnMain = MainActorBridge.sync { Thread.isMainThread }
            return startedOffMain && ranOnMain && !Thread.isMainThread
        }
        let result = await task.value
        XCTAssertTrue(result)
    }
}
