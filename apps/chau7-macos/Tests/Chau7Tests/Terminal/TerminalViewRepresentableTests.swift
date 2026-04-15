import XCTest
import Chau7Core

@testable import Chau7

final class TerminalViewRepresentableTests: XCTestCase {
    func testRenderPhaseCoordinatorTracksOnlyRealPhaseTransitions() {
        let coordinator = TerminalViewRepresentable.Coordinator()

        coordinator.seedRenderPhase(.warm)

        XCTAssertEqual(coordinator.consumeRenderPhaseTransition(to: .warm).previous, .warm)
        XCTAssertFalse(coordinator.consumeRenderPhaseTransition(to: .warm).changed)
        XCTAssertEqual(coordinator.consumeRenderPhaseTransition(to: .active).previous, .warm)
        XCTAssertTrue(coordinator.consumeRenderPhaseTransition(to: .hidden).changed)
    }

    func testRenderPhaseCoordinatorDetectsHideAfterReactivation() {
        let coordinator = TerminalViewRepresentable.Coordinator()

        coordinator.seedRenderPhase(.hidden)

        XCTAssertFalse(coordinator.consumeRenderPhaseTransition(to: .hidden).changed)
        XCTAssertTrue(coordinator.consumeRenderPhaseTransition(to: .warm).changed)
        XCTAssertTrue(coordinator.consumeRenderPhaseTransition(to: .hidden).changed)
    }
}
