import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class AppModelEventRoutingTests: XCTestCase {
    func testRecordEventEagerlyResolvesTabIDFromSessionContext() {
        let model = AppModel()
        let expectedTabID = UUID()
        var capturedTarget: TabTarget?

        model.tabIDResolver = { target in
            capturedTarget = target
            return expectedTabID
        }

        model.recordEvent(
            source: .historyMonitor,
            type: "finished",
            tool: "Codex",
            message: "Codex finished",
            notify: false,
            directory: "/tmp/chau7",
            sessionID: "019d25d0-d0bd-7501-99ba-1f937c17b29b"
        )

        let expectationDone = expectation(description: "recordEvent appended on main queue")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(
                capturedTarget,
                TabTarget(
                    tool: "Codex",
                    directory: "/tmp/chau7",
                    tabID: nil,
                    sessionID: "019d25d0-d0bd-7501-99ba-1f937c17b29b"
                )
            )
            XCTAssertEqual(model.recentEvents.last?.tabID, expectedTabID)
            expectationDone.fulfill()
        }

        wait(for: [expectationDone], timeout: 1.0)
    }

    func testRecordEventDoesNotReResolveExplicitTabID() {
        let model = AppModel()
        let explicitTabID = UUID()
        var resolverCallCount = 0

        model.tabIDResolver = { _ in
            resolverCallCount += 1
            return UUID()
        }

        model.recordEvent(
            source: .terminalSession,
            type: "finished",
            tool: "Codex",
            message: "done",
            notify: false,
            directory: "/tmp/chau7",
            tabID: explicitTabID,
            sessionID: "019d25d0-d0bd-7501-99ba-1f937c17b29b"
        )

        let expectationDone = expectation(description: "recordEvent kept explicit tab id")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            XCTAssertEqual(resolverCallCount, 0)
            XCTAssertEqual(model.recentEvents.last?.tabID, explicitTabID)
            expectationDone.fulfill()
        }

        wait(for: [expectationDone], timeout: 1.0)
    }
}
#endif
