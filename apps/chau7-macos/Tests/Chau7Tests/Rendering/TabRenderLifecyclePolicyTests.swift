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

    func testPreviouslyLiveNonSelectedTabStaysInHierarchyForHandoff() {
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
        XCTAssertTrue(
            decision.keepsLiveHierarchy,
            "Previous-live tab should stay mounted briefly so rapid re-selection doesn't churn SwiftUI"
        )
        XCTAssertFalse(decision.isInteractive)
    }

    func testNonSelectedTabsWithoutSignalsDropFromLiveHierarchy() {
        // Three distinct shapes of "non-selected background tab" that the
        // policy must collapse to the lightweight placeholder:
        //   1. background activity running (PTY output streaming while the
        //      user is on a different tab)
        //   2. the window is off-screen and nothing else is pending
        //   3. a previously-selected tab whose handoff window has cleared
        //      (isPreviousLiveTab=false)
        let inputs: [TabRenderLifecycleInput] = [
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
            ),
            TabRenderLifecycleInput(
                isSelectedTab: false,
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
            ),
            TabRenderLifecycleInput(
                isSelectedTab: false,
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
        ]
        for input in inputs {
            let decision = TabRenderLifecyclePolicy.decide(input)
            XCTAssertEqual(decision.phase, .warm, "Expected .warm for non-selected: \(input)")
            XCTAssertFalse(
                decision.keepsLiveHierarchy,
                "Non-selected tab without active signal should fall back to placeholder: \(input)"
            )
        }
    }

    func testStartupBootstrapNonSelectedTabStaysInHierarchyUntilReplayFinishes() {
        // During a cold startup restore, background tabs whose scrollback
        // replay is still in flight must keep their SwiftUI mount so the
        // restore pipeline can drive them.
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
                isInputPriorityWindow: false,
                isWindowVisibleForRendering: false,
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
        XCTAssertTrue(
            decision.keepsLiveHierarchy,
            "Startup-bootstrap non-selected tabs need a live mount to complete replay"
        )
    }

    func testMCPControlledTabWithoutAttachedViewKeepsLiveHierarchy() {
        // MCP-driven tabs must have a hierarchy mount when no terminal
        // view has attached yet — otherwise a background exec or
        // input request has no PTY to land on.
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
                hasPendingRestoreBootstrap: false,
                isMCPControlled: true,
                hasAttachedTerminalView: false
            )
        )
        XCTAssertTrue(
            decision.keepsLiveHierarchy,
            "Fresh MCP tab without an attached view must stay mounted so exec requests have a PTY"
        )
    }

    func testMCPControlledTabWithAttachedViewDropsFromHierarchy() {
        // Once the MCP tab has an attached terminal view, the retained
        // RustTerminalView on the session keeps it alive; no need to
        // mount a SwiftUI wrapper for a non-selected background tab.
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
                hasPendingRestoreBootstrap: false,
                isMCPControlled: true,
                hasAttachedTerminalView: true
            )
        )
        XCTAssertFalse(
            decision.keepsLiveHierarchy,
            "MCP tab with attached view doesn't need a SwiftUI mount while in background"
        )
    }

    func testSelectedHiddenWindowGetsWarmButStaysLive() {
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
        XCTAssertTrue(
            decision.keepsLiveHierarchy,
            "Selected tab always keeps its mount even when window is currently hidden"
        )
    }

    func testOnlySelectedTabIsInteractive() {
        let selected = TabRenderLifecyclePolicy.decide(
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
        let notSelected = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
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
        let selectedNoWindow = TabRenderLifecyclePolicy.decide(
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
