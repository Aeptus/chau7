import XCTest
import Chau7Core

final class DeferredRestoreSchedulingPolicyTests: XCTestCase {
    func testIdleWhenNoPendingTabs() {
        let selected = UUID()

        XCTAssertEqual(
            DeferredRestoreSchedulingPolicy.decide(
                pendingTabIDs: [],
                tabOrder: [selected],
                selectedTabID: selected,
                lastSelectionChangedAt: nil,
                now: 10
            ),
            .idle
        )
    }

    func testSelectedPendingTabWinsImmediately() {
        let selected = UUID()
        let other = UUID()

        XCTAssertEqual(
            DeferredRestoreSchedulingPolicy.decide(
                pendingTabIDs: [other, selected],
                tabOrder: [selected, other],
                selectedTabID: selected,
                lastSelectionChangedAt: 9.9,
                now: 10,
                quietPeriod: 1
            ),
            .restore(selected, .selected)
        )
    }

    func testRapidSelectionWaitsBeforeBackgroundIdentityWork() {
        let selected = UUID()
        let pending = UUID()

        let decision = DeferredRestoreSchedulingPolicy.decide(
            pendingTabIDs: [pending],
            tabOrder: [selected, pending],
            selectedTabID: selected,
            lastSelectionChangedAt: 10,
            now: 10.2,
            quietPeriod: 0.45
        )
        if case .wait(let delay) = decision {
            XCTAssertEqual(delay, 0.25, accuracy: 0.0001)
        } else {
            XCTFail("Expected rapid selection to pause background restore")
        }
    }

    func testChoosesNearestPendingTabToSelection() {
        let tabs = (0 ..< 5).map { _ in UUID() }

        XCTAssertEqual(
            DeferredRestoreSchedulingPolicy.decide(
                pendingTabIDs: [tabs[0], tabs[4], tabs[3]],
                tabOrder: tabs,
                selectedTabID: tabs[2],
                lastSelectionChangedAt: nil,
                now: 10
            ),
            .restore(tabs[3], .nearestToSelection)
        )
    }

    func testFallsBackToFifoWhenSelectedTabIsNotInOrder() {
        let selected = UUID()
        let pending = [UUID(), UUID()]

        XCTAssertEqual(
            DeferredRestoreSchedulingPolicy.decide(
                pendingTabIDs: pending,
                tabOrder: [],
                selectedTabID: selected,
                lastSelectionChangedAt: nil,
                now: 10
            ),
            .restore(pending[0], .fifoFallback)
        )
    }
}
