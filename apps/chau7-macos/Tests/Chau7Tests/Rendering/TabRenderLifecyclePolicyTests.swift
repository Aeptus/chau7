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
        XCTAssertTrue(decision.isInteractive)
    }

    func testNonSelectedTabIsWarmWithoutMemoryPressure() {
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
                isInputPriorityWindow: false,
                isWindowVisibleForRendering: true,
                isPreviousLiveTab: false,
                isPrewarming: false,
                hasBackgroundActivity: true,
                isRenderSuspensionEnabled: true,
                isStartupRestoreActive: false,
                hasPendingRestoreBootstrap: false,
                isMCPControlled: false,
                hasAttachedTerminalView: true,
                isUnderMemoryPressure: false
            )
        )
        XCTAssertEqual(decision.phase, .warm)
    }

    func testNonSelectedTabDemotesToHiddenUnderMemoryPressure() {
        // Under pressure, non-selected tabs go `.hidden` so ScrollbackMemoryManager
        // flushes their scrollback to disk (reloaded on re-selection) instead of
        // hoarding it in RAM — the bulk of the footprint in many-tab sessions.
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: false,
                isInputPriorityWindow: false,
                isWindowVisibleForRendering: true,
                isPreviousLiveTab: false,
                isPrewarming: false,
                hasBackgroundActivity: true,
                isRenderSuspensionEnabled: true,
                isStartupRestoreActive: false,
                hasPendingRestoreBootstrap: false,
                isMCPControlled: false,
                hasAttachedTerminalView: true,
                isUnderMemoryPressure: true
            )
        )
        XCTAssertEqual(decision.phase, .hidden)
    }

    func testSelectedTabStaysActiveUnderMemoryPressure() {
        // Pressure only demotes NON-selected tabs; the tab the user is in is untouched.
        let decision = TabRenderLifecyclePolicy.decide(
            TabRenderLifecycleInput(
                isSelectedTab: true,
                isInputPriorityWindow: true,
                isWindowVisibleForRendering: true,
                isPreviousLiveTab: false,
                isPrewarming: false,
                hasBackgroundActivity: true,
                isRenderSuspensionEnabled: true,
                isStartupRestoreActive: false,
                hasPendingRestoreBootstrap: false,
                isMCPControlled: false,
                hasAttachedTerminalView: true,
                isUnderMemoryPressure: true
            )
        )
        XCTAssertEqual(decision.phase, .active)
    }

    func testSelectedVisibleBackgroundWindowWithActivityStaysActive() {
        // W3.18 policy: a selected tab in a visible-but-not-key window
        // stays in `.active` when the session is actively producing output
        // (hasBackgroundActivity=true). Previously dropped to
        // `.passiveVisible` and paused Metal presentation, so users
        // couldn't see AI-agent streaming progress when glancing at
        // another app. The PTY always drained regardless; only the
        // Metal presentation was paused.
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

        XCTAssertEqual(decision.phase, .active)
        XCTAssertFalse(
            decision.isInteractive,
            "Interactive still requires input-priority window — background-activity promotion only affects rendering, not input focus"
        )
    }

    func testSelectedVisibleBackgroundWindowWithoutActivityStaysActive() {
        // A selected tab on a visible-but-not-key window renders live
        // even without background activity. The previous policy dropped
        // to `.passiveVisible` here, intending to save GPU "when
        // nothing's happening," but in practice this froze the surface
        // at a stale frame whenever a non-AI-agent process produced
        // output (plain shell, long compiles, finished AI sessions),
        // because the PTY drains regardless of phase but presentation
        // was paused. Visibility is the right gate for "render live";
        // key/main is the gate for "accept input."
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

        XCTAssertEqual(
            decision.phase,
            .active,
            "Selected tab on visible window must render live regardless of focus or activity"
        )
        XCTAssertFalse(
            decision.isInteractive,
            "Interactive still requires input-priority window"
        )
    }

    func testSettledIdleNonSelectedTabIsHiddenAndNotInteractive() {
        // A settled non-selected tab with no live background activity demotes to
        // .hidden so its scrollback flushes; it is never interactive.
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

        XCTAssertEqual(decision.phase, .hidden)
        XCTAssertFalse(decision.isInteractive)
    }

    func testNonSelectedTabPhaseDependsOnActivityAndSettleState() {
        // Settled + idle → .hidden (scrollback flushes).
        let settledIdle = TabRenderLifecycleInput(
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
        XCTAssertEqual(TabRenderLifecyclePolicy.decide(settledIdle).phase, .hidden)

        // Live background activity → stays .warm at full fidelity.
        let busy = TabRenderLifecycleInput(
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
        XCTAssertEqual(TabRenderLifecyclePolicy.decide(busy).phase, .warm)

        // Still being set up (startup restore / bootstrap) → left .warm so it
        // isn't flushed mid-restore.
        let restoring = TabRenderLifecycleInput(
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
        XCTAssertEqual(TabRenderLifecyclePolicy.decide(restoring).phase, .warm)
    }

    func testSelectedHiddenWindowGetsWarm() {
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
        XCTAssertEqual(
            selectedNoWindow.phase,
            .active,
            "Selected tab on a visible window must render live regardless of focus"
        )
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
