import XCTest
import Chau7Core

@testable import Chau7

final class TerminalViewRepresentableTests: XCTestCase {
    func testRenderPhaseCoordinatorTracksOnlyRealPhaseTransitions() {
        let coordinator = TerminalViewRepresentable.Coordinator()

        coordinator.seedRenderPhase(.warm)

        XCTAssertFalse(coordinator.consumeRenderPhaseChange(to: .warm))
        XCTAssertTrue(coordinator.consumeRenderPhaseChange(to: .active))
        XCTAssertFalse(coordinator.consumeRenderPhaseChange(to: .active))
    }

    func testRenderPhaseCoordinatorDetectsHideAfterReactivation() {
        let coordinator = TerminalViewRepresentable.Coordinator()

        coordinator.seedRenderPhase(.hidden)

        XCTAssertFalse(coordinator.consumeRenderPhaseChange(to: .hidden))
        XCTAssertTrue(coordinator.consumeRenderPhaseChange(to: .warm))
        XCTAssertTrue(coordinator.consumeRenderPhaseChange(to: .hidden))
    }
}
