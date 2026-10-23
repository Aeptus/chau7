import XCTest
@testable import Chau7Core

final class TabExecutionReadinessTests: XCTestCase {
    func testReadyWhenPromptVisibleAndViewAttached() {
        let readiness = TabExecutionReadiness.evaluate(
            snapshot: TabExecutionReadinessSnapshot(
                shellLoading: false,
                isAtPrompt: true,
                hasView: true,
                status: "running"
            )
        )

        XCTAssertEqual(
            readiness,
            TabExecutionReadiness(
                isReady: true,
                canAcceptExec: true,
                acceptanceMode: .immediate,
                reason: .ready
            )
        )
    }

    func testExitedWinsOverOtherSignals() {
        let readiness = TabExecutionReadiness.evaluate(
            snapshot: TabExecutionReadinessSnapshot(
                shellLoading: false,
                isAtPrompt: false,
                hasView: true,
                status: "exited"
            )
        )

        XCTAssertEqual(
            readiness,
            TabExecutionReadiness(
                isReady: false,
                canAcceptExec: false,
                acceptanceMode: .blocked,
                reason: .exited
            )
        )
    }

    func testShellLoadingBlocksReadiness() {
        let readiness = TabExecutionReadiness.evaluate(
            snapshot: TabExecutionReadinessSnapshot(
                shellLoading: true,
                isAtPrompt: true,
                hasView: true,
                status: "idle"
            )
        )

        XCTAssertEqual(
            readiness,
            TabExecutionReadiness(
                isReady: false,
                canAcceptExec: true,
                acceptanceMode: .queued,
                reason: .shellLoading
            )
        )
    }

    func testMissingViewQueuesInsteadOfBlockingExecAcceptance() {
        let readiness = TabExecutionReadiness.evaluate(
            snapshot: TabExecutionReadinessSnapshot(
                shellLoading: false,
                isAtPrompt: true,
                hasView: false,
                status: "idle"
            )
        )

        XCTAssertEqual(
            readiness,
            TabExecutionReadiness(
                isReady: false,
                canAcceptExec: true,
                acceptanceMode: .queued,
                reason: .viewUnattached
            )
        )
    }

    func testMissingPromptBlocksReadiness() {
        let readiness = TabExecutionReadiness.evaluate(
            snapshot: TabExecutionReadinessSnapshot(
                shellLoading: false,
                isAtPrompt: false,
                hasView: true,
                status: "running"
            )
        )

        XCTAssertEqual(
            readiness,
            TabExecutionReadiness(
                isReady: false,
                canAcceptExec: false,
                acceptanceMode: .blocked,
                reason: .notAtPrompt
            )
        )
    }
}
