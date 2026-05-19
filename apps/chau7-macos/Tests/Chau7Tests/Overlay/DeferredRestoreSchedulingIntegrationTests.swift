import XCTest
@testable import Chau7

@MainActor
final class DeferredRestoreSchedulingIntegrationTests: XCTestCase {
    private func makeSavedTabState(
        tabID: UUID,
        title: String,
        directory: String,
        selectedTabIDMarker: UUID?
    ) -> SavedTabState {
        SavedTabState(
            tabID: tabID.uuidString,
            selectedTabID: selectedTabIDMarker?.uuidString,
            customTitle: title,
            color: TabColor.blue.rawValue,
            directory: directory,
            selectedIndex: nil,
            tokenOptOverride: nil,
            scrollbackContent: nil,
            aiResumeCommand: nil,
            splitLayout: nil,
            focusedPaneID: nil,
            paneStates: nil
        )
    }

    func testDeferredRestoreSchedulerWaitsAfterRecentSelection() {
        let tabIDs = (0 ..< 3).map { _ in UUID() }
        let states = (0 ..< 3).map { index in
            makeSavedTabState(
                tabID: tabIDs[index],
                title: "Tab \(index)",
                directory: "/tmp/tab-\(index)",
                selectedTabIDMarker: index == 0 ? tabIDs[0] : nil
            )
        }
        let model = OverlayTabsModel(appModel: AppModel(), restoreState: false, restoringStates: states)
        model.lastSelectionChangedAt = 10

        let result = model.restoreOneDeferredTabIfAllowed(reason: "test", now: 10.2)

        if case .deferred(let delay) = result {
            XCTAssertEqual(delay, 0.25, accuracy: 0.0001)
        } else {
            XCTFail("Expected background identity restore to wait after a recent selection")
        }
        XCTAssertEqual(model.deferredRestoreTabOrder, [tabIDs[1], tabIDs[2]])
    }

    func testDeferredRestoreSchedulerPrioritizesNearestTabToSelection() {
        let tabIDs = (0 ..< 4).map { _ in UUID() }
        let states = (0 ..< 4).map { index in
            makeSavedTabState(
                tabID: tabIDs[index],
                title: "Tab \(index)",
                directory: "/tmp/tab-\(index)",
                selectedTabIDMarker: index == 1 ? tabIDs[1] : nil
            )
        }
        let model = OverlayTabsModel(appModel: AppModel(), restoreState: false, restoringStates: states)

        XCTAssertEqual(model.restoreOneDeferredTabIfAllowed(reason: "test", now: 20), .restored)

        XCTAssertFalse(model.deferredRestoreTabOrder.contains(tabIDs[2]))
        XCTAssertTrue(model.deferredRestoreTabOrder.contains(tabIDs[0]))
        XCTAssertTrue(model.deferredRestoreTabOrder.contains(tabIDs[3]))
    }
}
