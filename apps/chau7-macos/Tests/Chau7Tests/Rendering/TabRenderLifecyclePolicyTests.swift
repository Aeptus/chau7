import XCTest
@testable import Chau7Core

final class TabRenderLifecyclePolicyTests: XCTestCase {
    func testSelectedTabIsActiveInteractiveAndLive() {
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

    func testNonSelectedTabIsActiveAndLiveButNotInteractive() {
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

        XCTAssertEqual(decision.phase, .active)
        XCTAssertTrue(decision.keepsLiveHierarchy)
        XCTAssertFalse(decision.isInteractive)
    }

    func testAllTabsStayActiveRegardlessOfInputs() {
        // Phase is always .active and keepsLiveHierarchy is always true,
        // regardless of selection, window visibility, or background activity.
        let inputs: [TabRenderLifecycleInput] = [
            // Prewarming
            TabRenderLifecycleInput(isSelectedTab: false, isInputPriorityWindow: true, isWindowVisibleForRendering: true, isPreviousLiveTab: false, isPrewarming: true, hasBackgroundActivity: false, isRenderSuspensionEnabled: true, isStartupRestoreActive: false, hasPendingRestoreBootstrap: false, isMCPControlled: false, hasAttachedTerminalView: true),
            // Background activity
            TabRenderLifecycleInput(isSelectedTab: false, isInputPriorityWindow: true, isWindowVisibleForRendering: true, isPreviousLiveTab: false, isPrewarming: false, hasBackgroundActivity: true, isRenderSuspensionEnabled: true, isStartupRestoreActive: false, hasPendingRestoreBootstrap: false, isMCPControlled: false, hasAttachedTerminalView: true),
            // Hidden window
            TabRenderLifecycleInput(isSelectedTab: false, isInputPriorityWindow: false, isWindowVisibleForRendering: false, isPreviousLiveTab: false, isPrewarming: false, hasBackgroundActivity: true, isRenderSuspensionEnabled: true, isStartupRestoreActive: false, hasPendingRestoreBootstrap: false, isMCPControlled: false, hasAttachedTerminalView: true),
            // Selected hidden window
            TabRenderLifecycleInput(isSelectedTab: true, isInputPriorityWindow: false, isWindowVisibleForRendering: false, isPreviousLiveTab: false, isPrewarming: false, hasBackgroundActivity: false, isRenderSuspensionEnabled: true, isStartupRestoreActive: false, hasPendingRestoreBootstrap: false, isMCPControlled: false, hasAttachedTerminalView: true),
            // Suspension disabled
            TabRenderLifecycleInput(isSelectedTab: false, isInputPriorityWindow: true, isWindowVisibleForRendering: true, isPreviousLiveTab: false, isPrewarming: false, hasBackgroundActivity: false, isRenderSuspensionEnabled: false, isStartupRestoreActive: false, hasPendingRestoreBootstrap: false, isMCPControlled: false, hasAttachedTerminalView: true),
            // Startup restore bootstrap
            TabRenderLifecycleInput(isSelectedTab: false, isInputPriorityWindow: true, isWindowVisibleForRendering: true, isPreviousLiveTab: false, isPrewarming: false, hasBackgroundActivity: false, isRenderSuspensionEnabled: true, isStartupRestoreActive: true, hasPendingRestoreBootstrap: true, isMCPControlled: false, hasAttachedTerminalView: false),
            // MCP tab
            TabRenderLifecycleInput(isSelectedTab: false, isInputPriorityWindow: true, isWindowVisibleForRendering: true, isPreviousLiveTab: false, isPrewarming: false, hasBackgroundActivity: false, isRenderSuspensionEnabled: true, isStartupRestoreActive: true, hasPendingRestoreBootstrap: false, isMCPControlled: true, hasAttachedTerminalView: false),
        ]

        for input in inputs {
            let decision = TabRenderLifecyclePolicy.decide(input)
            XCTAssertEqual(decision.phase, .active, "Expected .active for input: \(input)")
            XCTAssertTrue(decision.keepsLiveHierarchy, "Expected keepsLiveHierarchy for input: \(input)")
        }
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
