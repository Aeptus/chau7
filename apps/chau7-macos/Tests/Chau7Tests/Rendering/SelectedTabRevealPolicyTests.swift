import XCTest
@testable import Chau7Core

final class SelectedTabRevealPolicyTests: XCTestCase {
    func testReactivationOfLiveAttachedSurfaceStaysNonBlocking() {
        XCTAssertFalse(
            SelectedTabRevealPolicy.shouldAwaitVisibleFrame(
                for: SelectedTabRevealRequest(
                    trigger: .reactivation,
                    keepsVisibleSurface: true,
                    hasAttachedRenderer: true,
                    isCurrentlyLivePresentable: true
                )
            )
        )
    }

    func testReactivationWithoutAttachedRendererRemainsBlocking() {
        XCTAssertTrue(
            SelectedTabRevealPolicy.shouldAwaitVisibleFrame(
                for: SelectedTabRevealRequest(
                    trigger: .reactivation,
                    keepsVisibleSurface: true,
                    hasAttachedRenderer: false,
                    isCurrentlyLivePresentable: true
                )
            )
        )
    }

    func testSelectionChangeStillBlocksUntilFreshFrame() {
        XCTAssertTrue(
            SelectedTabRevealPolicy.shouldAwaitVisibleFrame(
                for: SelectedTabRevealRequest(
                    trigger: .selectionChange,
                    keepsVisibleSurface: true,
                    hasAttachedRenderer: true,
                    isCurrentlyLivePresentable: true
                )
            )
        )
    }
}
