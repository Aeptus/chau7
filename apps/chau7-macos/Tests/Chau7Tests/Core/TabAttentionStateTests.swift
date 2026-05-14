import XCTest
@testable import Chau7Core

final class TabAttentionStateTests: XCTestCase {
    func testApprovalOutranksWaitingInput() {
        XCTAssertEqual(
            TabAttentionKind.strongest(statuses: ["running", "waitingForInput", "approvalRequired"]),
            .approvalRequired
        )
    }

    func testWaitingInputAppliesStateOwnedStyleWhenMissing() {
        let decision = TabAttentionStatePolicy.reconcile(TabAttentionSnapshot(
            rawStatuses: ["waitingForInput"],
            currentOwnedKind: .none,
            hasVisibleStyle: false
        ))

        XCTAssertEqual(decision.desiredKind, .waitingForInput)
        XCTAssertEqual(decision.action, .apply)
        XCTAssertTrue(decision.shouldApplyStyle)
        XCTAssertFalse(decision.shouldClearVisibleStyle)
        XCTAssertEqual(decision.nextOwnedKind, .waitingForInput)
    }

    func testOwnedWaitingInputRepairsMissingVisibleStyle() {
        let decision = TabAttentionStatePolicy.reconcile(TabAttentionSnapshot(
            rawStatuses: ["waitingForInput"],
            currentOwnedKind: .waitingForInput,
            hasVisibleStyle: false
        ))

        XCTAssertEqual(decision.action, .repairMissingStyle)
        XCTAssertTrue(decision.shouldApplyStyle)
        XCTAssertEqual(decision.nextOwnedKind, .waitingForInput)
    }

    func testResolvedStateClearsOnlyStateOwnedVisibleStyle() {
        let decision = TabAttentionStatePolicy.reconcile(TabAttentionSnapshot(
            rawStatuses: ["running"],
            currentOwnedKind: .approvalRequired,
            hasVisibleStyle: true
        ))

        XCTAssertEqual(decision.desiredKind, .none)
        XCTAssertEqual(decision.action, .clearOwnedStyle)
        XCTAssertFalse(decision.shouldApplyStyle)
        XCTAssertTrue(decision.shouldClearVisibleStyle)
        XCTAssertEqual(decision.nextOwnedKind, .none)
    }

    func testResolvedStateDoesNotClearNonOwnedVisibleStyle() {
        let decision = TabAttentionStatePolicy.reconcile(TabAttentionSnapshot(
            rawStatuses: ["done"],
            currentOwnedKind: .none,
            hasVisibleStyle: true
        ))

        XCTAssertEqual(decision.action, .none)
        XCTAssertFalse(decision.shouldClearVisibleStyle)
        XCTAssertEqual(decision.nextOwnedKind, .none)
    }
}
