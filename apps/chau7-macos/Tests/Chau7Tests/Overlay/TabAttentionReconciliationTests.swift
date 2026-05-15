import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class TabAttentionReconciliationTests: XCTestCase {
    private var model: OverlayTabsModel!
    private var appModel: AppModel!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        appModel = AppModel()
        model = OverlayTabsModel(appModel: appModel, restoreState: false)
    }

    override func tearDown() {
        model = nil
        appModel = nil
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        super.tearDown()
    }

    func testAppliesPersistentStyleForWaitingSession() throws {
        let session = try XCTUnwrap(model.tabs[0].session)
        session.status = .waitingForInput

        let changed = model.reconcileTabAttentionStyles(reason: "test")

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(model.tabs[0].stateAttentionKind, .waitingForInput)
        XCTAssertTrue(model.tabs[0].notificationStyle?.persistent == true)
        XCTAssertEqual(model.tabs[0].notificationStyle?.icon, TabNotificationStyle.attention.icon)
    }

    func testRepairsMissingStateOwnedStyle() throws {
        let session = try XCTUnwrap(model.tabs[0].session)
        session.status = .waitingForInput
        _ = model.reconcileTabAttentionStyles(reason: "test-apply")
        model.tabs[0].notificationStyle = nil

        let changed = model.reconcileTabAttentionStyles(reason: "test-repair")

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(model.tabs[0].stateAttentionKind, .waitingForInput)
        XCTAssertNotNil(model.tabs[0].notificationStyle)
    }

    func testClearsOnlyStateOwnedStyleWhenResolved() throws {
        let session = try XCTUnwrap(model.tabs[0].session)
        session.status = .approvalRequired
        _ = model.reconcileTabAttentionStyles(reason: "test-apply")
        session.status = .running

        let changed = model.reconcileTabAttentionStyles(reason: "test-clear")

        XCTAssertEqual(changed, 1)
        XCTAssertEqual(model.tabs[0].stateAttentionKind, .none)
        XCTAssertNil(model.tabs[0].notificationStyle)
    }

    func testLeavesNonOwnedStyleWhenResolved() {
        _ = model.setNotificationStyle(.success, for: model.tabs[0].id)

        let changed = model.reconcileTabAttentionStyles(reason: "test-noop")

        XCTAssertEqual(changed, 0)
        XCTAssertEqual(model.tabs[0].stateAttentionKind, .none)
        XCTAssertEqual(model.tabs[0].notificationStyle, .success)
    }

    func testNotificationStyleOverrideReleasesStateAttentionOwnership() throws {
        let session = try XCTUnwrap(model.tabs[0].session)
        session.status = .waitingForInput
        _ = model.reconcileTabAttentionStyles(reason: "test-apply")

        _ = model.setNotificationStyle(.success, for: model.tabs[0].id)
        session.status = .running
        _ = model.reconcileTabAttentionStyles(reason: "test-resolved")

        XCTAssertEqual(model.tabs[0].stateAttentionKind, .none)
        XCTAssertEqual(model.tabs[0].notificationStyle, .success)
    }

    func testNotificationAttentionPromotesMatchingSessionState() throws {
        let session = try XCTUnwrap(model.tabs[0].session)
        session.lastAISessionId = "session-1"
        session.lastAISessionIdentitySource = .observed
        session.status = .running

        let changed = model.assertNotificationAttention(
            tabID: model.tabs[0].id,
            kind: .waitingForInput,
            sessionID: "session-1",
            reason: "test-notification"
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(session.status, .waitingForInput)
        XCTAssertEqual(model.tabs[0].stateAttentionKind, .waitingForInput)
        XCTAssertTrue(model.tabs[0].notificationStyle?.persistent == true)
    }

    func testNotificationAttentionDoesNotDowngradeApprovalToWaiting() throws {
        let session = try XCTUnwrap(model.tabs[0].session)
        session.lastAISessionId = "session-1"
        session.lastAISessionIdentitySource = .observed
        session.status = .approvalRequired
        _ = model.reconcileTabAttentionStyles(reason: "test-approval")

        _ = model.assertNotificationAttention(
            tabID: model.tabs[0].id,
            kind: .waitingForInput,
            sessionID: "session-1",
            reason: "test-waiting-repeat"
        )

        XCTAssertEqual(session.status, .approvalRequired)
        XCTAssertEqual(model.tabs[0].stateAttentionKind, .approvalRequired)
    }

    func testNotificationResolutionClearsPromotedInteractiveState() throws {
        let session = try XCTUnwrap(model.tabs[0].session)
        session.lastAISessionId = "session-1"
        session.lastAISessionIdentitySource = .observed
        session.status = .approvalRequired
        _ = model.reconcileTabAttentionStyles(reason: "test-approval")

        let changed = model.clearNotificationAttention(
            tabID: model.tabs[0].id,
            sessionID: "session-1",
            resolvedStatus: .done,
            reason: "test-finished"
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(session.status, .done)
        XCTAssertEqual(model.tabs[0].stateAttentionKind, .none)
        XCTAssertNil(model.tabs[0].notificationStyle)
    }

    func testNotificationResolutionDoesNotClearDifferentSession() throws {
        let session = try XCTUnwrap(model.tabs[0].session)
        session.lastAISessionId = "session-1"
        session.lastAISessionIdentitySource = .observed
        session.status = .waitingForInput
        _ = model.reconcileTabAttentionStyles(reason: "test-waiting")

        let changed = model.clearNotificationAttention(
            tabID: model.tabs[0].id,
            sessionID: "other-session",
            resolvedStatus: .done,
            reason: "test-finished"
        )

        XCTAssertFalse(changed)
        XCTAssertEqual(session.status, .waitingForInput)
        XCTAssertEqual(model.tabs[0].stateAttentionKind, .waitingForInput)
        XCTAssertNotNil(model.tabs[0].notificationStyle)
    }
}
#endif
