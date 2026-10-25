import Foundation
import XCTest
@testable import Chau7Core

final class RemoteTabPickerSnapshotTests: XCTestCase {
    func testMacFocusAndInputPaneChangesDoNotRebuildPicker() {
        let original = RemoteTabPickerSnapshot(orderedTabs: [tab(1, active: true)])
        let refreshed = RemoteTabPickerSnapshot(orderedTabs: [tab(1, active: false, pane: UUID())])
        XCTAssertEqual(original, refreshed)
    }

    func testDisplayedMetadataAndMembershipChangesUpdatePicker() {
        let original = RemoteTabPickerSnapshot(orderedTabs: [tab(1)])
        XCTAssertNotEqual(original, RemoteTabPickerSnapshot(orderedTabs: [tab(1, branch: "feature")]))
        XCTAssertNotEqual(original, RemoteTabPickerSnapshot(orderedTabs: [tab(1, title: "Build")]))
        XCTAssertNotEqual(original, RemoteTabPickerSnapshot(orderedTabs: [tab(1, provider: "Codex")]))
        XCTAssertNotEqual(original, RemoteTabPickerSnapshot(orderedTabs: [tab(1, controlled: true)]))
        XCTAssertNotEqual(original, RemoteTabPickerSnapshot(orderedTabs: [tab(1), tab(2)]))
    }

    func testGroupingPreservesAlphabeticalRowsAndKeepsUngroupedLast() {
        let snapshot = RemoteTabPickerSnapshot(orderedTabs: [
            tab(1, title: "Alpha", project: "Zulu"),
            tab(2, title: "Beta", project: "  Acme  "),
            tab(3, title: "Gamma", project: "Acme"),
            tab(4, project: " "),
            tab(5, project: "Other")
        ])
        XCTAssertEqual(snapshot.groups.map(\.title), ["Acme", "Other", "Zulu", "Other"])
        XCTAssertEqual(snapshot.groups.first?.rows.map(\.id), [2, 3])
        XCTAssertEqual(Set(snapshot.groups.map(\.id)).count, 4, "a repo named Other is not the fallback")
    }

    func testSearchFindsTitleProjectBranchProviderAndTabNumber() {
        let snapshot = RemoteTabPickerSnapshot(orderedTabs: [
            tab(42, title: "Deploy", project: "Chau7", branch: "release", provider: "Claude"),
            tab(9, title: "Build", project: "Example")
        ])
        for query in ["deploy", "CHAU7", "release", "claude", "42"] {
            XCTAssertEqual(snapshot.filteredGroups(query: query).flatMap { $0.rows.map(\.id) }, [42])
        }
        XCTAssertEqual(snapshot.filteredGroups(query: "  "), snapshot.groups)
        XCTAssertTrue(snapshot.filteredGroups(query: "missing").isEmpty)
    }

    private func tab(
        _ id: UInt32, title: String = "Shell", project: String? = nil,
        branch: String? = "main", provider: String? = nil,
        active: Bool = false, controlled: Bool = false, pane: UUID? = nil
    ) -> RemoteTabDescriptor {
        RemoteTabDescriptor(
            tabID: id,
            title: title,
            projectName: project,
            branchName: branch,
            aiProvider: provider,
            isActive: active,
            isMCPControlled: controlled,
            inputPaneID: pane
        )
    }
}

final class RemoteTabPickerFocusTests: XCTestCase {
    func testOpeningFocusesSelectedTabEvenWhenItIsFarDownTheList() {
        var focus = RemoteTabPickerFocus()
        XCTAssertEqual(focus.target(activeTabID: 90, visibleTabIDs: Array(1 ... 100)), 90)
    }

    func testRepeatedAndChangedInventoriesDoNotResetBrowsingPosition() {
        var focus = RemoteTabPickerFocus()
        XCTAssertEqual(focus.target(activeTabID: 2, visibleTabIDs: [1, 2]), 2)
        XCTAssertNil(focus.target(activeTabID: 2, visibleTabIDs: [1, 2]))
        XCTAssertNil(focus.target(activeTabID: 2, visibleTabIDs: [3, 2, 1]))
    }

    func testLateInventoryFocusesOnceAndSelectionChangesFocusAgain() {
        var focus = RemoteTabPickerFocus()
        XCTAssertNil(focus.target(activeTabID: 0, visibleTabIDs: []))
        XCTAssertNil(focus.target(activeTabID: 2, visibleTabIDs: []))
        XCTAssertEqual(focus.target(activeTabID: 2, visibleTabIDs: [1, 2]), 2)
        XCTAssertEqual(focus.target(activeTabID: 1, visibleTabIDs: [1, 2]), 1)
        XCTAssertNil(focus.target(activeTabID: 1, visibleTabIDs: []))
        XCTAssertNil(focus.target(activeTabID: 1, visibleTabIDs: [1, 2]))
    }

    func testNewPresentationFocusesCurrentSelectionAgain() {
        var focus = RemoteTabPickerFocus()
        XCTAssertEqual(focus.target(activeTabID: 2, visibleTabIDs: [1, 2]), 2)
        var reopened = RemoteTabPickerFocus()
        XCTAssertEqual(reopened.target(activeTabID: 2, visibleTabIDs: [1, 2]), 2)
    }
}

final class RemoteTabInventoryRetentionTests: XCTestCase {
    func testAutomaticReconnectKeepsInventoryForSameMac() {
        let mac = pairing("mac-a")
        XCTAssertFalse(RemoteTabInventoryRetention.shouldClear(
            previousPairing: mac, nextPairing: mac, discardingUserIntent: false
        ))
    }

    func testExplicitDisconnectClearsInventory() {
        let mac = pairing("mac-a")
        XCTAssertTrue(RemoteTabInventoryRetention.shouldClear(
            previousPairing: mac, nextPairing: mac, discardingUserIntent: true
        ))
    }

    func testDifferentMacAndUnpairClearInventory() {
        XCTAssertTrue(RemoteTabInventoryRetention.shouldClear(
            previousPairing: pairing("mac-a"), nextPairing: pairing("mac-b"), discardingUserIntent: false
        ))
        XCTAssertTrue(RemoteTabInventoryRetention.shouldClear(
            previousPairing: pairing("mac-a"), nextPairing: nil, discardingUserIntent: false
        ))
    }

    private func pairing(_ id: String) -> RemotePairingPayload {
        RemotePairingPayload(
            relayURL: "wss://example.invalid",
            deviceID: id,
            macPub: "test-key",
            pairingCode: "test-code",
            expiresAt: ""
        )
    }
}
