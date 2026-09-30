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

    func testRunOnMainExecutesInline() {
        var ran = false
        MainActorBridge.run { ran = true }
        XCTAssertTrue(ran)
    }

    /// Regression: observer side effects (e.g. `liveAgentName` didSet reached
    /// from `deinit`) can fire off-main; `run` must hop instead of trapping.
    func testRunOffMainHopsToMainWithoutTrapping() async {
        let ranOnMain = expectation(description: "block ran on main")
        DispatchQueue(label: "test.main-actor-bridge.run").async {
            MainActorBridge.run {
                XCTAssertTrue(Thread.isMainThread)
                ranOnMain.fulfill()
            }
        }
        await fulfillment(of: [ranOnMain], timeout: 5)
    }
}
