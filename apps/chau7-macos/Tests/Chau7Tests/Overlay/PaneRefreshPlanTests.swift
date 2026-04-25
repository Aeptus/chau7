import XCTest
@testable import Chau7

/// SPM-runnable tests for `OverlayTabsModel.paneRefreshPlan`.
///
/// The plan governs per-pane behaviour during
/// `performSelectedTabInPlaceRefresh`. Three rules:
///   1. Only the focused pane claims input focus (`isInteractive=true`),
///      and only when the tab-level decision allows it.
///   2. Secondary panes always have `isInteractive=false` regardless of
///      the tab-level decision.
///   3. The `applyRenderPhaseReason` string differs between focused and
///      secondary panes so log lines are greppable per role.
final class PaneRefreshPlanTests: XCTestCase {

    private typealias Plan = OverlayTabsModel.PaneRefreshPlan

    // MARK: - Focused pane

    /// Focused pane + tab decision interactive=true → pane is interactive.
    /// This is the standard "selected, key window, focused pane" case.
    func testFocusedPaneInheritsInteractiveFromDecision() {
        let plan = OverlayTabsModel.paneRefreshPlan(
            isFocused: true,
            decisionIsInteractive: true
        )
        XCTAssertEqual(plan.role, .focused)
        XCTAssertTrue(plan.isInteractive)
        XCTAssertEqual(plan.applyRenderPhaseReason, "selectedTabInPlaceRefresh:focused")
    }

    /// Focused pane + tab decision interactive=false (e.g., visible-but-not-key
    /// window with background activity) → pane is NOT interactive even though
    /// it's focused. The interactive flag tracks input focus, not visibility.
    func testFocusedPaneRespectsDecisionWhenInteractiveIsFalse() {
        let plan = OverlayTabsModel.paneRefreshPlan(
            isFocused: true,
            decisionIsInteractive: false
        )
        XCTAssertEqual(plan.role, .focused)
        XCTAssertFalse(
            plan.isInteractive,
            "Focused pane must not claim input focus when the tab-level decision is non-interactive"
        )
        XCTAssertEqual(plan.applyRenderPhaseReason, "selectedTabInPlaceRefresh:focused")
    }

    // MARK: - Secondary pane

    /// Secondary pane is NEVER interactive, regardless of decision.
    /// Secondary panes receive `applyRenderPhase` calls (so their visual
    /// surface tracks the focused pane's phase) but must never claim
    /// input focus.
    func testSecondaryPaneNeverInteractiveEvenWhenDecisionIs() {
        let plan = OverlayTabsModel.paneRefreshPlan(
            isFocused: false,
            decisionIsInteractive: true
        )
        XCTAssertEqual(plan.role, .secondary)
        XCTAssertFalse(
            plan.isInteractive,
            "Secondary panes must not be interactive even when the tab-level decision says interactive=true"
        )
        XCTAssertEqual(plan.applyRenderPhaseReason, "selectedTabInPlaceRefresh:secondary")
    }

    func testSecondaryPaneNonInteractiveWhenDecisionIsAlsoFalse() {
        let plan = OverlayTabsModel.paneRefreshPlan(
            isFocused: false,
            decisionIsInteractive: false
        )
        XCTAssertEqual(plan.role, .secondary)
        XCTAssertFalse(plan.isInteractive)
        XCTAssertEqual(plan.applyRenderPhaseReason, "selectedTabInPlaceRefresh:secondary")
    }

    // MARK: - Log-breadcrumb invariant

    /// The `applyRenderPhaseReason` strings differ by role and are stable.
    /// Per-pane log breadcrumbs are greppable on the `:focused` /
    /// `:secondary` suffix; flipping these strings would silently break
    /// log-grep workflows.
    func testApplyRenderPhaseReasonStringsAreStable() {
        XCTAssertEqual(
            OverlayTabsModel.paneRefreshPlan(isFocused: true, decisionIsInteractive: false).applyRenderPhaseReason,
            "selectedTabInPlaceRefresh:focused"
        )
        XCTAssertEqual(
            OverlayTabsModel.paneRefreshPlan(isFocused: false, decisionIsInteractive: true).applyRenderPhaseReason,
            "selectedTabInPlaceRefresh:secondary"
        )
    }

    // MARK: - Role enum

    func testRoleRawValuesMatchLogConventions() {
        XCTAssertEqual(Plan.Role.focused.rawValue, "focused")
        XCTAssertEqual(Plan.Role.secondary.rawValue, "secondary")
    }
}
