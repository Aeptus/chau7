import XCTest
@testable import Chau7Core

final class SelectedTabRevealPolicyTests: XCTestCase {
    func testSelectionChangeWithLiveAttachedSurfaceUsesInPlaceRefresh() {
        XCTAssertEqual(
            SelectedTabRefreshPolicy.action(
                for: SelectedTabRevealRequest(
                    trigger: .selectionChange,
                    keepsVisibleSurface: true,
                    hasAttachedRenderer: true,
                    isCurrentlyLivePresentable: true
                )
            ),
            .liveRepaintInPlace
        )
    }

    func testSelectionChangeWithoutLiveSurfaceUsesBlockingAuthoritativeReveal() {
        XCTAssertEqual(
            SelectedTabRefreshPolicy.action(
                for: SelectedTabRevealRequest(
                    trigger: .selectionChange,
                    keepsVisibleSurface: true,
                    hasAttachedRenderer: false,
                    isCurrentlyLivePresentable: false
                )
            ),
            .authoritativeReveal(shouldAwaitVisibleFrame: true)
        )
    }

    func testExplicitRefreshStillUsesAuthoritativeRevealEvenWhenSurfaceIsLive() {
        XCTAssertEqual(
            SelectedTabRefreshPolicy.action(
                for: SelectedTabRevealRequest(
                    trigger: .explicitRefresh,
                    keepsVisibleSurface: true,
                    hasAttachedRenderer: true,
                    isCurrentlyLivePresentable: true
                )
            ),
            .authoritativeReveal(shouldAwaitVisibleFrame: true)
        )
    }

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

    func testSelectionChangeWithLiveAttachedSurfaceStaysNonBlocking() {
        XCTAssertFalse(
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

    func testSelectionChangeWithoutAttachedRendererRemainsBlocking() {
        XCTAssertTrue(
            SelectedTabRevealPolicy.shouldAwaitVisibleFrame(
                for: SelectedTabRevealRequest(
                    trigger: .selectionChange,
                    keepsVisibleSurface: true,
                    hasAttachedRenderer: false,
                    isCurrentlyLivePresentable: false
                )
            )
        )
    }

    func testRestoreBootstrapForLiveAttachedSurfaceStaysNonBlocking() {
        XCTAssertFalse(
            SelectedTabRevealPolicy.shouldAwaitVisibleFrame(
                for: SelectedTabRevealRequest(
                    trigger: .restoreBootstrap,
                    keepsVisibleSurface: true,
                    hasAttachedRenderer: true,
                    isCurrentlyLivePresentable: true
                )
            )
        )
    }

    func testRestoreBootstrapWithoutLiveSurfaceStillBlocks() {
        XCTAssertTrue(
            SelectedTabRevealPolicy.shouldAwaitVisibleFrame(
                for: SelectedTabRevealRequest(
                    trigger: .restoreBootstrap,
                    keepsVisibleSurface: true,
                    hasAttachedRenderer: false,
                    isCurrentlyLivePresentable: false
                )
            )
        )
    }

    func testRestoreBootstrapWithLiveAttachedSurfaceUsesInPlaceRefresh() {
        XCTAssertEqual(
            SelectedTabRefreshPolicy.action(
                for: SelectedTabRevealRequest(
                    trigger: .restoreBootstrap,
                    keepsVisibleSurface: true,
                    hasAttachedRenderer: true,
                    isCurrentlyLivePresentable: true
                )
            ),
            .liveRepaintInPlace
        )
    }
}
