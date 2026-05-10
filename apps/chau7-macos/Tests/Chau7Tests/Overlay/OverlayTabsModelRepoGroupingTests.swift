import XCTest
#if !SWIFT_PACKAGE
@testable import Chau7

@MainActor
final class OverlayTabsModelRepoGroupingTests: XCTestCase {
    private var model: OverlayTabsModel!
    private var appModel: AppModel!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        OverlayTabsModel.sessionFinders = [:]
        appModel = AppModel()
        model = OverlayTabsModel(appModel: appModel, restoreState: false)
    }

    override func tearDown() {
        model = nil
        appModel = nil
        OverlayTabsModel.sessionFinders = [:]
        UserDefaults.standard.removeObject(forKey: SavedTabState.userDefaultsKey)
        UserDefaults.standard.removeObject(forKey: SavedMultiWindowState.userDefaultsKey)
        super.tearDown()
    }

    func testAddTabToRepoGroupUsesFocusedSplitPaneRepository() {
        model.splitCurrentTabHorizontally()
        let sessions = model.tabs[0].splitController.terminalSessions
        XCTAssertEqual(sessions.count, 2)

        let secondaryPaneID = sessions[1].0
        let primarySession = sessions[0].1
        let secondarySession = sessions[1].1
        primarySession.gitRootPath = "/tmp/chau7-primary"
        secondarySession.gitRootPath = "/tmp/chau7-secondary"
        model.tabs[0].splitController.setFocusedPane(secondaryPaneID)

        model.addTabToRepoGroup(tabID: model.tabs[0].id)

        XCTAssertEqual(model.tabs[0].repoGroupID, "/tmp/chau7-secondary")
    }

    func testGroupAllSameRepoUsesFocusedSplitPaneRepository() {
        model.splitCurrentTabHorizontally()
        model.newTab()

        let firstTabSessions = model.tabs[0].splitController.terminalSessions
        XCTAssertEqual(firstTabSessions.count, 2)
        let secondaryPaneID = firstTabSessions[1].0
        let secondarySession = firstTabSessions[1].1
        model.tabs[0].session?.gitRootPath = "/tmp/chau7-primary"
        secondarySession.gitRootPath = "/tmp/chau7-shared"
        model.tabs[0].splitController.setFocusedPane(secondaryPaneID)
        model.tabs[1].session?.gitRootPath = "/tmp/chau7-shared"

        model.groupAllSameRepo(asTab: model.tabs[0].id)

        XCTAssertEqual(model.tabs[0].repoGroupID, "/tmp/chau7-shared")
        XCTAssertEqual(model.tabs[1].repoGroupID, "/tmp/chau7-shared")
    }
}
#endif
