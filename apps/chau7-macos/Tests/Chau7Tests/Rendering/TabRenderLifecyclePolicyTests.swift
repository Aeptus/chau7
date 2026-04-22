import XCTest
@testable import Chau7Core

final class TabRenderLifecyclePolicyTests: XCTestCase {
    func testSelectedInputPriorityTabIsActiveInteractiveAndLive() {
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

    func testSelectedVisibleBackgroundWindowIsPassiveVisible() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: true,
                isInputPriorityWindow: false,
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

        XCTAssertEqual(decision.phase, .passiveVisible)
        XCTAssertTrue(decision.keepsLiveHierarchy)
        XCTAssertFalse(decision.isInteractive)
    }

    func testNonSelectedTabIsWarmAndLiveButNotInteractive() {
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

    func testNonSelectedTabsGetWarmPhase() {
        let inputs: [TabRenderLifecycleInput] = [
            TabRenderLifecycleInput(isSelectedTab: false, isInputPriorityWindow: true, isWindowVisibleForRendering: true, isPreviousLiveTab: true, isPrewarming: false, hasBackgroundActivity: false, isRenderSuspensionEnabled: true, isStartupRestoreActive: false, hasPendingRestoreBootstrap: false, isMCPControlled: false, hasAttachedTerminalView: true),
            TabRenderLifecycleInput(isSelectedTab: false, isInputPriorityWindow: true, isWindowVisibleForRendering: true, isPreviousLiveTab: false, isPrewarming: false, hasBackgroundActivity: true, isRenderSuspensionEnabled: true, isStartupRestoreActive: false, hasPendingRestoreBootstrap: false, isMCPControlled: false, hasAttachedTerminalView: true),
            TabRenderLifecycleInput(isSelectedTab: false, isInputPriorityWindow: false, isWindowVisibleForRendering: false, isPreviousLiveTab: false, isPrewarming: false, hasBackgroundActivity: false, isRenderSuspensionEnabled: true, isStartupRestoreActive: true, hasPendingRestoreBootstrap: true, isMCPControlled: false, hasAttachedTerminalView: false),
        ]
        for input in inputs {
            let decision = TabRenderLifecyclePolicy.decide(input)
            XCTAssertEqual(decision.phase, .warm, "Expected .warm for non-selected: \(input)")
            XCTAssertTrue(decision.keepsLiveHierarchy)
        }
    }

    func testSelectedHiddenWindowGetsWarm() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(isSelectedTab: true, isInputPriorityWindow: false, isWindowVisibleForRendering: false, isPreviousLiveTab: false, isPrewarming: false, hasBackgroundActivity: false, isRenderSuspensionEnabled: true, isStartupRestoreActive: false, hasPendingRestoreBootstrap: false, isMCPControlled: false, hasAttachedTerminalView: true)
        )
        XCTAssertEqual(decision.phase, .warm)
        XCTAssertTrue(decision.keepsLiveHierarchy)
    }

    func testOnlySelectedTabIsInteractive() {
        let selected = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(isSelectedTab: true, isInputPriorityWindow: true, isWindowVisibleForRendering: true, isPreviousLiveTab: false, isPrewarming: false, hasBackgroundActivity: false, isRenderSuspensionEnabled: true, isStartupRestoreActive: false, hasPendingRestoreBootstrap: false, isMCPControlled: false, hasAttachedTerminalView: true)
        )
        let notSelected = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(isSelectedTab: false, isInputPriorityWindow: true, isWindowVisibleForRendering: true, isPreviousLiveTab: false, isPrewarming: false, hasBackgroundActivity: false, isRenderSuspensionEnabled: true, isStartupRestoreActive: false, hasPendingRestoreBootstrap: false, isMCPControlled: false, hasAttachedTerminalView: true)
        )
        let selectedNoWindow = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(isSelectedTab: true, isInputPriorityWindow: false, isWindowVisibleForRendering: true, isPreviousLiveTab: false, isPrewarming: false, hasBackgroundActivity: false, isRenderSuspensionEnabled: true, isStartupRestoreActive: false, hasPendingRestoreBootstrap: false, isMCPControlled: false, hasAttachedTerminalView: true)
        )

        XCTAssertTrue(selected.isInteractive)
        XCTAssertFalse(notSelected.isInteractive)
        XCTAssertFalse(selectedNoWindow.isInteractive)
        XCTAssertEqual(selectedNoWindow.phase, .passiveVisible)
    }

    func testActivePhaseProperties() {
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
