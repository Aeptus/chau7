import XCTest
@testable import Chau7Core

final class TabAttentionStateTests: XCTestCase {
    func testApprovalOutranksWaitingInput() {
        XCTAssertEqual(
            TabAttentionKind.strongest(statuses: ["running", "waitingForInput", "approvalRequired"]),
            .approvalRequired
        )
    }

    func testNotificationSemanticMapsToInteractiveAttentionKind() {
        XCTAssertEqual(
            TabAttentionKind.fromNotificationSemantic(.waitingForInput),
            .waitingForInput
        )
        XCTAssertEqual(
            TabAttentionKind.fromNotificationSemantic(.permissionRequired),
            .approvalRequired
        )
        XCTAssertEqual(
            TabAttentionKind.fromNotificationSemantic(.attentionRequired),
            .approvalRequired
        )
        XCTAssertEqual(
            TabAttentionKind.fromNotificationSemantic(.taskFinished),
            .none
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

    func testAttentionReportCompactLineIncludesStateAndStyle() {
        let report = TabAttentionReport(
            statuses: ["waitingForInput"],
            ownedKind: .none,
            hasVisibleStyle: false,
            isSelected: true,
            styleSummary: "none"
        )

        XCTAssertEqual(report.desiredKind, .waitingForInput)
        XCTAssertEqual(
            report.compactLine,
            "statuses=waitingForInput desired=waitingForInput owned=none style=none visibleStyle=false selected=true"
        )
    }
}
