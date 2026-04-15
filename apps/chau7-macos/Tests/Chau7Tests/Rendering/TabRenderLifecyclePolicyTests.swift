import XCTest
@testable import Chau7Core

final class TabRenderLifecyclePolicyTests: XCTestCase {
    func testSelectedTabIsActiveAndKeptLive() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: true,
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
    }

    func testPreviousLiveTabStaysWarmAndAttached() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
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
    }

    func testPrewarmingTabStaysWarmAndAttached() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
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
    }

    func testBackgroundActivityKeepsTabActiveWithoutForcingHierarchy() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
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

        XCTAssertEqual(decision.phase, .active)
        XCTAssertFalse(decision.keepsLiveHierarchy)
    }

    func testSuspensionDisabledKeepsNonSelectedTabsWarm() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
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
