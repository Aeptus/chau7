import XCTest
import AppKit
import Chau7Core

@testable import Chau7

final class TerminalViewRepresentableTests: XCTestCase {
    func testRendererSyncCallbackIsIndependentFromSessionBufferCallback() {
        let view = RustTerminalView(frame: .zero)
        var events: [String] = []
        view.onBufferChanged = {
            events.append("base")
        }
        view.onDisplaySyncNeeded = {
            events.append("metal")
        }

        view.onBufferChanged?()
        view.onDisplaySyncNeeded?()

        XCTAssertEqual(events, ["base", "metal"])
    }

    func testRendererPresentationCallbackIsIndependentFromSessionFrameCallback() {
        let view = RustTerminalView(frame: .zero)
        var events: [String] = []
        view.onDisplayFramePresented = {
            events.append("metal")
        }
        view.onFramePresented = {
            events.append("base")
        }

        view.onDisplayFramePresented?()
        view.onFramePresented?()

        XCTAssertEqual(events, ["metal", "base"])
    }

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

    func testDismantleDemotesRetainedTerminalViewOutOfLivePolling() {
        let view = RustTerminalView(frame: .zero)
        let container = UnifiedTerminalContainerView(rustView: view)

        view.applyRenderPhase(.active, isInteractive: true, reason: "test")
        view.isHidden = false

        TerminalViewRepresentable.dismantleNSView(
            container,
            coordinator: TerminalViewRepresentable.Coordinator()
        )

        XCTAssertEqual(view.currentRenderPhase, .hidden)
        XCTAssertFalse(view.notifyUpdateChanges)
        XCTAssertTrue(view.isHidden)
        XCTAssertEqual(view.currentRenderLoopMode, "background_drain")
    }
}
