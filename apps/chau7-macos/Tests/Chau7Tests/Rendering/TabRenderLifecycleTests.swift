import XCTest
import Chau7Core

final class TabRenderLifecycleTests: XCTestCase {

    // MARK: - TabRenderPhase

    func testHiddenIsOnlyPhaseThatStopsCurrentState() {
        XCTAssertTrue(TabRenderPhase.active.keepsTerminalStateCurrent)
        XCTAssertTrue(TabRenderPhase.passiveVisible.keepsTerminalStateCurrent)
        XCTAssertTrue(TabRenderPhase.warm.keepsTerminalStateCurrent)
        XCTAssertFalse(TabRenderPhase.hidden.keepsTerminalStateCurrent)
    }

    func testOnlyActivePhaseAllowsLivePresentation() {
        XCTAssertTrue(TabRenderPhase.active.allowsLivePresentation)
        XCTAssertFalse(TabRenderPhase.passiveVisible.allowsLivePresentation)
        XCTAssertFalse(TabRenderPhase.warm.allowsLivePresentation)
        XCTAssertFalse(TabRenderPhase.hidden.allowsLivePresentation)
    }

    func testKeepsVisibleSurfaceOnlyForActiveAndPassiveVisible() {
        XCTAssertTrue(TabRenderPhase.active.keepsVisibleSurface)
        XCTAssertTrue(TabRenderPhase.passiveVisible.keepsVisibleSurface)
        XCTAssertFalse(TabRenderPhase.warm.keepsVisibleSurface)
        XCTAssertFalse(TabRenderPhase.hidden.keepsVisibleSurface)
    }

    // MARK: - phase(for:)

    func testSelectedTabInInputPriorityVisibleWindowIsActive() {
        let input = makeInput(
            isSelectedTab: true,
            isInputPriorityWindow: true,
            isWindowVisibleForRendering: true
        )
        XCTAssertEqual(TabRenderLifecyclePolicy.phase(for: input), .active)
    }

    func testSelectedTabInVisibleBackgroundWindowStaysActive() {
        // Selected tab on visible window renders live regardless of focus.
        // Previous policy returned `.passiveVisible` here, which froze the
        // surface for users with multi-monitor setups (window visible on
        // one screen, focus on another) whenever no AI background activity
        // was present.
        let input = makeInput(
            isSelectedTab: true,
            isInputPriorityWindow: false,
            isWindowVisibleForRendering: true
        )
        XCTAssertEqual(TabRenderLifecyclePolicy.phase(for: input), .active)
    }

    func testSelectedTabInInvisibleWindowIsWarm() {
        let input = makeInput(isSelectedTab: true, isWindowVisibleForRendering: false)
        XCTAssertEqual(TabRenderLifecyclePolicy.phase(for: input), .warm)
    }

    func testIdleUnselectedTabIsHidden() {
        // No live background activity → demote to .hidden so scrollback flushes,
        // regardless of window visibility or memory pressure.
        let input = makeInput(isSelectedTab: false, isWindowVisibleForRendering: true)
        XCTAssertEqual(TabRenderLifecyclePolicy.phase(for: input), .hidden)

        let invisibleInput = makeInput(isSelectedTab: false, isWindowVisibleForRendering: false)
        XCTAssertEqual(TabRenderLifecyclePolicy.phase(for: invisibleInput), .hidden)
    }

    func testUnselectedTabWithBackgroundActivityStaysWarm() {
        // A running/waiting AI session keeps the tab .warm at full fidelity.
        let input = makeInput(
            isSelectedTab: false,
            isWindowVisibleForRendering: true,
            hasBackgroundActivity: true
        )
        XCTAssertEqual(TabRenderLifecyclePolicy.phase(for: input), .warm)
    }

    func testUnselectedTabWithBackgroundActivityDemotesUnderMemoryPressure() {
        let input = makeInput(
            isSelectedTab: false,
            isWindowVisibleForRendering: true,
            hasBackgroundActivity: true,
            isUnderMemoryPressure: true
        )
        XCTAssertEqual(TabRenderLifecyclePolicy.phase(for: input), .hidden)
    }

    // MARK: - isInteractive(for:)

    func testInteractiveRequiresSelectedAndPriorityWindow() {
        XCTAssertTrue(
            TabRenderLifecyclePolicy.isInteractive(
                for: makeInput(isSelectedTab: true, isInputPriorityWindow: true)
            )
        )
        XCTAssertFalse(
            TabRenderLifecyclePolicy.isInteractive(
                for: makeInput(isSelectedTab: false, isInputPriorityWindow: true)
            )
        )
        XCTAssertFalse(
            TabRenderLifecyclePolicy.isInteractive(
                for: makeInput(isSelectedTab: true, isInputPriorityWindow: false)
            )
        )
    }

    func testInputPriorityRequiresKeyWindowOutsideStartupRestore() {
        XCTAssertTrue(
            TabRenderLifecyclePolicy.isInputPriorityWindow(
                hasWindow: true,
                isKeyWindow: true,
                isMainWindow: false,
                isStartupRestoreActive: false
            )
        )
        XCTAssertFalse(
            TabRenderLifecyclePolicy.isInputPriorityWindow(
                hasWindow: true,
                isKeyWindow: false,
                isMainWindow: true,
                isStartupRestoreActive: false
            )
        )
    }

    func testInputPriorityDefaultsToReadyDuringStartupOrBeforeWindowAttachment() {
        XCTAssertTrue(
            TabRenderLifecyclePolicy.isInputPriorityWindow(
                hasWindow: true,
                isKeyWindow: false,
                isMainWindow: false,
                isStartupRestoreActive: true
            )
        )
        XCTAssertTrue(
            TabRenderLifecyclePolicy.isInputPriorityWindow(
                hasWindow: false,
                isKeyWindow: false,
                isMainWindow: false,
                isStartupRestoreActive: false
            )
        )
    }

    // MARK: - requiresAuthoritativeReveal

    func testNoRevealNeededWithoutPreviousPhase() {
        XCTAssertFalse(
            TabRenderLifecyclePolicy.requiresAuthoritativeReveal(
                previousPhase: nil,
                nextPhase: .active
            )
        )
    }

    func testRevealRequiredWhenSurfaceWasInvisibleAndBecomesVisible() {
        XCTAssertTrue(
            TabRenderLifecyclePolicy.requiresAuthoritativeReveal(
                previousPhase: .warm,
                nextPhase: .active
            )
        )
        XCTAssertTrue(
            TabRenderLifecyclePolicy.requiresAuthoritativeReveal(
                previousPhase: .hidden,
                nextPhase: .passiveVisible
            )
        )
    }

    func testRevealRequiredWhenMovingIntoActiveFromNonActive() {
        XCTAssertTrue(
            TabRenderLifecyclePolicy.requiresAuthoritativeReveal(
                previousPhase: .passiveVisible,
                nextPhase: .active
            )
        )
    }

    func testNoRevealWhenBothPhasesKeepSurfaceAndStayOutsideActive() {
        // active -> active: already active, no new reveal needed
        XCTAssertFalse(
            TabRenderLifecyclePolicy.requiresAuthoritativeReveal(
                previousPhase: .active,
                nextPhase: .active
            )
        )
        // passiveVisible -> passiveVisible: surface already retained, not going active
        XCTAssertFalse(
            TabRenderLifecyclePolicy.requiresAuthoritativeReveal(
                previousPhase: .passiveVisible,
                nextPhase: .passiveVisible
            )
        )
    }

    func testNoRevealWhenMovingFromActiveToDormantSurface() {
        // Leaving active doesn't require an incoming reveal.
        XCTAssertFalse(
            TabRenderLifecyclePolicy.requiresAuthoritativeReveal(
                previousPhase: .active,
                nextPhase: .warm
            )
        )
    }

    // MARK: - helpers

    private func makeInput(
        isSelectedTab: Bool = false,
        isInputPriorityWindow: Bool = false,
        isWindowVisibleForRendering: Bool = true,
        isPreviousLiveTab: Bool = false,
        isPrewarming: Bool = false,
        hasBackgroundActivity: Bool = false,
        isRenderSuspensionEnabled: Bool = false,
        isStartupRestoreActive: Bool = false,
        hasPendingRestoreBootstrap: Bool = false,
        isMCPControlled: Bool = false,
        hasAttachedTerminalView: Bool = true,
        isUnderMemoryPressure: Bool = false
    ) -> TabRenderLifecycleInput {
        TabRenderLifecycleInput(
            isSelectedTab: isSelectedTab,
            isInputPriorityWindow: isInputPriorityWindow,
            isWindowVisibleForRendering: isWindowVisibleForRendering,
            isPreviousLiveTab: isPreviousLiveTab,
            isPrewarming: isPrewarming,
            hasBackgroundActivity: hasBackgroundActivity,
            isRenderSuspensionEnabled: isRenderSuspensionEnabled,
            isStartupRestoreActive: isStartupRestoreActive,
            hasPendingRestoreBootstrap: hasPendingRestoreBootstrap,
            isMCPControlled: isMCPControlled,
            hasAttachedTerminalView: hasAttachedTerminalView,
            isUnderMemoryPressure: isUnderMemoryPressure
        )
    }
}
