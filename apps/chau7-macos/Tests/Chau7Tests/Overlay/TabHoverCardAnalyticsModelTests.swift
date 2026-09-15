import Foundation
import XCTest
@testable import Chau7
@testable import Chau7Core

final class TabHoverCardAnalyticsModelTests: XCTestCase {
    func testCompletionForObsoleteTabIsDiscarded() {
        let firstLoadStarted = expectation(description: "first tab load started")
        let releaseFirstLoad = DispatchSemaphore(value: 0)
        let loadQueue = DispatchQueue(
            label: "com.chau7.tests.hover-card-analytics",
            attributes: .concurrent
        )
        let model = TabHoverCardAnalyticsModel(loadQueue: loadQueue) { tabID in
            if tabID == "tab-a" {
                firstLoadStarted.fulfill()
                _ = releaseFirstLoad.wait(timeout: .now() + 1)
                return Self.snapshot(runID: "run-a", tool: "old-tool")
            }
            return Self.snapshot(runID: "run-b", tool: "current-tool")
        }

        model.refresh(tabID: "tab-a")
        wait(for: [firstLoadStarted], timeout: 1)
        model.refresh(tabID: "tab-b")

        XCTAssertTrue(waitUntil { model.completedRun?.id == "run-b" })
        releaseFirstLoad.signal()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))

        XCTAssertEqual(model.completedRun?.id, "run-b")
        XCTAssertEqual(model.topTools, [.init(tool: "current-tool", count: 1)])
    }

    private static func snapshot(runID: String, tool: String) -> TabHoverCardAnalyticsModel.Snapshot {
        TabHoverCardAnalyticsModel.Snapshot(
            completedRun: TelemetryRun(
                id: runID,
                provider: "test",
                cwd: "/repos/test"
            ),
            topTools: [.init(tool: tool, count: 1)]
        )
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
