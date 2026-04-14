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

        XCTAssertEqual(readiness, TabExecutionReadiness(isReady: true, reason: .ready))
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

        XCTAssertEqual(readiness, TabExecutionReadiness(isReady: false, reason: .exited))
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

        XCTAssertEqual(readiness, TabExecutionReadiness(isReady: false, reason: .shellLoading))
    }

    func testMissingViewBlocksReadiness() {
        let readiness = TabExecutionReadiness.evaluate(
            snapshot: TabExecutionReadinessSnapshot(
                shellLoading: false,
                isAtPrompt: true,
                hasView: false,
                status: "idle"
            )
        )

        XCTAssertEqual(readiness, TabExecutionReadiness(isReady: false, reason: .viewUnattached))
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

        XCTAssertEqual(readiness, TabExecutionReadiness(isReady: false, reason: .notAtPrompt))
    }
}
