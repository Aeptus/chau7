import XCTest
@testable import Chau7

@MainActor
final class MainActorBridgeTests: XCTestCase {
    func testExpiredQueuedReadIsSkippedWhenMainRecovers() async {
        let readFinished = DispatchSemaphore(value: 0)
        var executed = false
        DispatchQueue.global().async {
            let value = MainActorBridge.read(timeout: 0.02) {
                executed = true
                return 42
            }
            XCTAssertNil(value)
            readFinished.signal()
        }
        // Block only this isolated test main queue until the background caller returns.
        XCTAssertEqual(readFinished.wait(timeout: .now() + 2), .success)
        let drained = expectation(description: "queued expired read drained")
        DispatchQueue.main.async { drained.fulfill() }
        await fulfillment(of: [drained], timeout: 2)
        XCTAssertFalse(executed)
    }

    func testBoundedReadPreservesNilResultAndRunsOnMain() async {
        let task = Task.detached { MainActorBridge.read { Thread.isMainThread ? 42 : 0 } }
        let value = await task.value
        XCTAssertEqual(value, 42)
    }

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

    func testSynchronousMutationReturnsCommittedResultAfterReadDeadline() async {
        let request = Task.detached {
            MainActorBridge.sync {
                Thread.sleep(forTimeInterval: MainActorBridge.readTimeout + 0.05)
                return "committed"
            }
        }
        let result = await request.value
        XCTAssertEqual(result, "committed")
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
