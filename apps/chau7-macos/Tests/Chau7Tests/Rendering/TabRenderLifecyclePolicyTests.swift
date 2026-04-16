import XCTest
@testable import Chau7Core

final class TabRenderLifecyclePolicyTests: XCTestCase {
    func testSelectedTabIsActiveAndKeptLive() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: true,
                isInputPriorityWindow: true,
                isWindowVisibleForRendering: true,
                isPreviousLiveTab: false,
                isPrewarming: false,
                hasBackgroundActivity: false,
                isRenderSuspensionEnabled: true,
                isStartupRestoreActive: false,
                hasPendingRestoreBootstrap: false,
                isMCPControlled: false,
                hasAttachedTerminalView: true
            )
        )

        XCTAssertEqual(decision.phase, .active)
        XCTAssertTrue(decision.keepsLiveHierarchy)
        XCTAssertTrue(decision.isInteractive)
    }

    func testPreviousLiveTabStaysWarmAndAttached() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
                isInputPriorityWindow: true,
                isWindowVisibleForRendering: true,
                isPreviousLiveTab: true,
                isPrewarming: false,
                hasBackgroundActivity: false,
                isRenderSuspensionEnabled: true,
                isStartupRestoreActive: false,
                hasPendingRestoreBootstrap: false,
                isMCPControlled: false,
                hasAttachedTerminalView: true
            )
        )

        XCTAssertEqual(decision.phase, .warm)
        XCTAssertTrue(decision.keepsLiveHierarchy)
        XCTAssertFalse(decision.isInteractive)
    }

    func testPrewarmingTabStaysWarmAndAttached() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
                isInputPriorityWindow: true,
                isWindowVisibleForRendering: true,
                isPreviousLiveTab: false,
                isPrewarming: true,
                hasBackgroundActivity: false,
                isRenderSuspensionEnabled: true,
                isStartupRestoreActive: false,
                hasPendingRestoreBootstrap: false,
                isMCPControlled: false,
                hasAttachedTerminalView: true
            )
        )

        XCTAssertEqual(decision.phase, .warm)
        XCTAssertTrue(decision.keepsLiveHierarchy)
        XCTAssertFalse(decision.isInteractive)
    }

    func testBackgroundActivityUsesWarmPhaseAndStaysAttached() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
                isInputPriorityWindow: true,
                isWindowVisibleForRendering: true,
                isPreviousLiveTab: false,
                isPrewarming: false,
                hasBackgroundActivity: true,
                isRenderSuspensionEnabled: true,
                isStartupRestoreActive: false,
                hasPendingRestoreBootstrap: false,
                isMCPControlled: false,
                hasAttachedTerminalView: true
            )
        )

        XCTAssertEqual(decision.phase, .warm)
        XCTAssertTrue(decision.keepsLiveHierarchy)
        XCTAssertFalse(decision.isInteractive)
    }

    func testSelectedVisibleTabStaysActiveWithoutInputOwnership() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: true,
                isInputPriorityWindow: false,
                isWindowVisibleForRendering: true,
                isPreviousLiveTab: false,
                isPrewarming: false,
                hasBackgroundActivity: false,
                isRenderSuspensionEnabled: true,
                isStartupRestoreActive: false,
                hasPendingRestoreBootstrap: false,
                isMCPControlled: false,
                hasAttachedTerminalView: true
            )
        )

        XCTAssertEqual(decision.phase, .active)
        XCTAssertTrue(decision.keepsLiveHierarchy)
        XCTAssertFalse(decision.isInteractive)
    }

    func testSelectedHiddenWindowDropsToWarmWithoutInputOwnership() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: true,
                isInputPriorityWindow: false,
                isWindowVisibleForRendering: false,
                isPreviousLiveTab: false,
                isPrewarming: false,
                hasBackgroundActivity: false,
                isRenderSuspensionEnabled: true,
                isStartupRestoreActive: false,
                hasPendingRestoreBootstrap: false,
                isMCPControlled: false,
                hasAttachedTerminalView: true
            )
        )

        XCTAssertEqual(decision.phase, .warm)
        XCTAssertTrue(decision.keepsLiveHierarchy)
        XCTAssertFalse(decision.isInteractive)
    }

    func testSelectedHiddenWindowWithBackgroundActivityStillStaysWarm() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: true,
                isInputPriorityWindow: false,
                isWindowVisibleForRendering: false,
                isPreviousLiveTab: false,
                isPrewarming: false,
                hasBackgroundActivity: true,
                isRenderSuspensionEnabled: true,
                isStartupRestoreActive: false,
                hasPendingRestoreBootstrap: false,
                isMCPControlled: false,
                hasAttachedTerminalView: true
            )
        )

        XCTAssertEqual(decision.phase, .warm)
        XCTAssertTrue(decision.keepsLiveHierarchy)
        XCTAssertFalse(decision.isInteractive)
    }

    func testActivePhaseKeepsLivePresentationAndVisibleSurface() {
        XCTAssertTrue(TabRenderPhase.active.allowsLivePresentation)
        XCTAssertTrue(TabRenderPhase.active.keepsVisibleSurface)
    }

    func testPassiveVisibleKeepsSurfaceWithoutLivePresentation() {
        XCTAssertFalse(TabRenderPhase.passiveVisible.allowsLivePresentation)
        XCTAssertTrue(TabRenderPhase.passiveVisible.keepsVisibleSurface)
    }

    func testWarmPhaseDoesNotKeepVisibleSurface() {
        XCTAssertFalse(TabRenderPhase.warm.allowsLivePresentation)
        XCTAssertFalse(TabRenderPhase.warm.keepsVisibleSurface)
    }

    func testSuspensionDisabledKeepsNonSelectedTabsWarm() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
                isInputPriorityWindow: true,
                isWindowVisibleForRendering: true,
                isPreviousLiveTab: false,
                isPrewarming: false,
                hasBackgroundActivity: false,
                isRenderSuspensionEnabled: false,
                isStartupRestoreActive: false,
                hasPendingRestoreBootstrap: false,
                isMCPControlled: false,
                hasAttachedTerminalView: true
            )
        )

        XCTAssertEqual(decision.phase, .warm)
        XCTAssertFalse(decision.keepsLiveHierarchy)
    }

    func testStartupRestoreBootstrapWarmsTabButDefersHierarchy() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
                isInputPriorityWindow: true,
                isWindowVisibleForRendering: true,
                isPreviousLiveTab: false,
                isPrewarming: false,
                hasBackgroundActivity: false,
                isRenderSuspensionEnabled: true,
                isStartupRestoreActive: true,
                hasPendingRestoreBootstrap: true,
                isMCPControlled: false,
                hasAttachedTerminalView: false
            )
        )

        XCTAssertEqual(decision.phase, .warm)
        XCTAssertFalse(decision.keepsLiveHierarchy)
    }

    func testPostStartupRestoreBootstrapKeepsTabAttachedUntilViewExists() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
                isInputPriorityWindow: true,
                isWindowVisibleForRendering: true,
                isPreviousLiveTab: false,
                isPrewarming: false,
                hasBackgroundActivity: false,
                isRenderSuspensionEnabled: true,
                isStartupRestoreActive: false,
                hasPendingRestoreBootstrap: true,
                isMCPControlled: false,
                hasAttachedTerminalView: false
            )
        )

        XCTAssertEqual(decision.phase, .warm)
        XCTAssertTrue(decision.keepsLiveHierarchy)
    }

    func testMCPTabWithoutAttachedViewStaysAttached() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
                isInputPriorityWindow: true,
                isWindowVisibleForRendering: true,
                isPreviousLiveTab: false,
                isPrewarming: false,
                hasBackgroundActivity: false,
                isRenderSuspensionEnabled: true,
                isStartupRestoreActive: true,
                hasPendingRestoreBootstrap: false,
                isMCPControlled: true,
                hasAttachedTerminalView: false
            )
        )

        XCTAssertEqual(decision.phase, .hidden)
        XCTAssertTrue(decision.keepsLiveHierarchy)
    }

    func testAuthoritativeRevealOnlyWhenBecomingActive() {
        XCTAssertTrue(
            TabRenderLifecyclePolicy.requiresAuthoritativeReveal(
                previousPhase: .hidden,
                nextPhase: .active
            )
        )
        XCTAssertTrue(
            TabRenderLifecyclePolicy.requiresAuthoritativeReveal(
                previousPhase: .warm,
                nextPhase: .passiveVisible
            )
        )
        XCTAssertTrue(
            TabRenderLifecyclePolicy.requiresAuthoritativeReveal(
                previousPhase: .passiveVisible,
                nextPhase: .active
            )
        )
        XCTAssertFalse(
            TabRenderLifecyclePolicy.requiresAuthoritativeReveal(
                previousPhase: .active,
                nextPhase: .active
            )
        )
        XCTAssertFalse(
            TabRenderLifecyclePolicy.requiresAuthoritativeReveal(
                previousPhase: nil,
                nextPhase: .active
            )
        )
    }
}
