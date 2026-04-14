import XCTest

@testable import Chau7

final class TerminalViewRepresentableTests: XCTestCase {
    func testSuspensionCoordinatorCapturesOnlyOnTransitionIntoSuspended() {
        let coordinator = TerminalViewRepresentable.Coordinator()

        coordinator.seedSuspensionState(false)

        XCTAssertFalse(coordinator.consumeSuspensionChange(to: false))
        XCTAssertTrue(coordinator.consumeSuspensionChange(to: true))
        XCTAssertFalse(coordinator.consumeSuspensionChange(to: true))
    }

    func testSuspensionCoordinatorRecapturesAfterResumeThenSuspend() {
        let coordinator = TerminalViewRepresentable.Coordinator()

        coordinator.seedSuspensionState(true)

        XCTAssertFalse(coordinator.consumeSuspensionChange(to: true))
        XCTAssertTrue(coordinator.consumeSuspensionChange(to: false))
        XCTAssertTrue(coordinator.consumeSuspensionChange(to: true))
    }
}
