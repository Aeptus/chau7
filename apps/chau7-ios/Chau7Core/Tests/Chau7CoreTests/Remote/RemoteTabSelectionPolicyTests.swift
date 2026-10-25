import XCTest
@testable import Chau7Core

final class RemoteTabSelectionPolicyTests: XCTestCase {
    func testValidPhoneSelectionSurvivesMacActiveTabChange() {
        let tabs = [tab(id: 1, isActive: true), tab(id: 2, isActive: false)]

        XCTAssertEqual(
            RemoteTabSelectionPolicy.resolvedActiveTabID(
                currentActiveTabID: 2,
                incoming: tabs
            ),
            2
        )
    }

    func testInitialOrMissingSelectionUsesMacActiveTab() {
        let tabs = [tab(id: 1, isActive: false), tab(id: 2, isActive: true)]

        XCTAssertEqual(
            RemoteTabSelectionPolicy.resolvedActiveTabID(
                currentActiveTabID: 0,
                incoming: tabs
            ),
            2
        )
        XCTAssertEqual(
            RemoteTabSelectionPolicy.resolvedActiveTabID(
                currentActiveTabID: 9,
                incoming: tabs
            ),
            2
        )
    }

    func testOnlyUnsubscribedPhoneFollowsMacFocus() {
        XCTAssertTrue(RemoteTabSelectionPolicy.followsMacFocus(hasExplicitRemoteSelection: false))
        XCTAssertFalse(RemoteTabSelectionPolicy.followsMacFocus(hasExplicitRemoteSelection: true))
    }

    private func tab(id: UInt32, isActive: Bool) -> RemoteTabDescriptor {
        RemoteTabDescriptor(
            tabID: id,
            title: "Tab \(id)",
            isActive: isActive,
            isMCPControlled: false
        )
    }
}
